import Foundation
import Observation
import PhotosUI
import SwiftData
import SwiftUI

/// Media upload job queue (SPEC §20). queued → uploading → completed | failed | paused. Only failed jobs are re-sent.
///
/// - Jobs are processed one at a time, oldest draft first, in block order.
/// - Uploads run with `RequestPriority.foregroundMedia`, so comment POSTs (`interactiveWrite`) preempt them (SPEC §29).
/// - Offline (or the remote reporting `.offline`) leaves jobs `queued`; they are never failed because of connectivity.
/// - Completion writes `remoteMediaID` / `remoteURL` back to the `DraftBlock`, so a block is never uploaded twice.
@MainActor
@Observable
final class UploadQueue {
    private(set) var isRunning = false
    /// Job currently being uploaded.
    private(set) var activeJobID: String?

    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let remote: RemoteDataSourceProvider
    @ObservationIgnored let network: NetworkModeController
    @ObservationIgnored let mediaStore: DraftMediaStore
    @ObservationIgnored private var activeTask: Task<RemoteUploadResult, Error>?
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(store: LocalStore, remote: RemoteDataSourceProvider, network: NetworkModeController,
         mediaStore: DraftMediaStore = DraftMediaStore()) {
        self.store = store
        self.remote = remote
        self.network = network
        self.mediaStore = mediaStore
        recoverInterruptedJobs()
    }

    /// True when uploads may start (network mode is not Offline and a path is available). Observable.
    var isNetworkAvailable: Bool {
        network.effectiveMode != .offline && network.pathSatisfied
    }

    /// Jobs left `uploading` by a previous process (app killed mid-upload) go back to `queued`.
    private func recoverInterruptedJobs() {
        let uploadingRaw = UploadJobState.uploading.rawValue
        let stale = store.fetch(FetchDescriptor<UploadJob>(predicate: #Predicate { $0.stateRaw == uploadingRaw }))
        guard !stale.isEmpty else { return }
        for job in stale {
            job.state = .queued
            job.progress = 0
        }
        store.save()
    }

    // MARK: Queries

    /// Jobs of a draft in block order.
    func jobs(draftID: String) -> [UploadJob] {
        store.fetch(FetchDescriptor<UploadJob>(predicate: #Predicate { $0.draftID == draftID }, sortBy: [SortDescriptor(\.order)]))
    }

    func job(id: String) -> UploadJob? { store.first(#Predicate<UploadJob> { $0.id == id }) }

    /// Jobs of a draft that still have to be uploaded (queued / uploading / paused / failed).
    func unfinishedJobs(draftID: String) -> [UploadJob] { jobs(draftID: draftID).filter { $0.state != .completed } }

    /// Image / file blocks that have neither a remote media id nor an unfinished job.
    func pendingBlockCount(draftID: String) -> Int {
        guard let draft = store.draft(id: draftID) else { return 0 }
        let jobBlockIDs = Set(unfinishedJobs(draftID: draftID).map(\.draftBlockID))
        return draft.blocks.filter {
            ($0.kind == .image || $0.kind == .file) && $0.remoteMediaID == nil && $0.localFileName != nil && !jobBlockIDs.contains($0.id)
        }.count
    }

    // MARK: Enqueue

    /// Creates an `UploadJob` for every image / file block that lacks `remoteMediaID` (in block order).
    /// Existing unfinished jobs are kept (failed stays failed — see `retryFailed`); jobs of deleted blocks are removed.
    /// Returns all jobs of the draft.
    @discardableResult
    func enqueue(draftID: String) -> [UploadJob] {
        guard let draft = store.draft(id: draftID) else { return [] }
        let blocks = draft.orderedBlocks
        let blockIDs = Set(blocks.map(\.id))
        let existing = jobs(draftID: draftID)
        for job in existing where !blockIDs.contains(job.draftBlockID) {
            discard(job)
        }
        var byBlock: [String: [UploadJob]] = [:]
        for job in existing where blockIDs.contains(job.draftBlockID) {
            byBlock[job.draftBlockID, default: []].append(job)
        }
        for block in blocks where block.kind == .image || block.kind == .file {
            var blockJobs = byBlock[block.id] ?? []
            // Unfinished jobs for a file the block no longer uses are obsolete.
            for job in blockJobs where job.state != .completed && job.localFileName != block.localFileName {
                discard(job)
            }
            blockJobs.removeAll { $0.state != .completed && $0.localFileName != block.localFileName }
            for job in blockJobs { job.order = block.order }
            guard block.remoteMediaID == nil, let local = block.localFileName else { continue }
            if blockJobs.contains(where: { $0.state != .completed && $0.localFileName == local }) { continue }
            if let done = blockJobs.first(where: { $0.state == .completed && $0.localFileName == local && $0.remoteMediaID != nil }) {
                // Uploaded before but the write-back was lost: reuse the result instead of uploading again.
                block.remoteMediaID = done.remoteMediaID
                block.remoteURL = done.remoteURL
                continue
            }
            let job = UploadJob(draftID: draftID, draftBlockID: block.id, accountID: draft.accountID,
                                fileName: block.originalFileName ?? local, localFileName: local,
                                kind: block.kind == .image ? .image : .file, bytesTotal: block.fileSize ?? 0, order: block.order)
            store.context.insert(job)
        }
        store.save()
        return jobs(draftID: draftID)
    }

    /// Keeps job order in sync with block order after a reorder.
    func syncOrder(draftID: String) {
        guard let draft = store.draft(id: draftID) else { return }
        let orderByBlock = Dictionary(draft.blocks.map { ($0.id, $0.order) }, uniquingKeysWith: { a, _ in a })
        for job in jobs(draftID: draftID) {
            if let order = orderByBlock[job.draftBlockID], job.order != order { job.order = order }
        }
    }

    // MARK: Control

    /// Pauses a queued or uploading job. An in-flight upload is cancelled.
    func pause(jobID: String) {
        guard let job = job(id: jobID) else { return }
        switch job.state {
        case .queued:
            job.state = .paused
        case .uploading:
            job.state = .paused
            if activeJobID == jobID { activeTask?.cancel() }
        case .paused, .failed, .completed:
            return
        }
        job.updatedAt = .now
        store.save()
    }

    /// Paused → queued. Starts the queue when `autoStart`.
    func resume(jobID: String, autoStart: Bool = true) {
        guard let job = job(id: jobID), job.state == .paused else { return }
        job.state = .queued
        job.progress = 0
        job.updatedAt = .now
        store.save()
        if autoStart { start() }
    }

    /// Resumes every paused job of a draft.
    func resumeAll(draftID: String, autoStart: Bool = true) {
        let paused = jobs(draftID: draftID).filter { $0.state == .paused }
        guard !paused.isEmpty else { return }
        for job in paused {
            job.state = .queued
            job.progress = 0
            job.updatedAt = .now
        }
        store.save()
        if autoStart { start() }
    }

    /// Re-queues ONLY failed jobs of the draft (SPEC §20). Completed jobs are never re-sent. Returns the number re-queued.
    @discardableResult
    func retryFailed(draftID: String, autoStart: Bool = true) -> Int {
        let failed = jobs(draftID: draftID).filter { $0.state == .failed }
        for job in failed {
            job.state = .queued
            job.progress = 0
            job.lastError = nil
            job.updatedAt = .now
        }
        if !failed.isEmpty {
            store.save()
            if autoStart { start() }
        }
        return failed.count
    }

    /// Removes the job(s) of a block (block deleted). Cancels an in-flight upload.
    func removeJobs(blockID: String) {
        let jobs = store.fetch(FetchDescriptor<UploadJob>(predicate: #Predicate { $0.draftBlockID == blockID }))
        for job in jobs { discard(job) }
        store.save()
    }

    /// Removes every job of a draft (draft deleted). Cancels an in-flight upload.
    func removeJobs(draftID: String) {
        for job in jobs(draftID: draftID) { discard(job) }
        store.save()
    }

    private func discard(_ job: UploadJob) {
        if activeJobID == job.id { activeTask?.cancel() }
        store.context.delete(job)
    }

    /// Starts processing in the background (no-op while already running).
    func start() {
        guard !isRunning else { return }
        Task { await self.run() }
    }

    // MARK: Run loop

    /// Processes queued jobs one at a time until none is left or the network goes away.
    /// When a run is already in progress, waits for it to finish instead of starting a second one.
    func run() async {
        if isRunning {
            await withCheckedContinuation { idleWaiters.append($0) }
            return
        }
        isRunning = true
        while isNetworkAvailable, let job = nextQueuedJob() {
            let keepGoing = await process(job)
            if !keepGoing { break }
        }
        isRunning = false
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Oldest draft first; within a draft, block order.
    private func nextQueuedJob() -> UploadJob? {
        let queuedRaw = UploadJobState.queued.rawValue
        let queued = store.fetch(FetchDescriptor<UploadJob>(predicate: #Predicate { $0.stateRaw == queuedRaw }))
        guard let oldest = queued.min(by: { $0.createdAt < $1.createdAt }) else { return nil }
        return queued.filter { $0.draftID == oldest.draftID }.min(by: { $0.order < $1.order })
    }

    /// Uploads one job. Returns false when the run loop should stop (offline).
    private func process(_ job: UploadJob) async -> Bool {
        let jobID = job.id
        guard let account = store.account(id: job.accountID) else {
            markFailed(job, reason: "アカウントが見つかりません")
            return true
        }
        let fileURL = mediaStore.fileURL(draftID: job.draftID, fileName: job.localFileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            markFailed(job, reason: "ローカルファイルが見つかりません")
            return true
        }

        job.state = .uploading
        job.progress = 0
        job.attemptCount += 1
        job.lastError = nil
        job.updatedAt = .now
        activeJobID = jobID
        store.save()

        let context = account.context
        let source = remote.dataSource(for: context)
        let kind = job.kind
        let onProgress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.applyProgress(jobID: jobID, value: value) }
        }
        let task = Task.detached(priority: .utility) { () async throws -> RemoteUploadResult in
            try await RequestContext.$priority.withValue(.foregroundMedia) {
                switch kind {
                case .image: return try await source.uploadImage(fileURL: fileURL, account: context, progress: onProgress)
                case .file: return try await source.uploadFile(fileURL: fileURL, account: context, progress: onProgress)
                }
            }
        }
        activeTask = task
        let outcome = await task.result
        activeTask = nil
        activeJobID = nil

        // The job may have been deleted (block / draft removed) while uploading.
        guard let job = self.job(id: jobID) else { return true }
        switch outcome {
        case .success(let result):
            job.state = .completed
            job.progress = 1
            job.remoteMediaID = result.mediaID
            job.remoteURL = result.url
            job.lastError = nil
            job.updatedAt = .now
            let blockID = job.draftBlockID
            if let block = store.first(#Predicate<DraftBlock> { $0.id == blockID }), block.localFileName == job.localFileName {
                block.remoteMediaID = result.mediaID
                block.remoteURL = result.url
            }
            store.save()
            return true
        case .failure(let error):
            let remoteError = RemoteError.creatorWrapping(error)
            if job.state == .paused {
                job.progress = 0
                store.save()
                return true
            }
            switch remoteError {
            case .offline, .blockedByPolicy, .cancelled:
                // Connectivity / policy / cancellation: stay queued and stop; the next run picks it up again.
                job.state = .queued
                job.progress = 0
                job.updatedAt = .now
                store.save()
                return false
            default:
                if !isNetworkAvailable {
                    job.state = .queued
                    job.progress = 0
                    store.save()
                    return false
                }
                markFailed(job, reason: remoteError.userMessage)
                AppLog.creator.error("upload failed: \(remoteError.userMessage, privacy: .public)")
                return true
            }
        }
    }

    private func markFailed(_ job: UploadJob, reason: String) {
        job.state = .failed
        job.lastError = reason
        job.updatedAt = .now
        store.save()
    }

    private func applyProgress(jobID: String, value: Double) {
        guard let job = job(id: jobID), job.state == .uploading else { return }
        let clamped = min(max(value, 0), 1)
        if clamped > job.progress { job.progress = clamped }
    }
}

/// Progress of a PhotosPicker / file import into a draft.
struct DraftImportProgress: Equatable, Sendable {
    var draftID: String
    var completed: Int
    var total: Int
}

/// Result of adding several media items.
struct DraftImportReport: Equatable, Sendable {
    var added: Int = 0
    var failures: [String] = []
}

/// Local drafts, native editor operations, Post Edit import and publish (SPEC §18 / §19).
@MainActor
@Observable
final class DraftService {
    /// Draft ids with a publish in flight.
    private(set) var publishingDraftIDs: Set<String> = []
    private(set) var importProgress: DraftImportProgress?
    /// Time of the last autosave write.
    private(set) var lastAutosaveAt: Date?

    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let uploads: UploadQueue
    @ObservationIgnored let remote: RemoteDataSourceProvider
    @ObservationIgnored let web: WebBridge
    /// Debounce interval of autosave (SPEC §19).
    @ObservationIgnored var autosaveDelay: Duration = .milliseconds(500)
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(store: LocalStore, uploads: UploadQueue, remote: RemoteDataSourceProvider, web: WebBridge) {
        self.store = store
        self.uploads = uploads
        self.remote = remote
        self.web = web
        recoverInterruptedPublishes()
    }

    var mediaStore: DraftMediaStore { uploads.mediaStore }

    /// Drafts left `uploading` / `publishing` by a previous process are marked failed (content untouched).
    private func recoverInterruptedPublishes() {
        let uploadingRaw = DraftStatus.uploading.rawValue
        let publishingRaw = DraftStatus.publishing.rawValue
        let stale = store.fetch(FetchDescriptor<Draft>(predicate: #Predicate { $0.statusRaw == uploadingRaw || $0.statusRaw == publishingRaw }))
        guard !stale.isEmpty else { return }
        for draft in stale {
            draft.status = .failed
            draft.lastError = "前回の送信が中断されました。FANBOX 側の状態を確認してから再送してください。"
        }
        store.save()
    }

    func isPublishing(_ draftID: String) -> Bool { publishingDraftIDs.contains(draftID) }

    /// Local file of an image / file block (nil when the block has no local copy, e.g. imported by Post Edit).
    func localFileURL(for block: DraftBlock) -> URL? {
        guard let name = block.localFileName else { return nil }
        return mediaStore.fileURL(draftID: block.draftID, fileName: name)
    }

    // MARK: Create / edit

    /// New local draft with one empty text block. Works offline.
    @discardableResult
    func createDraft(accountID: String) -> Draft {
        let draft = Draft(accountID: accountID, creatorID: store.account(id: accountID)?.creatorID)
        store.context.insert(draft)
        let block = DraftBlock(draftID: draft.id, order: 0, kind: .text)
        store.context.insert(block)
        draft.blocks.append(block)
        store.save()
        return draft
    }

    /// Appends a block (or inserts it after `after`).
    @discardableResult
    func addBlock(_ kind: DraftBlockKind, to draft: Draft, text: String = "", after: DraftBlock? = nil) -> DraftBlock {
        let block = DraftBlock(draftID: draft.id, order: 0, kind: kind, text: text)
        if kind == .embed { block.embedProvider = DraftEmbedProvider.youtube.rawValue }
        insert(block, into: draft, after: after)
        touch(draft)
        return block
    }

    private func insert(_ block: DraftBlock, into draft: Draft, after: DraftBlock? = nil) {
        var ordered = draft.orderedBlocks
        store.context.insert(block)
        draft.blocks.append(block)
        if let after, let index = ordered.firstIndex(where: { $0.id == after.id }) {
            ordered.insert(block, at: index + 1)
        } else {
            ordered.append(block)
        }
        for (i, b) in ordered.enumerated() where b.order != i { b.order = i }
    }

    /// Adds images from PhotosPicker, preserving selection order (max 20). Each image is resized / converted if needed.
    @discardableResult
    func addImages(from items: [PhotosPickerItem], to draftID: String) async -> DraftImportReport {
        let items = Array(items.prefix(20))
        var report = DraftImportReport()
        guard !items.isEmpty else { return report }
        importProgress = DraftImportProgress(draftID: draftID, completed: 0, total: items.count)
        defer { importProgress = nil }
        for (index, item) in items.enumerated() {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw DraftMediaError.unreadableImage }
                _ = try await addImage(data: data, to: draftID)
                report.added += 1
            } catch {
                report.failures.append("画像 \(index + 1): \((error as? LocalizedError)?.errorDescription ?? "読み込めませんでした")")
            }
            importProgress = DraftImportProgress(draftID: draftID, completed: index + 1, total: items.count)
        }
        return report
    }

    /// Adds one image from raw data (PhotosPicker / tests). Processing runs off the main actor.
    @discardableResult
    func addImage(data: Data, to draftID: String) async throws -> DraftBlock {
        guard let draft = store.draft(id: draftID) else { throw DraftMediaError.io("draft not found") }
        let number = draft.blocks.filter { $0.kind == .image }.count + 1
        let media = mediaStore
        let item = try await Task.detached(priority: .userInitiated) {
            try media.storeImage(data: data, draftID: draftID, displayBaseName: "\(number)")
        }.value
        guard let draft = store.draft(id: draftID) else {
            media.removeFile(draftID: draftID, fileName: item.fileName)
            throw DraftMediaError.io("draft not found")
        }
        let block = DraftBlock(draftID: draftID, order: 0, kind: .image)
        apply(item, to: block)
        insert(block, into: draft)
        touch(draft)
        return block
    }

    /// Adds an attachment picked with `fileImporter` (copied into draft storage).
    @discardableResult
    func addFile(url: URL, to draftID: String) async throws -> DraftBlock {
        guard store.draft(id: draftID) != nil else { throw DraftMediaError.io("draft not found") }
        let media = mediaStore
        let item = try await Task.detached(priority: .userInitiated) {
            try media.importFile(from: url, draftID: draftID)
        }.value
        guard let draft = store.draft(id: draftID) else {
            media.removeFile(draftID: draftID, fileName: item.fileName)
            throw DraftMediaError.io("draft not found")
        }
        let block = DraftBlock(draftID: draftID, order: 0, kind: .file)
        apply(item, to: block)
        insert(block, into: draft)
        touch(draft)
        return block
    }

    private func apply(_ item: DraftMediaItem, to block: DraftBlock) {
        block.localFileName = item.fileName
        block.originalFileName = item.originalFileName
        block.mimeType = item.mimeType
        block.fileSize = item.size
        block.width = item.width
        block.height = item.height
    }

    /// Reorders blocks (List `.onMove`).
    func moveBlocks(in draft: Draft, from source: IndexSet, to destination: Int) {
        var ordered = draft.orderedBlocks
        ordered.move(fromOffsets: source, toOffset: destination)
        for (i, block) in ordered.enumerated() where block.order != i { block.order = i }
        uploads.syncOrder(draftID: draft.id)
        touch(draft)
    }

    /// Moves one block up (-1) or down (+1).
    func moveBlock(_ block: DraftBlock, by offset: Int) {
        guard let draft = block.draft ?? store.draft(id: block.draftID) else { return }
        let ordered = draft.orderedBlocks
        guard let index = ordered.firstIndex(where: { $0.id == block.id }) else { return }
        let target = index + offset
        guard target >= 0, target < ordered.count else { return }
        moveBlocks(in: draft, from: IndexSet(integer: index), to: offset > 0 ? target + 1 : target)
    }

    /// Deletes a block, its local media file and its upload job.
    func deleteBlock(_ block: DraftBlock) {
        let draft = block.draft ?? store.draft(id: block.draftID)
        uploads.removeJobs(blockID: block.id)
        if let name = block.localFileName {
            let stillUsed = draft?.blocks.contains { $0.id != block.id && $0.localFileName == name } ?? false
            if !stillUsed { mediaStore.removeFile(draftID: block.draftID, fileName: name) }
        }
        draft?.blocks.removeAll { $0.id == block.id }
        store.context.delete(block)
        if let draft {
            for (i, b) in draft.orderedBlocks.enumerated() where b.order != i { b.order = i }
            touch(draft)
        } else {
            store.save()
        }
    }

    // MARK: Autosave

    /// Marks the draft as edited (updatedAt = now) and schedules a debounced save. Works offline.
    func touch(_ draft: Draft) {
        draft.updatedAt = .now
        if draft.status == .published || draft.status == .readyToPublish {
            // Local changes not yet sent; the next publish updates `remotePostID`.
            draft.status = .local
        }
        scheduleSave()
    }

    func scheduleSave() {
        pendingSave?.cancel()
        let delay = autosaveDelay
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes pending edits immediately (leaving the editor, before publish, tests).
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        store.save()
        lastAutosaveAt = .now
    }

    var hasPendingSave: Bool { pendingSave != nil }

    // MARK: Post Edit

    /// Imports an existing FANBOX post into a local draft ("Post Edit"). Image / file blocks keep their
    /// `remoteMediaID`, so nothing is uploaded again. An unsent local edit of the same post is reused.
    func importRemotePost(postID: String, accountID: String) async throws -> Draft {
        let existing = store.fetch(FetchDescriptor<Draft>(predicate: #Predicate { $0.accountID == accountID },
                                                          sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
            .filter { $0.remotePostID == postID }
        if let draft = existing.first(where: { $0.status != .published && $0.status != .readyToPublish }) {
            return draft
        }
        guard let account = store.account(id: accountID) else { throw RemoteError.invalidRequest("アカウントが見つかりません") }
        guard uploads.isNetworkAvailable else { throw RemoteError.offline }
        let context = account.context
        let source = remote.dataSource(for: context)
        let editable: RemoteEditablePost
        do {
            editable = try await RequestContext.$priority.withValue(.interactiveRead) {
                try await source.editablePost(id: postID, account: context)
            }
        } catch {
            throw RemoteError.creatorWrapping(error)
        }

        let draft = Draft(accountID: accountID, creatorID: account.creatorID, remotePostID: editable.id, title: editable.title,
                          targetPlanID: editable.planID, feeRequired: editable.feeRequired)
        draft.tags = editable.tags
        draft.hasAdultContent = editable.hasAdultContent
        store.context.insert(draft)
        var order = 0
        for remoteBlock in editable.blocks {
            guard let imported = DraftPostMapping.importedBlock(from: remoteBlock) else { continue }
            let block = DraftBlock(draftID: draft.id, order: order, kind: imported.kind, text: imported.text)
            block.remoteMediaID = imported.remoteMediaID
            block.remoteURL = imported.remoteURL
            block.originalFileName = imported.originalFileName
            block.fileSize = imported.fileSize
            block.width = imported.width
            block.height = imported.height
            block.url = imported.url
            block.embedProvider = imported.embedProvider
            block.embedContentID = imported.embedContentID
            store.context.insert(block)
            draft.blocks.append(block)
            order += 1
        }
        if draft.blocks.isEmpty {
            let block = DraftBlock(draftID: draft.id, order: 0, kind: .text)
            store.context.insert(block)
            draft.blocks.append(block)
        }
        store.save()
        return draft
    }

    // MARK: Publish

    /// Pure mapping Draft → create / update payload (see `DraftPostMapping`).
    func remotePostDraft(from draft: Draft, publish: Bool = true) throws -> RemotePostDraft {
        try DraftPostMapping.remotePostDraft(from: draft, publish: publish)
    }

    /// Uploads pending media (waits for completion), then creates or updates the FANBOX post.
    /// `publish` false = "FANBOX に下書き保存". On any failure the draft is kept intact with `lastError`.
    func publish(draftID: String, publish: Bool) async -> Result<String, RemoteError> {
        guard let draft = store.draft(id: draftID) else { return .failure(.notFound) }
        guard !publishingDraftIDs.contains(draftID) else { return .failure(.invalidRequest("送信中です")) }
        publishingDraftIDs.insert(draftID)
        defer { publishingDraftIDs.remove(draftID) }
        saveNow()
        draft.lastError = nil

        guard let account = store.account(id: draft.accountID) else {
            return fail(draft, .invalidRequest("アカウントが見つかりません"))
        }
        guard account.creatorID != nil else {
            return fail(draft, .invalidRequest("このアカウントには Creator ページがありません"))
        }
        if publish && draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fail(draft, .invalidRequest("タイトルを入力してください"))
        }

        // 1. Media uploads (only blocks without remoteMediaID; failed jobs are retried, completed ones never re-sent).
        uploads.enqueue(draftID: draftID)
        uploads.retryFailed(draftID: draftID, autoStart: false)
        uploads.resumeAll(draftID: draftID, autoStart: false)
        if !uploads.unfinishedJobs(draftID: draftID).isEmpty {
            guard uploads.isNetworkAvailable else { return fail(draft, .offline) }
            draft.status = .uploading
            store.save()
            await uploads.run()
            // Another run may have been in progress; drain anything still queued for this draft.
            if uploads.unfinishedJobs(draftID: draftID).contains(where: { $0.state == .queued }) && uploads.isNetworkAvailable {
                await uploads.run()
            }
        }
        let unfinished = uploads.unfinishedJobs(draftID: draftID)
        let failedCount = unfinished.filter { $0.state == .failed }.count
        if failedCount > 0 {
            return fail(draft, .invalidRequest("アップロードに失敗した項目があります（\(failedCount) 件）"))
        }
        if !unfinished.isEmpty {
            return fail(draft, uploads.isNetworkAvailable ? .invalidRequest("アップロードが完了していません") : .offline)
        }

        // 2. Payload.
        let payload: RemotePostDraft
        do {
            payload = try DraftPostMapping.remotePostDraft(from: draft, publish: publish)
        } catch {
            return fail(draft, RemoteError.creatorWrapping(error))
        }
        guard uploads.isNetworkAvailable else { return fail(draft, .offline) }

        // 3. Create / update with interactiveWrite priority.
        draft.status = .publishing
        store.save()
        let context = account.context
        let source = remote.dataSource(for: context)
        let existingID = draft.remotePostID
        do {
            let postID: String = try await RequestContext.$priority.withValue(.interactiveWrite) {
                if let existingID {
                    try await source.updatePost(id: existingID, payload, account: context)
                    return existingID
                }
                return try await source.createPost(payload, account: context)
            }
            guard let draft = store.draft(id: draftID) else { return .success(postID) }
            draft.remotePostID = postID
            draft.status = publish ? .published : .readyToPublish
            if publish { draft.publishedAt = .now }
            draft.lastError = nil
            store.save()
            return .success(postID)
        } catch {
            let remoteError = RemoteError.creatorWrapping(error)
            AppLog.creator.error("publish failed: \(remoteError.userMessage, privacy: .public)")
            guard let draft = store.draft(id: draftID) else { return .failure(remoteError) }
            return fail(draft, remoteError)
        }
    }

    private func fail(_ draft: Draft, _ error: RemoteError) -> Result<String, RemoteError> {
        draft.status = .failed
        draft.lastError = error.userMessage
        store.save()
        return .failure(error)
    }

    // MARK: Delete

    /// Deletes a local draft, its blocks, upload jobs and media files. Never touches the FANBOX post.
    func deleteDraft(draftID: String) {
        uploads.removeJobs(draftID: draftID)
        if let draft = store.draft(id: draftID) {
            for block in draft.blocks { store.context.delete(block) }
            store.context.delete(draft)
        }
        mediaStore.removeAll(draftID: draftID)
        store.save()
    }
}

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
        let context = account.context
        let source = remote.dataSource(for: context)
        guard source.draftCapabilities.uploadsMedia else {
            // This account uploads in the web editor (SPEC §40): never a failure, never retried here.
            pauseForWeb(draftID: job.draftID)
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
            case .unsupported:
                // The data source cannot upload: hand over to the web editor instead of failing / retrying.
                pauseForWeb(draftID: job.draftID)
                return true
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

    /// Shown on jobs of accounts that upload in the web editor.
    static let webOnlyMessage = "Web エディタで追加してください"

    /// Pauses every unfinished job of the draft with `webOnlyMessage` (the account cannot upload natively).
    /// Such jobs are never counted as failed and never retried automatically.
    func pauseForWeb(draftID: String) {
        var changed = false
        for job in jobs(draftID: draftID) where job.state != .completed && job.id != activeJobID {
            if job.state != .paused || job.lastError != Self.webOnlyMessage {
                job.state = .paused
                job.progress = 0
                job.lastError = Self.webOnlyMessage
                job.updatedAt = .now
                changed = true
            }
        }
        if changed { store.save() }
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

    /// Text of a block changed (editor binding). Text equal to what FANBOX holds (e.g. rewritten after a send split a
    /// multi-line block into paragraphs) is saved without marking the draft as locally changed.
    func blockTextChanged(_ block: DraftBlock, in draft: Draft) {
        if let imported = block.importedText, imported == block.text, draft.status == .published || draft.status == .readyToPublish {
            scheduleSave()
        } else {
            touch(draft)
        }
    }

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

    // MARK: Capabilities

    /// What the account's data source can write natively (decided before any send).
    func capabilities(accountID: String) -> DraftCapabilities {
        guard let account = store.account(id: accountID) else { return .webOnly }
        return remote.dataSource(for: account.context).draftCapabilities
    }

    /// Plan of a send with the locally known FANBOX state (for the editor's badges, banners and confirmation).
    func plan(draftID: String, publish: Bool) -> DraftSendPlan? {
        guard let draft = store.draft(id: draftID) else { return nil }
        return DraftSendPlanner.plan(draft: draft, capabilities: capabilities(accountID: draft.accountID), publish: publish)
    }

    // MARK: Post Edit

    /// Imports an existing FANBOX post into a local draft ("Post Edit"). Image / file / link card / embed blocks keep their
    /// FANBOX ids (nothing is uploaded again), paragraphs keep their text styles and empty spacing paragraphs, and the
    /// FANBOX status / fee / comment permission / revision are recorded so a later send never changes them by accident.
    /// Content that cannot be written back natively is kept visibly and blocks the native update (web editor instead).
    /// An unsent local edit of the same post is reused.
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
        let capabilities = source.draftCapabilities
        let editable: RemoteEditablePost
        do {
            editable = try await RequestContext.$priority.withValue(.interactiveRead) {
                try await source.editablePost(id: postID, account: context)
            }
        } catch {
            throw RemoteError.creatorWrapping(error)
        }

        let draft = Draft(accountID: accountID, creatorID: account.creatorID, remotePostID: editable.id, title: editable.title,
                          targetPlanID: editable.planID ?? matchingPlanID(creatorID: account.creatorID, fee: editable.feeRequired),
                          feeRequired: editable.feeRequired)
        draft.tags = editable.tags
        draft.hasAdultContent = editable.hasAdultContent
        draft.remoteStatusRaw = editable.status.rawValue
        draft.remoteFeeRequired = editable.feeRequired
        draft.remoteUpdatedAt = editable.updatedAt
        draft.commentPermission = editable.commentPermission
        if !editable.tagsKnown {
            draft.tagsUnverified = true
            // Best effort: the reader-side listing of the same post may know its tags.
            if draft.tags.isEmpty, let cached = store.post(id: postID)?.fanboxTags, !cached.isEmpty { draft.tags = cached }
        }
        if editable.status == .published || editable.status == .scheduled { draft.publishedAt = editable.publishedAt }
        store.context.insert(draft)

        var unsupported: [String] = []
        var order = 0
        for remoteBlock in editable.blocks {
            let imported = DraftPostMapping.importedBlock(from: remoteBlock)
            if let reason = imported.unsupportedReason, !unsupported.contains(reason) { unsupported.append(reason) }
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
            block.importedText = imported.importedText
            block.importedStyles = imported.styles
            block.isLockedRemote = imported.isLocked
            store.context.insert(block)
            draft.blocks.append(block)
            order += 1
        }
        if draft.blocks.isEmpty {
            let block = DraftBlock(draftID: draft.id, order: 0, kind: .text)
            store.context.insert(block)
            draft.blocks.append(block)
        }
        draft.nativeUpdateBlocker = Self.nativeUpdateBlocker(editable: editable, unsupportedBlocks: unsupported, capabilities: capabilities)
        store.save()
        return draft
    }

    /// Why a native update of this post would not be faithful (nil = it can be updated natively).
    static func nativeUpdateBlocker(editable: RemoteEditablePost, unsupportedBlocks: [String], capabilities: DraftCapabilities) -> String? {
        if editable.status == .scheduled { return DraftSendPlanner.scheduledBlocker }
        if editable.postType != .article && !capabilities.updatesNonArticlePosts {
            return "「\(editable.postType.creatorLabel)」形式の投稿はアプリから更新できません（本文が記事形式に変わってしまうため）。Web エディタで編集してください。"
        }
        if !unsupportedBlocks.isEmpty {
            return "アプリで扱えない内容があります（\(unsupportedBlocks.joined(separator: "、"))）。内容を失わないよう、Web エディタで編集してください。"
        }
        return nil
    }

    /// FANBOX gates posts by minimum fee; the plan with exactly that fee (if the plans are known locally).
    private func matchingPlanID(creatorID: String?, fee: Int) -> String? {
        guard let creatorID, fee > 0 else { return nil }
        let matches = store.plans(creatorID: creatorID).filter { $0.fee == fee }
        return matches.count == 1 ? matches.first?.planID : nil
    }

    // MARK: Publish

    /// Pure mapping Draft → create / update payload (see `DraftPostMapping`).
    func remotePostDraft(from draft: Draft, publish: Bool = true) throws -> RemotePostDraft {
        try DraftPostMapping.remotePostDraft(from: draft, publish: publish)
    }

    /// Compatibility wrapper of `send` (no warnings accepted, never unpublishes). Returns the post id.
    func publish(draftID: String, publish: Bool) async -> Result<String, RemoteError> {
        await send(draftID: draftID, publish: publish).map(\.postID)
    }

    static let conflictMessage = "FANBOX 側で投稿が更新されています（Web エディタなど）。上書きしないよう送信を中止しました。ローカル下書きを削除して「編集」から読み込み直すか、Web エディタで編集してください。"

    /// Sends the draft: uploads pending media (when the account can), then creates or updates the FANBOX post.
    ///
    /// - `publish`: the creator's choice — true = publish (or keep a live post published), false = FANBOX draft.
    /// - Taking a live post down (`publish == false` on a published post) requires `allowUnpublish`; otherwise nothing is sent.
    /// - Warnings of the plan (formatting loss, unknown tags / comment permission) require `acceptWarnings`.
    /// - An existing post is re-read first: a newer FANBOX revision (edited elsewhere) or a changed publish status stops the
    ///   send, so local content never overwrites work done in the web editor.
    /// - Accounts that cannot upload / create link cards / embeds get a text-first send: everything else is saved and the
    ///   receipt lists what to add in the web editor. A new post is then saved as a FANBOX draft, never published unfinished.
    /// - A create whose content save failed stores the new post id first, so the retry updates that post (no duplicates).
    /// On any failure the local draft stays intact with `lastError`.
    func send(draftID: String, publish: Bool, acceptWarnings: Bool = false,
              allowUnpublish: Bool = false) async -> Result<DraftSendReceipt, RemoteError> {
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
        let context = account.context
        let source = remote.dataSource(for: context)
        let capabilities = source.draftCapabilities

        // 0. Plan with what is known locally (no request yet).
        var plan = DraftSendPlanner.plan(draft: draft, capabilities: capabilities, publish: publish)
        if let refusal = refusal(of: plan, draft: draft, acceptWarnings: acceptWarnings, allowUnpublish: allowUnpublish) {
            return refusal
        }
        guard uploads.isNetworkAvailable else { return fail(draft, .offline) }

        // 1. Existing post: re-read its current state before uploading / writing anything.
        if let postID = draft.remotePostID {
            let previousStatus = draft.status
            draft.status = .publishing
            store.save()
            let current: RemoteEditablePost
            do {
                current = try await RequestContext.$priority.withValue(.interactiveRead) {
                    try await source.editablePost(id: postID, account: context)
                }
            } catch {
                guard let draft = store.draft(id: draftID) else { return .failure(RemoteError.creatorWrapping(error)) }
                return fail(draft, RemoteError.creatorWrapping(error))
            }
            guard let draft = store.draft(id: draftID) else { return .failure(.notFound) }
            let known = draft.remoteStatus
            draft.remoteStatusRaw = current.status.rawValue
            if let base = draft.remoteUpdatedAt, let now = current.updatedAt, now.timeIntervalSince(base) > 1 {
                return fail(draft, .invalidRequest(Self.conflictMessage))
            }
            if let known, known != .unknown, known != current.status {
                return fail(draft, .invalidRequest("FANBOX 側で公開状態が「\(current.status.creatorLabel)」に変わっています。内容を確認してから送信し直してください。"))
            }
            plan = DraftSendPlanner.plan(draft: draft, capabilities: capabilities, publish: publish, remoteStatus: current.status)
            if let refusal = refusal(of: plan, draft: draft, acceptWarnings: acceptWarnings, allowUnpublish: allowUnpublish) {
                if draft.status == .publishing { draft.status = previousStatus }
                store.save()
                return refusal
            }
        }
        guard let draft = store.draft(id: draftID) else { return .failure(.notFound) }

        // 2. Media uploads (only blocks without remoteMediaID; failed jobs are retried, completed ones never re-sent).
        if capabilities.uploadsMedia {
            if let failure = await runUploads(for: draft) { return failure }
        } else {
            uploads.pauseForWeb(draftID: draftID)
        }
        guard let draft = store.draft(id: draftID) else { return .failure(.notFound) }

        // 3. Payload (text-first: blocks for the web editor are left out).
        let payload: DraftPostMapping.Payload
        do {
            payload = try DraftPostMapping.payload(from: draft, publish: plan.sendsPublished, capabilities: capabilities)
        } catch {
            return fail(draft, RemoteError.creatorWrapping(error))
        }
        guard uploads.isNetworkAvailable else { return fail(draft, .offline) }

        // 4. Create / update with interactiveWrite priority.
        draft.status = .publishing
        store.save()
        let existingID = draft.remotePostID
        let body = payload.draft
        let webIDs = payload.webItemBlockIDs
        do {
            let postID: String = try await RequestContext.$priority.withValue(.interactiveWrite) {
                if let existingID {
                    try await source.updatePost(id: existingID, body, account: context)
                    return existingID
                }
                return try await source.createPost(body, account: context)
            }
            guard let draft = store.draft(id: draftID) else {
                return .success(DraftSendReceipt(postID: postID, sentPublished: body.publish, webItems: []))
            }
            commitSent(draft, postID: postID, published: body.publish, leavesWebItems: !webIDs.isEmpty)
            let webItems = DraftSendPlanner.webItems(for: draft, blockIDs: webIDs)
            // 5. Revision baseline for the next conflict check (best effort read).
            if let fresh = try? await RequestContext.$priority.withValue(.interactiveRead, operation: {
                try await source.editablePost(id: postID, account: context)
            }), let draft = store.draft(id: draftID) {
                draft.remoteUpdatedAt = fresh.updatedAt ?? draft.remoteUpdatedAt
                draft.remoteStatusRaw = fresh.status.rawValue
                if let permission = fresh.commentPermission { draft.commentPermission = permission }
                store.save()
            }
            return .success(DraftSendReceipt(postID: postID, sentPublished: body.publish, webItems: webItems))
        } catch let partial as RemotePostCreatedPartially {
            AppLog.creator.error("post created but content not saved: \(partial.underlying.userMessage, privacy: .public)")
            guard let draft = store.draft(id: draftID) else { return .failure(partial.underlying) }
            // Persist the new id FIRST: the retry updates this post instead of creating another one.
            draft.remotePostID = partial.postID
            draft.remoteStatusRaw = RemotePostStatus.draft.rawValue
            draft.remoteFeeRequired = nil
            draft.remoteUpdatedAt = nil
            // A post this app just created has no comment setting of the creator's to preserve.
            if draft.commentPermission == nil { draft.commentPermission = .default(feeRequired: draft.feeRequired) }
            return fail(draft, partial.underlying,
                        message: "FANBOX に下書きを作成しましたが、内容の保存に失敗しました（\(partial.underlying.userMessage)）。再送すると同じ下書きを更新します。")
        } catch {
            let remoteError = RemoteError.creatorWrapping(error)
            AppLog.creator.error("publish failed: \(remoteError.userMessage, privacy: .public)")
            guard let draft = store.draft(id: draftID) else { return .failure(remoteError) }
            return fail(draft, remoteError)
        }
    }

    /// A plan that must not be sent as requested → the failure to return (local status untouched for confirmations).
    private func refusal(of plan: DraftSendPlan, draft: Draft, acceptWarnings: Bool,
                         allowUnpublish: Bool) -> Result<DraftSendReceipt, RemoteError>? {
        if let validation = plan.validationError { return fail(draft, validation) }
        if let blocker = plan.blockers.first { return fail(draft, .unsupported(operation: blocker), message: blocker) }
        if plan.unpublishes && !allowUnpublish {
            return .failure(.invalidRequest("公開中の投稿を非公開（下書き）に戻す操作です。確認してから送信してください。"))
        }
        if !plan.warnings.isEmpty && !acceptWarnings {
            return .failure(.invalidRequest("確認が必要です: " + plan.warnings.joined(separator: " ")))
        }
        return nil
    }

    /// Uploads the draft's pending media and waits. Returns a failure when something is left.
    private func runUploads(for draft: Draft) async -> Result<DraftSendReceipt, RemoteError>? {
        let draftID = draft.id
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
        guard let draft = store.draft(id: draftID) else { return .failure(.notFound) }
        let unfinished = uploads.unfinishedJobs(draftID: draftID)
        let failedCount = unfinished.filter { $0.state == .failed }.count
        if failedCount > 0 {
            return fail(draft, .invalidRequest("アップロードに失敗した項目があります（\(failedCount) 件）"))
        }
        if !unfinished.isEmpty {
            return fail(draft, uploads.isNetworkAvailable ? .invalidRequest("アップロードが完了していません") : .offline)
        }
        return nil
    }

    /// Records a successful send: FANBOX status / fee, and the sent text as the new baseline of every paragraph
    /// (a multi-line text block becomes one block per paragraph, exactly like the post on FANBOX).
    private func commitSent(_ draft: Draft, postID: String, published: Bool, leavesWebItems: Bool) {
        // A new post got the default comment permission (or the one sent): later updates keep it without asking.
        if draft.remotePostID == nil && draft.commentPermission == nil {
            draft.commentPermission = .default(feeRequired: draft.feeRequired)
        }
        draft.remotePostID = postID
        draft.remoteStatusRaw = (published ? RemotePostStatus.published : RemotePostStatus.draft).rawValue
        draft.remoteFeeRequired = draft.feeRequired
        draft.status = published ? .published : .readyToPublish
        if published && draft.publishedAt == nil { draft.publishedAt = .now }
        if !published { draft.publishedAt = nil }
        draft.lastError = nil
        draft.webHandoffAt = leavesWebItems ? .now : nil

        var ordered = draft.orderedBlocks
        var index = 0
        while index < ordered.count {
            let block = ordered[index]
            index += 1
            guard block.kind == .text || block.kind == .header, !block.isLockedRemote else { continue }
            if let imported = block.importedText, imported == block.text { continue }
            guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let styles = DraftPostMapping.sentStyles(of: block).styles
            guard block.kind == .text else {
                block.importedText = block.text
                block.importedStyles = styles
                continue
            }
            let paragraphs = DraftPostMapping.paragraphs(of: block.text, styles: styles)
            guard let first = paragraphs.first else { continue }
            block.text = first.text
            block.importedText = first.text
            block.importedStyles = first.styles
            var insertAt = index
            for paragraph in paragraphs.dropFirst() {
                let extra = DraftBlock(draftID: draft.id, order: 0, kind: .text, text: paragraph.text)
                extra.importedText = paragraph.text
                extra.importedStyles = paragraph.styles
                store.context.insert(extra)
                draft.blocks.append(extra)
                ordered.insert(extra, at: insertAt)
                insertAt += 1
            }
            index = insertAt
        }
        for (i, block) in ordered.enumerated() where block.order != i { block.order = i }
        uploads.syncOrder(draftID: draft.id)
        store.save()
    }

    private func fail<T>(_ draft: Draft, _ error: RemoteError, message: String? = nil) -> Result<T, RemoteError> {
        draft.status = .failed
        draft.lastError = message ?? error.userMessage
        store.save()
        return .failure(error)
    }

    // MARK: Web editor hand-off (SPEC §40)

    /// Processed local media of the items left for the web editor, copied under their display names (numbered in body
    /// order) so the web editor's file picker can reach them via Files / Photos. Keyed by item (block) id.
    func exportWebItemFiles(draftID: String, items: [DraftWebItem]) -> [String: URL] {
        let media = items.filter { $0.localFileName != nil }
        let urls = mediaStore.exportCopies(draftID: draftID, files: media.map { item in
            (fileName: item.localFileName ?? "", displayName: item.title, position: item.position)
        })
        var result: [String: URL] = [:]
        for (item, url) in zip(media, urls) {
            if let url { result[item.id] = url }
        }
        return result
    }

    /// How the creator finished the post in the web editor.
    enum WebCompletion {
        case published
        case savedAsDraft
    }

    /// Marks the draft as finished in the web editor. The FANBOX post is now the reference: the local copy keeps its
    /// content but a later native send is refused as a conflict (the revision on FANBOX changed).
    func markCompletedOnWeb(draftID: String, as completion: WebCompletion) {
        guard let draft = store.draft(id: draftID) else { return }
        draft.webHandoffAt = nil
        draft.lastError = nil
        switch completion {
        case .published:
            draft.status = .published
            draft.remoteStatusRaw = RemotePostStatus.published.rawValue
            if draft.publishedAt == nil { draft.publishedAt = .now }
        case .savedAsDraft:
            draft.status = .readyToPublish
            if draft.remoteStatusRaw == nil { draft.remoteStatusRaw = RemotePostStatus.draft.rawValue }
        }
        store.save()
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

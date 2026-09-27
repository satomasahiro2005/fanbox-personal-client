import CryptoKit
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
/// - Completion writes `remoteMediaID` / `remoteURL` / the upload result back to the `DraftBlock`, so a block is never
///   uploaded twice.
/// - Sources that store uploads INTO a post (`DraftCapabilities.uploadsNeedPost`, FANBOX) upload against the draft's
///   `remotePostID`. A draft without one (a new post) has its jobs paused with `awaitingPostMessage`: `DraftService.send`
///   creates the FANBOX draft first and then resumes them. Jobs the app could never save into that post (a draft blocked
///   from native updates, or a block kind the post type cannot hold) are paused instead of leaving orphan assets.
/// - Outside a send (upload button, connectivity auto-start), an upload into an existing post first re-reads the post
///   once per run: a revision newer than the draft's baseline (edited elsewhere) pauses the draft's jobs with
///   `conflictMessage`; after each upload the post's new revision becomes the baseline, so the app's own uploads never
///   look like an edit made elsewhere. During a send, `DraftService` does both itself.
/// - The file is sent under the block's display name (a per-job staging link, made and removed inside the upload task).
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
    /// Drafts whose post a running `DraftService.send` has just checked (it also re-reads the revision afterwards).
    @ObservationIgnored private var sendCheckedDraftIDs: Set<String> = []
    /// Drafts whose FANBOX revision this run has already checked.
    @ObservationIgnored private var revisionCheckedDraftIDs: Set<String> = []
    /// Content of each checked post (`RemoteEditablePost.contentFingerprint`): a revision after an upload is adopted only
    /// while the content is still this, so an edit made elsewhere during a long upload is not taken for the upload's own.
    @ObservationIgnored private var checkedContent: [String: [String]] = [:]

    init(store: LocalStore, remote: RemoteDataSourceProvider, network: NetworkModeController,
         mediaStore: DraftMediaStore = DraftMediaStore()) {
        self.store = store
        self.remote = remote
        self.network = network
        self.mediaStore = mediaStore
        recoverInterruptedJobs()
        mediaStore.removeAllUploadStaging()
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
            if let done = blockJobs.first(where: { $0.state == .completed && $0.localFileName == local && $0.remoteMediaID != nil }),
               done.remoteMedia?.postID == nil || done.remoteMedia?.postID == draft.remotePostID {
                // Uploaded before (into this post) but the write-back was lost: reuse the result instead of uploading again.
                block.remoteMediaID = done.remoteMediaID
                block.remoteURL = done.remoteURL
                block.remoteMediaJSON = done.remoteMediaJSON
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

    /// Re-queues jobs that were paused only because the draft had no FANBOX post yet (never jobs the creator paused).
    func resumeAwaitingPost(draftID: String, autoStart: Bool = false) {
        let waiting = jobs(draftID: draftID).filter(Self.isAwaitingPost)
        guard !waiting.isEmpty else { return }
        for job in waiting {
            job.state = .queued
            job.progress = 0
            job.lastError = nil
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
        revisionCheckedDraftIDs = []
        checkedContent = [:]
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
        let capabilities = source.draftCapabilities
        guard capabilities.uploadsMedia else {
            // This account uploads in the web editor (SPEC §40): never a failure, never retried here.
            pauseForWeb(draftID: job.draftID)
            return true
        }
        var postID: String?
        if capabilities.uploadsNeedPost {
            guard let draft = store.draft(id: job.draftID), let id = draft.remotePostID else {
                // Uploads are stored into a post that does not exist yet: the send creates it first, then resumes these.
                pauseAwaitingPost(draftID: job.draftID)
                return true
            }
            if let unsavable = Self.unsavableUpload(draft: draft, kind: job.kind, capabilities: capabilities) {
                // The asset could never be referenced by a native save: it would stay behind on FANBOX unused.
                if unsavable.wholeDraft {
                    pauseUnfinished(draftID: job.draftID, reason: unsavable.reason)
                } else {
                    pause(job, reason: unsavable.reason)
                }
                return true
            }
            postID = id
        }
        guard mediaStore.fileExists(draftID: job.draftID, fileName: job.localFileName) else {
            markFailed(job, reason: "ローカルファイルが見つかりません")
            return true
        }

        // An upload into an existing post outside a send: the post must still be the revision this draft is based on.
        var adoptsRevision = false
        let jobDraftID = job.draftID
        if let postID, !sendCheckedDraftIDs.contains(jobDraftID) {
            if !revisionCheckedDraftIDs.contains(jobDraftID) {
                switch await checkRevision(draftID: jobDraftID, postID: postID, source: source, context: context) {
                case .current:
                    revisionCheckedDraftIDs.insert(jobDraftID)
                case .conflict:
                    pauseUnfinished(draftID: jobDraftID, reason: Self.conflictMessage)
                    return true
                case .unreachable:
                    return false   // offline: stay queued, the next run checks again
                case .failed(let reason):
                    // Every waiting job of the draft needs the same check: one read decides for all of them.
                    failQueued(draftID: jobDraftID, reason: reason)
                    return true
                }
            }
            adoptsRevision = true
        }
        // The job may have been removed / paused while the post was read.
        guard self.job(id: jobID)?.state == .queued else { return true }

        job.state = .uploading
        job.progress = 0
        job.attemptCount += 1
        job.lastError = nil
        job.updatedAt = .now
        activeJobID = jobID
        store.save()

        let kind = job.kind
        let media = mediaStore
        let draftID = job.draftID
        let localFileName = job.localFileName
        let displayName = job.fileName
        let onProgress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.applyProgress(jobID: jobID, value: value) }
        }
        let task = Task.detached(priority: .utility) { () async throws -> RemoteUploadResult in
            // Staged here, off the main actor: the copy fallback of a 300 MB attachment must not block the UI.
            let fileURL: URL
            do {
                fileURL = try media.stageUpload(draftID: draftID, fileName: localFileName, displayName: displayName, jobID: jobID)
            } catch {
                throw UploadStagingFailed()
            }
            defer { media.removeUploadStaging(jobID: jobID) }
            return try await RequestContext.$priority.withValue(.foregroundMedia) {
                switch (kind, postID) {
                case (.image, let postID?):
                    return try await source.uploadImage(fileURL: fileURL, postID: postID, account: context, progress: onProgress)
                case (.file, let postID?):
                    return try await source.uploadFile(fileURL: fileURL, postID: postID, account: context, progress: onProgress)
                case (.image, nil):
                    return try await source.uploadImage(fileURL: fileURL, account: context, progress: onProgress)
                case (.file, nil):
                    return try await source.uploadFile(fileURL: fileURL, account: context, progress: onProgress)
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
            job.remoteMedia = result
            job.lastError = nil
            job.updatedAt = .now
            let blockID = job.draftBlockID
            if let block = store.first(#Predicate<DraftBlock> { $0.id == blockID }), block.localFileName == job.localFileName {
                block.remoteMediaID = result.mediaID
                block.remoteURL = result.url
                block.remoteMedia = result
            }
            store.save()
            if adoptsRevision, let postID {
                // This upload may have bumped the post's revision: it is the draft's own change, not an edit elsewhere.
                await adoptRevision(draftID: draftID, postID: postID, source: source, context: context)
            }
            return true
        case .failure(let error):
            if job.state == .paused {
                job.progress = 0
                store.save()
                return true
            }
            if error is UploadStagingFailed {
                markFailed(job, reason: "アップロード用の一時ファイルを作成できませんでした")
                return true
            }
            let remoteError = RemoteError.creatorWrapping(error)
            switch remoteError {
            case .unsupported:
                // The data source cannot upload: hand over to the web editor instead of failing / retrying.
                pauseForWeb(draftID: job.draftID)
                return true
            case .offline, .blockedByPolicy, .cancelled:
                // Connectivity / policy / cancellation: stay queued and stop; the next run picks it up again.
                if adoptsRevision, remoteError != .blockedByPolicy, job.progress > 0, let draft = store.draft(id: draftID),
                   draft.remotePostID == postID {
                    // The file was being sent when the connection went, so it may have reached FANBOX: a revision it
                    // bumped (with the content left as checked) is this draft's own. Nothing sent is nothing remembered.
                    draft.rememberOwnWrite(keptContent: checkedContent[draftID].map(RemoteEditablePost.digest))
                }
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
                if adoptsRevision, let postID {
                    // The request reached FANBOX: whatever it changed is this draft's own doing.
                    await adoptRevision(draftID: draftID, postID: postID, source: source, context: context)
                }
                return true
            }
        }
    }

    /// Shown on jobs of accounts that upload in the web editor.
    static let webOnlyMessage = "Webエディタで追加してください"
    /// Shown on jobs of a new post whose uploads need the FANBOX post first (created by the send).
    static let awaitingPostMessage = "送信時にFANBOXの下書きを作成してからアップロードします"
    /// Earlier spellings of `awaitingPostMessage` still stored in `UploadJob.lastError`.
    static let legacyAwaitingPostMessages: Set<String> = ["送信時に FANBOX の下書きを作成してからアップロードします"]

    /// True for a job paused only because its draft has no FANBOX post yet (the reason is stored and recognised by value).
    static func isAwaitingPost(_ job: UploadJob) -> Bool {
        guard job.state == .paused, let reason = job.lastError else { return false }
        return reason == awaitingPostMessage || legacyAwaitingPostMessages.contains(reason)
    }
    /// Shown on jobs of a draft whose FANBOX post was changed elsewhere since it was imported / last sent.
    static let conflictMessage = "FANBOX側で投稿が更新されているため、上書きしないようアップロードを止めました。ローカル下書きを削除して「編集」から読み込み直すか、Webエディタで編集してください。"

    /// A running send checked the draft's post (`DraftService.send` step 1, or it just created it) and re-reads its revision
    /// afterwards: the queue skips its own check for the draft until `endSendCheck`.
    func beginSendCheck(draftID: String) { sendCheckedDraftIDs.insert(draftID) }

    func endSendCheck(draftID: String) { sendCheckedDraftIDs.remove(draftID) }

    /// Why an upload into the draft's existing post must not start: a native save could never reference the asset, so
    /// it would stay behind on FANBOX unused. `wholeDraft`: every job of the draft is affected. nil = the upload may run.
    static func unsavableUpload(draft: Draft, kind: UploadKind, capabilities: DraftCapabilities) -> (reason: String, wholeDraft: Bool)? {
        if draft.nativeUpdateBlocker != nil { return (webOnlyMessage, true) }
        let blockKind: DraftBlockKind = kind == .image ? .image : .file
        let type = draft.remotePostType
        if let allowed = capabilities.allowedKinds(in: type), !allowed.contains(blockKind) {
            let media = kind == .image ? "画像" : "ファイル"
            return ("「\(type.creatorLabel)」形式の投稿には\(media)を保存できません。削除するか、Webエディタで編集してください。", false)
        }
        return nil
    }

    private enum RevisionCheck {
        case current
        case conflict
        /// Offline / cancelled: try again on the next run.
        case unreachable
        case failed(String)
    }

    /// Re-reads the post and compares its revision with the draft's baseline (the same rule as `DraftService.send`).
    private func checkRevision(draftID: String, postID: String, source: RemoteDataSource, context: AccountContext) async -> RevisionCheck {
        let current: RemoteEditablePost
        do {
            current = try await RequestContext.$priority.withValue(.interactiveRead) {
                try await source.editablePost(id: postID, account: context)
            }
        } catch {
            let remoteError = RemoteError.creatorWrapping(error)
            switch remoteError {
            case .offline, .blockedByPolicy, .cancelled: return .unreachable
            default: return isNetworkAvailable ? .failed(remoteError.userMessage) : .unreachable
            }
        }
        guard let draft = store.draft(id: draftID) else { return .unreachable }
        if draft.isEditedElsewhere(revision: current.updatedAt, contentDigest: current.contentDigest) { return .conflict }
        draft.setBaseline(revision: current.updatedAt)
        store.save()
        checkedContent[draftID] = current.contentFingerprint
        return .current
    }

    /// Best effort: the post's revision after this draft's own upload becomes the draft's baseline — only while the post
    /// holds the content checked before the upload (an upload adds media, it changes nothing else). Content changed
    /// meanwhile is an edit made elsewhere: the baseline stays, so the next check / send refuses to overwrite it. A post
    /// that cannot be read leaves the upload remembered with that content (`Draft.ownWriteAt` / `ownWriteContent`).
    private func adoptRevision(draftID: String, postID: String, source: RemoteDataSource, context: AccountContext) async {
        let fresh = try? await RequestContext.$priority.withValue(.interactiveRead, operation: {
            try await source.editablePost(id: postID, account: context)
        })
        guard let draft = store.draft(id: draftID), draft.remotePostID == postID else { return }
        guard let fresh else {
            draft.rememberOwnWrite(keptContent: checkedContent[draftID].map(RemoteEditablePost.digest))
            store.save()
            return
        }
        if let checked = checkedContent[draftID], checked != fresh.contentFingerprint {
            revisionCheckedDraftIDs.remove(draftID)
            return
        }
        draft.setBaseline(revision: fresh.updatedAt)
        store.save()
    }

    /// Marks every waiting job of a draft failed (the active one finishes on its own).
    private func failQueued(draftID: String, reason: String) {
        var changed = false
        for job in jobs(draftID: draftID) where job.state == .queued && job.id != activeJobID {
            job.state = .failed
            job.lastError = reason
            job.updatedAt = .now
            changed = true
        }
        if changed { store.save() }
    }

    /// Pauses one job (it cannot run as things are; never a failure).
    private func pause(_ job: UploadJob, reason: String) {
        guard job.state != .paused || job.lastError != reason else { return }
        job.state = .paused
        job.progress = 0
        job.lastError = reason
        job.updatedAt = .now
        store.save()
    }

    /// Pauses every unfinished job of the draft with `webOnlyMessage` (the account cannot upload natively).
    /// Such jobs are never counted as failed and never retried automatically.
    func pauseForWeb(draftID: String) {
        pauseUnfinished(draftID: draftID, reason: Self.webOnlyMessage)
    }

    /// Pauses every unfinished job of a draft that has no FANBOX post yet (never a failure; the send resumes them).
    func pauseAwaitingPost(draftID: String) {
        pauseUnfinished(draftID: draftID, reason: Self.awaitingPostMessage)
    }

    private func pauseUnfinished(draftID: String, reason: String) {
        var changed = false
        for job in jobs(draftID: draftID) where job.state != .completed && job.id != activeJobID {
            if job.state != .paused || job.lastError != reason {
                job.state = .paused
                job.progress = 0
                job.lastError = reason
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

/// The per-job staging link (display name) could not be made.
private struct UploadStagingFailed: Error {}

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
    /// Imports in flight ("accountID|postID"): a second 編集 of the same post joins the first instead of making a second
    /// local draft.
    @ObservationIgnored private var importTasks: [String: Task<String, Error>] = [:]

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
            draft.lastError = "前回の送信が中断されました。FANBOX側の状態を確認してから再送してください。"
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
                report.failures.append("画像\(index + 1): \((error as? LocalizedError)?.errorDescription ?? "読み込めませんでした")")
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
        let capabilities = capabilities(accountID: draft.accountID)
        var plan = DraftSendPlanner.plan(draft: draft, capabilities: capabilities, publish: publish)
        checkLocalMedia(of: draft, capabilities: capabilities, into: &plan)
        return plan
    }

    /// Image / file blocks still to upload whose local copy is gone: nothing could be uploaded for them, so the send is
    /// refused up front (before a FANBOX draft is created for it).
    func missingLocalMedia(in draft: Draft) -> [DraftBlock] {
        draft.orderedBlocks.filter { block in
            guard block.kind == .image || block.kind == .file, block.remoteMediaID == nil, !block.isLockedRemote,
                  let name = block.localFileName else { return false }
            return !mediaStore.fileExists(draftID: draft.id, fileName: name)
        }
    }

    /// Adds the missing-local-media check (file system) to a plan made by the pure `DraftSendPlanner`.
    private func checkLocalMedia(of draft: Draft, capabilities: DraftCapabilities, into plan: inout DraftSendPlan) {
        guard capabilities.uploadsMedia, plan.validationError == nil else { return }
        let missing = missingLocalMedia(in: draft)
        guard !missing.isEmpty else { return }
        let names = missing.prefix(3).map { $0.originalFileName ?? DraftSendPlanner.kindLabel($0.kind) }.joined(separator: "、")
        let message = "端末内の画像・ファイルが見つかりません（\(names)\(missing.count > 3 ? "ほか" : "")）。ブロックを削除して追加し直してください。"
        plan.validationError = .invalidRequest(message)
        plan.blockers.append(message)
    }

    // MARK: Post Edit

    /// Imports an existing FANBOX post into a local draft ("Post Edit"). Image / file / link card / embed blocks keep their
    /// FANBOX ids (nothing is uploaded again), paragraphs keep their text styles and empty spacing paragraphs, and the
    /// FANBOX status / fee / comment permission / revision are recorded so a later send never changes them by accident.
    /// Content that cannot be written back natively is kept visibly and blocks the native update (web editor instead).
    /// An unsent local edit of the same post is reused, and so is an import of it that is still running.
    func importRemotePost(postID: String, accountID: String) async throws -> Draft {
        let key = "\(accountID)|\(postID)"
        let draftID: String
        if let running = importTasks[key] {
            draftID = try await running.value
        } else {
            let task = Task { @MainActor [weak self] () throws -> String in
                guard let self else { throw RemoteError.cancelled }
                return try await self.performImport(postID: postID, accountID: accountID).id
            }
            importTasks[key] = task
            defer { importTasks[key] = nil }
            draftID = try await task.value
        }
        guard let draft = store.draft(id: draftID) else { throw RemoteError.notFound }
        return draft
    }

    private func performImport(postID: String, accountID: String) async throws -> Draft {
        let existing = store.fetch(FetchDescriptor<Draft>(predicate: #Predicate { $0.accountID == accountID },
                                                          sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
            .filter { $0.remotePostID == postID }
        if let draft = existing.first(where: { $0.status != .published && $0.status != .readyToPublish }) {
            return draft
        }
        guard let account = store.account(id: accountID) else { throw RemoteError.invalidRequest("アカウントが見つかりません") }
        guard account.enabled else { throw RemoteError.invalidRequest(Self.disabledAccountMessage) }
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
        draft.remotePostTypeRaw = editable.postType.rawValue
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
        if editable.postType != .article && !capabilities.updates(editable.postType) {
            return "「\(editable.postType.creatorLabel)」形式の投稿はアプリから更新できません（本文が記事形式に変わってしまうため）。Webエディタで編集してください。"
        }
        if !unsupportedBlocks.isEmpty {
            return "アプリで扱えない内容があります（\(unsupportedBlocks.joined(separator: "、"))）。内容を失わないよう、Webエディタで編集してください。"
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

    static let conflictMessage = "FANBOX側で投稿が更新されています（Webエディタなど）。上書きしないよう送信を中止しました。ローカル下書きを削除して「編集」から読み込み直すか、Webエディタで編集してください。"

    /// Sends the draft: uploads pending media (when the account can), then creates or updates the FANBOX post.
    ///
    /// - Accounts that store uploads INTO a post (`uploadsNeedPost`, FANBOX): a new post with media / link cards to send is
    ///   created first (`createEmptyPost`) and its id persisted at once; then only the unfinished uploads run against it
    ///   (completed ones are never re-sent, failed ones are retried), new link cards are registered (`addURLEmbed`), and
    ///   the content is saved with `updatePost`, referencing every item by id in block order. Whatever fails, the local
    ///   draft, its `remotePostID` and every completed media id are kept, so the next send continues on the same post.
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
        // A turned-off account never writes (its drafts are hidden everywhere).
        guard account.enabled else { return fail(draft, .invalidRequest(Self.disabledAccountMessage)) }
        guard account.creatorID != nil else {
            return fail(draft, .invalidRequest("このアカウントにはCreatorページがありません"))
        }
        let context = account.context
        let source = remote.dataSource(for: context)
        let capabilities = source.draftCapabilities

        // 0. Plan with what is known locally (no request yet).
        var plan = DraftSendPlanner.plan(draft: draft, capabilities: capabilities, publish: publish)
        checkLocalMedia(of: draft, capabilities: capabilities, into: &plan)
        if let refusal = refusal(of: plan, draft: draft, acceptWarnings: acceptWarnings, allowUnpublish: allowUnpublish) {
            return refusal
        }
        guard uploads.isNetworkAvailable else { return fail(draft, .offline) }

        // 1. Existing post: re-read its current state before uploading / writing anything.
        var checked: RemoteEditablePost?
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
                let remoteError = RemoteError.creatorWrapping(error)
                guard let draft = store.draft(id: draftID) else { return .failure(remoteError) }
                // Deleted on FANBOX: the draft can be sent as a new post instead (`detachFromRemotePost`).
                if remoteError == .notFound { return fail(draft, remoteError, message: Self.remotePostMissingMessage) }
                return fail(draft, remoteError)
            }
            guard let draft = store.draft(id: draftID) else { return .failure(.notFound) }
            let known = draft.remoteStatus
            draft.remoteStatusRaw = current.status.rawValue
            if draft.isEditedElsewhere(revision: current.updatedAt, contentDigest: current.contentDigest) {
                return fail(draft, .invalidRequest(Self.conflictMessage))
            }
            if let known, known != .unknown, known != current.status {
                return fail(draft, .invalidRequest(Self.statusChangedMessage(current.status)))
            }
            // A post whose status was not known locally is only sent as published while it is live: "更新（公開のまま）"
            // never publishes a FANBOX draft or a taken-down post.
            if publish, known == .unknown, current.status != .published {
                return fail(draft, .invalidRequest(Self.statusChangedMessage(current.status)))
            }
            // The revision just checked is this send's baseline (a post created by an earlier attempt may have had none).
            draft.setBaseline(revision: current.updatedAt)
            checked = current
            plan = DraftSendPlanner.plan(draft: draft, capabilities: capabilities, publish: publish, remoteStatus: current.status)
            checkLocalMedia(of: draft, capabilities: capabilities, into: &plan)
            if let refusal = refusal(of: plan, draft: draft, acceptWarnings: acceptWarnings, allowUnpublish: allowUnpublish) {
                if draft.status == .publishing { draft.status = previousStatus }
                store.save()
                return refusal
            }
        }
        guard store.draft(id: draftID) != nil else { return .failure(.notFound) }
        // A post.create of an earlier attempt whose answer was lost may have created the post: adopt it, never create a
        // second one.
        if let failure = await resolveLostCreate(draftID: draftID, source: source, context: context) { return failure }
        guard let draft = store.draft(id: draftID) else { return .failure(.notFound) }

        // 2. Post-bound media: a new post is created FIRST and its id stored before anything is uploaded into it, so a
        //    retry reuses it (never a second post.create) and completed uploads stay valid.
        var continuation: String?
        if capabilities.uploadsNeedPost && draft.remotePostID == nil && Self.needsPostBoundWork(draft, capabilities: capabilities) {
            draft.status = .publishing
            draft.createAttemptAt = .now
            store.save()
            do {
                let postID = try await RequestContext.$priority.withValue(.interactiveWrite) {
                    try await source.createEmptyPost(account: context)
                }
                guard let draft = store.draft(id: draftID) else { return .failure(.notFound) }
                recordCreatedPost(draft, postID: postID)
                continuation = Self.createdDraftNote
                // Baseline of the new post, so an edit of it in the web editor between retries is detected.
                await adoptRevision(draftID: draftID, postID: postID, source: source, context: context)
            } catch {
                let remoteError = RemoteError.creatorWrapping(error)
                AppLog.creator.error("post.create before uploads failed: \(remoteError.userMessage, privacy: .public)")
                guard let draft = store.draft(id: draftID) else { return .failure(remoteError) }
                return failCreate(draft, remoteError)
            }
        } else if capabilities.uploadsNeedPost && draft.remotePostID != nil {
            continuation = Self.continueNote
        }
        guard let draft = store.draft(id: draftID) else { return .failure(.notFound) }

        // Steps 3–5 write into the FANBOX post (uploads, link cards, the save). When a later step fails, the post's new
        // revision becomes the baseline (best effort), so the retry does not take this send's own writes for an edit
        // made elsewhere. Before the save only while the post still holds what step 1 read: an edit made elsewhere during
        // the uploads is never adopted.
        let postBound = capabilities.uploadsNeedPost && draft.remotePostID != nil
        var wroteIntoPost = postBound && Self.needsPostBoundWork(draft, capabilities: capabilities)
        var expectedContent = checked?.contentFingerprint
        func settled(_ failure: Result<DraftSendReceipt, RemoteError>) async -> Result<DraftSendReceipt, RemoteError> {
            if wroteIntoPost, let postID = store.draft(id: draftID)?.remotePostID {
                await adoptRevision(draftID: draftID, postID: postID, source: source, context: context, expecting: expectedContent)
            }
            return failure
        }

        // 3. Media uploads (only blocks without remoteMediaID; failed jobs are retried, completed ones never re-sent).
        if capabilities.uploadsMedia {
            // The post was checked in step 1 (or created in step 2): the queue skips its own revision check meanwhile.
            if postBound { uploads.beginSendCheck(draftID: draftID) }
            let failure = await runUploads(for: draft, note: continuation)
            if postBound { uploads.endSendCheck(draftID: draftID) }
            if let failure { return await settled(failure) }
        } else {
            uploads.pauseForWeb(draftID: draftID)
        }
        // 3b. New link cards registered in the post (their ids go into the url_embed blocks).
        if capabilities.uploadsNeedPost && capabilities.createsLinkCards {
            if let failure = await registerLinkCards(draftID: draftID, source: source, context: context, note: continuation) {
                return await settled(failure)
            }
        }
        // 3c. Uploads / link cards took time: the post must still be what step 1 read (an edit or a status change made
        //     meanwhile in the web editor is never overwritten, nor is a post published meanwhile taken down).
        if let checked, wroteIntoPost, let postID = store.draft(id: draftID)?.remotePostID {
            let fresh: RemoteEditablePost
            do {
                fresh = try await RequestContext.$priority.withValue(.interactiveRead) {
                    try await source.editablePost(id: postID, account: context)
                }
            } catch {
                guard let draft = store.draft(id: draftID) else { return .failure(RemoteError.creatorWrapping(error)) }
                return await settled(fail(draft, RemoteError.creatorWrapping(error)))
            }
            guard let draft = store.draft(id: draftID) else { return .failure(.notFound) }
            if fresh.status != checked.status {
                draft.remoteStatusRaw = fresh.status.rawValue
                return fail(draft, .invalidRequest(Self.statusChangedMessage(fresh.status)))
            }
            if fresh.contentFingerprint != checked.contentFingerprint {
                return fail(draft, .invalidRequest(Self.conflictMessage))
            }
            // Only this send's own uploads / link cards changed the post: its revision is the baseline.
            draft.setBaseline(revision: fresh.updatedAt)
            store.save()
        }
        guard let draft = store.draft(id: draftID) else { return .failure(.notFound) }
        let isMediaPost = draft.remotePostID != nil && capabilities.allowedKinds(in: draft.remotePostType) != nil

        // 4. Payload (text-first: blocks for the web editor are left out).
        let payload: DraftPostMapping.Payload
        do {
            payload = try DraftPostMapping.payload(from: draft, publish: plan.sendsPublished, capabilities: capabilities)
        } catch {
            return await settled(fail(draft, RemoteError.creatorWrapping(error)))
        }
        guard uploads.isNetworkAvailable else { return await settled(fail(draft, .offline)) }

        // 5. Create / update with interactiveWrite priority. The save replaces the post's content: what it holds after a
        //    failed save is this send's own doing.
        draft.status = .publishing
        let existingID = draft.remotePostID
        if existingID != nil { wroteIntoPost = true } else { draft.createAttemptAt = .now }
        expectedContent = nil
        store.save()
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
            commitSent(draft, postID: postID, published: body.publish, leavesWebItems: !webIDs.isEmpty, keepsTextBlocks: isMediaPost,
                       unpublished: plan.unpublishes)
            let webItems = DraftSendPlanner.webItems(for: draft, blockIDs: webIDs)
            // 6. Revision baseline for the next conflict check (best effort read). When it fails, the write is remembered:
            //    the next send takes a revision up to now for this app's own update, not for an edit made elsewhere.
            if let fresh = try? await RequestContext.$priority.withValue(.interactiveRead, operation: {
                try await source.editablePost(id: postID, account: context)
            }), let draft = store.draft(id: draftID) {
                draft.setBaseline(revision: fresh.updatedAt)
                draft.remoteStatusRaw = fresh.status.rawValue
                if let permission = fresh.commentPermission { draft.commentPermission = permission }
                store.save()
            } else if let draft = store.draft(id: draftID) {
                draft.rememberOwnWrite(keptContent: nil)
                store.save()
            }
            return .success(DraftSendReceipt(postID: postID, sentPublished: body.publish, webItems: webItems))
        } catch let partial as RemotePostCreatedPartially {
            AppLog.creator.error("post created but content not saved: \(partial.underlying.userMessage, privacy: .public)")
            guard let draft = store.draft(id: draftID) else { return .failure(partial.underlying) }
            // Persist the new id FIRST: the retry updates this post instead of creating another one.
            draft.remotePostID = partial.postID
            draft.createAttemptAt = nil
            draft.remoteStatusRaw = RemotePostStatus.draft.rawValue
            draft.remoteFeeRequired = nil
            draft.remoteUpdatedAt = nil
            // A post this app just created has no comment setting of the creator's to preserve.
            if draft.commentPermission == nil { draft.commentPermission = .default(feeRequired: draft.feeRequired) }
            let failure: Result<DraftSendReceipt, RemoteError> = fail(draft, partial.underlying,
                message: "FANBOXに下書きを作成しましたが、内容の保存に失敗しました（\(partial.underlying.userMessage)）。再送すると同じ下書きを更新します。")
            // Baseline of the post just created, so an edit of it elsewhere before the retry is detected.
            await adoptRevision(draftID: draftID, postID: partial.postID, source: source, context: context)
            return failure
        } catch {
            let remoteError = RemoteError.creatorWrapping(error)
            AppLog.creator.error("publish failed: \(remoteError.userMessage, privacy: .public)")
            guard let draft = store.draft(id: draftID) else { return .failure(remoteError) }
            if existingID == nil { return failCreate(draft, remoteError) }
            if continuation == Self.createdDraftNote {
                return await settled(fail(draft, remoteError, message: "FANBOXに下書きを作成してメディアを送信しましたが、内容の保存に失敗しました（\(remoteError.userMessage)）。再送すると同じ下書きを更新します（送信済みのメディアは再送しません）。"))
            }
            return await settled(fail(draft, remoteError))
        }
    }

    /// Best effort: the post's current revision becomes the draft's baseline for the next conflict check (read right
    /// after this app's own writes into the post). When it cannot be read, the write is remembered (`Draft.ownWriteAt`).
    /// `expecting`: the content (`RemoteEditablePost.contentFingerprint`) the post held before those writes. Content
    /// changed meanwhile is an edit made elsewhere: the baseline stays, so the next send refuses to overwrite it. It is
    /// remembered with the write too, so a revision read later is adopted only with that content.
    private func adoptRevision(draftID: String, postID: String, source: RemoteDataSource, context: AccountContext,
                               expecting: [String]? = nil) async {
        let fresh = try? await RequestContext.$priority.withValue(.interactiveRead, operation: {
            try await source.editablePost(id: postID, account: context)
        })
        guard let draft = store.draft(id: draftID), draft.remotePostID == postID else { return }
        if let fresh {
            if let expecting, expecting != fresh.contentFingerprint { return }
            draft.setBaseline(revision: fresh.updatedAt)
        } else {
            draft.rememberOwnWrite(keptContent: expecting.map(RemoteEditablePost.digest))
        }
        store.save()
    }

    static let disabledAccountMessage = "このアカウントは無効になっています"
    /// Shown when the linked FANBOX post no longer exists (deleted on FANBOX); `detachFromRemotePost` offers the way out.
    static let remotePostMissingMessage = "FANBOXで投稿が見つかりませんでした（削除された可能性があります）"
    /// A post.create whose answer was lost could not be matched with the creator's posts.
    static let lostCreateMessage = "前回の送信でFANBOXに下書きが作成されたか確認できませんでした。FANBOXの投稿一覧を確認してください。"

    static func statusChangedMessage(_ status: RemotePostStatus) -> String {
        "FANBOX側で公開状態が「\(status.creatorLabel)」に変わっています。内容を確認してから送信し直してください。"
    }

    /// A failed post.create: when the request may have created the post although its answer was lost (timeout, dropped
    /// connection, cancellation, a server error), the attempt is remembered and the next send looks for the post it may
    /// have created (`resolveLostCreate`) instead of creating a second one. Any other answer from FANBOX clears it.
    private func failCreate(_ draft: Draft, _ error: RemoteError) -> Result<DraftSendReceipt, RemoteError> {
        if !Self.createOutcomeUnknown(error) { draft.createAttemptAt = nil }
        return fail(draft, error)
    }

    static func createOutcomeUnknown(_ error: RemoteError) -> Bool {
        switch error {
        case .offline, .network, .cancelled: return true
        // A 5xx may come after the post was stored (or from a gateway that gave up waiting for FANBOX).
        case .server(let status): return (500...599).contains(status)
        default: return false
        }
    }

    /// Before a new post is created: an earlier post.create of this draft whose answer was lost may have created it. The
    /// creator's managed posts are read and an untitled FANBOX draft created since that attempt is adopted (uploads and
    /// the save then go into it). nil = go on (adopted, or nothing was created); a failure when it cannot be told.
    private func resolveLostCreate(draftID: String, source: RemoteDataSource,
                                   context: AccountContext) async -> Result<DraftSendReceipt, RemoteError>? {
        guard let draft = store.draft(id: draftID), draft.remotePostID == nil, let attempt = draft.createAttemptAt else { return nil }
        let listed: [RemotePostSummary]
        do {
            listed = try await RequestContext.$priority.withValue(.interactiveRead) {
                try await source.managedPosts(account: context, cursor: nil).items
            }
        } catch {
            let remoteError = RemoteError.creatorWrapping(error)
            guard let draft = store.draft(id: draftID) else { return .failure(remoteError) }
            return fail(draft, remoteError)
        }
        guard let draft = store.draft(id: draftID), draft.remotePostID == nil else { return nil }
        let since = attempt.addingTimeInterval(-Draft.ownWriteTolerance)
        let candidates = listed.filter { post in
            post.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (post.remoteStatus ?? .draft) == .draft
                && max(post.updatedAt, post.publishedAt) >= since
        }
        switch candidates.count {
        case 0:
            draft.createAttemptAt = nil
            store.save()
            return nil
        case 1:
            recordCreatedPost(draft, postID: candidates[0].id)
            await adoptRevision(draftID: draftID, postID: candidates[0].id, source: source, context: context)
            return nil
        default:
            return fail(draft, .invalidRequest(Self.lostCreateMessage))
        }
    }

    static let createdDraftNote = "FANBOXに下書きを作成済みです。再送すると同じ下書きに続きから送信します（完了した項目は再送しません）。"
    static let continueNote = "完了した項目は再送しません。再送すると残りだけを送信します。"

    /// True when the draft has media to upload or new link cards to register (both are stored into a FANBOX post).
    static func needsPostBoundWork(_ draft: Draft, capabilities: DraftCapabilities) -> Bool {
        draft.blocks.contains { block in
            guard !block.isLockedRemote, block.remoteMediaID == nil else { return false }
            switch block.kind {
            case .image, .file: return capabilities.uploadsMedia && block.localFileName != nil
            case .url: return capabilities.createsLinkCards && !(block.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .text, .header, .embed: return false
            }
        }
    }

    /// Stores the id of the post just created for uploads (before anything is uploaded into it).
    private func recordCreatedPost(_ draft: Draft, postID: String) {
        draft.remotePostID = postID
        draft.createAttemptAt = nil
        draft.remoteStatusRaw = RemotePostStatus.draft.rawValue
        draft.remoteFeeRequired = nil
        draft.remoteUpdatedAt = nil
        draft.remotePostTypeRaw = PostType.article.rawValue
        // A post this app just created has no comment setting of the creator's to preserve.
        if draft.commentPermission == nil { draft.commentPermission = .default(feeRequired: draft.feeRequired) }
        store.save()
    }

    /// Registers the draft's new link cards in its post (`addURLEmbed`) and stores each card id on its block. Cards
    /// registered by an earlier attempt keep their ids and are never registered again. Returns a failure when a card is
    /// left unregistered (the others keep their ids).
    private func registerLinkCards(draftID: String, source: RemoteDataSource, context: AccountContext,
                                   note: String?) async -> Result<DraftSendReceipt, RemoteError>? {
        guard let draft = store.draft(id: draftID), let postID = draft.remotePostID else { return nil }
        let pending = draft.orderedBlocks.compactMap { block -> (id: String, url: String)? in
            guard block.kind == .url, !block.isLockedRemote, block.remoteMediaID == nil else { return nil }
            let url = (block.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? nil : (block.id, url)
        }
        guard !pending.isEmpty else { return nil }
        guard uploads.isNetworkAvailable else { return fail(draft, .offline, message: Self.message(for: .offline, note: note)) }
        var failures = 0
        var lastError: RemoteError?
        for item in pending {
            do {
                let result = try await RequestContext.$priority.withValue(.interactiveWrite) {
                    try await source.addURLEmbed(url: item.url, postID: postID, account: context)
                }
                let blockID = item.id
                if let block = store.first(#Predicate<DraftBlock> { $0.id == blockID }), block.remoteMediaID == nil,
                   (block.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == item.url {
                    block.remoteMediaID = result.mediaID
                    block.remoteMedia = result
                    store.save()
                }
            } catch {
                let remoteError = RemoteError.creatorWrapping(error)
                if remoteError == .offline || remoteError == .cancelled {
                    guard let draft = store.draft(id: draftID) else { return .failure(remoteError) }
                    return fail(draft, remoteError, message: Self.message(for: remoteError, note: note))
                }
                AppLog.creator.error("link card registration failed: \(remoteError.userMessage, privacy: .public)")
                failures += 1
                lastError = remoteError
            }
        }
        guard failures > 0, let lastError else { return nil }
        guard let draft = store.draft(id: draftID) else { return .failure(lastError) }
        let summary = "リンクカードを登録できませんでした（\(failures)件）"
        return fail(draft, .invalidRequest(summary), message: "\(summary): \(lastError.userMessage)" + (note.map { "\n" + $0 } ?? ""))
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

    /// Uploads the draft's pending media and waits. Returns a failure when something is left (`note` explains how a retry
    /// continues on a post-bound account).
    private func runUploads(for draft: Draft, note: String? = nil) async -> Result<DraftSendReceipt, RemoteError>? {
        let draftID = draft.id
        uploads.enqueue(draftID: draftID)
        uploads.retryFailed(draftID: draftID, autoStart: false)
        uploads.resumeAll(draftID: draftID, autoStart: false)
        if !uploads.unfinishedJobs(draftID: draftID).isEmpty {
            guard uploads.isNetworkAvailable else { return fail(draft, .offline, message: Self.message(for: .offline, note: note)) }
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
            let summary = "アップロードに失敗した項目があります（\(failedCount)件）"
            return fail(draft, .invalidRequest(summary), message: note.map { summary + "\n" + $0 })
        }
        if !unfinished.isEmpty {
            let error: RemoteError = uploads.isNetworkAvailable ? .invalidRequest("アップロードが完了していません") : .offline
            return fail(draft, error, message: Self.message(for: error, note: note))
        }
        return nil
    }

    /// `lastError` of a failure that may leave a FANBOX draft behind: the error plus how a retry continues (`note`).
    private static func message(for error: RemoteError, note: String?) -> String? {
        note.map { "\(error.userMessage)\n\($0)" }
    }

    /// Records a successful send: FANBOX status / fee, and the sent text as the new baseline of every paragraph
    /// (a multi-line text block becomes one block per paragraph, exactly like the post on FANBOX).
    /// `keepsTextBlocks`: image- / file-type post, whose text blocks are paragraphs of one plain text (never split by line).
    /// `unpublished`: a live post was taken down; FANBOX then reports `archived` (非公開), and a taken-down post saved again
    /// without publishing stays archived. The read that follows the send records the real status.
    private func commitSent(_ draft: Draft, postID: String, published: Bool, leavesWebItems: Bool, keepsTextBlocks: Bool = false,
                            unpublished: Bool = false) {
        // The post now has the comment permission that was sent (the default when none was known) and exactly the tags
        // that were sent: later updates keep them without asking.
        if draft.commentPermission == nil {
            draft.commentPermission = .default(feeRequired: draft.feeRequired)
        }
        draft.tagsUnverified = false
        let wasArchived = draft.remotePostID != nil && draft.remoteStatus == .archived
        draft.remotePostID = postID
        draft.createAttemptAt = nil
        let status: RemotePostStatus = published ? .published : (unpublished || wasArchived ? .archived : .draft)
        draft.remoteStatusRaw = status.rawValue
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
            let styles = keepsTextBlocks ? [] : DraftPostMapping.sentStyles(of: block).styles
            guard block.kind == .text, !keepsTextBlocks else {
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

    // MARK: Deleted FANBOX post

    /// The draft's FANBOX post no longer exists (a send could not find it, or a complete managed listing lacks it).
    func isRemotePostMissing(_ draft: Draft) -> Bool {
        guard let postID = draft.remotePostID else { return false }
        return draft.lastError == Self.remotePostMissingMessage || store.post(id: postID)?.isRemovedFromFanbox == true
    }

    /// Unlinks a draft from its deleted FANBOX post so it can be sent as a new post; its content is kept. Media and link
    /// cards stored into the old post are uploaded / registered again from their local copies (an imported item without
    /// one is reported by the send), and the old post's status, revision and settings no longer apply.
    func detachFromRemotePost(draftID: String) {
        guard let draft = store.draft(id: draftID), draft.remotePostID != nil else { return }
        uploads.removeJobs(draftID: draftID)
        for block in draft.blocks where block.remoteMediaID != nil {
            block.remoteMediaID = nil
            block.remoteMedia = nil
        }
        draft.remotePostID = nil
        draft.remoteStatusRaw = nil
        draft.remoteFeeRequired = nil
        draft.remoteUpdatedAt = nil
        draft.remotePostTypeRaw = nil
        draft.nativeUpdateBlocker = nil
        draft.tagsUnverified = false
        draft.ownWriteAt = nil
        draft.ownWriteContent = nil
        draft.createAttemptAt = nil
        draft.webHandoffAt = nil
        draft.publishedAt = nil
        draft.lastError = nil
        draft.status = .local
        draft.updatedAt = .now
        store.save()
    }

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

extension RemoteEditablePost {
    /// What an edit in the web editor changes and this app's own uploads / link card registrations do not (those only add
    /// to the post's media maps; the body references them after the save): title, fee, status, tags, the R-18 flag and
    /// the body. Media items of an image- / file-type post are left out (an upload may add to them).
    var contentFingerprint: [String] {
        var parts = [title, String(feeRequired), status.rawValue, tagsKnown ? tags.joined(separator: "\u{1F}") : "?",
                     String(hasAdultContent), postType.rawValue]
        for block in blocks where postType == .article || block.mediaID == nil {
            parts.append([block.kind.rawValue, block.text, block.mediaID ?? "", block.url ?? "", block.embedContentID ?? ""]
                .joined(separator: "\u{1F}"))
        }
        return parts
    }

    /// `contentFingerprint` as a short stable digest (kept on the draft with `Draft.ownWriteAt`).
    var contentDigest: String { Self.digest(contentFingerprint) }

    static func digest(_ fingerprint: [String]) -> String {
        SHA256.hash(data: Data(fingerprint.joined(separator: "\u{1E}").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

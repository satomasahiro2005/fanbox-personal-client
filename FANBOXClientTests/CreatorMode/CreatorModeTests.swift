import CoreGraphics
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import FANBOXClient

// MARK: - Fakes

/// Fake remote for Creator Mode tests (records calls, configurable failures).
final class CreatorMockRemote: RemoteDataSource, @unchecked Sendable {
    struct State {
        var uploadCalls: [String] = []
        var uploadPriorities: [RequestPriority] = []
        var failOnce: Set<String> = []
        var failAlways: Set<String> = []
        var offlineUploads = false
        var editable: RemoteEditablePost?
        var editableCalls = 0
        var createResult: Result<String, RemoteError> = .success("new-post-1")
        var updateError: RemoteError?
        var created: [RemotePostDraft] = []
        var updated: [(String, RemotePostDraft)] = []
        var writePriorities: [RequestPriority] = []
        /// Uploads throw `.unsupported` (an account that uploads in the web editor).
        var unsupportedUploads = false
        var capabilities: DraftCapabilities = .full
        /// Thrown by createPost (after recording) instead of `createResult`.
        var createError: Error?
        /// Applied to `editable` by every successful updatePost (simulates the new revision / status on the service).
        var bumpEditableOnUpdate = true
        var managed: [RemotePostSummary] = []
        var managedCalls = 0
        var fansCalls = 0
        var dashboardCalls = 0
    }

    private let lock = NSLock()
    private var state = State()

    func with<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    var snapshot: State { with { $0 } }

    // Upload
    private func upload(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        let name = url.lastPathComponent
        let priority = RequestContext.priority
        let outcome: RemoteError? = with { s in
            s.uploadCalls.append(name)
            s.uploadPriorities.append(priority)
            if s.offlineUploads { return .offline }
            if s.unsupportedUploads { return .unsupported(operation: "upload") }
            if s.failAlways.contains(name) { return .server(status: 500) }
            if s.failOnce.contains(name) {
                s.failOnce.remove(name)
                return .server(status: 503)
            }
            return nil
        }
        progress(0.42)
        if let outcome { throw outcome }
        progress(1)
        return RemoteUploadResult(mediaID: "m-\(name)", url: "https://example.invalid/\(name)")
    }

    func uploadImage(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        try await upload(fileURL, progress: progress)
    }

    func uploadFile(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        try await upload(fileURL, progress: progress)
    }

    func editablePost(id: String, account: AccountContext) async throws -> RemoteEditablePost {
        let post = with { s -> RemoteEditablePost? in
            s.editableCalls += 1
            return s.editable
        }
        guard let post else { throw RemoteError.notFound }
        return post
    }

    var draftCapabilities: DraftCapabilities { with { $0.capabilities } }

    func createPost(_ draft: RemotePostDraft, account: AccountContext) async throws -> String {
        let priority = RequestContext.priority
        let (result, error) = with { s -> (Result<String, RemoteError>, Error?) in
            s.created.append(draft)
            s.writePriorities.append(priority)
            return (s.createResult, s.createError)
        }
        if let error { throw error }
        return try result.get()
    }

    func updatePost(id: String, _ draft: RemotePostDraft, account: AccountContext) async throws {
        let priority = RequestContext.priority
        let error = with { s -> RemoteError? in
            s.updated.append((id, draft))
            s.writePriorities.append(priority)
            if s.updateError == nil, s.bumpEditableOnUpdate, var editable = s.editable, editable.id == id {
                editable.updatedAt = (editable.updatedAt ?? .now).addingTimeInterval(60)
                editable.status = draft.publish ? .published : .draft
                s.editable = editable
            }
            return s.updateError
        }
        if let error { throw error }
    }

    // Unused by these tests.
    func currentUser(account: AccountContext) async throws -> RemoteUser { throw RemoteError.notFound }
    func homeTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { RemotePage(items: []) }
    func supportingTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { RemotePage(items: []) }
    func creatorPosts(creatorID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        RemotePage(items: [])
    }
    func post(id: String, account: AccountContext) async throws -> RemotePostDetail { throw RemoteError.notFound }
    func creator(id: String, account: AccountContext) async throws -> RemoteCreator { throw RemoteError.notFound }
    func followingCreators(account: AccountContext) async throws -> [RemoteCreator] { [] }
    func supportingPlans(account: AccountContext) async throws -> [RemoteSupport] { [] }
    func creatorPlans(creatorID: String, account: AccountContext) async throws -> [RemotePlan] { [] }
    func setLike(postID: String, liked: Bool, account: AccountContext) async throws {}
    func comments(postID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> { RemotePage(items: []) }
    func addComment(postID: String, body: String, parentCommentID: String?, rootCommentID: String?,
                    account: AccountContext) async throws -> RemoteComment {
        throw RemoteError.unsupported(operation: "addComment")
    }
    func deleteComment(commentID: String, postID: String, account: AccountContext) async throws {}
    func notifications(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteNotification> { RemotePage(items: []) }
    func newsletters(account: AccountContext) async throws -> [RemoteNewsletter] { [] }
    func newsletter(id: String, account: AccountContext) async throws -> RemoteNewsletter { throw RemoteError.notFound }
    func paidRecords(account: AccountContext) async throws -> [RemotePayment] { [] }
    func managedPosts(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        with { s in
            s.managedCalls += 1
            return RemotePage(items: cursor == nil ? s.managed : [])
        }
    }
    func fans(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteFan> {
        with { $0.fansCalls += 1 }
        return RemotePage(items: [])
    }
    func creatorDashboard(account: AccountContext) async throws -> RemoteCreatorDashboard {
        with { $0.dashboardCalls += 1 }
        return RemoteCreatorDashboard(month: "2026-09")
    }
    func creatorComments(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> { RemotePage(items: []) }
}

struct CreatorMockProvider: RemoteDataSourceProvider {
    let source: CreatorMockRemote
    func dataSource(for account: AccountContext) -> RemoteDataSource { source }
}

@MainActor
final class CreatorTestHarness {
    let container: ModelContainer
    let store: LocalStore
    let settings: AppSettings
    let network: NetworkModeController
    let remote = CreatorMockRemote()
    let root: URL
    let mediaStore: DraftMediaStore
    let uploads: UploadQueue
    let drafts: DraftService
    let account: Account

    init() throws {
        container = try PersistenceController.makeContainer(inMemory: true)
        store = LocalStore(container: container)
        settings = AppSettings(defaults: UserDefaults(suiteName: "creator-tests-\(UUID().uuidString)")!)
        settings.networkModePreference = .normal
        network = NetworkModeController(settings: settings, policyStore: NetworkPolicyStore())
        network.recompute()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CreatorModeTests-\(UUID().uuidString)", isDirectory: true)
        mediaStore = DraftMediaStore(rootDirectory: root)
        let provider = CreatorMockProvider(source: remote)
        uploads = UploadQueue(store: store, remote: provider, network: network, mediaStore: mediaStore)
        drafts = DraftService(store: store, uploads: uploads, remote: provider, web: WebBridge())
        account = Account(kind: .demo, displayName: "Creator", creatorID: "me")
        store.context.insert(account)
        store.save()
    }

    func setOffline(_ offline: Bool) {
        settings.networkModePreference = offline ? .offline : .normal
        network.recompute()
    }

    /// Adds an image / file block with a real local file (dummy bytes) named `<name>`.
    @discardableResult
    func addMediaBlock(to draft: Draft, kind: DraftBlockKind, name: String) throws -> DraftBlock {
        try mediaStore.ensureDirectory(draftID: draft.id)
        try Data("bytes-\(name)".utf8).write(to: mediaStore.fileURL(draftID: draft.id, fileName: name))
        let block = drafts.addBlock(kind, to: draft)
        block.localFileName = name
        block.originalFileName = name
        block.fileSize = 10
        store.save()
        return block
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Tests

@MainActor
final class CreatorModeTests: XCTestCase {
    private var harness: CreatorTestHarness!

    override func setUp() async throws {
        harness = try CreatorTestHarness()
    }

    override func tearDown() async throws {
        harness?.cleanUp()
        harness = nil
    }

    // MARK: Mapping

    func testRemotePostDraftMapping() throws {
        let h = harness!
        let draft = h.drafts.createDraft(accountID: h.account.id)
        XCTAssertEqual(draft.creatorID, "me")
        draft.title = "  Hello  "
        draft.targetPlanID = "plan-500"
        draft.feeRequired = 500
        draft.tags = ["#art", "art", "  sketch ", "", "＃note"]
        draft.hasAdultContent = true
        draft.orderedBlocks[0].text = "Body"
        h.drafts.addBlock(.text, to: draft, text: "   ")
        h.drafts.addBlock(.header, to: draft, text: "Heading")
        let image = h.drafts.addBlock(.image, to: draft)
        image.remoteMediaID = "img-1"
        let file = h.drafts.addBlock(.file, to: draft)
        file.remoteMediaID = "file-1"
        let url = h.drafts.addBlock(.url, to: draft)
        url.url = "https://example.com/a"
        h.drafts.addBlock(.url, to: draft)                      // empty → omitted
        let embed = h.drafts.addBlock(.embed, to: draft)
        embed.embedProvider = DraftEmbedProvider.youtube.rawValue
        embed.url = "https://youtu.be/abc123"

        let payload = try h.drafts.remotePostDraft(from: draft, publish: true)
        XCTAssertEqual(payload.title, "Hello")
        XCTAssertEqual(payload.feeRequired, 500)
        XCTAssertEqual(payload.planID, "plan-500")
        XCTAssertEqual(payload.tags, ["art", "sketch", "note"])
        XCTAssertTrue(payload.hasAdultContent)
        XCTAssertTrue(payload.publish)
        XCTAssertEqual(payload.blocks.map(\.kind), [.text, .header, .image, .file, .url, .embed])
        XCTAssertEqual(payload.blocks[0].text, "Body")
        XCTAssertEqual(payload.blocks[2].mediaID, "img-1")
        XCTAssertEqual(payload.blocks[3].mediaID, "file-1")
        XCTAssertEqual(payload.blocks[4].url, "https://example.com/a")
        XCTAssertEqual(payload.blocks[5].embedProvider, "youtube")
        XCTAssertEqual(payload.blocks[5].embedContentID, "abc123")

        // A title is required for every send (also a FANBOX draft save): an update rejected after post.create would
        // otherwise leave an empty post behind.
        draft.title = " "
        XCTAssertThrowsError(try DraftPostMapping.remotePostDraft(from: draft, publish: false))
        XCTAssertThrowsError(try DraftPostMapping.remotePostDraft(from: draft, publish: true))

        // Media without remote id cannot be mapped.
        draft.title = "T"
        image.remoteMediaID = nil
        XCTAssertThrowsError(try DraftPostMapping.remotePostDraft(from: draft, publish: false)) { error in
            guard case RemoteError.invalidRequest = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testEmbedContentIDParsing() {
        XCTAssertEqual(DraftEmbedProvider.youtube.contentID(from: "https://www.youtube.com/watch?v=xyz789&t=10"), "xyz789")
        XCTAssertEqual(DraftEmbedProvider.youtube.contentID(from: "https://youtube.com/shorts/short1"), "short1")
        XCTAssertEqual(DraftEmbedProvider.youtube.contentID(from: " rawid "), "rawid")
        XCTAssertEqual(DraftEmbedProvider.twitter.contentID(from: "https://x.com/someone/status/12345"), "12345")
        XCTAssertEqual(DraftEmbedProvider.vimeo.contentID(from: "https://vimeo.com/76979871"), "76979871")
    }

    // MARK: Upload queue

    func testUploadQueueSuccessWritesRemoteIDsInBlockOrder() async throws {
        let h = harness!
        let draft = h.drafts.createDraft(accountID: h.account.id)
        let a = try h.addMediaBlock(to: draft, kind: .image, name: "1.jpg")
        let b = try h.addMediaBlock(to: draft, kind: .image, name: "2.jpg")
        let c = try h.addMediaBlock(to: draft, kind: .file, name: "demo.zip")
        // Reorder: move demo.zip first.
        h.drafts.moveBlocks(in: draft, from: IndexSet(integer: 3), to: 1)

        let jobs = h.uploads.enqueue(draftID: draft.id)
        XCTAssertEqual(jobs.map(\.fileName), ["demo.zip", "1.jpg", "2.jpg"])
        XCTAssertTrue(jobs.allSatisfy { $0.state == .queued })
        XCTAssertEqual(jobs.first?.kind, .file)
        // Enqueue is idempotent.
        XCTAssertEqual(h.uploads.enqueue(draftID: draft.id).count, 3)

        await h.uploads.run()

        let done = h.uploads.jobs(draftID: draft.id)
        XCTAssertTrue(done.allSatisfy { $0.state == .completed && $0.progress == 1 })
        XCTAssertEqual(h.remote.snapshot.uploadCalls, ["demo.zip", "1.jpg", "2.jpg"])
        XCTAssertTrue(h.remote.snapshot.uploadPriorities.allSatisfy { $0 == .foregroundMedia })
        XCTAssertEqual(a.remoteMediaID, "m-1.jpg")
        XCTAssertEqual(b.remoteMediaID, "m-2.jpg")
        XCTAssertEqual(c.remoteMediaID, "m-demo.zip")
        XCTAssertEqual(c.remoteURL, "https://example.invalid/demo.zip")
        // Nothing left to upload.
        h.uploads.enqueue(draftID: draft.id)
        XCTAssertTrue(h.uploads.unfinishedJobs(draftID: draft.id).isEmpty)
        XCTAssertFalse(h.uploads.isRunning)
    }

    func testUploadQueueFailureThenRetryOnlyFailed() async throws {
        let h = harness!
        h.remote.with { $0.failOnce = ["2.jpg"] }
        let draft = h.drafts.createDraft(accountID: h.account.id)
        try h.addMediaBlock(to: draft, kind: .image, name: "1.jpg")
        let second = try h.addMediaBlock(to: draft, kind: .image, name: "2.jpg")
        try h.addMediaBlock(to: draft, kind: .image, name: "3.png")
        h.uploads.enqueue(draftID: draft.id)

        await h.uploads.run()
        var jobs = h.uploads.jobs(draftID: draft.id)
        XCTAssertEqual(jobs.map(\.state), [.completed, .failed, .completed])
        XCTAssertNotNil(jobs[1].lastError)
        XCTAssertNil(second.remoteMediaID)
        // enqueue does not silently re-send failed jobs.
        h.uploads.enqueue(draftID: draft.id)
        XCTAssertEqual(h.uploads.jobs(draftID: draft.id).map(\.state), [.completed, .failed, .completed])

        XCTAssertEqual(h.uploads.retryFailed(draftID: draft.id, autoStart: false), 1)
        jobs = h.uploads.jobs(draftID: draft.id)
        XCTAssertEqual(jobs.map(\.state), [.completed, .queued, .completed])
        XCTAssertNil(jobs[1].lastError)

        await h.uploads.run()
        XCTAssertEqual(h.uploads.jobs(draftID: draft.id).map(\.state), [.completed, .completed, .completed])
        XCTAssertEqual(second.remoteMediaID, "m-2.jpg")
        let calls = h.remote.snapshot.uploadCalls
        XCTAssertEqual(calls.filter { $0 == "1.jpg" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "2.jpg" }.count, 2)
        XCTAssertEqual(calls.filter { $0 == "3.png" }.count, 1)
        XCTAssertEqual(h.uploads.jobs(draftID: draft.id)[1].attemptCount, 2)
    }

    func testUploadQueuePauseAndResume() async throws {
        let h = harness!
        let draft = h.drafts.createDraft(accountID: h.account.id)
        try h.addMediaBlock(to: draft, kind: .image, name: "1.jpg")
        try h.addMediaBlock(to: draft, kind: .image, name: "2.jpg")
        let jobs = h.uploads.enqueue(draftID: draft.id)
        h.uploads.pause(jobID: jobs[0].id)
        XCTAssertEqual(jobs[0].state, .paused)

        await h.uploads.run()
        XCTAssertEqual(h.uploads.jobs(draftID: draft.id).map(\.state), [.paused, .completed])
        XCTAssertEqual(h.remote.snapshot.uploadCalls, ["2.jpg"])

        // Pausing a completed job is a no-op; retryFailed does not touch paused jobs.
        h.uploads.pause(jobID: jobs[1].id)
        XCTAssertEqual(jobs[1].state, .completed)
        XCTAssertEqual(h.uploads.retryFailed(draftID: draft.id, autoStart: false), 0)

        h.uploads.resume(jobID: jobs[0].id, autoStart: false)
        XCTAssertEqual(jobs[0].state, .queued)
        await h.uploads.run()
        XCTAssertEqual(h.uploads.jobs(draftID: draft.id).map(\.state), [.completed, .completed])
        XCTAssertEqual(h.remote.snapshot.uploadCalls, ["2.jpg", "1.jpg"])
    }

    func testUploadQueueOfflineStaysQueued() async throws {
        let h = harness!
        let draft = h.drafts.createDraft(accountID: h.account.id)
        try h.addMediaBlock(to: draft, kind: .image, name: "1.jpg")
        try h.addMediaBlock(to: draft, kind: .file, name: "demo.zip")

        // Offline network mode: nothing is attempted.
        h.setOffline(true)
        h.uploads.enqueue(draftID: draft.id)
        await h.uploads.run()
        XCTAssertEqual(h.uploads.jobs(draftID: draft.id).map(\.state), [.queued, .queued])
        XCTAssertTrue(h.remote.snapshot.uploadCalls.isEmpty)

        // Online policy but the transport reports offline: stays queued (never failed), run stops.
        h.setOffline(false)
        h.remote.with { $0.offlineUploads = true }
        await h.uploads.run()
        let jobs = h.uploads.jobs(draftID: draft.id)
        XCTAssertEqual(jobs.map(\.state), [.queued, .queued])
        XCTAssertTrue(jobs.allSatisfy { $0.lastError == nil })
        XCTAssertEqual(h.remote.snapshot.uploadCalls, ["1.jpg"])

        // Back online: completes.
        h.remote.with { $0.offlineUploads = false }
        await h.uploads.run()
        XCTAssertEqual(h.uploads.jobs(draftID: draft.id).map(\.state), [.completed, .completed])
    }

    // MARK: Drafts

    func testAutosaveTouchUpdatesUpdatedAt() async throws {
        let h = harness!
        let draft = h.drafts.createDraft(accountID: h.account.id)
        XCTAssertEqual(draft.blocks.count, 1)
        XCTAssertEqual(draft.orderedBlocks.first?.kind, .text)
        let past = Date(timeIntervalSinceNow: -3600)
        draft.updatedAt = past
        h.drafts.saveNow()
        let savedBefore = try XCTUnwrap(h.drafts.lastAutosaveAt)

        h.drafts.autosaveDelay = .milliseconds(20)
        draft.title = "Offline edit"
        h.drafts.touch(draft)
        XCTAssertGreaterThan(draft.updatedAt, past)
        XCTAssertTrue(h.drafts.hasPendingSave)

        // Debounced save lands without an explicit saveNow.
        for _ in 0..<100 where h.drafts.hasPendingSave {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(h.drafts.hasPendingSave)
        XCTAssertGreaterThan(try XCTUnwrap(h.drafts.lastAutosaveAt), savedBefore)
        XCTAssertFalse(h.store.context.hasChanges)

        // Offline editing is fine and a published draft goes back to "local changes".
        h.setOffline(true)
        draft.status = .published
        h.drafts.addBlock(.header, to: draft, text: "H")
        XCTAssertEqual(draft.status, .local)
        XCTAssertEqual(draft.orderedBlocks.map(\.kind), [.text, .header])
    }

    func testMoveAndDeleteBlocksRenumber() throws {
        let h = harness!
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.orderedBlocks[0].text = "A"
        h.drafts.addBlock(.text, to: draft, text: "B")
        h.drafts.addBlock(.text, to: draft, text: "C")
        h.drafts.moveBlocks(in: draft, from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(draft.orderedBlocks.map(\.text), ["C", "A", "B"])
        h.drafts.moveBlock(draft.orderedBlocks[0], by: 1)
        XCTAssertEqual(draft.orderedBlocks.map(\.text), ["A", "C", "B"])
        h.drafts.deleteBlock(draft.orderedBlocks[1])
        XCTAssertEqual(draft.orderedBlocks.map(\.text), ["A", "B"])
        XCTAssertEqual(draft.orderedBlocks.map(\.order), [0, 1])
    }

    func testImportRemotePostKeepsMediaIDsAndUpdatesWithoutReupload() async throws {
        let h = harness!
        h.remote.with {
            $0.editable = RemoteEditablePost(
                id: "post-1", title: "Existing", feeRequired: 300, planID: "plan-300", status: .published,
                blocks: [
                    RemoteBlock(kind: .paragraph, text: "Hello"),
                    RemoteBlock(kind: .image, mediaID: "img-9", thumbnailURL: "https://example.invalid/t.jpg",
                                displayURL: "https://example.invalid/d.jpg", width: 800, height: 600),
                    RemoteBlock(kind: .file, mediaID: "file-1", fileName: "demo", fileExtension: "zip", fileSize: 1234),
                    RemoteBlock(kind: .url, mediaID: "ue-1", url: "https://example.com", title: "Example"),
                    RemoteBlock(kind: .embed, mediaID: "em-1", embedProvider: "youtube", embedContentID: "abc"),
                ],
                tags: ["tag1"], hasAdultContent: false, publishedAt: .now, updatedAt: .now)
        }
        let draft = try await h.drafts.importRemotePost(postID: "post-1", accountID: h.account.id)
        XCTAssertEqual(draft.remotePostID, "post-1")
        XCTAssertEqual(draft.title, "Existing")
        XCTAssertEqual(draft.targetPlanID, "plan-300")
        XCTAssertEqual(draft.feeRequired, 300)
        XCTAssertEqual(draft.tags, ["tag1"])
        let blocks = draft.orderedBlocks
        XCTAssertEqual(blocks.map(\.kind), [.text, .image, .file, .url, .embed])
        XCTAssertEqual(blocks[1].remoteMediaID, "img-9")
        XCTAssertEqual(blocks[1].remoteURL, "https://example.invalid/d.jpg")
        XCTAssertEqual(blocks[2].remoteMediaID, "file-1")
        XCTAssertEqual(blocks[2].originalFileName, "demo.zip")
        XCTAssertNil(blocks[1].localFileName)
        XCTAssertEqual(blocks[3].remoteMediaID, "ue-1", "link cards keep their FANBOX id")
        XCTAssertEqual(blocks[3].text, "Example")
        XCTAssertEqual(blocks[4].remoteMediaID, "em-1", "embeds keep their FANBOX id")
        XCTAssertEqual(draft.remoteStatus, .published)
        XCTAssertEqual(draft.remoteFeeRequired, 300)

        // Importing again reuses the unsent local draft (no second fetch, no clobbering).
        draft.title = "Edited locally"
        let again = try await h.drafts.importRemotePost(postID: "post-1", accountID: h.account.id)
        XCTAssertEqual(again.id, draft.id)
        XCTAssertEqual(again.title, "Edited locally")
        XCTAssertEqual(h.remote.snapshot.editableCalls, 1)

        // No upload jobs are created for kept media.
        XCTAssertTrue(h.uploads.enqueue(draftID: draft.id).isEmpty)

        let result = await h.drafts.publish(draftID: draft.id, publish: true)
        XCTAssertEqual(try result.get(), "post-1")
        let snap = h.remote.snapshot
        XCTAssertTrue(snap.uploadCalls.isEmpty)
        XCTAssertTrue(snap.created.isEmpty)
        XCTAssertEqual(snap.updated.count, 1)
        XCTAssertEqual(snap.updated.first?.0, "post-1")
        XCTAssertEqual(snap.updated.first?.1.blocks.compactMap(\.mediaID), ["img-9", "file-1", "ue-1", "em-1"],
                       "existing media, link cards and embeds round-trip by id")
        XCTAssertEqual(snap.updated.first?.1.publish, true, "a live post stays published")
        XCTAssertEqual(snap.writePriorities, [.interactiveWrite])
        XCTAssertEqual(draft.status, .published)
        XCTAssertNotNil(draft.publishedAt)
    }

    func testImportRemotePostOfflineThrows() async throws {
        let h = harness!
        h.setOffline(true)
        do {
            _ = try await h.drafts.importRemotePost(postID: "post-x", accountID: h.account.id)
            XCTFail("expected offline error")
        } catch {
            XCTAssertEqual(error as? RemoteError, .offline)
        }
    }

    func testPublishNewPostUploadsThenCreates() async throws {
        let h = harness!
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "New"
        draft.orderedBlocks[0].text = "Body"
        let image = try h.addMediaBlock(to: draft, kind: .image, name: "1.jpg")

        let result = await h.drafts.publish(draftID: draft.id, publish: true)
        XCTAssertEqual(try result.get(), "new-post-1")
        XCTAssertEqual(image.remoteMediaID, "m-1.jpg")
        let snap = h.remote.snapshot
        XCTAssertEqual(snap.uploadCalls, ["1.jpg"])
        XCTAssertEqual(snap.created.count, 1)
        XCTAssertEqual(snap.created.first?.blocks.map(\.kind), [.text, .image])
        XCTAssertEqual(snap.created.first?.blocks.last?.mediaID, "m-1.jpg")
        XCTAssertEqual(snap.writePriorities, [.interactiveWrite])
        XCTAssertEqual(draft.remotePostID, "new-post-1")
        XCTAssertEqual(draft.status, .published)
        XCTAssertNil(draft.lastError)
        XCTAssertFalse(h.drafts.isPublishing(draft.id))
    }

    func testPublishFailuresKeepDraftIntact() async throws {
        let h = harness!
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "Keep me"
        draft.orderedBlocks[0].text = "Body"
        try h.addMediaBlock(to: draft, kind: .image, name: "1.jpg")

        // Upload failure → publish fails, nothing created.
        h.remote.with { $0.failAlways = ["1.jpg"] }
        var result = await h.drafts.publish(draftID: draft.id, publish: true)
        guard case .failure(.invalidRequest) = result else { return XCTFail("expected upload failure, got \(result)") }
        XCTAssertEqual(draft.status, .failed)
        XCTAssertNotNil(draft.lastError)
        XCTAssertTrue(h.remote.snapshot.created.isEmpty)

        // Server error on create → failure, draft kept.
        h.remote.with {
            $0.failAlways = []
            $0.createResult = .failure(.server(status: 500))
        }
        result = await h.drafts.publish(draftID: draft.id, publish: true)
        XCTAssertEqual(result.failureValue, .server(status: 500))
        XCTAssertEqual(draft.status, .failed)
        XCTAssertEqual(draft.lastError, RemoteError.server(status: 500).userMessage)
        XCTAssertEqual(draft.blocks.count, 2)
        XCTAssertNotNil(h.store.draft(id: draft.id))
        XCTAssertNil(draft.remotePostID)

        // Unsupported → surfaced as .unsupported (UI offers the Web editor).
        h.remote.with { $0.createResult = .failure(.unsupported(operation: "createPost")) }
        result = await h.drafts.publish(draftID: draft.id, publish: false)
        XCTAssertEqual(result.failureValue, .unsupported(operation: "createPost"))
        XCTAssertEqual(draft.title, "Keep me")

        // Offline → failure without any request.
        h.remote.with { $0.createResult = .success("ok-1") }
        h.setOffline(true)
        let createdBefore = h.remote.snapshot.created.count
        result = await h.drafts.publish(draftID: draft.id, publish: true)
        XCTAssertEqual(result.failureValue, .offline)
        XCTAssertEqual(h.remote.snapshot.created.count, createdBefore)

        // FANBOX draft save succeeds once online again.
        h.setOffline(false)
        result = await h.drafts.publish(draftID: draft.id, publish: false)
        XCTAssertEqual(try result.get(), "ok-1")
        XCTAssertEqual(draft.status, .readyToPublish)
        XCTAssertNil(draft.publishedAt)
    }

    func testDeleteDraftRemovesMediaAndJobs() throws {
        let h = harness!
        let draft = h.drafts.createDraft(accountID: h.account.id)
        try h.addMediaBlock(to: draft, kind: .image, name: "1.jpg")
        h.uploads.enqueue(draftID: draft.id)
        let draftID = draft.id
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.mediaStore.directory(draftID: draftID).path))

        h.drafts.deleteDraft(draftID: draftID)
        XCTAssertNil(h.store.draft(id: draftID))
        XCTAssertTrue(h.uploads.jobs(draftID: draftID).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.mediaStore.directory(draftID: draftID).path))
        let orphanBlocks = h.store.fetch(FetchDescriptor<DraftBlock>(predicate: #Predicate { $0.draftID == draftID }))
        XCTAssertTrue(orphanBlocks.isEmpty)
    }

    func testInterruptedUploadsAndPublishesRecoverOnLaunch() throws {
        let h = harness!
        let draft = h.drafts.createDraft(accountID: h.account.id)
        try h.addMediaBlock(to: draft, kind: .image, name: "1.jpg")
        let job = try XCTUnwrap(h.uploads.enqueue(draftID: draft.id).first)
        job.state = .uploading
        job.progress = 0.5
        draft.status = .publishing
        h.store.save()

        // Simulates the next app launch with the same store.
        let provider = CreatorMockProvider(source: h.remote)
        let queue = UploadQueue(store: h.store, remote: provider, network: h.network, mediaStore: h.mediaStore)
        _ = DraftService(store: h.store, uploads: queue, remote: provider, web: WebBridge())
        XCTAssertEqual(job.state, .queued)
        XCTAssertEqual(job.progress, 0)
        XCTAssertEqual(draft.status, .failed)
        XCTAssertNotNil(draft.lastError)
        XCTAssertEqual(draft.blocks.count, 2)
    }

    // MARK: Media store

    func testDraftMediaStoreResizesLargeImageAndKeepsPNG() throws {
        let h = harness!
        let data = try Self.makeImage(width: 5000, height: 1000, type: .png)
        let item = try h.mediaStore.storeImage(data: data, draftID: "d1", displayBaseName: "1")
        XCTAssertTrue(item.wasResized)
        XCTAssertFalse(item.wasConverted)
        XCTAssertEqual(item.width, 4096)
        XCTAssertEqual(item.height.map { abs($0 - 819) <= 1 }, true)
        XCTAssertEqual(item.mimeType, "image/png")
        XCTAssertEqual(item.originalFileName, "1.png")
        let url = h.mediaStore.fileURL(draftID: "d1", fileName: item.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url).count, item.size)

        h.mediaStore.removeAll(draftID: "d1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDraftImageProcessorConvertsAndKeeps() throws {
        // TIFF (not accepted as-is) → JPEG, size kept.
        let tiff = try Self.makeImage(width: 800, height: 600, type: .tiff)
        let converted = try DraftImageProcessor.process(tiff)
        XCTAssertEqual(converted.type, .jpeg)
        XCTAssertTrue(converted.wasConverted)
        XCTAssertFalse(converted.wasResized)
        XCTAssertEqual(converted.width, 800)
        XCTAssertEqual(converted.height, 600)

        // Small JPEG is kept as JPEG without resizing.
        let jpeg = try Self.makeImage(width: 120, height: 80, type: .jpeg)
        let kept = try DraftImageProcessor.process(jpeg)
        XCTAssertEqual(kept.type, .jpeg)
        XCTAssertFalse(kept.wasConverted)
        XCTAssertFalse(kept.wasResized)
        XCTAssertEqual(kept.width, 120)

        // Large JPEG is downscaled, long edge = 4096.
        let tall = try Self.makeImage(width: 600, height: 4500, type: .jpeg)
        let resized = try DraftImageProcessor.process(tall)
        XCTAssertEqual(resized.height, 4096)
        XCTAssertEqual(resized.type, .jpeg)

        // HEIC → JPEG when the platform can encode HEIC.
        if let heic = try? Self.makeImage(width: 640, height: 480, type: .heic) {
            let fromHEIC = try DraftImageProcessor.process(heic)
            XCTAssertEqual(fromHEIC.type, .jpeg)
            XCTAssertTrue(fromHEIC.wasConverted)
            XCTAssertEqual(fromHEIC.width, 640)
        }

        XCTAssertThrowsError(try DraftImageProcessor.process(Data("not an image".utf8)))
    }

    // MARK: Pure helpers

    func testFormattingHelpers() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let start = cal.date(from: DateComponents(year: 2024, month: 1, day: 15))!
        XCTAssertEqual(CreatorFormatting.supportPeriod(startedAt: start, months: 20), "2024/01〜・20ヶ月")
        XCTAssertEqual(CreatorFormatting.supportPeriod(startedAt: nil, months: 3), "3ヶ月")
        XCTAssertEqual(CreatorFormatting.supportPeriod(startedAt: nil, months: nil), "期間不明")

        XCTAssertEqual(CreatorFormatting.metric(12, source: .actual), .value("12"))
        XCTAssertEqual(CreatorFormatting.metric(12, source: .estimated), .estimated("12"))
        XCTAssertEqual(CreatorFormatting.metric(12, source: .unavailable), .unavailable)
        XCTAssertEqual(CreatorFormatting.metric(nil, source: .actual), .unavailable)

        XCTAssertEqual(CreatorFormatting.uploadStatus(state: .uploading, progress: 0.42), "Uploading 42%")
        XCTAssertEqual(CreatorFormatting.uploadStatus(state: .completed, progress: 1), "✓")
        XCTAssertEqual(CreatorFormatting.uploadStatus(state: .queued, progress: 0), "Waiting")
        XCTAssertEqual(CreatorFormatting.monthTitle("2026-09"), "2026年9月")
    }

    func testFanFilteringAndPlanCounts() {
        let h = harness!
        func fan(_ id: String, _ name: String, plan: String?, fee: Int?, state: FanState) -> Fan {
            let f = Fan(accountID: h.account.id, userID: id, name: name, state: state)
            f.planID = plan
            f.fee = fee
            h.store.context.insert(f)
            return f
        }
        let fans = [
            fan("1", "Alice", plan: "p500", fee: 500, state: .supporting),
            fan("2", "Bob", plan: "p1000", fee: 1000, state: .supporting),
            fan("3", "Carol", plan: nil, fee: nil, state: .following),
            fan("4", "alex", plan: "p500", fee: 500, state: .ended),
        ]
        XCTAssertEqual(CreatorFanFiltering.filter(fans, query: "", plan: .all, state: nil).map(\.name), ["Bob", "Alice", "Carol", "alex"])
        XCTAssertEqual(CreatorFanFiltering.filter(fans, query: "al", plan: .all, state: nil).map(\.name), ["Alice", "alex"])
        XCTAssertEqual(CreatorFanFiltering.filter(fans, query: "", plan: .plan("p500"), state: nil).map(\.name), ["Alice", "alex"])
        XCTAssertEqual(CreatorFanFiltering.filter(fans, query: "", plan: .noPlan, state: nil).map(\.name), ["Carol"])
        XCTAssertEqual(CreatorFanFiltering.filter(fans, query: "", plan: .all, state: .supporting).count, 2)
        XCTAssertEqual(CreatorPlanCounting.supporterCounts(fans), ["p500": 1, "p1000": 1])
    }

    // MARK: Image fixtures

    static func makeImage(width: Int, height: Int, type: UTType) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw DraftMediaError.encodingFailed }
        ctx.setFillColor(CGColor(red: 0.55, green: 0.36, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.18, green: 0.83, blue: 0.75, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        guard let image = ctx.makeImage() else { throw DraftMediaError.encodingFailed }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
            throw DraftMediaError.encodingFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw DraftMediaError.encodingFailed }
        return out as Data
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

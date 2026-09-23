import SwiftData
import XCTest
@testable import FANBOXClient

// Creator Mode audit fixes: Post Edit safety / fidelity, real-account capabilities (text-first + web hand-off),
// orphan-free creates, managed post status, read throttling, JST dashboard month, web reconciliation, §43 embed vocabulary.

struct FixCreatorProvider: RemoteDataSourceProvider {
    let source: RemoteDataSource
    func dataSource(for account: AccountContext) -> RemoteDataSource { source }
}

/// DraftService wired to the real `FanboxRemoteDataSource` over the scripted HTTP client (nothing leaves the process).
@MainActor
final class FixCreatorFanboxHarness {
    let fanbox = FanboxTestHarness()
    let container: ModelContainer
    let store: LocalStore
    let settings: AppSettings
    let network: NetworkModeController
    let root: URL
    let mediaStore: DraftMediaStore
    let uploads: UploadQueue
    let drafts: DraftService
    let account: Account

    init() async throws {
        container = try PersistenceController.makeContainer(inMemory: true)
        store = LocalStore(container: container)
        settings = AppSettings(defaults: UserDefaults(suiteName: "fixcreator-\(UUID().uuidString)")!)
        settings.networkModePreference = .normal
        network = NetworkModeController(settings: settings, policyStore: NetworkPolicyStore())
        network.recompute()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FixCreator-\(UUID().uuidString)", isDirectory: true)
        mediaStore = DraftMediaStore(rootDirectory: root)
        let provider = FixCreatorProvider(source: fanbox.source)
        uploads = UploadQueue(store: store, remote: provider, network: network, mediaStore: mediaStore)
        drafts = DraftService(store: store, uploads: uploads, remote: provider, web: WebBridge())
        account = Account(kind: .fanbox, displayName: "Alice", pixivUserID: "11", fanboxUserID: "11", creatorID: "alice",
                          sessionState: .valid)
        store.context.insert(account)
        store.save()
        try await fanbox.saveCredential(accountID: account.id, csrf: "tok-abc")
    }

    var http: FanboxFakeHTTPClient { fanbox.http }

    /// Text of every post.update multipart body. post.update forms have no file parts, so they are sent from memory
    /// through `send` (the CSRF token never touches disk). Updated for native uploads: media uploads (post.addImage /
    /// post.addFile) are the only bodies sent from a file, and they are not post.update bodies.
    var updateBodies: [String] {
        let inMemory = http.requests(for: "post.update").compactMap(\.body)
        return (inMemory + http.uploadRecords(for: "post.update").map(\.body)).map { String(data: $0, encoding: .utf8) ?? "" }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

enum FixCreatorFixtures {
    /// Published article with styles, a spacing paragraph, resolved / unresolved media and link cards, and a comment scope.
    static let styledEditable = #"""
    {"id":"p1","title":"記事","status":"published","feeRequired":500,"type":"article",
     "updatedAt":"2026-09-06T10:00:00+09:00","publishedAt":"2026-09-06T10:00:00+09:00",
     "tags":["a","b"],"commentingPermissionScope":"none",
     "body":{"blocks":[
       {"type":"p","text":"太字とリンク","styles":[{"type":"bold","offset":0,"length":2}],
        "links":[{"offset":3,"length":3,"url":"https://example.com/"}]},
       {"type":"p","text":""},
       {"type":"image","imageId":"im1"},
       {"type":"image","imageId":"gone"},
       {"type":"url_embed","urlEmbedId":"ue1"},
       {"type":"url_embed","urlEmbedId":"ue-missing"},
       {"type":"embed","embedId":"em1"}
     ],
     "imageMap":{"im1":{"id":"im1","extension":"png","originalUrl":"https://downloads.fanbox.cc/images/post/p1/im1.png",
                        "thumbnailUrl":"https://downloads.fanbox.cc/images/post/p1/w/1200/im1.jpeg"}},
     "urlEmbedMap":{"ue1":{"id":"ue1","type":"fanbox.creator","profile":{"user":{"userId":"1","name":"X"}}}},
     "embedMap":{"em1":{"id":"em1","serviceProvider":"youtube","videoId":"abc"}}}}
    """#

    /// Paid post without `tags` / `commentingPermissionScope` keys (the defaultcf spec shape).
    static let bareEditable = #"""
    {"id":"p2","title":"有料","status":"published","feeRequired":500,
     "updatedAt":"2026-09-06T10:00:00+09:00","publishedAt":"2026-09-06T10:00:00+09:00",
     "body":{"blocks":[{"type":"p","text":"本文"}],"imageMap":{},"urlEmbedMap":{}}}
    """#

    static func editable(id: String, status: String = "draft", type: String? = nil, extraBlock: String? = nil) -> String {
        let typeField = type.map { #""type":"\#($0)","# } ?? ""
        let blocks = [#"{"type":"p","text":"本文"}"#, extraBlock].compactMap { $0 }.joined(separator: ",")
        return #"{"id":"\#(id)",\#(typeField)"title":"T","status":"\#(status)","feeRequired":0,"tags":[],"commentingPermissionScope":"everyone","#
            + #""updatedAt":"2026-09-06T10:00:00+09:00","body":{"blocks":[\#(blocks)],"imageMap":{},"urlEmbedMap":{}}}"#
    }
}

@MainActor
final class FixCreatorTests: XCTestCase {
    private var harness: CreatorTestHarness!

    override func setUp() async throws {
        harness = try CreatorTestHarness()
    }

    override func tearDown() async throws {
        harness?.cleanUp()
        harness = nil
    }

    private func publishedEditable(status: RemotePostStatus = .published, updatedAt: Date = Date(timeIntervalSince1970: 1_780_000_000),
                                   planID: String? = nil, fee: Int = 300) -> RemoteEditablePost {
        RemoteEditablePost(id: "post-1", title: "Existing", feeRequired: fee, planID: planID, status: status,
                           blocks: [RemoteBlock(kind: .paragraph, text: "Hello")], tags: ["t"], hasAdultContent: false,
                           publishedAt: updatedAt, updatedAt: updatedAt)
    }

    // MARK: Post Edit never unpublishes by accident

    func testUpdateOfLivePostStaysPublishedAndUnpublishNeedsConfirmation() async throws {
        let h = harness!
        h.remote.with { $0.editable = self.publishedEditable() }
        let draft = try await h.drafts.importRemotePost(postID: "post-1", accountID: h.account.id)
        XCTAssertEqual(draft.remoteStatus, .published)
        draft.orderedBlocks[0].text = "Hello, edited"

        // "FANBOX に下書き保存" on a live post = unpublish: refused without explicit confirmation, nothing sent.
        let refused = await h.drafts.publish(draftID: draft.id, publish: false)
        guard case .failure(.invalidRequest) = refused else { return XCTFail("expected refusal, got \(refused)") }
        XCTAssertTrue(h.remote.snapshot.updated.isEmpty)
        XCTAssertEqual(h.remote.snapshot.editableCalls, 1, "refused before any request")
        XCTAssertNotEqual(draft.status, .failed)

        let plan = try XCTUnwrap(h.drafts.plan(draftID: draft.id, publish: false))
        XCTAssertTrue(plan.unpublishes)
        XCTAssertTrue(plan.notes.contains { $0.contains("非公開") })
        XCTAssertFalse(try XCTUnwrap(h.drafts.plan(draftID: draft.id, publish: true)).unpublishes)

        // Default action: update and stay published.
        let updated = await h.drafts.send(draftID: draft.id, publish: true)
        XCTAssertEqual(try updated.get().sentPublished, true)
        XCTAssertEqual(h.remote.snapshot.updated.last?.1.publish, true)
        XCTAssertEqual(draft.remoteStatus, .published)

        // Explicitly confirmed unpublish.
        draft.orderedBlocks[0].text = "Hello, again"
        h.drafts.touch(draft)
        let down = await h.drafts.send(draftID: draft.id, publish: false, allowUnpublish: true)
        XCTAssertEqual(try down.get().sentPublished, false)
        XCTAssertEqual(h.remote.snapshot.updated.last?.1.publish, false)
        XCTAssertEqual(draft.remoteStatus, .draft)
        XCTAssertEqual(draft.status, .readyToPublish)
    }

    func testLegacyLinkedDraftWithUnknownStatusIsTreatedAsPossiblyLive() {
        let h = harness!
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "T"
        draft.orderedBlocks[0].text = "x"
        draft.remotePostID = "old-1"
        XCTAssertEqual(draft.remoteStatus, .unknown)
        let plan = DraftSendPlanner.plan(draft: draft, capabilities: .full, publish: false)
        XCTAssertTrue(plan.unpublishes, "a draft save may take a live post down: needs confirmation")
    }

    func testRemoteChangesStopTheUpdate() async throws {
        let h = harness!
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        h.remote.with { $0.editable = self.publishedEditable(updatedAt: base) }
        let draft = try await h.drafts.importRemotePost(postID: "post-1", accountID: h.account.id)

        // Edited in the web editor meanwhile (newer revision): never overwritten.
        h.remote.with { $0.editable?.updatedAt = base.addingTimeInterval(120) }
        let conflict = await h.drafts.send(draftID: draft.id, publish: true)
        XCTAssertEqual(conflict.failureValue, .invalidRequest(DraftService.conflictMessage))
        XCTAssertTrue(h.remote.snapshot.updated.isEmpty)
        XCTAssertEqual(draft.status, .failed)

        // Unpublished elsewhere (same revision): "update, stay published" must not republish it.
        h.remote.with {
            $0.editable?.updatedAt = base
            $0.editable?.status = .draft
        }
        let changed = await h.drafts.send(draftID: draft.id, publish: true)
        guard case .failure(.invalidRequest) = changed else { return XCTFail("expected status change refusal, got \(changed)") }
        XCTAssertTrue(h.remote.snapshot.updated.isEmpty)
        XCTAssertEqual(draft.remoteStatus, .draft, "fresh status recorded for the next attempt")
    }

    // MARK: Plan picker fidelity

    func testImportSelectsThePlanMatchingTheFee() async throws {
        let h = harness!
        h.store.context.insert(Plan(planID: "p300", creatorID: "me", title: "スタンダード", fee: 300))
        h.store.context.insert(Plan(planID: "p500", creatorID: "me", title: "上位", fee: 500))
        h.store.save()
        h.remote.with { $0.editable = self.publishedEditable(planID: nil, fee: 300) }
        let draft = try await h.drafts.importRemotePost(postID: "post-1", accountID: h.account.id)
        XCTAssertEqual(draft.targetPlanID, "p300")
        XCTAssertEqual(draft.feeRequired, 300)
    }

    // MARK: Orphan / duplicate protection

    func testPartialCreateStoresPostIDSoRetryUpdates() async throws {
        let h = harness!
        h.remote.with { $0.createError = RemotePostCreatedPartially(postID: "made-1", underlying: .server(status: 500)) }
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "New"
        draft.orderedBlocks[0].text = "Body"

        let first = await h.drafts.publish(draftID: draft.id, publish: false)
        XCTAssertEqual(first.failureValue, .server(status: 500))
        XCTAssertEqual(draft.remotePostID, "made-1", "persisted before anything else")
        XCTAssertEqual(draft.remoteStatus, .draft)
        XCTAssertTrue(draft.lastError?.contains("再送") ?? false)

        h.remote.with {
            $0.createError = nil
            $0.editable = RemoteEditablePost(id: "made-1", title: "", feeRequired: 0, planID: nil, status: .draft, blocks: [], tags: [],
                                             hasAdultContent: false, publishedAt: nil, updatedAt: .now)
        }
        let second = await h.drafts.publish(draftID: draft.id, publish: false)
        XCTAssertEqual(try second.get(), "made-1")
        XCTAssertEqual(h.remote.snapshot.created.count, 1, "never a second create")
        XCTAssertEqual(h.remote.snapshot.updated.map(\.0), ["made-1"])
    }

    func testTagLimitIsCheckedBeforeAnyRequest() async throws {
        let h = harness!
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "T"
        draft.orderedBlocks[0].text = "Body"
        draft.tags = ["1", "2", "3", "4", "5", "6", "7"]
        let result = await h.drafts.publish(draftID: draft.id, publish: true)
        guard case .failure(.invalidRequest(let message)) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(message.contains("6"))
        XCTAssertTrue(h.remote.snapshot.created.isEmpty)
        XCTAssertThrowsError(try DraftPostMapping.validateBasics(title: "T", tags: draft.tags))
        XCTAssertNoThrow(try DraftPostMapping.validateBasics(title: "T", tags: Array(draft.tags.prefix(6))))
    }

    // MARK: Upload queue with accounts that cannot upload

    func testUnsupportedUploadIsPausedForWebNotFailed() async throws {
        let h = harness!
        h.remote.with { $0.unsupportedUploads = true }
        let draft = h.drafts.createDraft(accountID: h.account.id)
        try h.addMediaBlock(to: draft, kind: .image, name: "1.jpg")
        try h.addMediaBlock(to: draft, kind: .image, name: "2.jpg")
        h.uploads.enqueue(draftID: draft.id)
        await h.uploads.run()
        let jobs = h.uploads.jobs(draftID: draft.id)
        XCTAssertEqual(jobs.map(\.state), [.paused, .paused])
        XCTAssertTrue(jobs.allSatisfy { $0.lastError == UploadQueue.webOnlyMessage })
        XCTAssertEqual(h.remote.snapshot.uploadCalls, ["1.jpg"], "stops after the first unsupported answer")
        XCTAssertEqual(h.uploads.retryFailed(draftID: draft.id, autoStart: false), 0)

        // Capability known up front: no upload is even attempted.
        h.remote.with { $0.capabilities = .textOnly }
        h.uploads.resumeAll(draftID: draft.id, autoStart: false)
        await h.uploads.run()
        XCTAssertEqual(h.remote.snapshot.uploadCalls, ["1.jpg"])
        XCTAssertEqual(h.uploads.jobs(draftID: draft.id).map(\.state), [.paused, .paused])
    }

    // MARK: Text-first send + web hand-off (capability textOnly, fake remote)

    func testTextFirstSendNeverPublishesAnUnfinishedNewPost() async throws {
        let h = harness!
        h.remote.with { $0.capabilities = .textOnly }
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "New"
        draft.orderedBlocks[0].text = "本文"
        let image = try h.addMediaBlock(to: draft, kind: .image, name: "1.jpg")
        let link = h.drafts.addBlock(.url, to: draft)
        link.url = "https://example.com/x"

        let plan = try XCTUnwrap(h.drafts.plan(draftID: draft.id, publish: true))
        XCTAssertTrue(plan.canSend)
        XCTAssertFalse(plan.sendsPublished)
        XCTAssertEqual(plan.webItems.map(\.kind), [.image, .url])
        XCTAssertEqual(plan.webItems.map(\.position), [2, 3])
        XCTAssertEqual(plan.webItems.first?.afterLabel, "「本文」")
        XCTAssertTrue(plan.notes.contains { $0.contains("下書きとして保存") })

        let receipt = try await h.drafts.send(draftID: draft.id, publish: true).get()
        XCTAssertFalse(receipt.sentPublished)
        XCTAssertEqual(receipt.webItems.map(\.id), [image.id, link.id])
        let created = try XCTUnwrap(h.remote.snapshot.created.first)
        XCTAssertFalse(created.publish)
        XCTAssertEqual(created.blocks.map(\.kind), [.text], "text first; media / link card left for the web editor")
        XCTAssertTrue(h.remote.snapshot.uploadCalls.isEmpty)
        XCTAssertEqual(draft.status, .readyToPublish)
        XCTAssertNotNil(draft.webHandoffAt)
        XCTAssertEqual(draft.remotePostID, "new-post-1")

        // Processed media exported under body-ordered names for the web file picker.
        let exported = h.drafts.exportWebItemFiles(draftID: draft.id, items: receipt.webItems)
        XCTAssertEqual(exported[image.id]?.lastPathComponent, "02-1.jpg")
        XCTAssertNil(exported[link.id])

        // Finished on the web.
        h.drafts.markCompletedOnWeb(draftID: draft.id, as: .published)
        XCTAssertNil(draft.webHandoffAt)
        XCTAssertEqual(draft.status, .published)
        XCTAssertEqual(draft.remoteStatus, .published)
    }

    func testMultiLineTextBecomesParagraphsAfterSend() async throws {
        let h = harness!
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "T"
        draft.orderedBlocks[0].text = "一行目\n\n三行目"
        _ = try await h.drafts.publish(draftID: draft.id, publish: true).get()
        XCTAssertEqual(h.remote.snapshot.created.first?.blocks.map(\.text), ["一行目", "", "三行目"])
        XCTAssertEqual(draft.orderedBlocks.map(\.text), ["一行目", "", "三行目"])
        XCTAssertEqual(draft.orderedBlocks.map(\.importedText), ["一行目", "", "三行目"], "baseline = what FANBOX holds")
        XCTAssertEqual(draft.status, .published)
    }

    // MARK: Styles

    func testRebasedStyles() {
        let bold = RemoteTextStyle(type: "bold", offset: 0, length: 2, size: nil)
        let link = RemoteTextStyle(type: "link:https://e.example/", offset: 3, length: 3, size: nil)
        // Insertion before everything: shifted.
        var r = DraftPostMapping.rebasedStyles([bold, link], from: "太字とリンク", to: "新しい太字とリンク")
        XCTAssertEqual(r.lost, 0)
        XCTAssertEqual(r.styles.map(\.offset), [3, 6])
        // Edit inside the link: the link grows, bold untouched.
        r = DraftPostMapping.rebasedStyles([bold, link], from: "太字とリンク", to: "太字とリンンク")
        XCTAssertEqual(r.lost, 0)
        XCTAssertEqual(r.styles.map(\.length), [2, 4])
        // Edit inside bold: bold grows with it, link shifted.
        r = DraftPostMapping.rebasedStyles([bold, link], from: "太字とリンク", to: "太あいとリンク")
        XCTAssertEqual(r.lost, 0)
        XCTAssertEqual(r.styles, [RemoteTextStyle(type: "bold", offset: 0, length: 3, size: nil),
                                  RemoteTextStyle(type: link.type, offset: 4, length: 3, size: nil)])
        // Edit crossing the end of bold: bold lost, link shifted.
        r = DraftPostMapping.rebasedStyles([bold, link], from: "太字とリンク", to: "太Xリンク")
        XCTAssertEqual(r.lost, 1)
        XCTAssertEqual(r.styles, [RemoteTextStyle(type: link.type, offset: 2, length: 3, size: nil)])
        // Outside the BMP the offset unit is unverified: nothing is moved.
        r = DraftPostMapping.rebasedStyles([bold], from: "太字😀", to: "太字😀!")
        XCTAssertEqual(r.lost, 1)
        XCTAssertTrue(r.styles.isEmpty)
        // Unchanged text keeps everything (also outside the BMP).
        r = DraftPostMapping.rebasedStyles([bold], from: "😀字", to: "😀字")
        XCTAssertEqual(r.lost, 0)
        XCTAssertEqual(r.styles, [bold])
    }

    func testParagraphSplitMovesStyles() {
        let styles = [RemoteTextStyle(type: "bold", offset: 1, length: 4, size: nil)]
        let parts = DraftPostMapping.paragraphs(of: "ab\ncd", styles: styles)
        XCTAssertEqual(parts.map(\.text), ["ab", "cd"])
        XCTAssertEqual(parts[0].styles, [RemoteTextStyle(type: "bold", offset: 1, length: 1, size: nil)])
        XCTAssertEqual(parts[1].styles, [RemoteTextStyle(type: "bold", offset: 0, length: 2, size: nil)])
    }

    func testFormattingLossNeedsAcceptance() async throws {
        let h = harness!
        h.remote.with {
            $0.editable = RemoteEditablePost(
                id: "post-1", title: "T", feeRequired: 0, planID: nil, status: .draft,
                blocks: [RemoteBlock(kind: .paragraph, text: "太字とリンク",
                                     styles: [RemoteTextStyle(type: "bold", offset: 0, length: 2, size: nil)])],
                tags: [], hasAdultContent: false, publishedAt: nil, updatedAt: .now)
        }
        let draft = try await h.drafts.importRemotePost(postID: "post-1", accountID: h.account.id)
        draft.orderedBlocks[0].text = "太Xリンク"
        let plan = try XCTUnwrap(h.drafts.plan(draftID: draft.id, publish: false))
        XCTAssertEqual(plan.warnings.count, 1)
        let refused = await h.drafts.send(draftID: draft.id, publish: false)
        guard case .failure(.invalidRequest) = refused else { return XCTFail("\(refused)") }
        XCTAssertTrue(h.remote.snapshot.updated.isEmpty)
        _ = try await h.drafts.send(draftID: draft.id, publish: false, acceptWarnings: true).get()
        XCTAssertEqual(h.remote.snapshot.updated.first?.1.blocks.first?.styles, [], "the lost style is not sent at a wrong offset")
    }

    // MARK: Managed posts: status, reader visibility, pruning; read throttling

    func testManagedStatusAndPruning() async throws {
        let h = harness!
        let engine = SyncEngine(store: h.store, remote: CreatorMockProvider(source: h.remote), settings: h.settings, network: h.network)
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        func summary(_ id: String, _ status: RemotePostStatus?, minutesAgo: Double) -> RemotePostSummary {
            var s = RemotePostSummary(id: id, creatorID: "me", creatorName: "Me", title: id, publishedAt: base.addingTimeInterval(-minutesAgo * 60))
            s.remoteStatus = status
            return s
        }
        // Posts of my creator page known from reader listings: one newer than the listing's oldest, one older.
        let gone = Post(postID: "gone", creatorID: "me", creatorName: "Me", title: "gone", publishedAt: base.addingTimeInterval(-60))
        gone.isFavorite = true
        let old = Post(postID: "old", creatorID: "me", creatorName: "Me", title: "old", publishedAt: base.addingTimeInterval(-99_999))
        h.store.context.insert(gone)
        h.store.context.insert(old)
        h.store.save()

        h.remote.with { $0.managed = [summary("m1", .published, minutesAgo: 0), summary("m2", .draft, minutesAgo: 10)] }
        let outcome = await engine.sync(.creatorPosts, accountID: h.account.id, reason: .userRefresh)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(h.store.post(id: "m1")?.remoteStatusRaw, "published")
        XCTAssertEqual(h.store.post(id: "m2")?.remoteStatusRaw, "draft")
        XCTAssertFalse(h.store.post(id: "m2")?.isVisibleToReaders ?? true, "own FANBOX drafts stay out of reader views")
        XCTAssertEqual(gone.remoteStatusRaw, LocalStore.removedManagedStatus, "missing from the complete listing")
        XCTAssertTrue(gone.isFavorite, "user metadata is kept")
        XCTAssertFalse(gone.isVisibleToReaders)
        XCTAssertNil(old.remoteStatusRaw, "older than the listing: not judged (the listing may be capped)")

        // Listed again → no longer removed.
        h.remote.with { $0.managed.append(summary("gone", .published, minutesAgo: 1)) }
        await engine.sync(.creatorPosts, accountID: h.account.id, reason: .userRefresh)
        XCTAssertEqual(gone.remoteStatusRaw, "published")

        // An empty listing never marks anything.
        h.remote.with { $0.managed = [] }
        await engine.sync(.creatorPosts, accountID: h.account.id, reason: .userRefresh)
        XCTAssertEqual(gone.remoteStatusRaw, "published")
    }

    func testFanboxManagedSummariesCarryStatus() throws {
        let month = FanboxDateParser.monthKey(.now)
        let body = try FanboxFixtures.decodeBody(FanboxManagedPostListBody.self,
                                                 FanboxFixtures.managedPosts.replacingOccurrences(of: "MONTH", with: month))
        let summaries = FanboxAdapter.managedPostSummaries(body.items, creatorID: "alice", creatorName: "Alice", creatorIconURL: nil)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0.remoteStatus) }),
                       ["m1": .published, "m2": .draft, "m3": .published])
    }

    func testCreatorReadsAreThrottledOnScreenAppear() async throws {
        let h = harness!
        let engine = SyncEngine(store: h.store, remote: CreatorMockProvider(source: h.remote), settings: h.settings, network: h.network)
        await engine.sync(.fans, accountID: h.account.id, reason: .onDemand)
        await engine.sync(.fans, accountID: h.account.id, reason: .onDemand)
        await engine.sync(.creatorDashboard, accountID: h.account.id, reason: .onDemand)
        await engine.sync(.creatorDashboard, accountID: h.account.id, reason: .appLaunch)
        XCTAssertEqual(h.remote.snapshot.fansCalls, 1)
        XCTAssertEqual(h.remote.snapshot.dashboardCalls, 1)
        // Pull-to-refresh / after a write always fetch.
        await engine.sync(.fans, accountID: h.account.id, reason: .userRefresh)
        await engine.sync(.creatorDashboard, accountID: h.account.id, reason: .afterWrite)
        XCTAssertEqual(h.remote.snapshot.fansCalls, 2)
        XCTAssertEqual(h.remote.snapshot.dashboardCalls, 2)

        let now = Date()
        // The fan list is throttled inside SyncEngine (fansOnDemandInterval / fansAutomaticInterval, asserted above).
        XCTAssertTrue(CreatorReadPolicy.isFresh(.creatorDashboard, scope: "", reason: .onDemand, lastSuccess: now.addingTimeInterval(-5 * 60), now: now))
        XCTAssertFalse(CreatorReadPolicy.isFresh(.creatorDashboard, scope: "", reason: .onDemand, lastSuccess: now.addingTimeInterval(-11 * 60), now: now))
        XCTAssertFalse(CreatorReadPolicy.isFresh(.creatorComments, scope: "", reason: .onDemand, lastSuccess: now.addingTimeInterval(-11 * 60), now: now))
        XCTAssertFalse(CreatorReadPolicy.isFresh(.creatorPosts, scope: "someone", reason: .onDemand, lastSuccess: now, now: now),
                       "reader creator pages are not throttled here")
        XCTAssertFalse(CreatorReadPolicy.isFresh(.fans, scope: "", reason: .notification, lastSuccess: now, now: now))
        XCTAssertFalse(CreatorReadPolicy.isFresh(.fans, scope: "", reason: .onDemand, lastSuccess: nil, now: now))
    }

    // MARK: Small pure pieces

    func testDashboardMonthIsJST() throws {
        let lateAugustUTC = try XCTUnwrap(FanboxDateParser.parse("2026-08-31T20:00:00Z"))
        XCTAssertEqual(CreatorFormatting.monthKey(lateAugustUTC), "2026-09", "same key the snapshot is stored under")
        XCTAssertEqual(CreatorFormatting.monthKey(lateAugustUTC), FanboxDateParser.monthKey(lateAugustUTC))
    }

    func testWebReconcileAndCapabilities() {
        XCTAssertTrue(CreatorWebReconcile.needsManagedPostsResync(
            WebSessionRequest(accountID: "a", destination: .managePostEditor(postID: "1"), purpose: .fallback(reason: "x"))))
        XCTAssertTrue(CreatorWebReconcile.needsManagedPostsResync(WebSessionRequest(accountID: "a", destination: .managePosts, purpose: .browse)))
        XCTAssertFalse(CreatorWebReconcile.needsManagedPostsResync(WebSessionRequest(accountID: "a", destination: .home, purpose: .browse)))

        // Updated for native uploads: FANBOX accounts upload images / files and register link cards natively (into the
        // post, created first); new embeds, the R-18 flag and plan ids stay web-only.
        let fanbox = FanboxTestHarness().source
        XCTAssertEqual(fanbox.draftCapabilities, .fanbox)
        XCTAssertTrue(fanbox.draftCapabilities.sendsNew(.image))
        XCTAssertTrue(fanbox.draftCapabilities.sendsNew(.file))
        XCTAssertTrue(fanbox.draftCapabilities.sendsNew(.url))
        XCTAssertFalse(fanbox.draftCapabilities.sendsNew(.embed))
        XCTAssertTrue(fanbox.draftCapabilities.sendsNew(.header))
        XCTAssertFalse(fanbox.draftCapabilities.sendsAdultFlag)
        XCTAssertFalse(fanbox.draftCapabilities.sendsPlanID)
        XCTAssertTrue(fanbox.draftCapabilities.uploadsNeedPost)
        // Updated: the demo runs the same create-first flow (uploads bound to the post) with every block kind.
        let demo: RemoteDataSource = DemoRemoteDataSource()
        XCTAssertEqual(demo.draftCapabilities, .demo)
        XCTAssertTrue(demo.draftCapabilities.uploadsNeedPost)
        XCTAssertTrue(demo.draftCapabilities.sendsNew(.embed))
    }

    func testImportKeepsUnsupportedContentVisibleAndBlocksNativeUpdate() {
        let unknown = DraftPostMapping.importedBlock(from: RemoteBlock(kind: .unknown, text: "謎", subtitle: "sparkle"))
        XCTAssertTrue(unknown.isLocked)
        XCTAssertNotNil(unknown.unsupportedReason)
        XCTAssertTrue(unknown.text.contains("謎"))
        let unresolvedLink = DraftPostMapping.importedBlock(from: RemoteBlock(kind: .url, mediaID: "ue9"))
        XCTAssertEqual(unresolvedLink.kind, .url)
        XCTAssertEqual(unresolvedLink.remoteMediaID, "ue9")
        XCTAssertTrue(unresolvedLink.isLocked)
        XCTAssertNil(unresolvedLink.unsupportedReason, "kept by id: round-trips")

        let editable = RemoteEditablePost(id: "x", title: "", feeRequired: 0, planID: nil, status: .published, blocks: [], tags: [],
                                          hasAdultContent: false, publishedAt: nil, updatedAt: nil, postType: .image)
        XCTAssertNotNil(DraftService.nativeUpdateBlocker(editable: editable, unsupportedBlocks: [], capabilities: .textOnly))
        XCTAssertNil(DraftService.nativeUpdateBlocker(editable: editable, unsupportedBlocks: [], capabilities: .full))
        XCTAssertNil(DraftService.nativeUpdateBlocker(editable: editable, unsupportedBlocks: [], capabilities: .fanbox),
                     "FANBOX image posts are saved with their own {text, images} body")
        var video = editable
        video.postType = .video
        XCTAssertNotNil(DraftService.nativeUpdateBlocker(editable: video, unsupportedBlocks: [], capabilities: .fanbox))
        var scheduled = editable
        scheduled.postType = .article
        scheduled.status = .scheduled
        XCTAssertNotNil(DraftService.nativeUpdateBlocker(editable: scheduled, unsupportedBlocks: [], capabilities: .full))
    }
}

/// End-to-end through the FANBOX adapter and the multipart post.update form (scripted HTTP; nothing is sent anywhere).
@MainActor
final class FixCreatorFanboxRoundTripTests: XCTestCase {
    private var h: FixCreatorFanboxHarness!

    override func setUp() async throws {
        h = try await FixCreatorFanboxHarness()
    }

    override func tearDown() async throws {
        h?.cleanUp()
        h = nil
    }

    func testUnchangedPostRoundTripsStylesSpacingMediaAndLinkCards() async throws {
        h.http.stub("post.getEditable", json: FanboxFixtures.envelope(FixCreatorFixtures.styledEditable))
        h.http.stub("post.update", json: #"{"body":{"id":"p1"}}"#)
        let draft = try await h.drafts.importRemotePost(postID: "p1", accountID: h.account.id)
        XCTAssertEqual(draft.remoteStatus, .published)
        XCTAssertEqual(draft.commentPermission, .disabled)
        XCTAssertEqual(draft.remoteFeeRequired, 500)
        XCTAssertNil(draft.nativeUpdateBlocker)
        let blocks = draft.orderedBlocks
        XCTAssertEqual(blocks.map(\.kind), [.text, .text, .image, .image, .url, .url, .embed])
        XCTAssertEqual(blocks[1].importedText, "", "spacing paragraph kept")
        XCTAssertEqual(blocks[3].remoteMediaID, "gone")
        XCTAssertTrue(blocks[3].isLockedRemote)
        XCTAssertEqual(blocks[4].remoteMediaID, "ue1", "link card without a resolvable URL is kept, not dropped")
        XCTAssertEqual(blocks[5].remoteMediaID, "ue-missing")
        XCTAssertEqual(blocks[6].remoteMediaID, "em1")

        _ = try await h.drafts.send(draftID: draft.id, publish: true).get()
        XCTAssertTrue(h.http.requests(for: "post.create").isEmpty)
        let body = try XCTUnwrap(h.updateBodies.last)
        XCTAssertTrue(body.contains(#"{"links":[{"length":3,"offset":3,"url":"https://example.com/"}],"styles":[{"length":2,"offset":0,"type":"bold"}],"text":"太字とリンク","type":"p"}"#), body)
        XCTAssertTrue(body.contains(#"{"text":"","type":"p"}"#))
        XCTAssertTrue(body.contains(#"{"imageId":"im1","type":"image"}"#))
        XCTAssertTrue(body.contains(#"{"imageId":"gone","type":"image"}"#))
        XCTAssertTrue(body.contains(#"{"type":"url_embed","urlEmbedId":"ue1"}"#))
        XCTAssertTrue(body.contains(#"{"type":"url_embed","urlEmbedId":"ue-missing"}"#))
        XCTAssertTrue(body.contains(#"{"embedId":"em1","type":"embed"}"#))
        XCTAssertTrue(body.contains("name=\"status\"\r\n\r\npublished\r\n"))
        XCTAssertTrue(body.contains("name=\"commentingPermissionScope\"\r\n\r\nnone\r\n"), "the post's own setting is kept")
        XCTAssertTrue(body.contains("name=\"tags\"\r\n\r\na\r\n"))
        XCTAssertTrue(body.contains("name=\"feeRequired\"\r\n\r\n500\r\n"))
    }

    func testEditedStyledParagraphKeepsShiftedStyles() async throws {
        h.http.stub("post.getEditable", json: FanboxFixtures.envelope(FixCreatorFixtures.styledEditable))
        h.http.stub("post.update", json: #"{"body":{"id":"p1"}}"#)
        let draft = try await h.drafts.importRemotePost(postID: "p1", accountID: h.account.id)
        draft.orderedBlocks[0].text = "新しい太字とリンク"
        _ = try await h.drafts.send(draftID: draft.id, publish: true).get()
        let body = try XCTUnwrap(h.updateBodies.last)
        XCTAssertTrue(body.contains(#"{"links":[{"length":3,"offset":6,"url":"https://example.com/"}],"styles":[{"length":2,"offset":3,"type":"bold"}],"text":"新しい太字とリンク","type":"p"}"#), body)
    }

    func testMissingTagsAndCommentScopeNeedConfirmation() async throws {
        let cached = Post(postID: "p2", creatorID: "alice", creatorName: "Alice", title: "有料", publishedAt: .now)
        cached.fanboxTags = ["既存タグ"]
        h.store.context.insert(cached)
        h.store.save()
        h.http.stub("post.getEditable", json: FanboxFixtures.envelope(FixCreatorFixtures.bareEditable))
        h.http.stub("post.update", json: #"{"body":{"id":"p2"}}"#)
        let draft = try await h.drafts.importRemotePost(postID: "p2", accountID: h.account.id)
        XCTAssertTrue(draft.tagsUnverified)
        XCTAssertEqual(draft.tags, ["既存タグ"], "prefilled from the local listing")
        XCTAssertNil(draft.commentPermission)
        let plan = try XCTUnwrap(h.drafts.plan(draftID: draft.id, publish: true))
        XCTAssertEqual(plan.warnings.count, 2)

        let refused = await h.drafts.send(draftID: draft.id, publish: true)
        guard case .failure(.invalidRequest) = refused else { return XCTFail("\(refused)") }
        XCTAssertTrue(h.http.requests(for: "post.update").isEmpty)

        _ = try await h.drafts.send(draftID: draft.id, publish: true, acceptWarnings: true).get()
        let body = try XCTUnwrap(h.updateBodies.last)
        XCTAssertTrue(body.contains("name=\"commentingPermissionScope\"\r\n\r\nsupporters\r\n"))
        XCTAssertTrue(body.contains("name=\"tags\"\r\n\r\n既存タグ\r\n"))
    }

    func testUnsupportedContentBlocksNativeUpdate() async throws {
        h.http.stub("post.getEditable", json: FanboxFixtures.envelope(
            FixCreatorFixtures.editable(id: "p3", status: "published", extraBlock: #"{"type":"sparkle","text":"未知"}"#)))
        let draft = try await h.drafts.importRemotePost(postID: "p3", accountID: h.account.id)
        XCTAssertNotNil(draft.nativeUpdateBlocker)
        XCTAssertTrue(draft.orderedBlocks.contains { $0.isLockedRemote && $0.text.contains("未知") }, "kept visibly, not dropped")
        let result = await h.drafts.send(draftID: draft.id, publish: true)
        guard case .failure(.unsupported) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(h.http.requests(for: "post.update").isEmpty)

        // Updated for native uploads: image-type posts are now updated natively with their own {text, images} body
        // (NativeUploadTests.testImportedImagePostKeepsItsTypeAndListsImages); video-type posts still go to the web editor.
        h.http.stub("post.getEditable", json: FanboxFixtures.envelope(FixCreatorFixtures.editable(id: "p4", status: "published", type: "image")))
        let imagePost = try await h.drafts.importRemotePost(postID: "p4", accountID: h.account.id)
        XCTAssertNil(imagePost.nativeUpdateBlocker)
        XCTAssertEqual(imagePost.remotePostType, .image)
        h.http.stub("post.getEditable", json: FanboxFixtures.envelope(FixCreatorFixtures.editable(id: "p5", status: "published", type: "video")))
        let videoPost = try await h.drafts.importRemotePost(postID: "p5", accountID: h.account.id)
        XCTAssertNotNil(videoPost.nativeUpdateBlocker, "a block body would turn a video post into an article")
    }

    func testFailedUpdateAfterCreateNeverCreatesTwice() async throws {
        h.http.stub("post.create", json: #"{"body":{"postId":"9001"}}"#)
        h.http.stub("post.update", status: 500, json: #"{"error":"general_error"}"#)
        h.http.stub("post.update", json: #"{"body":{"id":"9001"}}"#)
        h.http.stub("post.getEditable", json: FanboxFixtures.envelope(FixCreatorFixtures.editable(id: "9001")))
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "T"
        draft.orderedBlocks[0].text = "本文"

        let first = await h.drafts.send(draftID: draft.id, publish: false)
        XCTAssertEqual(first.failureValue, .server(status: 500))
        XCTAssertEqual(draft.remotePostID, "9001")

        _ = try await h.drafts.send(draftID: draft.id, publish: false).get()
        XCTAssertEqual(h.http.requests(for: "post.create").count, 1, "the retry updates the created draft")
        XCTAssertEqual(h.http.requests(for: "post.update").count, 2)
    }

    func testTagLimitAndTitleCheckedBeforePostCreate() async throws {
        let tooMany = RemotePostDraft(title: "t", feeRequired: 0, planID: nil, tags: ["1", "2", "3", "4", "5", "6", "7"], hasAdultContent: false,
                                      blocks: [RemoteDraftBlock(kind: .text, text: "x", mediaID: nil, url: nil, embedProvider: nil, embedContentID: nil)],
                                      publish: false)
        do {
            _ = try await h.fanbox.source.createPost(tooMany, account: h.account.context)
            XCTFail("expected tag limit")
        } catch let error as RemoteError {
            guard case .invalidRequest = error else { return XCTFail("\(error)") }
        }
        var untitled = tooMany
        untitled.tags = []
        untitled.title = " "
        do {
            _ = try await h.fanbox.source.createPost(untitled, account: h.account.context)
            XCTFail("expected title error")
        } catch let error as RemoteError {
            guard case .invalidRequest = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(h.http.requests.isEmpty, "nothing is created on FANBOX")
    }

    func testTextFirstCreateThroughTheFanboxForm() async throws {
        // Updated for native uploads: the image is uploaded into the post (created first) and only the embed, which has
        // no add endpoint, is left for the web editor. The post is still saved as a draft, never published unfinished.
        h.http.stub("post.create", json: #"{"body":{"postId":"9002"}}"#)
        h.http.stub("post.addImage", json: #"{"body":{"id":"im-new","extension":"jpg","width":10,"height":10,"originalUrl":"https://downloads.fanbox.cc/images/post/9002/im-new.jpg","thumbnailUrl":"https://downloads.fanbox.cc/images/post/9002/w/1200/im-new.jpeg"}}"#)
        h.http.stub("post.update", json: #"{"body":{"id":"9002"}}"#)
        h.http.stub("post.getEditable", json: FanboxFixtures.envelope(FixCreatorFixtures.editable(id: "9002")))
        let draft = h.drafts.createDraft(accountID: h.account.id)
        draft.title = "T"
        draft.orderedBlocks[0].text = "本文"
        try h.mediaStore.ensureDirectory(draftID: draft.id)
        try Data("img".utf8).write(to: h.mediaStore.fileURL(draftID: draft.id, fileName: "a.jpg"))
        let image = h.drafts.addBlock(.image, to: draft)
        image.localFileName = "a.jpg"
        image.originalFileName = "1.jpg"
        let embed = h.drafts.addBlock(.embed, to: draft)
        embed.url = "https://youtu.be/abc123"

        let receipt = try await h.drafts.send(draftID: draft.id, publish: true).get()
        XCTAssertEqual(receipt.webItems.map(\.kind), [.embed])
        XCTAssertEqual(image.remoteMediaID, "im-new")
        let body = try XCTUnwrap(h.updateBodies.last)
        XCTAssertTrue(body.contains(#"[{"text":"本文","type":"p"},{"imageId":"im-new","type":"image"}]"#), body)
        XCTAssertTrue(body.contains("name=\"status\"\r\n\r\ndraft\r\n"), "never published unfinished")
        XCTAssertEqual(draft.remotePostID, "9002")
        XCTAssertEqual(h.http.requests.map(\.endpointKey).filter { $0 != "www.metadata" }.prefix(2), ["post.create", "post.addImage"])
        XCTAssertTrue(h.uploads.jobs(draftID: draft.id).allSatisfy { $0.state == .completed })
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

import SwiftData
import XCTest
@testable import FANBOXClient

/// Sync engine: cheap notification gate, coalescing, priority escalation, edge-block handling, new supporters,
/// first-import read state, launch ordering.
@MainActor
final class FixSyncNotifyEngineTests: XCTestCase {
    // MARK: bell.countUnread gate (docs/API.md §10.2)

    func testPollingListsNotificationsOnlyWhenTheUnreadCountChanges() async throws {
        let h = try SyncHarness()
        h.setClock(SyncFixtures.midMonthJST)
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update {
            $0.notifications[a.id] = [SyncFixtures.notification("r1", type: .newPost, postID: "p1")]
            $0.unreadCounts[a.id] = 1
        }
        await h.engine.sync(.notifications, accountID: a.id, reason: .appLaunch)
        XCTAssertEqual(h.mock.count("notifications|"), 1)

        await h.engine.sync(.notifications, accountID: a.id, reason: .foregroundPolling)
        XCTAssertEqual(h.mock.count("unreadCount|"), 1)
        XCTAssertEqual(h.mock.count("notifications|"), 2, "no stored count yet: list once")

        await h.engine.sync(.notifications, accountID: a.id, reason: .foregroundPolling)
        await h.engine.sync(.notifications, accountID: a.id, reason: .backgroundRefresh)
        XCTAssertEqual(h.mock.count("unreadCount|"), 3)
        XCTAssertEqual(h.mock.count("notifications|"), 2, "unchanged count: bell.list is skipped")
        XCTAssertEqual(h.mock.count("newsletters|"), 1, "newsletter.list is polled at most every 10 minutes")

        h.mock.update {
            $0.notifications[a.id] = [SyncFixtures.notification("r2", type: .newPost, postID: "p2"),
                                      SyncFixtures.notification("r1", type: .newPost, postID: "p1")]
            $0.unreadCounts[a.id] = 2
        }
        let changed = await h.engine.sync(.notifications, accountID: a.id, reason: .foregroundPolling)
        XCTAssertEqual(changed.newItemIDs, ["newPost|p2"])
        XCTAssertEqual(h.mock.count("notifications|"), 3)

        // The full listing still runs periodically, and user refreshes never use the gate.
        h.advanceClock(by: SyncEngine.notificationFullRefreshInterval + 1)
        await h.engine.sync(.notifications, accountID: a.id, reason: .foregroundPolling)
        XCTAssertEqual(h.mock.count("notifications|"), 4)
        await h.engine.sync(.notifications, accountID: a.id, reason: .userRefresh)
        XCTAssertEqual(h.mock.count("notifications|"), 5)
        XCTAssertEqual(h.mock.count("unreadCount|"), 5)
    }

    func testExpiredAccountsAreNotPolled() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        a.sessionState = .expired
        h.store.save()
        let polled = await h.engine.sync(.notifications, accountID: a.id, reason: .foregroundPolling)
        XCTAssertEqual(polled, .skipped(.notifications, accountID: a.id))
        await h.engine.syncLightweight(reason: .backgroundRefresh)
        XCTAssertTrue(h.mock.calls.isEmpty)
        await h.engine.sync(.notifications, accountID: a.id, reason: .userRefresh)
        XCTAssertEqual(h.mock.count("notifications|"), 1, "an explicit refresh still tries (and recovers the session state)")
        XCTAssertEqual(h.store.account(id: a.id)?.sessionState, .valid)
    }

    // MARK: Bell posts (new-post notifications render locally)

    func testNotificationPostsAreStoredWithoutMarkingTheFeedAsSeen() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update {
            $0.notifications[a.id] = [SyncFixtures.notification("r1", type: .newPost, postID: "p50")]
            $0.notificationPosts[a.id] = [SyncFixtures.summary("p50", title: "ベルの投稿")]
        }
        await h.engine.sync(.notifications, accountID: a.id, reason: .appLaunch)
        let post = try XCTUnwrap(h.store.post(id: "p50"))
        XCTAssertEqual(post.title, "ベルの投稿")
        XCTAssertTrue(post.seenByAccountIDs.isEmpty, "a notification is not a feed listing (feed paging stops at seen ids)")
        XCTAssertEqual(post.accessAccountIDs, [a.id])
    }

    // MARK: Coalescing between the notification prefetch and the post screen (SPEC §34)

    func testPostScreenJoinsTheRunningPrefetchOfTheSamePost() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.upsertPostSummaries([SyncFixtures.summary("p1")], account: a.context, source: .home)
        h.mock.update {
            $0.details[a.id] = ["p1": SyncFixtures.detail("p1")]
            $0.postDelayNanoseconds = 200_000_000
        }
        async let prefetch = h.engine.refreshPost(postID: "p1", priority: .notificationPrefetch)
        async let screen = h.engine.refreshPost(postID: "p1", accountID: a.id)
        let results = await [prefetch, screen]
        XCTAssertEqual(results, [nil, nil])
        XCTAssertEqual(h.mock.count("post|"), 1, "one GET for the post")
    }

    func testCommentFetchesForTheSamePostShareOneRequest() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        h.mock.update { $0.commentsDelayNanoseconds = 200_000_000 }
        async let viaA = h.engine.refreshComments(postID: "p1", accountID: a.id, priority: .notificationPrefetch)
        async let viaB = h.engine.refreshComments(postID: "p1", accountID: b.id)
        _ = await (viaA, viaB)
        XCTAssertEqual(h.mock.count("comments|"), 1)
        XCTAssertEqual(h.engine.commentAccount(postID: "p1", preferring: [b.id]), b.id, "notification receivers are preferred")
    }

    // MARK: Priority escalation (SPEC §29)

    func testUserRefreshRaisesARunningLaunchBatch() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update { $0.homeDelayNanoseconds = 300_000_000 }
        let launch = Task { await h.engine.syncAll(reason: .appLaunch) }
        // Let the launch batch reach the (slow) timeline request.
        var spins = 0
        while h.mock.count("home|") == 0 && spins < 100_000 { spins += 1; await Task.yield() }
        XCTAssertEqual(h.mock.count("home|"), 1)
        await h.engine.syncAll(reason: .userRefresh)
        await launch.value
        XCTAssertEqual(h.mock.priority(of: "notifications|\(a.id)"), .notificationPrefetch)
        XCTAssertEqual(h.mock.priority(of: "home|\(a.id)"), .backgroundSync, "already running when the user refreshed")
        XCTAssertEqual(h.mock.priority(of: "supporting|\(a.id)"), .interactiveRead, "the rest of the batch runs at the user's priority")
        XCTAssertEqual(h.mock.priority(of: "following|\(a.id)"), .interactiveRead)
        XCTAssertNil(h.engine.batchPriorityFloor)
    }

    // MARK: Edge-blocked post detail (docs/API.md §1.7)

    func testForbiddenDetailDoesNotTryEveryAccountAndFallsBackToMetadata() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        for account in [a, b] {
            h.store.upsertPostSummaries([SyncFixtures.summary("p1", title: "古いタイトル")], account: account.context, source: .home)
        }
        h.mock.update {
            $0.postErrors[a.id] = ["p1": .forbidden]
            $0.postErrors[b.id] = ["p1": .forbidden]
            $0.postMetadata["p1"] = SyncFixtures.summary("p1", title: "新しいタイトル")
        }
        let error = await h.engine.refreshPost(postID: "p1", priority: .notificationPrefetch)
        XCTAssertEqual(error, .forbidden)
        XCTAssertEqual(h.mock.count("post|"), 1, "a 403 is not retried with every other account")
        XCTAssertEqual(h.mock.count("postMetadata|"), 1)
        XCTAssertEqual(h.store.post(id: "p1")?.title, "新しいタイトル", "post.get keeps the summary current")

        // Automatic work pauses the detail endpoint for that account; a user open still tries once.
        _ = await h.engine.refreshPost(postID: "p1", priority: .notificationPrefetch)
        XCTAssertEqual(h.mock.count("post|"), 1)
        _ = await h.engine.refreshPost(postID: "p1", priority: .interactiveRead)
        XCTAssertEqual(h.mock.count("post|"), 2)
    }

    // MARK: 新規支援 (newSupporter)

    func testNewSupportersAfterTheFirstFanSyncCreateEvents() async throws {
        let h = try SyncHarness()
        let me = h.addAccount("Creator", pixivUserID: "pMe", creatorID: "mine", isMain: true)
        var delivered: [String] = []
        h.engine.onNewNotificationEvents = { delivered += $0 }
        func fan(_ id: String, _ state: FanState) -> RemoteFan {
            RemoteFan(userID: id, name: "Fan \(id)", iconURL: nil, planID: "pl1", planTitle: "スタンダード", fee: 500,
                      supportStartedAt: nil, supportMonths: 1, state: state)
        }
        h.mock.update { $0.fans[me.id] = [fan("u1", .supporting)] }
        await h.engine.sync(.fans, accountID: me.id, reason: .userRefresh)
        XCTAssertTrue(delivered.isEmpty, "the first fan list is a baseline")

        h.mock.update { $0.fans[me.id] = [fan("u1", .supporting), fan("u2", .supporting), fan("u3", .following)] }
        await h.engine.sync(.fans, accountID: me.id, reason: .userRefresh)
        XCTAssertEqual(delivered.count, 1)
        let event = try XCTUnwrap(h.store.notificationEvent(id: delivered[0]))
        XCTAssertEqual(event.type, .newSupporter)
        XCTAssertEqual(event.actorName, "Fan u2")
        XCTAssertTrue(event.message.contains("スタンダード"))
        XCTAssertEqual(NotificationService.destination(for: event), .creatorMode(.fans))

        // Automatic refreshes of the fan list are throttled; background refresh includes it for creator accounts.
        await h.engine.syncLightweight(reason: .backgroundRefresh)
        XCTAssertEqual(h.mock.count("fans|"), 2)
        h.advanceClock(by: SyncEngine.fansAutomaticInterval + 1)
        await h.engine.syncLightweight(reason: .backgroundRefresh)
        XCTAssertEqual(h.mock.count("fans|"), 3)
    }

    // MARK: Creator comments first import (Creator Mode 未読)

    func testFirstCreatorCommentImportIsReadAndLaterOnesAreUnread() async throws {
        let h = try SyncHarness()
        h.setClock(Date.now)
        let me = h.addAccount("Creator", pixivUserID: "pMe", creatorID: "mine", isMain: true)
        h.store.upsertManagedPosts([SyncFixtures.summary("own1", creator: "mine")], account: me.context)
        let old = RemoteComment(id: "old1", postID: "own1", authorUserID: "fan", authorName: "Fan", body: "昔のコメント",
                                createdAt: .now.addingTimeInterval(-86_400))
        let notified = RemoteComment(id: "old2", postID: "own1", authorUserID: "fan", authorName: "Fan", body: "通知済み",
                                     createdAt: .now.addingTimeInterval(-3600))
        _ = h.store.upsertNotifications([SyncFixtures.notification("r1", type: .comment, postID: "own1", commentID: "old2", creatorID: "mine")],
                                        account: me.context)
        let source = CreatorCommentSource(mock: h.mock, comments: [old, notified])
        let engine = SyncEngine(store: h.store, remote: source, settings: h.settings, network: h.network)
        engine.clock = h.engine.clock
        await engine.sync(.creatorComments, accountID: me.id, reason: .appLaunch)
        let comments = Dictionary(uniqueKeysWithValues: h.store.comments(postID: "own1").map { ($0.commentID, $0) })
        XCTAssertEqual(comments["old1"]?.isRead, true, "history is not flooded into 未読")
        XCTAssertEqual(comments["old2"]?.isRead, false, "an unread notification keeps its comment unread")

        let fresh = RemoteComment(id: "new1", postID: "own1", authorUserID: "fan", authorName: "Fan", body: "新しいコメント",
                                  createdAt: .now.addingTimeInterval(60))
        source.comments = [fresh, old, notified]
        engine.clock = { Date.now.addingTimeInterval(120) }
        await engine.sync(.creatorComments, accountID: me.id, reason: .userRefresh)
        XCTAssertEqual(h.store.comments(postID: "own1").first { $0.commentID == "new1" }?.isRead, false)
    }

    // MARK: Launch ordering (SPEC §3.3 MUST)

    func testLaunchFlushesQueuedRepliesWithoutWaitingForTheSync() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.setOffline(true)
        let id = h.replies.submit(postID: "p1", body: "起動前に書いた返信", accountID: a.id)
        h.setOffline(false)
        h.mock.update { $0.homeDelayNanoseconds = 400_000_000 }
        h.coordinator.start()
        var spins = 0
        while h.replies.item(id: id)?.state != .sent && spins < 100_000 { spins += 1; await Task.yield() }
        XCTAssertEqual(h.replies.item(id: id)?.state, .sent)
        let calls = h.mock.calls
        let reply = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("addComment") })
        XCTAssertFalse(calls[..<reply].contains { $0.hasPrefix("following|") || $0.hasPrefix("supporting|") },
                       "the reply does not wait for the multi-account refresh")
        XCTAssertEqual(h.mock.priority(of: "addComment"), .interactiveWrite)
        h.coordinator.stopPolling()
    }
}

/// Creator-comment source with mutable comments (other calls go to the shared mock).
private final class CreatorCommentSource: RemoteDataSourceProvider, @unchecked Sendable {
    let mock: SyncMockRemote
    var comments: [RemoteComment]

    init(mock: SyncMockRemote, comments: [RemoteComment]) {
        self.mock = mock
        self.comments = comments
    }

    func dataSource(for account: AccountContext) -> RemoteDataSource { Source(owner: self) }

    private struct Source: RemoteDataSource {
        let owner: CreatorCommentSource
        func currentUser(account: AccountContext) async throws -> RemoteUser { try await owner.mock.currentUser(account: account) }
        func homeTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { RemotePage(items: []) }
        func supportingTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { RemotePage(items: []) }
        func creatorPosts(creatorID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { RemotePage(items: []) }
        func post(id: String, account: AccountContext) async throws -> RemotePostDetail { throw RemoteError.notFound }
        func creator(id: String, account: AccountContext) async throws -> RemoteCreator { throw RemoteError.notFound }
        func followingCreators(account: AccountContext) async throws -> [RemoteCreator] { [] }
        func supportingPlans(account: AccountContext) async throws -> [RemoteSupport] { [] }
        func creatorPlans(creatorID: String, account: AccountContext) async throws -> [RemotePlan] { [] }
        func setLike(postID: String, liked: Bool, account: AccountContext) async throws {}
        func comments(postID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> { RemotePage(items: []) }
        func addComment(postID: String, body: String, parentCommentID: String?, rootCommentID: String?,
                        account: AccountContext) async throws -> RemoteComment { throw RemoteError.unsupported(operation: "x") }
        func deleteComment(commentID: String, postID: String, account: AccountContext) async throws {}
        func notifications(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteNotification> { RemotePage(items: []) }
        func newsletters(account: AccountContext) async throws -> [RemoteNewsletter] { [] }
        func newsletter(id: String, account: AccountContext) async throws -> RemoteNewsletter { throw RemoteError.notFound }
        func paidRecords(account: AccountContext) async throws -> [RemotePayment] { [] }
        func managedPosts(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { RemotePage(items: []) }
        func editablePost(id: String, account: AccountContext) async throws -> RemoteEditablePost { throw RemoteError.notFound }
        func createPost(_ draft: RemotePostDraft, account: AccountContext) async throws -> String { throw RemoteError.unsupported(operation: "x") }
        func updatePost(id: String, _ draft: RemotePostDraft, account: AccountContext) async throws {}
        func uploadImage(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
            throw RemoteError.unsupported(operation: "x")
        }
        func uploadFile(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
            throw RemoteError.unsupported(operation: "x")
        }
        func fans(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteFan> { RemotePage(items: []) }
        func creatorDashboard(account: AccountContext) async throws -> RemoteCreatorDashboard { RemoteCreatorDashboard(month: "2026-09") }
        func creatorComments(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> {
            RemotePage(items: owner.comments)
        }
    }
}

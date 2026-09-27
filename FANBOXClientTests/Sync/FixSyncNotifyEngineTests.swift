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

    /// A prefetch that finds the post screen already fetching the post shares that request.
    func testPrefetchJoinsTheRunningPostScreenFetch() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.upsertPostSummaries([SyncFixtures.summary("p1")], account: a.context, source: .home)
        h.mock.update {
            $0.details[a.id] = ["p1": SyncFixtures.detail("p1")]
            $0.postDelayNanoseconds = 200_000_000
        }
        let screen = Task { await h.engine.refreshPost(postID: "p1", accountID: a.id) }
        var spins = 0
        while h.mock.count("post|") == 0 && spins < 100_000 { spins += 1; await Task.yield() }
        let prefetch = await h.engine.refreshPost(postID: "p1", priority: .notificationPrefetch)
        let shown = await screen.value
        XCTAssertNil(shown)
        XCTAssertNil(prefetch)
        XCTAssertEqual(h.mock.priorities(of: "post|"), [.interactiveRead], "one GET for the post")
    }

    /// Opening the post never waits on a background fetch of it (notification prefetch / offline rule), which may sit in
    /// the background budget for up to 30 s or fail fast with "rate limited": that fetch is cancelled, the screen fetches
    /// at its own priority, and the prefetch gets the screen's result.
    func testPostScreenDoesNotWaitOnABackgroundPrefetchOfTheSamePost() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.upsertPostSummaries([SyncFixtures.summary("p1")], account: a.context, source: .home)
        h.mock.update {
            $0.details[a.id] = ["p1": SyncFixtures.detail("p1")]
            $0.postDelayNanoseconds = 5_000_000_000         // still waiting for the background budget
        }
        let prefetch = Task { await h.engine.refreshPost(postID: "p1", priority: .notificationPrefetch) }
        var spins = 0
        while h.mock.count("post|") == 0 && spins < 100_000 { spins += 1; await Task.yield() }
        h.mock.update { $0.postDelayNanoseconds = 0 }

        let shown = await h.engine.refreshPost(postID: "p1")
        XCTAssertNil(shown)
        // The screen sent its own request instead of joining the background one, and has the body before that ends.
        XCTAssertEqual(h.mock.priorities(of: "post|"), [.notificationPrefetch, .interactiveRead])
        XCTAssertEqual(h.store.post(id: "p1")?.hasCachedBody, true)
        let prefetched = await prefetch.value
        XCTAssertNil(prefetched, "the prefetch gets the screen's result")
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

    /// post.get carries no like state or revision: the fallback keeps what listings stored (an empty heart would send a
    /// second like, and a revision rolled back to publishedAt would stop an edited post's body from being fetched again).
    func testPostGetFallbackKeepsTheLikeStateAndRevision() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        var listed = SyncFixtures.summary("p1")
        listed.isLiked = true
        listed.updatedAt = listed.publishedAt.addingTimeInterval(3_600)
        h.store.upsertPostSummaries([listed], account: a.context, source: .home)
        var metadata = SyncFixtures.summary("p1", title: "新しいタイトル")
        metadata.unreported = [.isLiked, .updatedAt]
        h.mock.update {
            $0.postErrors[a.id] = ["p1": .forbidden]
            $0.postMetadata["p1"] = metadata
        }
        _ = await h.engine.refreshPost(postID: "p1", priority: .interactiveRead)
        let post = try XCTUnwrap(h.store.post(id: "p1"))
        XCTAssertEqual(post.title, "新しいタイトル")
        XCTAssertTrue(post.isLiked)
        XCTAssertEqual(post.updatedAt, listed.updatedAt)
    }

    // MARK: 新規支援 (newSupporter)

    /// Tapping a 新規支援 of creator account B opens B's fan list, not the account selected in Creator Mode last.
    func testNewSupporterNotificationOpensThatAccountsFans() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", creatorID: "ca", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB", creatorID: "cb")
        let defaults = h.notifications.creatorModeDefaults      // the harness's own suite (removed with it)
        defaults.set(a.id, forKey: CreatorModeKeys.selectedAccountID)
        h.store.upsertFans([RemoteFan(userID: "u1", name: "Fan", iconURL: nil, planID: nil, planTitle: nil, fee: nil,
                                      supportStartedAt: nil, supportMonths: 1, state: .supporting)], account: b.context)
        let ids = h.store.recordNewSupporterEvents(userIDs: ["u1"], account: b.context, accountName: "B")
        h.notifications.open(eventID: try XCTUnwrap(ids.first))
        XCTAssertEqual(defaults.string(forKey: CreatorModeKeys.selectedAccountID), b.id)
        XCTAssertEqual(h.router.selectedTab, .creatorMode)
    }

    /// A notification opening a route closes the 送信キュー sheet and the screens' sheets / covers above it (the route
    /// would otherwise open unseen underneath).
    func testNotificationRouteClosesTheSheetsAboveIt() {
        let router = AppRouter()
        router.isReplyQueuePresented = true
        let before = router.modalDismissGeneration
        router.openFromNotification(.post(postID: "p1"))
        XCTAssertFalse(router.isReplyQueuePresented)
        XCTAssertEqual(router.modalDismissGeneration, before + 1)
        XCTAssertEqual(router.selectedTab, .home)
    }

    /// A notification that opens the inbox (an unknown event, a reply item that is gone) closes the 送信キュー sheet and the
    /// screens' sheets first: the inbox cannot show above them.
    func testInboxFromANotificationClosesTheSheetsAboveIt() throws {
        let h = try SyncHarness()
        h.router.isReplyQueuePresented = true
        h.router.isSettingsPresented = true
        let before = h.router.modalDismissGeneration
        h.notifications.open(eventID: "missing")
        XCTAssertFalse(h.router.isReplyQueuePresented)
        XCTAssertFalse(h.router.isSettingsPresented)
        XCTAssertTrue(h.router.isNotificationInboxPresented)
        XCTAssertEqual(h.router.modalDismissGeneration, before + 1)

        h.router.isNotificationInboxPresented = false
        h.router.isReplyQueuePresented = true
        h.notifications.openReplyItem(id: "missing")
        XCTAssertFalse(h.router.isReplyQueuePresented)
        XCTAssertTrue(h.router.isNotificationInboxPresented)
    }

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
        XCTAssertEqual(SyncEngine.fansAutomaticInterval, 24 * 60 * 60, "about daily at most (docs/API.md §1.8)")
    }

    /// One empty fan listing (a service glitch) ends nobody, and a supporter listed again with the same start date is
    /// not announced as new.
    func testEmptyFanListingEndsNobodyAndNothingIsReannounced() async throws {
        let h = try SyncHarness()
        let me = h.addAccount("Creator", pixivUserID: "pMe", creatorID: "mine", isMain: true)
        var delivered: [String] = []
        h.engine.onNewNotificationEvents = { delivered += $0 }
        let started = Date(timeIntervalSince1970: 1_780_000_000)
        func fan(_ id: String) -> RemoteFan {
            RemoteFan(userID: id, name: "Fan \(id)", iconURL: nil, planID: "pl1", planTitle: "スタンダード", fee: 500,
                      supportStartedAt: started, supportMonths: 3, state: .supporting)
        }
        h.mock.update { $0.fans[me.id] = [fan("u1"), fan("u2")] }
        await h.engine.sync(.fans, accountID: me.id, reason: .userRefresh)

        h.mock.update { $0.fans[me.id] = [] }
        await h.engine.sync(.fans, accountID: me.id, reason: .userRefresh)
        let rows = h.store.fetch(FetchDescriptor<Fan>())
        XCTAssertTrue(rows.allSatisfy { $0.state == .supporting }, "an empty listing judges nothing")

        // u1 is missing from one listing (ended), then listed again with the same support period.
        h.mock.update { $0.fans[me.id] = [fan("u2")] }
        await h.engine.sync(.fans, accountID: me.id, reason: .userRefresh)
        XCTAssertEqual(h.store.fetch(FetchDescriptor<Fan>()).first { $0.userID == "u1" }?.state, .ended)
        h.mock.update { $0.fans[me.id] = [fan("u1"), fan("u2")] }
        await h.engine.sync(.fans, accountID: me.id, reason: .userRefresh)
        XCTAssertTrue(delivered.isEmpty, "not a new supporter")
    }

    /// The last supporter leaving is still recorded: a second listing without any supporter confirms the first.
    func testTwoEmptyFanListingsEndTheLastSupporter() async throws {
        let h = try SyncHarness()
        let me = h.addAccount("Creator", pixivUserID: "pMe", creatorID: "mine", isMain: true)
        h.mock.update {
            $0.fans[me.id] = [RemoteFan(userID: "u1", name: "Fan", iconURL: nil, planID: "pl1", planTitle: nil, fee: 500,
                                        supportStartedAt: nil, supportMonths: 1, state: .supporting)]
        }
        await h.engine.sync(.fans, accountID: me.id, reason: .userRefresh)
        h.mock.update { $0.fans[me.id] = [] }
        await h.engine.sync(.fans, accountID: me.id, reason: .userRefresh)
        XCTAssertEqual(h.store.fetch(FetchDescriptor<Fan>()).first?.state, .supporting, "one empty listing judges nothing")
        await h.engine.sync(.fans, accountID: me.id, reason: .userRefresh)
        XCTAssertEqual(h.store.fetch(FetchDescriptor<Fan>()).first?.state, .ended)
    }

    /// A fan listing with items that could not be read ends nobody: the dropped item may be any of the supporters.
    func testIncompleteFanListingEndsNobody() async throws {
        let h = try SyncHarness()
        let me = h.addAccount("Creator", pixivUserID: "pMe", creatorID: "mine", isMain: true)
        func fan(_ id: String) -> RemoteFan {
            RemoteFan(userID: id, name: "Fan \(id)", iconURL: nil, planID: "pl1", planTitle: nil, fee: 500,
                      supportStartedAt: nil, supportMonths: 1, state: .supporting)
        }
        h.mock.update { $0.fans[me.id] = [fan("u1"), fan("u2")] }
        await h.engine.sync(.fans, accountID: me.id, reason: .userRefresh)
        h.mock.update {
            $0.fans[me.id] = [fan("u2")]
            $0.fanProblems[me.id] = "user.userIdのない項目1件"
        }
        await h.engine.sync(.fans, accountID: me.id, reason: .userRefresh)
        XCTAssertEqual(h.store.fetch(FetchDescriptor<Fan>()).first { $0.userID == "u1" }?.state, .supporting)

        h.mock.update { $0.fanProblems[me.id] = nil }
        await h.engine.sync(.fans, accountID: me.id, reason: .userRefresh)
        XCTAssertEqual(h.store.fetch(FetchDescriptor<Fan>()).first { $0.userID == "u1" }?.state, .ended)
    }

    func testFanboxFanListingReportsDroppedItems() async throws {
        let h = FanboxTestHarness()
        h.http.stub("plan.listCreator", json: FanboxFixtures.envelope(#"{"plans":[]}"#))
        h.http.stub("relationship.listFans", json: FanboxFixtures.envelope(FanboxFixtures.fans))
        let listing = try await h.source.fanListing(account: FanboxTestHarness.creator, cursor: nil)
        XCTAssertEqual(listing.page.items.map(\.userID), ["51", "50", "52"])
        XCTAssertFalse(listing.isComplete, "an item without user.userId")

        h.http.stub("relationship.listFans", json: FanboxFixtures.envelope(#"{"fans":null}"#))
        let null = try await h.source.fanListing(account: FanboxTestHarness.creator, cursor: nil)
        XCTAssertFalse(null.isComplete)

        h.http.stub("relationship.listFans", json: FanboxFixtures.envelope(#"[{"status":"supporter","user":{"userId":"50","name":"Fan"}}]"#))
        let clean = try await h.source.fanListing(account: FanboxTestHarness.creator, cursor: nil)
        XCTAssertTrue(clean.isComplete)
        XCTAssertEqual(clean.page.items.map(\.userID), ["50"])
    }

    /// A plan change whose plan lookup failed never keeps the old plan's title and fee next to the new plan id.
    func testFanPlanChangeDropsTheOldPlansTitleAndFee() throws {
        let h = try SyncHarness()
        let me = h.addAccount("Creator", pixivUserID: "pMe", creatorID: "mine", isMain: true)
        h.store.upsertFans([RemoteFan(userID: "u1", name: "Fan", iconURL: nil, planID: "a", planTitle: "プランA", fee: 500,
                                      supportStartedAt: nil, supportMonths: 1, state: .supporting)], account: me.context)
        h.store.upsertFans([RemoteFan(userID: "u1", name: "Fan", iconURL: nil, planID: "b", planTitle: nil, fee: nil,
                                      supportStartedAt: nil, supportMonths: 2, state: .supporting)], account: me.context)
        let fan = try XCTUnwrap(h.store.fetch(FetchDescriptor<Fan>()).first)
        XCTAssertEqual(fan.planID, "b")
        XCTAssertNil(fan.planTitle)
        XCTAssertNil(fan.fee)

        h.store.upsertFans([RemoteFan(userID: "u1", name: "Fan", iconURL: nil, planID: "b", planTitle: nil, fee: nil,
                                      supportStartedAt: nil, supportMonths: 2, state: .supporting)], account: me.context)
        h.store.upsertFans([RemoteFan(userID: "u1", name: "Fan", iconURL: nil, planID: "b", planTitle: "プランB", fee: 1_000,
                                      supportStartedAt: nil, supportMonths: 2, state: .supporting)], account: me.context)
        XCTAssertEqual(fan.planTitle, "プランB")
        XCTAssertEqual(fan.fee, 1_000)
    }

    // MARK: Notification events of several accounts

    /// The same おたより received by two accounts: its inbox event lists both (filters, badge with one of them off).
    func testNewsletterEventListsEveryReceivingAccount() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        let letter = RemoteNewsletter(id: "nl1", creatorID: "c1", creatorName: "C1", creatorIconURL: nil, title: nil, body: "本文",
                                      createdAt: .now, isRead: false)
        let created = h.store.ensureNewsletterEvents(newsletterIDs: h.store.upsertNewsletters([letter], account: a.context),
                                                     account: a.context)
        XCTAssertTrue(h.store.upsertNewsletters([letter], account: b.context).isEmpty)
        let event = try XCTUnwrap(h.store.notificationEvent(id: created[0]))
        XCTAssertEqual(Set(event.accountIDs), [a.id, b.id])
        a.enabled = false
        h.store.save()
        XCTAssertEqual(h.store.unreadNotificationEventCount(), 1, "B received it too")
    }

    /// Local notifications off: A's restricted copy went through the pipeline without a banner. B's readable copy re-arms
    /// the prefetch, and the event is prefetched (not announced) instead of staying pending for good.
    func testRearmedEventThatWasNeverAnnouncedIsStillPrefetched() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        var delivered: [String] = []
        var prefetchOnly: [String] = []
        h.engine.onNewNotificationEvents = { delivered += $0 }
        h.engine.onPrefetchOnlyEvents = { prefetchOnly += $0 }
        await h.engine.sync(.notifications, accountID: a.id, reason: .appLaunch)
        await h.engine.sync(.notifications, accountID: b.id, reason: .appLaunch)
        var restricted = SyncFixtures.notification("ra", type: .newPost, postID: "p1")
        restricted.isRestricted = true
        var readable = SyncFixtures.notification("rb", type: .newPost, postID: "p1")
        readable.isRestricted = false
        h.mock.update {
            $0.notifications[a.id] = [restricted]
            $0.notifications[b.id] = [readable]
        }
        await h.engine.sync(.notifications, accountID: a.id, reason: .userRefresh)
        XCTAssertEqual(delivered, ["newPost|p1"])
        delivered.removeAll()            // no banner went out: deliveredLocally stays false, nothing is due

        await h.engine.sync(.notifications, accountID: b.id, reason: .userRefresh)
        XCTAssertEqual(h.store.notificationEvent(id: "newPost|p1")?.prefetchState, .pending)
        XCTAssertTrue(delivered.isEmpty, "not announced")
        XCTAssertEqual(prefetchOnly, ["newPost|p1"])

        // Wired like AppEnvironment: the text is fetched as B.
        h.mock.update { $0.details[b.id] = ["p1": SyncFixtures.detail("p1")] }
        await h.notifications.prefetchWithoutDelivery(eventIDs: prefetchOnly)
        XCTAssertEqual(h.store.notificationEvent(id: "newPost|p1")?.prefetchState, .textReady)
        XCTAssertTrue(h.poster.requests.isEmpty)
    }

    /// A post event whose first copy was restricted (no prefetch) is prefetched once another account's copy is readable.
    func testUnrestrictedCopyOfAnotherAccountRearmsThePrefetch() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        var delivered: [String] = []
        h.engine.onNewNotificationEvents = { delivered += $0 }
        await h.engine.sync(.notifications, accountID: a.id, reason: .appLaunch)
        await h.engine.sync(.notifications, accountID: b.id, reason: .appLaunch)
        var restricted = SyncFixtures.notification("ra", type: .newPost, postID: "p1")
        restricted.isRestricted = true
        var readable = SyncFixtures.notification("rb", type: .newPost, postID: "p1")
        readable.isRestricted = false
        h.mock.update {
            $0.notifications[a.id] = [restricted]
            $0.notifications[b.id] = [readable]
        }
        await h.engine.sync(.notifications, accountID: a.id, reason: .userRefresh)
        XCTAssertEqual(delivered, ["newPost|p1"])
        XCTAssertEqual(h.store.notificationEvent(id: "newPost|p1")?.prefetchState, .notNeeded)
        h.store.notificationEvent(id: "newPost|p1")?.deliveredLocally = true      // the banner went out with the title
        delivered.removeAll()

        await h.engine.sync(.notifications, accountID: b.id, reason: .userRefresh)
        XCTAssertEqual(h.store.notificationEvent(id: "newPost|p1")?.prefetchState, .pending)
        XCTAssertEqual(delivered, ["newPost|p1"], "handed to the pipeline again for its prefetch")
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

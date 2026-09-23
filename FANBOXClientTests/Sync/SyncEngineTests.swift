import SwiftData
import UIKit
import XCTest
@testable import FANBOXClient

@MainActor
final class SyncEngineTests: XCTestCase {
    func testFeedStopsAtFirstPageWithKnownPostID() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update { $0.homePages[a.id] = ["": SyncFixtures.page(["p10", "p9"], next: "c1"),
                                             "c1": SyncFixtures.page(["p8"], next: nil)] }

        let first = await h.engine.sync(.timeline, accountID: a.id, reason: .appLaunch)
        XCTAssertNil(first.error)
        XCTAssertEqual(h.mock.count("home|"), 1, "first-ever sync reads one page only")
        XCTAssertEqual(first.newItemIDs, ["p10", "p9"])
        XCTAssertNil(h.store.post(id: "p8"))

        h.mock.update { $0.homePages[a.id] = ["": SyncFixtures.page(["p13", "p12"], next: "c1"),
                                             "c1": SyncFixtures.page(["p11", "p10"], next: "c2"),
                                             "c2": SyncFixtures.page(["p8", "p7"], next: nil)] }
        let second = await h.engine.sync(.timeline, accountID: a.id, reason: .userRefresh)
        XCTAssertNil(second.error)
        XCTAssertEqual(h.mock.count("home|"), 3, "stops after the page containing known p10")
        XCTAssertEqual(second.newItemIDs, ["p13", "p12", "p11"])
        XCTAssertNil(h.store.post(id: "p8"), "never crawls past the known post")

        let state = h.store.syncState(accountID: a.id, resource: .timeline)
        XCTAssertEqual(state.lastKnownItemID, "p13")
        XCTAssertNotNil(state.lastSuccessfulSync)
        XCTAssertEqual(state.consecutiveFailures, 0)
        XCTAssertNotNil(h.store.account(id: a.id)?.lastSyncAt)
    }

    func testFeedPageCapAndLightweightSinglePage() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update { $0.homePages[a.id] = ["": SyncFixtures.page(["old1"])] }
        await h.engine.sync(.timeline, accountID: a.id, reason: .appLaunch)

        var pages: [String: RemotePage<RemotePostSummary>] = [:]
        pages[""] = SyncFixtures.page(["n1"], next: "k1")
        for i in 1...5 { pages["k\(i)"] = SyncFixtures.page(["n\(i + 1)"], next: "k\(i + 1)") }
        h.mock.update { $0.homePages[a.id] = pages }

        let capped = await h.engine.sync(.timeline, accountID: a.id, reason: .userRefresh)
        XCTAssertEqual(capped.newItemIDs, ["n1", "n2", "n3"], "hard cap of \(SyncEngine.maxFeedPages) pages")
        XCTAssertEqual(h.mock.count("home|"), 1 + SyncEngine.maxFeedPages)
        XCTAssertNil(h.store.post(id: "n4"))

        var fresh: [String: RemotePage<RemotePostSummary>] = [:]
        fresh[""] = SyncFixtures.page(["m1"], next: "q1")
        fresh["q1"] = SyncFixtures.page(["m2"], next: nil)
        h.mock.update { $0.homePages[a.id] = fresh }
        let light = await h.engine.sync(.timeline, accountID: a.id, reason: .backgroundRefresh)
        XCTAssertEqual(light.newItemIDs, ["m1"], "background refresh reads the newest page only")
    }

    func testConcurrentIdenticalSyncsAreCoalesced() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update {
            $0.homePages[a.id] = ["": SyncFixtures.page(["p1", "p2"])]
            $0.homeDelayNanoseconds = 300_000_000
        }
        async let first = h.engine.sync(.timeline, accountID: a.id, reason: .userRefresh)
        async let second = h.engine.sync(.timeline, accountID: a.id, reason: .appLaunch)
        async let third = h.engine.sync(.timeline, accountID: a.id, reason: .foregroundPolling)
        let results = await [first, second, third]
        XCTAssertEqual(h.mock.count("home|"), 1, "identical (account, resource, scope) requests share one request")
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(results[1], results[2])
        XCTAssertEqual(results[0].newItemIDs, ["p1", "p2"])
        XCTAssertFalse(h.engine.isSyncing)

        // A different scope is a different request.
        h.mock.update { $0.homeDelayNanoseconds = 0 }
        async let c1 = h.engine.sync(.comments, accountID: a.id, scope: "p1", reason: .onDemand)
        async let c2 = h.engine.sync(.comments, accountID: a.id, scope: "p2", reason: .onDemand)
        _ = await (c1, c2)
        XCTAssertEqual(h.mock.count("comments|"), 2)
    }

    func testOfflineReturnsImmediatelyAndKeepsLocalData() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.upsertPostDetail(SyncFixtures.detail("p1"), account: a.context)
        h.setOffline(true)

        let outcome = await h.engine.sync(.timeline, accountID: a.id, reason: .userRefresh)
        XCTAssertEqual(outcome.error, .offline)
        let postError = await h.engine.refreshPost(postID: "p1")
        XCTAssertEqual(postError, .offline)
        await h.engine.syncAll(reason: .userRefresh)
        XCTAssertEqual(h.engine.lastError, .offline)
        XCTAssertTrue(h.mock.calls.isEmpty, "no request is attempted offline")
        XCTAssertEqual(h.store.post(id: "p1")?.bodyText, "本文", "cache survives")
    }

    func testRefreshPostFallsBackToAccountThatCanView() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        h.store.upsertPostSummaries([SyncFixtures.summary("p1", restricted: true)], account: a.context, source: .home)
        h.mock.update {
            $0.details[a.id] = ["p1": SyncFixtures.detail("p1", restricted: true)]
            $0.details[b.id] = ["p1": SyncFixtures.detail("p1", text: "B で読める本文")]
        }
        let error = await h.engine.refreshPost(postID: "p1")
        XCTAssertNil(error)
        let post = try XCTUnwrap(h.store.post(id: "p1"))
        XCTAssertEqual(post.bodyText, "B で読める本文")
        XCTAssertEqual(post.detailAccountID, b.id)
        XCTAssertEqual(h.mock.calls.filter { $0.hasPrefix("post|") }, ["post|\(a.id)|p1", "post|\(b.id)|p1"])
        XCTAssertEqual(h.store.postAccesses(postID: "p1").first { $0.accountID == b.id }?.bodyCached, true)

        // Explicit account: no fallback.
        let explicit = await h.engine.refreshPost(postID: "p1", accountID: a.id)
        XCTAssertNil(explicit)
        XCTAssertEqual(post.bodyText, "B で読める本文", "restricted answer never wipes the cached body")
    }

    func testUnauthorizedExpiresSessionAndKeepsCache() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.upsertPostSummaries([SyncFixtures.summary("p1")], account: a.context, source: .home)
        h.mock.update { $0.accountErrors[a.id] = .unauthorized }

        let outcome = await h.engine.sync(.timeline, accountID: a.id, reason: .userRefresh)
        XCTAssertEqual(outcome.error, .unauthorized)
        XCTAssertEqual(h.store.account(id: a.id)?.sessionState, .expired)
        XCTAssertEqual(h.engine.lastError, .unauthorized)
        let state = h.store.syncState(accountID: a.id, resource: .timeline)
        XCTAssertEqual(state.consecutiveFailures, 1)
        XCTAssertEqual(state.error, RemoteError.unauthorized.userMessage)
        XCTAssertNotNil(h.store.post(id: "p1"))

        h.mock.update { $0.accountErrors[a.id] = nil }
        let recovered = await h.engine.sync(.timeline, accountID: a.id, reason: .userRefresh)
        XCTAssertNil(recovered.error)
        XCTAssertEqual(state.consecutiveFailures, 0)
        XCTAssertEqual(h.store.account(id: a.id)?.sessionState, .valid)
    }

    func testNotificationSyncReportsNewEventsAfterFirstSync() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        var delivered: [[String]] = []
        h.engine.onNewNotificationEvents = { ids in delivered.append(ids) }

        h.mock.update { $0.notifications[a.id] = [SyncFixtures.notification("r1", type: .comment, postID: "p1", commentID: "cm1")] }
        let first = await h.engine.sync(.notifications, accountID: a.id, reason: .appLaunch)
        XCTAssertEqual(first.newItemIDs, ["comment|cm1"])
        XCTAssertTrue(delivered.isEmpty, "history imported by the first sync is not re-announced")

        // Automatic polling reads newsletter.list at most every `newsletterPollInterval`.
        h.advanceClock(by: SyncEngine.newsletterPollInterval + 1)
        h.mock.update {
            $0.notifications[a.id] = [SyncFixtures.notification("r2", type: .newPost, postID: "p2"),
                                      SyncFixtures.notification("r3", type: .newPost, postID: "p3", unread: false),
                                      SyncFixtures.notification("r1", type: .comment, postID: "p1", commentID: "cm1")]
            $0.newsletters[a.id] = [RemoteNewsletter(id: "nl1", creatorID: "c1", creatorName: "Creator c1", creatorIconURL: nil,
                                                     title: "近況", body: "おたより本文", createdAt: .now, isRead: false)]
        }
        let second = await h.engine.sync(.notifications, accountID: a.id, reason: .foregroundPolling)
        XCTAssertEqual(Set(second.newItemIDs), ["newPost|p2", "newPost|p3", "newsletter|nl1"])
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(Set(delivered.first ?? []), ["newPost|p2", "newsletter|nl1"], "already-read events are not announced")
        XCTAssertEqual(h.store.newsletter(id: "nl1")?.body, "おたより本文")
        XCTAssertEqual(h.store.notificationEvent(id: "newsletter|nl1")?.prefetchState, .textReady)
    }

    func testSupportsSyncRecordsObservedChangeEvents() async throws {
        let h = try SyncHarness()
        // Outside the 1st–5th: a disappearance is a 支援状態変化 (on the 1st–5th it becomes 決済要確認, see FixSync tests).
        h.setClock(SyncFixtures.midMonthJST)
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        var delivered: [String] = []
        h.engine.onNewNotificationEvents = { ids in delivered += ids }
        h.mock.update {
            $0.supports[a.id] = [SyncFixtures.support("c1", plan: "p1", fee: 500)]
            $0.payments[a.id] = [RemotePayment(id: "pay1", creatorID: "c1", creatorName: "Creator c1", amount: 500, paidAt: .now,
                                               paymentMethod: "card")]
        }
        await h.engine.sync(.supports, accountID: a.id, reason: .appLaunch)
        XCTAssertTrue(delivered.isEmpty, "first sync only imports")
        XCTAssertEqual(h.store.fetch(FetchDescriptor<PaymentRecord>()).count, 1)

        h.mock.update { $0.supports[a.id] = [] }
        let outcome = await h.engine.sync(.supports, accountID: a.id, reason: .backgroundRefresh)
        XCTAssertEqual(outcome.newItemIDs, ["c1"])
        XCTAssertEqual(delivered.count, 1)
        let event = try XCTUnwrap(h.store.notificationEvent(id: delivered[0]))
        XCTAssertEqual(event.type, .supportChanged)
        XCTAssertEqual(event.creatorID, "c1")
        XCTAssertTrue(event.message.contains("原因は確認できません"))
        XCTAssertEqual(h.store.supports(accountID: a.id).first?.status, .missing)
    }

    func testCreatorOnlyResourcesSkipReaderAccounts() async throws {
        let h = try SyncHarness()
        let reader = h.addAccount("Reader", pixivUserID: "pR", isMain: true)
        let creator = h.addAccount("Creator", pixivUserID: "pC", creatorID: "mine")
        let skipped = await h.engine.sync(.creatorDashboard, accountID: reader.id, reason: .userRefresh)
        XCTAssertEqual(skipped, .skipped(.creatorDashboard, accountID: reader.id))
        await h.engine.sync(.creatorDashboard, accountID: creator.id, reason: .userRefresh)
        XCTAssertEqual(h.mock.count("dashboard|"), 1)

        await h.engine.syncAll(reason: .userRefresh)
        XCTAssertEqual(h.mock.count("fans|"), 1)
        XCTAssertEqual(h.mock.count("creatorComments|"), 1)
        XCTAssertEqual(h.mock.count("notifications|"), 2)
        XCTAssertNil(h.engine.lastError)
        XCTAssertNotNil(h.engine.lastSuccessAt)
    }

    func testRemoteRelayFetchResult() {
        let ok = SyncOutcome(resource: .notifications, accountID: "a", scope: "", newItemIDs: ["x"], error: nil)
        let none = SyncOutcome.skipped(.timeline, accountID: "a")
        let failed = SyncOutcome.failed(.timeline, accountID: "a", error: .network(code: -1, detail: ""))
        XCTAssertEqual(RemoteRelay.fetchResult(for: [ok, failed]), .newData)
        XCTAssertEqual(RemoteRelay.fetchResult(for: [none, failed]), .noData)
        XCTAssertEqual(RemoteRelay.fetchResult(for: [failed]), .failed)
    }
}

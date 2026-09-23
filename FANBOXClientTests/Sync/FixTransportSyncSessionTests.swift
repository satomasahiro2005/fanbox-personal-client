import XCTest
@testable import FANBOXClient

/// Sync rules for account sessions: identity mismatch (`.error`) never syncs and is never promoted by a success;
/// expired / logged-out accounts are not polled automatically; restricted posts are not re-requested for accounts
/// that cannot be entitled.
@MainActor
final class FixTransportSyncSessionTests: XCTestCase {
    func testIdentityMismatchedAccountsNeverSyncAndExpiredOnesAreNotPolled() async throws {
        let h = try SyncHarness()
        let mismatched = h.addAccount("A", pixivUserID: "pA", isMain: true)
        mismatched.sessionState = .error
        let expired = h.addAccount("B", pixivUserID: "pB")
        expired.sessionState = .expired
        h.store.save()

        for reason in [SyncReason.userRefresh, .foregroundPolling, .appLaunch, .onDemand] {
            let outcome = await h.engine.sync(.notifications, accountID: mismatched.id, reason: reason)
            XCTAssertNil(outcome.error)
        }
        XCTAssertFalse(h.mock.calls.contains { $0.contains(mismatched.id) }, "nothing is requested as another pixiv user")
        XCTAssertEqual(mismatched.sessionState, .error)

        for reason in [SyncReason.foregroundPolling, .backgroundRefresh, .appLaunch, .notification] {
            _ = await h.engine.sync(.timeline, accountID: expired.id, reason: reason)
        }
        XCTAssertEqual(h.mock.count("home|\(expired.id)"), 0, "requests known to fail are not polled")
        _ = await h.engine.sync(.timeline, accountID: expired.id, reason: .userRefresh)
        XCTAssertEqual(h.mock.count("home|\(expired.id)"), 1, "an explicit refresh still runs")
        XCTAssertEqual(expired.sessionState, .valid, "and a success revives an expired session")
    }

    func testSessionOfAnotherUserIsReportedAndNotApplied() async throws {
        let h = try SyncHarness()
        let remote = AuthMockRemote(user: .success(RemoteUser(pixivUserID: "other", fanboxUserID: nil, name: "Mallory",
                                                              iconURL: nil, creatorID: "mallory")))
        let engine = SyncEngine(store: h.store, remote: AuthMockProvider(mock: remote), settings: h.settings, network: h.network)
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        var reported: [(String, String)] = []
        engine.onIdentityMismatch = { accountID, user in reported.append((accountID, user)) }
        let outcome = await engine.sync(.session, accountID: a.id, reason: .userRefresh)
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(reported.map(\.0), [a.id])
        XCTAssertEqual(reported.map(\.1), ["other"])
        XCTAssertEqual(a.pixivUserID, "pA", "the account is never rebound to another user")
        XCTAssertNil(a.creatorID)
    }

    func testRestrictedAnswerDoesNotTryAccountsWithoutAMatchingSupport() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        h.store.upsertPostSummaries([SyncFixtures.summary("p1", restricted: true, fee: 500)], account: a.context, source: .home)
        var restrictedDetail = SyncFixtures.detail("p1", restricted: true)
        restrictedDetail.summary.feeRequired = 500
        h.mock.update {
            $0.details[a.id] = ["p1": restrictedDetail]
            $0.details[b.id] = ["p1": SyncFixtures.detail("p1", text: "B")]
        }
        _ = await h.engine.refreshPost(postID: "p1")
        // Tri-state ranking (AccountSelector): A is KNOWN restricted, B is unknown, so B is asked first and A is never
        // re-asked. Exactly one post.info is spent (docs/API.md §1.8), on the only account that might be entitled.
        XCTAssertEqual(h.mock.calls.filter { $0.hasPrefix("post|") }, ["post|\(b.id)|p1"],
                       "one post.info only, never on the account already known to be restricted")
    }

    func testEdgeBlockedDetailDoesNotTryOtherAccounts() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        _ = h.addAccount("B", pixivUserID: "pB")
        h.store.upsertPostSummaries([SyncFixtures.summary("p1")], account: a.context, source: .home)
        h.mock.update { $0.accountErrors[a.id] = .edgeBlocked(retryAfter: nil) }
        let error = await h.engine.refreshPost(postID: "p1")
        XCTAssertEqual(error, .edgeBlocked(retryAfter: nil))
        XCTAssertEqual(h.mock.calls.filter { $0.hasPrefix("post|") }.count, 1, "a block is not multiplied across accounts")
        XCTAssertEqual(h.store.account(id: a.id)?.sessionState, .valid, "an edge block says nothing about the session")
    }

    func testRestrictedBellPostsAreNotPrefetched() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let restricted = RemoteNotification(remoteID: "n1", type: .newPost, rawType: "on_post_published", createdAt: .now, creatorID: "c1",
                                            creatorName: "C", postID: "p9", postTitle: "t", commentID: nil, newsletterID: nil,
                                            actorName: nil, actorIconURL: nil, title: "t", message: "m", isUnread: true,
                                            isRestricted: true)
        let ids = h.store.upsertNotifications([restricted], account: a.context)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(h.store.notificationEvent(id: ids[0])?.prefetchState, .notNeeded)
    }
}

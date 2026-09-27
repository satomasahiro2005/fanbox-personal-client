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

    /// A logged-out account has no credential: nothing runs for it, and nothing turns the logout into "expired".
    func testLoggedOutAccountNeverSyncsAndStaysLoggedOut() async throws {
        let h = try SyncHarness()
        _ = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        b.sessionState = .loggedOut
        h.store.save()
        var expired: [String] = []
        h.engine.onSessionExpired = { expired.append($0) }
        h.mock.update { $0.accountErrors[b.id] = .unauthorized }     // what a guest request would get

        for reason in [SyncReason.userRefresh, .onDemand, .afterWrite] {
            _ = await h.engine.sync(.timeline, accountID: b.id, reason: reason)
            _ = await h.engine.sync(.plans, accountID: b.id, scope: "c1", reason: reason)
        }
        await h.engine.syncAll(reason: .userRefresh)
        XCTAssertEqual(h.mock.count("home|\(b.id)"), 0)
        XCTAssertEqual(h.mock.count("plans|"), 0)
        XCTAssertEqual(b.sessionState, .loggedOut)

        // A refused explicit request as B does not make it "expired" either (no re-login notice after a logout).
        _ = await h.engine.refreshPost(postID: "p1", accountID: b.id)
        XCTAssertEqual(b.sessionState, .loggedOut)
        XCTAssertTrue(expired.isEmpty)
    }

    /// Endpoints FANBOX also serves to guests prove nothing about the session.
    func testOnlySessionEndpointsReviveAnExpiredSession() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", creatorID: "mine", isMain: true)
        a.sessionState = .expired
        h.store.save()
        _ = await h.engine.sync(.plans, accountID: a.id, scope: "c1", reason: .onDemand)
        _ = await h.engine.sync(.comments, accountID: a.id, scope: "p1", reason: .onDemand)
        _ = await h.engine.sync(.creatorPosts, accountID: a.id, scope: "c1", reason: .onDemand)
        // My creator comments are read from my public post pages: the Creator tab's refresh does not revive it either.
        _ = await h.engine.sync(.creatorComments, accountID: a.id, reason: .userRefresh)
        XCTAssertEqual(h.mock.count("creatorComments|\(a.id)"), 1)
        XCTAssertEqual(a.sessionState, .expired)
        _ = await h.engine.sync(.notifications, accountID: a.id, reason: .userRefresh)
        XCTAssertEqual(a.sessionState, .valid)
    }

    /// Automatic account choice never picks an account without a session (its requests would go out as a guest).
    func testAutomaticChoiceSkipsAccountsWithoutASession() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        let c = h.addAccount("C", pixivUserID: "pC")
        b.sessionState = .loggedOut
        c.sessionState = .error
        h.store.save()
        h.store.applySupports([SyncFixtures.support("c1", plan: "p1", fee: 500)], account: a.context, source: .sync)
        h.store.applySupports([SyncFixtures.support("c1", plan: "p2", fee: 1_000)], account: b.context, source: .sync)
        h.store.applySupports([SyncFixtures.support("c1", plan: "p3", fee: 2_000)], account: c.context, source: .sync)
        XCTAssertEqual(h.engine.bestAccount(creatorID: "c1"), a.id)

        h.store.upsertPostSummaries([SyncFixtures.summary("p1")], account: b.context, source: .home)   // B can view it
        XCTAssertEqual(AccountSelector.bestAccount(postID: "p1", store: h.store), a.id)
        XCTAssertEqual(h.engine.commentAccount(postID: "p1", preferring: [b.id, c.id]), a.id)
        XCTAssertFalse(AccountSelector.hasSession(kind: .fanbox, state: .loggedOut))
        XCTAssertTrue(AccountSelector.hasSession(kind: .fanbox, state: .expired))
    }

    /// A post screen that names a logged-out or quarantined account sends nothing as it: FANBOX would answer a guest, and
    /// the restricted answer would be stored as that account's viewing right.
    func testExplicitPostFetchWithoutASessionSendsNothing() async throws {
        let h = try SyncHarness()
        _ = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        let c = h.addAccount("C", pixivUserID: "pC")
        b.sessionState = .loggedOut
        c.sessionState = .error
        h.store.save()
        h.mock.update {
            $0.details[b.id] = ["p1": SyncFixtures.detail("p1", restricted: true)]
            $0.details[c.id] = ["p1": SyncFixtures.detail("p1", restricted: true)]
        }
        for account in [b, c] {
            let error = await h.engine.refreshPost(postID: "p1", accountID: account.id)
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertEqual(h.mock.count("post|"), 0)
        XCTAssertNil(h.store.post(id: "p1"), "nothing stored from a guest answer")
    }

    /// My quarantined creator account is not chosen for the comments or the page of its own creator (another account reads
    /// them), and a refresh that names it says why nothing was read instead of reporting success.
    func testQuarantinedOwnerIsNotUsedAndAnExplicitRefreshSaysSo() async throws {
        let h = try SyncHarness()
        let fan = h.addAccount("Fan", pixivUserID: "pF", isMain: true)
        let owner = h.addAccount("Creator", pixivUserID: "pC", creatorID: "mine")
        owner.sessionState = .error
        h.store.save()
        h.store.upsertPostSummaries([SyncFixtures.summary("p1", creator: "mine")], account: fan.context, source: .home)
        XCTAssertEqual(h.engine.commentAccount(postID: "p1"), fan.id)
        XCTAssertEqual(h.engine.bestAccount(creatorID: "mine"), fan.id)

        let comments = await h.engine.refreshComments(postID: "p1", accountID: owner.id)
        XCTAssertEqual(comments, .unauthorized)
        let creator = await h.engine.refreshCreator(creatorID: "mine", accountID: owner.id)
        XCTAssertEqual(creator, .unauthorized)
        XCTAssertEqual(h.mock.count("comments|\(owner.id)"), 0)
        XCTAssertEqual(h.mock.count("creator|"), 0)

        let automatic = await h.engine.refreshComments(postID: "p1")
        XCTAssertNil(automatic)
        XCTAssertEqual(h.mock.count("comments|\(fan.id)|p1"), 1)
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

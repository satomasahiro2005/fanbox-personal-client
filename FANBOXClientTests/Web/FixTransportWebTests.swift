import XCTest
@testable import FANBOXClient

/// Web bridge robustness: 404 fallbacks for unverified destinations, replaced sessions still run their dismissal work,
/// Offline gating of the account web view, and the WebView transport refusing to run without a usable account.
@MainActor
final class FixTransportWebTests: XCTestCase {
    func testUnverifiedPaymentDestinationsHaveFallbacks() {
        XCTAssertEqual(WebDestination.plan(creatorID: "alice", planID: "9").fallbacks,
                       [.creatorPlans(creatorID: "alice"), .creator(creatorID: "alice")])
        XCTAssertEqual(WebDestination.paymentSettings.fallbacks.map(\.url), [WebDestination.pixivCardsURL])
        XCTAssertEqual(WebDestination.supportingPlans.fallbacks, [.home])
        XCTAssertEqual(WebDestination.login.fallbacks.map { $0.url.host }, ["accounts.pixiv.net"])
        XCTAssertTrue(WebDestination.home.fallbacks.isEmpty)
        XCTAssertEqual(WebDestination.pixivCardsURL.host, "payment.pixiv.net")
    }

    func testCoordinatorFollowsFallbacksOnlyForTheExpectedPage() {
        let research = ResearchRecorder()
        let initial = WebDestination.plan(creatorID: "alice", planID: "9").url
        let fallbacks = WebDestination.plan(creatorID: "alice", planID: "9").fallbacks.map(\.url)
        let coordinator = AccountWebCoordinator(controller: AccountWebController(), accountID: "A", research: research,
                                                policy: NetworkPolicyStore(), initialURL: initial, fallbackURLs: fallbacks)
        XCTAssertNil(coordinator.fallback(afterNotFound: URL(string: "https://www.fanbox.cc/@bob")), "someone else's 404")
        XCTAssertEqual(coordinator.fallback(afterNotFound: URL(string: initial.absoluteString + "/")), fallbacks[0])
        XCTAssertEqual(coordinator.fallback(afterNotFound: fallbacks[0]), fallbacks[1])
        XCTAssertNil(coordinator.fallback(afterNotFound: fallbacks[1]), "the last fallback's 404 is shown")
    }

    func testCoordinatorBlocksNetworkWhileOffline() {
        let policy = NetworkPolicyStore()
        let coordinator = AccountWebCoordinator(controller: AccountWebController(), accountID: "A", research: ResearchRecorder(),
                                                policy: policy)
        XCTAssertTrue(coordinator.allowsNetwork)
        policy.update { $0.mode = .offline }
        XCTAssertFalse(coordinator.allowsNetwork)
    }

    func testReplacingAPresentedSessionStillRunsItsDismissalWork() {
        let bridge = WebBridge()
        var dismissed: [WebSessionRequest] = []
        bridge.onDismiss = { dismissed.append($0) }
        bridge.openWeb(account: "A", destination: .plan(creatorID: "alice", planID: "1"), purpose: .payment)
        let first = bridge.presented
        bridge.openWeb(account: "B", destination: .home, purpose: .browse)
        XCTAssertEqual(dismissed.map(\.id), [first?.id].compactMap { $0 }, "the replaced payment session is resynced")
        XCTAssertEqual(bridge.presented?.accountID, "B")
        bridge.dismiss()
        XCTAssertEqual(dismissed.count, 2)
    }

    func testWebTransportIsUnavailableWithoutAUsableAccountOrWhileOffline() async {
        let policy = NetworkPolicyStore()
        let pool = WebFetchHostPool(webSessions: WebSessionStore(ephemeral: true), credentials: InMemoryCredentialStore(),
                                    scheduler: NetworkScheduler(policy: policy), recorder: ResearchRecorder(), policy: policy)
        pool.accountResolver = { _ in nil }
        let request = HTTPRequest(url: URL(string: "https://api.fanbox.cc/post.info?postId=1")!, priority: .interactiveRead,
                                  endpointKey: "post.info")
        do {
            _ = try await pool.fetch(request, accountID: "demo")
            XCTFail("expected unavailable")
        } catch {
            guard case .unavailable = error as? WebFetchError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(pool.liveHostCount, 0, "no hidden WebView is created for it")

        pool.accountResolver = { id in WebFetchAccount(accountID: id, webProfileID: UUID().uuidString, pixivUserID: "1") }
        let other = HTTPRequest(url: URL(string: "https://example.com/x")!, priority: .interactiveRead, endpointKey: "x")
        do {
            _ = try await pool.fetch(other, accountID: "A")
            XCTFail("only FANBOX hosts")
        } catch {
            guard case .unavailable = error as? WebFetchError else { return XCTFail("\(error)") }
        }

        policy.update { $0.mode = .offline }
        do {
            _ = try await pool.fetch(request, accountID: "A")
            XCTFail("expected offline")
        } catch {
            XCTAssertEqual(error as? RemoteError, .offline)
        }
        XCTAssertEqual(pool.liveHostCount, 0)
    }

    /// A rejected in-page fetch is an edge block only when the page's own origin is still reachable; otherwise it is a
    /// network failure (a read then goes through the native transport, and no breaker / cooldown starts).
    func testFailedPageFetchIsAnEdgeBlockOnlyWhenThePageOriginIsReachable() {
        let online = NetworkPolicySnapshot.default
        XCTAssertEqual(WebFetchHost.mapScriptError("EdgeBlocked", policy: online), .edgeBlocked(retryAfter: nil))
        guard case .network = WebFetchHost.mapScriptError("NetworkError", policy: online) else {
            return XCTFail("a dropped connection is not an edge block")
        }
        var offline = online
        offline.mode = .offline
        XCTAssertEqual(WebFetchHost.mapScriptError("NetworkError", policy: offline), .offline)
        XCTAssertTrue(WebFetchHost.fetchScript.contains("'NetworkError'"))
        XCTAssertTrue(WebFetchHost.fetchScript.contains("'EdgeBlocked'"))
    }

    /// A page past its age is never reloaded while other fetches run in it (the navigation would take their document
    /// away); a page being loaded (not verified yet) is joined rather than used or loaded a second time.
    func testAgedPageIsNotReloadedUnderRunningFetches() {
        XCTAssertTrue(WebFetchHost.pageUsableAsIs(isFresh: true, isVerified: true, fetchesInUse: 1))
        XCTAssertTrue(WebFetchHost.pageUsableAsIs(isFresh: false, isVerified: true, fetchesInUse: 2), "another fetch runs in it")
        XCTAssertFalse(WebFetchHost.pageUsableAsIs(isFresh: false, isVerified: true, fetchesInUse: 1), "idle: reloaded")
        XCTAssertFalse(WebFetchHost.pageUsableAsIs(isFresh: false, isVerified: false, fetchesInUse: 3), "loading: joined")
    }

    /// The pool was shut down (background, Offline, memory warning, logout) while the account's session was being
    /// prepared: the fetch gives up instead of loading a page into a host nothing can tear down any more.
    func testHostShutDownWhileItsSessionIsPreparedLoadsNoPage() async {
        let policy = NetworkPolicyStore()
        let pool = WebFetchHostPool(webSessions: WebSessionStore(ephemeral: true), credentials: InMemoryCredentialStore(),
                                    scheduler: NetworkScheduler(policy: policy), recorder: ResearchRecorder(), policy: policy)
        pool.accountResolver = { id in WebFetchAccount(accountID: id, webProfileID: UUID().uuidString, pixivUserID: "1") }
        pool.prepareSession = { _ in pool.shutdownAll() }
        let request = HTTPRequest(url: URL(string: "https://api.fanbox.cc/post.info?postId=1")!, priority: .interactiveRead,
                                  endpointKey: "post.info")
        do {
            _ = try await pool.fetch(request, accountID: "A")
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? WebFetchError, .unavailable("web transport shut down"))
        }
        XCTAssertEqual(pool.liveHostCount, 0)
        pool.prepareSession = nil
    }

    func testIdentityStatesInTheSessionBanner() {
        XCTAssertNotEqual(WebSessionIdentity.verified, .mismatch(pageUserID: "9"))
        XCTAssertTrue(SessionEdgeBlockNotice.applies(to: .edgeBlocked(retryAfter: nil)))
        XCTAssertFalse(SessionEdgeBlockNotice.applies(to: .forbidden))
        XCTAssertFalse(AccountWebSessionView.googleLoginHint.isEmpty)
    }
}

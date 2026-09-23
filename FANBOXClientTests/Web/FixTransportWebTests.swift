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

    func testIdentityStatesInTheSessionBanner() {
        XCTAssertNotEqual(WebSessionIdentity.verified, .mismatch(pageUserID: "9"))
        XCTAssertTrue(SessionEdgeBlockNotice.applies(to: .edgeBlocked(retryAfter: nil)))
        XCTAssertFalse(SessionEdgeBlockNotice.applies(to: .forbidden))
        XCTAssertFalse(AccountWebSessionView.googleLoginHint.isEmpty)
    }
}

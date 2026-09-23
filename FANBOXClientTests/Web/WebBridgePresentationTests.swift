import UIKit
import WebKit
import XCTest
@testable import FANBOXClient

/// Exercises the real presentation path inside the test host app: `env.web.openWeb` → UIKit-hosted
/// `AccountWebSessionView` → `AccountWebView` bound to the account's own data store. Loads only about:blank (no network).
@MainActor
final class WebBridgePresentationTests: XCTestCase {
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private func findWebView(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews {
            if let found = findWebView(in: sub) { return found }
        }
        return nil
    }

    func testOpenWebPresentsAccountBoundSessionAndDismisses() async throws {
        guard let env = AppDelegate.environment else { throw XCTSkip("test host has no app environment") }
        guard WebPresentationAnchor.topViewController() != nil else { throw XCTSkip("no window in test host") }

        let account = env.accounts.addDemoAccount(name: "WebBridgeTest")
        let accountID = account.id
        let webProfileID = account.webProfileID
        defer { Task { @MainActor in await env.accounts.remove(accountID: accountID) } }

        env.web.openWeb(account: accountID, destination: .url(URL(string: "about:blank")!), purpose: .browse)

        let presented = await waitUntil { WebPresentationAnchor.topViewController() is WebSessionHostingController }
        XCTAssertTrue(presented, "web session should be presented above the current UI")
        let host = try XCTUnwrap(WebPresentationAnchor.topViewController() as? WebSessionHostingController)
        XCTAssertEqual(host.requestID, env.web.presented?.id)

        let foundWebView = await waitUntil { self.findWebView(in: host.view) != nil }
        XCTAssertTrue(foundWebView, "AccountWebView should be created for an existing account")
        if let webView = findWebView(in: host.view) {
            XCTAssertTrue(webView.configuration.websiteDataStore === env.webSessions.dataStore(webProfileID: webProfileID),
                          "the web view must use the account's own data store")
            XCTAssertFalse(webView.configuration.websiteDataStore === WKWebsiteDataStore.default())
        }

        env.web.dismiss()
        let dismissed = await waitUntil { !(WebPresentationAnchor.topViewController() is WebSessionHostingController) }
        XCTAssertTrue(dismissed, "closing the bridge dismisses the hosted session")
        XCTAssertNil(env.web.presented)
    }
}

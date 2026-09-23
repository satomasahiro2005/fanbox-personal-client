import SwiftUI
import UIKit
import WebKit

/// A `window.open` / `target=_blank` page opened by the account WebView (e.g. PayPal / 3-D Secure during payment).
/// It uses the configuration WebKit hands us, so it shares the SAME account data store.
struct AccountWebPopup: Identifiable {
    let id = UUID()
    let webView: WKWebView
}

/// Observable state + commands of one account-aware WKWebView (progress / back / forward / title).
@MainActor
@Observable
final class AccountWebController {
    private(set) var estimatedProgress: Double = 0
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var title: String?
    private(set) var currentURL: URL?
    /// User-facing message of the last failed main-frame load (nil once a new load starts).
    var loadError: String?
    var popup: AccountWebPopup?
    /// Fallback page shown instead of the requested one (nil = the requested page). See `WebDestination.fallbackSteps`.
    private(set) var activeFallback: WebFallbackStep?
    /// Remaining automatic fallbacks, tried in order when the requested page answers 404 / 410.
    @ObservationIgnored var fallbackSteps: [WebFallbackStep] = []
    /// True until the first main-frame response of the requested page (or of an automatic fallback) arrived.
    @ObservationIgnored private var awaitingInitialResponse = true

    /// Called on the main actor after each main-frame navigation finishes.
    @ObservationIgnored var onMainFrameFinished: ((URL) -> Void)?
    @ObservationIgnored private(set) weak var webView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init() {}

    func attach(_ webView: WKWebView) {
        observations.forEach { $0.invalidate() }
        self.webView = webView
        let refresh: (WKWebView) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshState() }
        }
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { wv, _ in refresh(wv) },
            webView.observe(\.isLoading, options: [.new]) { wv, _ in refresh(wv) },
            webView.observe(\.canGoBack, options: [.new]) { wv, _ in refresh(wv) },
            webView.observe(\.canGoForward, options: [.new]) { wv, _ in refresh(wv) },
            webView.observe(\.title, options: [.new]) { wv, _ in refresh(wv) },
            webView.observe(\.url, options: [.new]) { wv, _ in refresh(wv) },
        ]
        refreshState()
    }

    func detach(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        observations.forEach { $0.invalidate() }
        observations = []
        self.webView = nil
    }

    func refreshState() {
        guard let webView else { return }
        estimatedProgress = webView.estimatedProgress
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        let t = webView.title ?? ""
        title = t.isEmpty ? nil : t
        currentURL = webView.url
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func reload() {
        loadError = nil
        if webView?.url == nil, let url = currentURL {
            webView?.load(URLRequest(url: url))
        } else {
            webView?.reload()
        }
    }

    func stopLoading() { webView?.stopLoading() }

    func load(_ url: URL) {
        loadError = nil
        webView?.load(URLRequest(url: url))
    }

    /// First main-frame response of the requested page: a missing page (404 / 410) is replaced by the next fallback.
    /// Returns true when the response must be cancelled because a fallback is being loaded instead.
    func handleMainFrameResponse(status: Int?) -> Bool {
        guard awaitingInitialResponse else { return false }
        guard WebDestination.isMissingPageStatus(status), !fallbackSteps.isEmpty else {
            awaitingInitialResponse = false
            return false
        }
        let next = fallbackSteps.removeFirst()
        activeFallback = next
        AppLog.web.notice("requested page missing; opening fallback \(next.title, privacy: .public)")
        DispatchQueue.main.async { [weak self] in self?.load(next.url) }
        return true
    }

    /// Manual choice from the web screen ("ページが表示されない場合").
    func openFallback(_ step: WebFallbackStep) {
        awaitingInitialResponse = false
        activeFallback = step
        load(step.url)
    }

    /// Reads page metadata (CSRF token, logged-in user, navigator.userAgent) from the current page.
    func inspectPage() async -> WebPageMetadata? {
        guard let webView else { return nil }
        return await WebPageInspector.inspect(webView)
    }

    /// `navigator.userAgent` of this web view (fallback when page inspection failed: the API must present the same UA
    /// as the web session, docs/API.md §1.2).
    func userAgent() async -> String? {
        guard let webView else { return nil }
        let value = try? await webView.evaluateJavaScript("navigator.userAgent")
        return (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    func closePopup() {
        popup?.webView.stopLoading()
        popup = nil
    }
}

/// `WKWebView` bound to ONE account's isolated `WKWebsiteDataStore` (SPEC §7.1 / §40). Cookies of other accounts are
/// physically unreachable from here. Every main-frame navigation is recorded (redacted) for Research Mode.
///
/// Offline (SPEC §30 "ネットワーク通信を完全停止する"): nothing is loaded while `policy` forbids network access; every
/// http(s) navigation of the view and its popups is cancelled.
/// Unverified destinations (docs/API.md §20): a 404 answer to the initial page loads `fallbackURLs` in order.
struct AccountWebView: UIViewRepresentable {
    let accountID: String
    let webProfileID: String
    let initialURL: URL
    let controller: AccountWebController
    /// `env.webSessions` — resolves the account's own `WKWebsiteDataStore`.
    let webSessions: WebSessionStore
    /// `env.research` — receives one redacted `.navigation` entry per main-frame navigation.
    let research: ResearchRecorder
    /// `env.policyStore` — Offline blocks every load.
    var policy: NetworkPolicyStore? = nil
    /// Tried in order when the initial page (or the previous fallback) answers 404.
    var fallbackURLs: [URL] = []

    func makeCoordinator() -> AccountWebCoordinator {
        AccountWebCoordinator(controller: controller, accountID: accountID, research: research, policy: policy,
                              initialURL: initialURL, fallbackURLs: fallbackURLs)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = webSessions.dataStore(webProfileID: webProfileID)
        configuration.allowsInlineMediaPlayback = true
        configuration.dataDetectorTypes = []
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        if research.capturesBodies {
            // Research Mode: record the page's own API calls (structure only), e.g. the post editor's upload endpoint.
            configuration.userContentController.add(
                WebPageRequestCaptureHandler(accountID: accountID, research: research), contentWorld: .page,
                name: WebPageRequestCapture.handlerName)
            configuration.userContentController.addUserScript(WebPageRequestCapture.userScript)
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.accessibilityIdentifier = "accountWebView"
        context.coordinator.mainWebView = webView
        controller.attach(webView)
        if context.coordinator.allowsNetwork {
            webView.load(URLRequest(url: initialURL))
        } else {
            controller.loadError = "オフラインモードのため読み込みません"
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: AccountWebCoordinator) {
        uiView.stopLoading()
        uiView.configuration.userContentController.removeAllScriptMessageHandlers()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        coordinator.controller?.closePopup()
        coordinator.controller?.detach(uiView)
    }
}

/// Hosts an existing popup `WKWebView`.
struct AccountWebPopupView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Navigation / UI delegate of the account WebView and its popups.
@MainActor
final class AccountWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var controller: AccountWebController?
    weak var mainWebView: WKWebView?
    let accountID: String
    let research: ResearchRecorder
    let policy: NetworkPolicyStore?
    /// URL whose 404 triggers the next fallback (nil once a page was shown).
    private var expectedURL: URL?
    private var pendingFallbacks: [URL]

    init(controller: AccountWebController, accountID: String, research: ResearchRecorder, policy: NetworkPolicyStore? = nil,
         initialURL: URL? = nil, fallbackURLs: [URL] = []) {
        self.controller = controller
        self.accountID = accountID
        self.research = research
        self.policy = policy
        self.expectedURL = fallbackURLs.isEmpty ? nil : initialURL
        self.pendingFallbacks = fallbackURLs
    }

    var allowsNetwork: Bool { policy?.current.allowsNetwork ?? true }

    private func isMain(_ webView: WKWebView) -> Bool { webView === mainWebView }

    /// Same page (host + path, trailing slash ignored): redirects between equivalent URLs keep the fallback armed.
    static func samePage(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        func norm(_ u: URL) -> String {
            var path = u.path
            while path.hasSuffix("/") && path.count > 1 { path.removeLast() }
            return (u.host ?? "").lowercased() + path
        }
        return norm(a) == norm(b)
    }

    /// Next fallback for a main-frame 404 of the expected page (nil = show the 404 page).
    func fallback(afterNotFound url: URL?) -> URL? {
        guard let expected = expectedURL, Self.samePage(expected, url), !pendingFallbacks.isEmpty else { return nil }
        let next = pendingFallbacks.removeFirst()
        expectedURL = pendingFallbacks.isEmpty ? nil : next
        return next
    }

    private func disarmFallbacks() {
        expectedURL = nil
        pendingFallbacks.removeAll()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if (scheme == "http" || scheme == "https") && !allowsNetwork {
            // Offline mode: no page (or popup) of the account web view may load.
            decisionHandler(.cancel)
            if isMain(webView) { controller?.loadError = "オフラインモードのため読み込みません" }
            return
        }
        switch scheme {
        case "http", "https", "about", "blob", "data", "javascript":
            decisionHandler(.allow)
        default:
            // App links (pixiv://, itms-apps://, mailto: ...) leave the account context; only follow explicit taps.
            decisionHandler(.cancel)
            recordNavigation(url: url, method: "EXTERNAL", status: nil, error: nil)
            if navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame {
            let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode
            recordNavigation(url: navigationResponse.response.url, method: isMain(webView) ? "NAVIGATE" : "POPUP", status: status, error: nil)
            // Unverified destinations (docs/API.md §20): never leave the user on a missing page. The controller walks
            // `WebDestination.fallbackSteps` (each chain ends at a verified page) and shows which page replaced it.
            if isMain(webView), controller?.handleMainFrameResponse(status: status) == true {
                recordNavigation(url: navigationResponse.response.url ?? webView.url ?? URL(string: "about:blank")!,
                                 method: "FALLBACK", status: status, error: nil)
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if isMain(webView) { controller?.loadError = nil }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        recordNavigation(url: webView.url, method: "REDIRECT", status: nil, error: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isMain(webView), let controller else { return }
        controller.refreshState()
        if let url = webView.url { controller.onMainFrameFinished?(url) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(webView, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        AppLog.web.notice("web content process terminated; reloading")
        webView.reload()
    }

    private func handleFailure(_ webView: WKWebView, error: Error) {
        let ns = error as NSError
        // Cancelled loads (new navigation started) and "frame load interrupted" (policy cancel) are not errors.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        let failingURL = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        recordNavigation(url: failingURL, method: isMain(webView) ? "NAVIGATE" : "POPUP", status: nil, error: error)
        guard isMain(webView) else { return }
        controller?.refreshState()
        if ns.domain == NSURLErrorDomain && (ns.code == NSURLErrorNotConnectedToInternet || ns.code == NSURLErrorNetworkConnectionLost) {
            controller?.loadError = "オフラインのためページを読み込めませんでした"
        } else {
            controller?.loadError = "ページを読み込めませんでした (\(ns.code))"
        }
    }

    private func recordNavigation(url: URL?, method: String, status: Int?, error: Error?) {
        guard let url else { return }
        let errorText = error.map { e -> String in
            let ns = e as NSError
            return "\(ns.domain) \(ns.code)"
        }
        research.record(ResearchEntry(kind: .navigation, accountID: accountID, method: method,
                                      endpoint: SecretRedactor.redactURL(url), statusCode: status, errorDescription: errorText))
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        guard let controller else { return nil }
        if controller.popup != nil {
            // Only one popup level: load further popups in place.
            if let url = navigationAction.request.url { controller.popup?.webView.load(URLRequest(url: url)) }
            return nil
        }
        // `configuration` inherits the account's websiteDataStore → the popup stays in the same account session.
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.accessibilityIdentifier = "accountWebPopup"
        controller.popup = AccountWebPopup(webView: popup)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let popup = controller?.popup, popup.webView === webView {
            controller?.popup = nil
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor () -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        if !WebPresentationAnchor.present(alert) { completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        if !WebPresentationAnchor.present(alert) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = UIAlertController(title: frame.request.url?.host, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in completionHandler(alert?.textFields?.first?.text) })
        if !WebPresentationAnchor.present(alert) { completionHandler(nil) }
    }
}

/// Finds the top-most view controller of the key window (UIKit presentation above SwiftUI sheets).
@MainActor
enum WebPresentationAnchor {
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        let window = windows.first(where: \.isKeyWindow) ?? windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    @discardableResult
    static func present(_ viewController: UIViewController, animated: Bool = true, completion: (() -> Void)? = nil) -> Bool {
        guard let top = topViewController() else { return false }
        top.present(viewController, animated: animated, completion: completion)
        return true
    }
}

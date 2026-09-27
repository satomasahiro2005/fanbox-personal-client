import Foundation
import os
import UIKit
import WebKit

/// What the WebView transport needs to know about an account (resolved on the main actor from the local DB).
struct WebFetchAccount: Sendable, Equatable {
    var accountID: String
    var webProfileID: String
    /// The pixiv user this local account is bound to. The page's logged-in user must match it before anything is sent.
    var pixivUserID: String?
}

/// Why a hidden page could not be used. Nothing was sent to the API in any of these cases.
enum WebFetchHostError: Error, Equatable {
    case timeout
    case offline
    case loadFailed(Int)
    /// Challenge page / no page metadata / non-2xx page.
    case challenged(Int?)
    /// The web store is not logged in.
    case loggedOut
    /// The web store is logged in as another pixiv user (SPEC §3.2): the page is never used.
    case identityMismatch(pageUserID: String)
    case processTerminated

    var reason: String {
        switch self {
        case .timeout: return "page timeout"
        case .offline: return "offline"
        case .loadFailed(let code): return "page load failed (\(code))"
        case .challenged(let status): return "page challenged (\(status.map(String.init) ?? "no metadata"))"
        case .loggedOut: return "web session logged out"
        case .identityMismatch: return "web session belongs to another pixiv user"
        case .processTerminated: return "web content process terminated"
        }
    }
}

/// Raw answer of one in-page `fetch()`.
struct WebFetchRawResult: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data
    var url: URL?
}

/// ONE account's hidden WKWebView used as a request transport (docs/API.md §1.11).
///
/// - Its configuration uses the SAME `WKWebsiteDataStore` as the account's visible web sessions
///   (`WebSessionStore.dataStore(webProfileID:)`), no custom User-Agent, and has https://www.fanbox.cc/ loaded, so
///   requests carry exactly the browser session (cookies, cf_clearance, UA, TLS) of that account.
/// - Before first use the page metadata is read: the logged-in user must equal `WebFetchAccount.pixivUserID`.
/// - `fetch` runs `fetch(url, {credentials: "include"})` in the isolated `.defaultClient` content world (page scripts
///   cannot intercept it) and returns status / headers / body. Only https://api.fanbox.cc and https://www.fanbox.cc
///   URLs are accepted. Writes use `redirect: "manual"` (a redirect is reported, never followed).
/// - The CSRF token read from the page is kept in memory only.
@MainActor
final class WebFetchHost: NSObject, WKNavigationDelegate {
    static let homeURL = URL(string: "https://www.fanbox.cc/")!
    static let readyTimeout: TimeInterval = 20
    /// The page (and its CSRF token) is reloaded after this long.
    static let pageMaxAge: TimeInterval = 30 * 60

    let account: WebFetchAccount
    private let webSessions: WebSessionStore
    private let policy: NetworkPolicyStore

    private(set) var webView: WKWebView?
    private(set) var readyAt: Date?
    private(set) var pageCSRFToken: String?
    private(set) var userAgent: String?
    var lastUsed = Date()
    /// Fetches currently running (a host in use is never evicted).
    var inUse = 0

    private var loadWaiters: [CheckedContinuation<Void, Error>] = []
    private var loadGeneration = 0
    private var mainFrameStatus: Int?

    init(account: WebFetchAccount, webSessions: WebSessionStore, policy: NetworkPolicyStore) {
        self.account = account
        self.webSessions = webSessions
        self.policy = policy
    }

    var isReady: Bool {
        guard let readyAt, webView != nil else { return false }
        return Date().timeIntervalSince(readyAt) < Self.pageMaxAge
    }

    // MARK: - Ready

    /// Loads https://www.fanbox.cc/ (if needed) and verifies the page's logged-in user. Returns the page metadata.
    @discardableResult
    func ensureReady() async throws -> WebPageMetadata? {
        if isReady { return nil }
        readyAt = nil
        pageCSRFToken = nil
        try await loadHome()
        guard let webView else { throw WebFetchHostError.processTerminated }
        if let status = mainFrameStatus, !(200..<300).contains(status) { throw WebFetchHostError.challenged(status) }
        guard let metadata = await WebPageInspector.inspect(webView) else { throw WebFetchHostError.challenged(nil) }
        if metadata.user == nil && metadata.csrfToken == nil && metadata.isLoggedIn == nil {
            // No metadata tag at all: a challenge / interstitial page, not proof of logout.
            throw WebFetchHostError.challenged(mainFrameStatus)
        }
        guard metadata.isLoggedIn != false, let user = metadata.user else { throw WebFetchHostError.loggedOut }
        if let expected = account.pixivUserID, !expected.isEmpty, user.pixivUserID != expected {
            throw WebFetchHostError.identityMismatch(pageUserID: user.pixivUserID)
        }
        pageCSRFToken = metadata.csrfToken
        userAgent = metadata.userAgent
        readyAt = Date()
        return metadata
    }

    private func loadHome() async throws {
        let webView = makeWebViewIfNeeded()
        loadGeneration += 1
        let generation = loadGeneration
        mainFrameStatus = nil
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadWaiters.append(continuation)
            if loadWaiters.count == 1 {
                webView.load(URLRequest(url: Self.homeURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.readyTimeout))
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.readyTimeout * 1_000_000_000))
                guard let self, self.loadGeneration == generation, !self.loadWaiters.isEmpty else { return }
                self.webView?.stopLoading()
                self.finishLoad(.failure(WebFetchHostError.timeout))
            }
        }
    }

    private func finishLoad(_ result: Result<Void, Error>) {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    private func makeWebViewIfNeeded() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = webSessions.dataStore(webProfileID: account.webProfileID)
        configuration.dataDetectorTypes = []
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: configuration)
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
        webView.accessibilityElementsHidden = true
        webView.isAccessibilityElement = false
        // Kept in the window (behind everything) so WebKit does not throttle the page's process.
        if let window = Self.hostWindow() { window.insertSubview(webView, at: 0) }
        self.webView = webView
        return webView
    }

    private static func hostWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    /// Stops and releases the WebView (the data store itself is untouched).
    func shutdown() {
        loadGeneration += 1
        finishLoad(.failure(WebFetchHostError.processTerminated))
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        readyAt = nil
        pageCSRFToken = nil
    }

    // MARK: - Fetch

    /// Runs one request inside the page. `csrfToken` is added as `x-csrf-token` for writes.
    /// - Throws: `RemoteError.edgeBlocked` (TypeError while the network is up), `.offline`, `.network` (timeout / unknown).
    func fetch(_ request: HTTPRequest, csrfToken: String?) async throws -> WebFetchRawResult {
        guard let webView, isReady else { throw WebFetchHostError.processTerminated }
        var headers: [String: String] = [:]
        for (name, value) in request.headers where Self.isForwardedHeader(name) { headers[name] = value }
        if request.requiresCSRF {
            guard let csrfToken, !csrfToken.isEmpty else { throw RemoteError.csrfUnavailable }
            headers["x-csrf-token"] = csrfToken
        }
        let arguments: [String: Any] = [
            "url": request.url.absoluteString,
            "method": request.method.uppercased(),
            "headers": headers,
            "bodyBase64": request.body.map { $0.base64EncodedString() } ?? NSNull(),
            "timeoutMs": Int(max(1, request.timeout) * 1000),
        ]
        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(Self.fetchScript, arguments: arguments, in: nil, contentWorld: .defaultClient)
        } catch {
            let ns = error as NSError
            AppLog.web.notice("web transport script failed (\(ns.domain, privacy: .public) \(ns.code, privacy: .public))")
            throw RemoteError.network(code: ns.code, detail: "WebView script failed")
        }
        guard let json = value as? String, let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RemoteError.network(code: -1, detail: "WebView transport returned no result")
        }
        if let name = object["error"] as? String {
            throw mapScriptError(name)
        }
        if (object["type"] as? String) == "opaqueredirect" {
            throw RemoteError.invalidRequest("FANBOXが書き込みをリダイレクトしました")
        }
        let status = (object["status"] as? NSNumber)?.intValue ?? 0
        var responseHeaders: [String: String] = [:]
        for (key, value) in (object["headers"] as? [String: Any]) ?? [:] { responseHeaders[key] = "\(value)" }
        let body = (object["body"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        let url = (object["url"] as? String).flatMap(URL.init(string:))
        return WebFetchRawResult(status: status, headers: responseHeaders, body: body, url: url)
    }

    private func mapScriptError(_ name: String) -> RemoteError {
        switch name {
        case "AbortError", "TimeoutError":
            return .network(code: URLError.timedOut.rawValue, detail: "WebView fetch timeout")
        case "TypeError":
            // A CORS-less edge answer (Cloudflare 403 / 429) reaches JavaScript only as "Failed to fetch".
            let snapshot = policy.current
            return snapshot.allowsNetwork && snapshot.pathSatisfied ? .edgeBlocked(retryAfter: nil) : .offline
        default:
            return .network(code: -1, detail: "WebView fetch \(name.prefix(40))")
        }
    }

    /// Headers the page may set itself; the browser owns Cookie / Origin / Referer / User-Agent / Sec-* / Host.
    static func isForwardedHeader(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "accept" || lower == "content-type"
    }

    /// `fetch()` inside the page. Arguments: url, method, headers, bodyBase64 (or null), timeoutMs. Returns a JSON string.
    static let fetchScript = """
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const init = { method: method, headers: headers, credentials: 'include', mode: 'cors', cache: 'no-store',
                     redirect: method === 'GET' ? 'follow' : 'manual', signal: controller.signal };
      if (bodyBase64 !== null) {
        const bin = atob(bodyBase64);
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) { bytes[i] = bin.charCodeAt(i); }
        init.body = bytes;
      }
      const response = await fetch(url, init);
      const buffer = new Uint8Array(await response.arrayBuffer());
      let binary = '';
      for (let i = 0; i < buffer.length; i += 0x8000) {
        binary += String.fromCharCode.apply(null, buffer.subarray(i, i + 0x8000));
      }
      const outHeaders = {};
      response.headers.forEach((value, key) => { outHeaders[key] = value; });
      return JSON.stringify({ status: response.status, type: response.type, url: response.url, headers: outHeaders,
                              body: btoa(binary) });
    } catch (e) {
      return JSON.stringify({ error: (e && e.name) ? String(e.name) : 'Error' });
    } finally {
      clearTimeout(timer);
    }
    """

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard policy.current.allowsNetwork else {
            decisionHandler(.cancel)
            finishLoad(.failure(WebFetchHostError.offline))
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if isMainFrame, let url = navigationAction.request.url {
            let allowed = url.scheme?.lowercased() == "https" && FanboxHostPolicy.isFanboxHost(url.host)
            if !allowed {
                // e.g. a redirect to the pixiv login page: this hidden page never leaves FANBOX.
                decisionHandler(.cancel)
                finishLoad(.failure(WebFetchHostError.loggedOut))
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame {
            mainFrameStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failLoad(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failLoad(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        AppLog.web.notice("web transport content process terminated")
        readyAt = nil
        pageCSRFToken = nil
        finishLoad(.failure(WebFetchHostError.processTerminated))
    }

    private func failLoad(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        if ns.domain == NSURLErrorDomain && (ns.code == NSURLErrorNotConnectedToInternet || ns.code == NSURLErrorNetworkConnectionLost) {
            finishLoad(.failure(WebFetchHostError.offline))
        } else {
            finishLoad(.failure(WebFetchHostError.loadFailed(ns.code)))
        }
    }
}

/// The app's `WebFetching` implementation: at most `maxLiveHosts` hidden WebViews (LRU), torn down after
/// `idleTimeout`, in the background, on memory warnings, when the app goes Offline, and on logout / removal
/// (`shutdown(accountID:)` BEFORE the account's data store is cleared or removed).
///
/// Every fetch runs inside `NetworkScheduler.run(priority, label:)` (Offline fails before anything loads) and records a
/// redacted `ResearchEntry` named "webview".
@MainActor
final class WebFetchHostPool: WebFetching {
    nonisolated let scheduler: NetworkScheduler
    nonisolated let recorder: ResearchRecorder
    nonisolated let credentials: CredentialStoring
    nonisolated let policy: NetworkPolicyStore
    let webSessions: WebSessionStore

    /// accountID → account (nil for demo / placeholder / unknown accounts: the transport is then unavailable).
    var accountResolver: ((String) -> WebFetchAccount?)?
    /// Called before a host loads its page (installs the Keychain session into an empty web store).
    var prepareSession: ((String) async -> Void)?
    /// The web store of the account is logged in as another pixiv user.
    var onIdentityMismatch: ((_ accountID: String, _ pageUserID: String) -> Void)?

    let maxLiveHosts: Int
    let idleTimeout: TimeInterval

    private var hosts: [String: WebFetchHost] = [:]
    private var idleTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var policyObserver: UUID?
    private nonisolated let foreground: OSAllocatedUnfairLock<Bool>

    init(webSessions: WebSessionStore, credentials: CredentialStoring, scheduler: NetworkScheduler, recorder: ResearchRecorder,
         policy: NetworkPolicyStore, maxLiveHosts: Int = 2, idleTimeout: TimeInterval = 180) {
        self.webSessions = webSessions
        self.credentials = credentials
        self.scheduler = scheduler
        self.recorder = recorder
        self.policy = policy
        self.maxLiveHosts = max(1, maxLiveHosts)
        self.idleTimeout = idleTimeout
        foreground = OSAllocatedUnfairLock(initialState: UIApplication.shared.applicationState != .background)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setForeground(false) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setForeground(true) }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setForeground(true) }
            },
            center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.shutdownAll() }
            },
        ]
        policyObserver = policy.addObserver { [weak self] snapshot in
            guard !snapshot.allowsNetwork else { return }
            Task { @MainActor in self?.shutdownAll() }
        }
    }

    nonisolated var isForeground: Bool { foreground.withLock { $0 } }

    /// Number of live hidden WebViews (tests / Research Mode).
    var liveHostCount: Int { hosts.count }

    private func setForeground(_ value: Bool) {
        foreground.withLock { $0 = value }
        if !value { shutdownAll() }
    }

    // MARK: - WebFetching

    nonisolated func fetch(_ request: HTTPRequest, accountID: String) async throws -> HTTPResponse {
        try await scheduler.run(request.priority, label: request.endpointKey) { [self] in
            try await self.perform(request, accountID: accountID)
        }
    }

    nonisolated func shutdown(accountID: String) async {
        await shutdownHost(accountID: accountID)
    }

    func shutdownAll() {
        for host in hosts.values { host.shutdown() }
        hosts.removeAll()
        idleTask?.cancel()
        idleTask = nil
    }

    private func shutdownHost(accountID: String) {
        hosts.removeValue(forKey: accountID)?.shutdown()
    }

    // MARK: - Private

    private func perform(_ request: HTTPRequest, accountID: String) async throws -> HTTPResponse {
        guard isForeground else { throw WebFetchError.unavailable("background") }
        guard let account = accountResolver?(accountID) else { throw WebFetchError.unavailable("no web account") }
        guard request.url.scheme?.lowercased() == "https",
              FanboxHostPolicy.isAPIHost(request.url.host) || FanboxHostPolicy.isWWWHost(request.url.host) else {
            throw WebFetchError.unavailable("host not allowed")
        }
        let host = host(for: account)
        host.inUse += 1
        host.lastUsed = Date()
        defer {
            host.inUse -= 1
            host.lastUsed = Date()
            scheduleIdleTeardown()
        }
        if !host.isReady {
            await prepareSession?(accountID)
            do {
                if let metadata = try await host.ensureReady(), let ua = metadata.userAgent {
                    await storeUserAgent(ua, accountID: accountID)
                }
            } catch let error as WebFetchHostError {
                if case .identityMismatch(let pageUser) = error {
                    AppLog.web.error("web transport: web store of \(accountID, privacy: .public) is another pixiv user")
                    shutdownHost(accountID: accountID)
                    onIdentityMismatch?(accountID, pageUser)
                }
                recordNote("web transport unavailable: \(error.reason)", accountID: accountID)
                throw WebFetchError.unavailable(error.reason)
            }
        }
        let started = Date()
        var token = host.pageCSRFToken
        if request.requiresCSRF, token == nil { token = await credentials.credential(for: accountID)?.csrfToken }
        do {
            let raw = try await host.fetch(request, csrfToken: token)
            let response = HTTPResponse(statusCode: raw.status, headers: raw.headers, data: raw.body, url: raw.url ?? request.url,
                                        duration: Date().timeIntervalSince(started))
            record(request: request, accountID: accountID, started: started, response: response, error: nil)
            return response
        } catch let error as WebFetchHostError {
            // The page went away before the script ran: nothing was sent.
            record(request: request, accountID: accountID, started: started, response: nil, error: .network(code: -1, detail: error.reason))
            throw WebFetchError.unavailable(error.reason)
        } catch {
            let mapped = HTTPErrorMapper.map(error)
            record(request: request, accountID: accountID, started: started, response: nil, error: mapped)
            if case .network = mapped, request.method.uppercased() == "GET" {
                // A read whose page failed can safely go through the native transport.
                throw WebFetchError.unavailable("script failed")
            }
            throw mapped
        }
    }

    private func host(for account: WebFetchAccount) -> WebFetchHost {
        if let existing = hosts[account.accountID] {
            if existing.account == account { return existing }
            existing.shutdown()
            hosts[account.accountID] = nil
        }
        while hosts.count >= maxLiveHosts,
              let victim = hosts.values.filter({ $0.inUse == 0 }).min(by: { $0.lastUsed < $1.lastUsed }) {
            victim.shutdown()
            hosts[victim.account.accountID] = nil
        }
        let host = WebFetchHost(account: account, webSessions: webSessions, policy: policy)
        hosts[account.accountID] = host
        return host
    }

    private func scheduleIdleTeardown() {
        guard idleTask == nil else { return }
        let timeout = idleTimeout
        idleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(5, timeout / 3) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                let now = Date()
                for (id, host) in self.hosts where host.inUse == 0 && now.timeIntervalSince(host.lastUsed) >= timeout {
                    host.shutdown()
                    self.hosts[id] = nil
                }
                if self.hosts.isEmpty {
                    self.idleTask = nil
                    return
                }
            }
        }
    }

    /// The WKWebView UA is what cf_clearance is bound to: keep the native transport presenting the same one.
    /// (Update-only: a logged-out / removed account never gets a credential back.)
    private func storeUserAgent(_ ua: String, accountID: String) async {
        await credentials.updateUserAgent(ua, for: accountID)
    }

    private func recordNote(_ text: String, accountID: String) {
        recorder.recordNote(text, accountID: accountID, endpoint: "transport")
    }

    private func record(request: HTTPRequest, accountID: String, started: Date, response: HTTPResponse?, error: RemoteError?) {
        let captureBodies = recorder.capturesBodies
        var sentHeaders = request.headers.filter { WebFetchHost.isForwardedHeader($0.key) }
        if request.requiresCSRF { sentHeaders["x-csrf-token"] = SecretRedactor.placeholder }
        var requestHeaders = "# transport: \(TransportKind.webView.rawValue)\n" + SecretRedactor.formatHeaders(sentHeaders)
        if captureBodies, let body = request.body, !body.isEmpty {
            requestHeaders += "\n\n[request body]\n" + SecretRedactor.redactBody(body, contentType: request.headers["Content-Type"],
                                                                                  limit: 16_000)
        }
        var responseBody = ""
        if captureBodies, let data = response?.data, !data.isEmpty {
            responseBody = SecretRedactor.redactBody(data, contentType: response.flatMap {
                HTTPErrorMapper.header(named: "Content-Type", in: $0.headers)
            })
        }
        let statusError = response.flatMap { HTTPErrorMapper.error(status: $0.statusCode, headers: $0.headers, body: $0.data) }
        let finalError = error ?? statusError
        recorder.record(ResearchEntry(
            timestamp: started, kind: .request, accountID: accountID, method: request.method.uppercased(),
            endpoint: SecretRedactor.redactURL(response?.url ?? request.url), statusCode: response?.statusCode,
            durationMs: Int((Date().timeIntervalSince(started) * 1000).rounded()), priority: request.priority,
            requestHeaders: requestHeaders,
            responseHeaders: response.map { SecretRedactor.formatHeaders($0.headers) } ?? "",
            responseBody: responseBody, bytes: response?.data.count,
            errorDescription: finalError.map { "\(request.endpointKey): \(AccountHTTPClient.describe($0))" }))
    }
}

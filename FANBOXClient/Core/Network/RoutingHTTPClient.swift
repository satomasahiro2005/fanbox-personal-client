import Foundation
import os

/// The WebView-backed transport as the router sees it (seam for tests; the app uses `WebFetchHostPool`).
///
/// `fetch` runs `fetch()` inside the account's hidden WKWebView (same `WKWebsiteDataStore` as the account's web
/// sessions, page https://www.fanbox.cc/) and returns the HTTP answer like `HTTPClient.send` (non-2xx included).
/// - Throws `WebFetchError.unavailable` when nothing was sent (no usable web session / background / page not ready):
///   the router may then use the native transport, even for writes.
/// - Throws `RemoteError.edgeBlocked` when the browser request itself was refused at the edge (a CORS-less
///   Cloudflare 403 / 429 surfaces in JavaScript only as a TypeError).
/// - Throws other `RemoteError`s (e.g. `.network`) when the outcome is unknown; writes are then never re-sent.
protocol WebFetching: AnyObject, Sendable {
    /// Whether a WebView may be used right now (app in the foreground).
    var isForeground: Bool { get }
    func fetch(_ request: HTTPRequest, accountID: String) async throws -> HTTPResponse
    /// Tears down the account's hidden WebView (logout / removal, before its data store is cleared).
    func shutdown(accountID: String) async
}

enum WebFetchError: Error, Equatable, Sendable {
    /// The WebView transport could not be used; nothing was sent.
    case unavailable(String)
}

/// Research Mode override of the transport choice.
enum TransportOverride: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case nativeOnly
    case webViewOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "自動"
        case .nativeOnly: return "Nativeのみ"
        case .webViewOnly: return "WebViewのみ"
        }
    }
}

/// Remembers, per endpoint, that the native transport was edge-blocked, so the WebView is tried first for a while
/// (docs/API.md §1.11 "prefer that transport next time"). Device-wide on purpose: the edge judges the client
/// (TLS / HTTP fingerprint, IP), not the account, so another account would only collect the same block.
/// Non-secret values only (endpoint keys and dates) in UserDefaults.
final class TransportPreferences: @unchecked Sendable {
    static let preferWebDuration: TimeInterval = 24 * 60 * 60
    private static let preferKey = "transport.preferWebUntil"
    private static let overrideKey = "transport.override"

    private struct State {
        var preferWebUntil: [String: Date]
        var override: TransportOverride
    }

    private let defaults: UserDefaults?
    private let clock: @Sendable () -> Date
    private let state: OSAllocatedUnfairLock<State>

    /// `defaults == nil` keeps everything in memory (tests / previews).
    init(defaults: UserDefaults?, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.clock = clock
        var stored: [String: Date] = [:]
        if let raw = defaults?.dictionary(forKey: Self.preferKey) {
            for (key, value) in raw { if let date = value as? Date { stored[key] = date } }
        }
        let override = TransportOverride(rawValue: defaults?.string(forKey: Self.overrideKey) ?? "") ?? .automatic
        state = OSAllocatedUnfairLock(initialState: State(preferWebUntil: stored, override: override))
    }

    var override: TransportOverride {
        get { state.withLock { $0.override } }
        set {
            state.withLock { $0.override = newValue }
            defaults?.set(newValue.rawValue, forKey: Self.overrideKey)
        }
    }

    func prefersWeb(endpointKey: String) -> Bool {
        let now = clock()
        return state.withLock { ($0.preferWebUntil[endpointKey] ?? .distantPast) > now }
    }

    func markNativeEdgeBlocked(endpointKey: String) {
        let until = clock().addingTimeInterval(Self.preferWebDuration)
        let snapshot = state.withLock { s -> [String: Date] in
            s.preferWebUntil[endpointKey] = until
            let now = clock()
            s.preferWebUntil = s.preferWebUntil.filter { $0.value > now }
            return s.preferWebUntil
        }
        defaults?.set(snapshot, forKey: Self.preferKey)
    }

    /// Endpoint → prefer-WebView-until (Research Mode).
    func webPreferences() -> [String: Date] {
        let now = clock()
        return state.withLock { $0.preferWebUntil.filter { $0.value > now } }
    }

    func clear() {
        state.withLock { $0.preferWebUntil.removeAll() }
        defaults?.removeObject(forKey: Self.preferKey)
    }
}

/// Pure transport decision table (unit-tested).
enum TransportRouter {
    /// docs/API.md §1.7 / §6.1: blocked for non-browser clients since 2026-04 (post.getEditable reportedly too).
    static let webFirstEndpoints: Set<String> = ["post.info", "post.getEditable"]

    /// Ordered transports to try. The second one is only used when the first did not reach FANBOX (native edge block,
    /// or the WebView was unavailable) — never after an answer or an ambiguous failure.
    /// - Hosts other than api / www.fanbox.cc, background, no web transport → native only.
    /// - `webViewOnly` (Research) → WebView only while it can run, else native.
    /// - Web-first endpoints, or endpoints whose native transport was edge-blocked recently → WebView, then native.
    /// - Everything else → native, then WebView.
    static func plan(endpointKey: String, host: String?, isForeground: Bool, webAvailable: Bool,
                     override: TransportOverride, prefersWeb: Bool) -> [TransportKind] {
        guard FanboxHostPolicy.isBudgetedHost(host) else { return [.native] }
        guard webAvailable, isForeground else { return [.native] }
        switch override {
        case .nativeOnly: return [.native]
        case .webViewOnly: return [.webView]
        case .automatic:
            if webFirstEndpoints.contains(endpointKey) || prefersWeb { return [.webView, .native] }
            return [.native, .webView]
        }
    }
}

/// The app's `HTTPClient` (SPEC §40 "API 仕様変更時の緊急フォールバック", docs/API.md §1.11): routes each FANBOX request to
/// the native URLSession transport or the account's WebView transport, applies the device-wide `RateGate`, and falls
/// back from native to WebView when the native request is stopped at the edge.
///
/// - Every attempt passes `RateGate.admit` first; both transports run inside `NetworkScheduler` with the request
///   priority and record redacted Research entries (the transport is named in each entry).
/// - A write is re-sent on the other transport only when the first attempt provably did not reach FANBOX (native edge
///   block, or the WebView was not usable), never after a timeout or an unknown outcome.
/// - 429 answers start the device-wide cooldown; edge blocks trip breakers (see `RateGate`).
/// - Downloads always use the native transport (media hosts are not behind the post.info rule).
final class RoutingHTTPClient: CredentialBackedHTTPClient, SessionRevoking, @unchecked Sendable {
    let native: AccountHTTPClient
    let web: WebFetching?
    let gate: RateGate
    let preferences: TransportPreferences
    let recorder: ResearchRecorder?

    var credentials: CredentialStoring { native.credentials }

    init(native: AccountHTTPClient, web: WebFetching?, gate: RateGate, preferences: TransportPreferences,
         recorder: ResearchRecorder? = nil) {
        self.native = native
        self.web = web
        self.gate = gate
        self.preferences = preferences
        self.recorder = recorder
    }

    // MARK: - HTTPClient

    func send(_ request: HTTPRequest, accountID: String?) async throws -> HTTPResponse {
        let host = request.url.host
        guard FanboxHostPolicy.isBudgetedHost(host) else { return try await native.send(request, accountID: accountID) }
        let plan = TransportRouter.plan(endpointKey: request.endpointKey, host: host, isForeground: web?.isForeground ?? false,
                                        webAvailable: web != nil && accountID != nil, override: preferences.override,
                                        prefersWeb: preferences.prefersWeb(endpointKey: request.endpointKey))
        var edgeResponse: HTTPResponse?
        var breakerRemaining: TimeInterval?
        var webUnavailable: String?
        /// The native attempt had no CSRF token: it sent nothing.
        var nativeHadNoToken = false

        for transport in plan {
            if let remaining = await gate.breakerRemaining(accountID: accountID, endpointKey: request.endpointKey, transport: transport) {
                breakerRemaining = max(breakerRemaining ?? 0, remaining)
                continue
            }
            try await gate.admit(endpointKey: request.endpointKey, host: host, priority: request.priority)
            switch transport {
            case .native:
                let response: HTTPResponse
                do {
                    response = try await native.send(request, accountID: accountID)
                } catch RemoteError.csrfUnavailable where plan.last == .webView && transport != plan.last {
                    // Nothing was sent (no token for the URLSession); the page of the WebView has its own token.
                    nativeHadNoToken = true
                    continue
                }
                if let edge = await classify(response, request: request, accountID: accountID, transport: .native) {
                    edgeResponse = edge
                    note("\(request.endpointKey): native transport edge-blocked (HTTP \(response.statusCode))", accountID: accountID)
                    continue
                }
                return response
            case .webView:
                guard let web, let accountID else { continue }
                do {
                    let response = try await web.fetch(request, accountID: accountID)
                    if let edge = await classify(response, request: request, accountID: accountID, transport: .webView) {
                        return edge
                    }
                    if edgeResponse != nil {
                        note("\(request.endpointKey): served by the WebView transport after a native edge block", accountID: accountID)
                    }
                    return response
                } catch let error as WebFetchError {
                    if case .unavailable(let reason) = error { webUnavailable = reason }
                    continue
                } catch let error as RemoteError {
                    if case .edgeBlocked(let retryAfter) = error {
                        await gate.recordEdgeBlock(accountID: accountID, endpointKey: request.endpointKey, transport: .webView,
                                                   retryAfter: retryAfter)
                        note("\(request.endpointKey): WebView transport edge-blocked", accountID: accountID)
                    }
                    throw error
                }
            }
        }
        if let edgeResponse { return edgeResponse }
        if let breakerRemaining { throw RemoteError.edgeBlocked(retryAfter: breakerRemaining) }
        // Neither transport sent anything (no token for the URLSession, the page unusable): a refusal, not a network error
        // with an unknown outcome (a reply would otherwise be flagged "maybe sent").
        if nativeHadNoToken { throw RemoteError.csrfUnavailable }
        throw RemoteError.network(code: -1, detail: "WebView transport unavailable (\(webUnavailable ?? "no transport"))")
    }

    func download(_ request: HTTPRequest, accountID: String?, progress: (@Sendable (Double) -> Void)?) async throws -> (URL, HTTPResponse) {
        try await native.download(request, accountID: accountID, progress: progress)
    }

    /// Multipart bodies from files: native only (budgeted and classified like `send`).
    func upload(_ request: HTTPRequest, bodyFileURL: URL, accountID: String?,
                progress: (@Sendable (Double) -> Void)?) async throws -> HTTPResponse {
        let host = request.url.host
        if let remaining = await gate.breakerRemaining(accountID: accountID, endpointKey: request.endpointKey, transport: .native) {
            throw RemoteError.edgeBlocked(retryAfter: remaining)
        }
        try await gate.admit(endpointKey: request.endpointKey, host: host, priority: request.priority)
        let response = try await native.upload(request, bodyFileURL: bodyFileURL, accountID: accountID, progress: progress)
        _ = await classify(response, request: request, accountID: accountID, transport: .native)
        return response
    }

    /// Streamed bodies: native only (budgeted and classified like `send`).
    func upload(_ request: HTTPRequest, streamedBody: HTTPStreamedBody, accountID: String?,
                progress: (@Sendable (Double) -> Void)?) async throws -> HTTPResponse {
        let host = request.url.host
        if let remaining = await gate.breakerRemaining(accountID: accountID, endpointKey: request.endpointKey, transport: .native) {
            throw RemoteError.edgeBlocked(retryAfter: remaining)
        }
        try await gate.admit(endpointKey: request.endpointKey, host: host, priority: request.priority)
        let response = try await native.upload(request, streamedBody: streamedBody, accountID: accountID, progress: progress)
        _ = await classify(response, request: request, accountID: accountID, transport: .native)
        return response
    }

    // MARK: - SessionRevoking

    func revokeSession(accountID: String) async {
        native.invalidateSession(accountID: accountID)
        await web?.shutdown(accountID: accountID)
        await gate.reset(accountID: accountID)
    }

    // MARK: - Helpers

    /// Records 429 / edge blocks with the gate. Returns the response when it is an edge block.
    private func classify(_ response: HTTPResponse, request: HTTPRequest, accountID: String?,
                          transport: TransportKind) async -> HTTPResponse? {
        if response.statusCode == 429 {
            await gate.recordRateLimited(retryAfter: HTTPErrorMapper.retryAfter(HTTPErrorMapper.header(named: "Retry-After",
                                                                                                       in: response.headers)))
            return nil
        }
        guard EdgeBlockDetector.isEdgeBlock(status: response.statusCode, headers: response.headers, body: response.data) else {
            return nil
        }
        await gate.recordEdgeBlock(accountID: accountID, endpointKey: request.endpointKey, transport: transport,
                                   retryAfter: EdgeBlockDetector.retryAfter(headers: response.headers))
        if transport == .native { preferences.markNativeEdgeBlocked(endpointKey: request.endpointKey) }
        return response
    }

    private func note(_ text: String, accountID: String?) {
        AppLog.network.notice("\(text, privacy: .public)")
        recorder?.recordNote(text, accountID: accountID, endpoint: "transport")
    }
}

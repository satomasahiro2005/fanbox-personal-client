import Foundation

struct HTTPRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?
    var timeout: TimeInterval
    var priority: RequestPriority
    /// Stable key for Research Mode / API Inspector, e.g. "post.info".
    var endpointKey: String
    /// Adds `X-CSRF-Token` from the account credential.
    var requiresCSRF: Bool

    init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 30,
         priority: RequestPriority, endpointKey: String, requiresCSRF: Bool = false) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.priority = priority
        self.endpointKey = endpointKey
        self.requiresCSRF = requiresCSRF
    }
}

struct HTTPResponse: Sendable {
    var statusCode: Int
    var headers: [String: String]
    var data: Data
    var url: URL?
    var duration: TimeInterval
}

/// Per-account HTTP transport (SPEC §7.2). Implementations MUST:
/// - isolate cookies / CSRF / session per account (no shared cookie storage),
/// - run every request through `NetworkScheduler` with the request priority,
/// - record a redacted `ResearchLog` entry for each request,
/// - map failures to `RemoteError` and never log secrets.
///
/// Contract of `send` / `upload`: every HTTP answer is RETURNED, including non-2xx statuses (the caller —
/// `FanboxAPIClient.validate` — reads the status, headers and body to tell a FANBOX JSON refusal from a CDN edge block);
/// only transport failures (offline, timeout, cancellation, a missing CSRF token) throw. `download` throws for non-2xx
/// statuses (the partial file is deleted).
protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest, accountID: String?) async throws -> HTTPResponse
    /// Downloads to a temporary file the caller must move. Registered with the scheduler as a pausable transfer.
    func download(_ request: HTTPRequest, accountID: String?,
                  progress: (@Sendable (Double) -> Void)?) async throws -> (URL, HTTPResponse)
    /// Uploads `bodyFileURL` (e.g. a prebuilt multipart body) as the request body.
    func upload(_ request: HTTPRequest, bodyFileURL: URL, accountID: String?,
                progress: (@Sendable (Double) -> Void)?) async throws -> HTTPResponse
}

/// A transport that reads the per-account `CredentialStoring` (the store `FanboxAPIClient` keeps the CSRF token in).
protocol CredentialBackedHTTPClient: HTTPClient {
    var credentials: CredentialStoring { get }
}

/// Tears down everything a transport holds for one account (SPEC §7.2, logout / account removal): cancels its in-flight
/// requests and makes sure late responses can no longer write cookies or tokens for it.
protocol SessionRevoking: AnyObject, Sendable {
    func revokeSession(accountID: String) async
}

/// Which transport carried a request (Research Mode, routing decisions).
enum TransportKind: String, Sendable, CaseIterable {
    /// Per-account URLSession (`AccountHTTPClient`).
    case native
    /// `fetch()` inside the account's hidden WKWebView (`WebFetchHostPool`).
    case webView = "webview"
}

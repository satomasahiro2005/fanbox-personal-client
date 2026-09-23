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

/// A request body sent as a stream: bytes held in memory and files read from disk while they are sent. For uploads whose
/// body must never be written to a file as a whole (a multipart form carrying the CSRF token next to a large file,
/// SPEC §39) and must not be held in memory either. Sent with `Content-Length: length` (not chunked).
struct HTTPStreamedBody: Sendable, Equatable {
    enum Segment: Sendable, Equatable {
        case data(Data)
        /// `length` bytes of a file (its size when the body was built), read in chunks while the body is sent.
        case file(URL, length: Int64)
    }

    var segments: [Segment]

    /// Total size in bytes.
    var length: Int64 {
        segments.reduce(0) { total, segment in
            switch segment {
            case .data(let data): return total + Int64(data.count)
            case .file(_, let length): return total + length
            }
        }
    }

    /// The whole body in memory (test transports only; the app never assembles a streamed body).
    func assembled() throws -> Data {
        var out = Data()
        for segment in segments {
            switch segment {
            case .data(let data):
                out.append(data)
            case .file(let url, let length):
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                out.append(try handle.read(upToCount: Int(length)) ?? Data())
            }
        }
        return out
    }
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
    /// Uploads `streamedBody` as the request body (`Content-Length` = its length). The body is produced while it is sent,
    /// never assembled into one file or buffer. Registered with the scheduler as a pausable transfer like `upload`.
    func upload(_ request: HTTPRequest, streamedBody: HTTPStreamedBody, accountID: String?,
                progress: (@Sendable (Double) -> Void)?) async throws -> HTTPResponse
}

extension HTTPClient {
    /// Transports without streamed uploads send nothing.
    func upload(_ request: HTTPRequest, streamedBody: HTTPStreamedBody, accountID: String?,
                progress: (@Sendable (Double) -> Void)?) async throws -> HTTPResponse {
        throw RemoteError.unsupported(operation: "streamed upload")
    }
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

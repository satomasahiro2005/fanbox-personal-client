import Foundation

/// Receives every successful JSON response with the fields the DTO knows (tests / Research Mode hooks).
typealias FanboxSchemaObserver = @Sendable (_ endpointKey: String, _ rawJSON: Data, _ known: [String: Set<String>]) -> Void

/// Low-level FANBOX JSON API client (endpoints + envelope decoding). Only `FanboxAdapter` / `FanboxRemoteDataSource` use it.
///
/// - Builds `HTTPRequest`s from `FanboxEndpoint`s with the task-local `RequestContext.priority`.
/// - Adds the headers FANBOX requires (`Origin` / `Referer` / `Accept`; the transport adds cookies, UA and `X-CSRF-Token`).
/// - Maps non-2xx statuses and `{ "error": ... }` envelopes to `RemoteError`.
/// - Calls `SchemaInspector.observe(endpointKey:rawJSON:known:)` for every successful JSON response (SPEC §37).
/// - Never logs URLs with values, headers, cookies or tokens (SPEC §38).
final class FanboxAPIClient: Sendable {
    let http: HTTPClient
    let inspector: SchemaInspector
    /// When available, the client stores the CSRF token obtained from www.fanbox.cc metadata, fetches a missing token
    /// before a CSRF-protected write, and refreshes a stale token once when such a write is rejected.
    /// Defaults to the credential store of a `CredentialBackedHTTPClient` transport (`AccountHTTPClient` or the
    /// `RoutingHTTPClient` wrapping it — the store the transport reads `X-CSRF-Token` from). `AppEnvironment` passes it
    /// explicitly anyway, so wrapping the transport can never silently disable CSRF handling.
    let credentials: CredentialStoring?
    let schemaObserver: FanboxSchemaObserver?

    init(http: HTTPClient, inspector: SchemaInspector, credentials: CredentialStoring? = nil, schemaObserver: FanboxSchemaObserver? = nil) {
        self.http = http
        self.inspector = inspector
        self.credentials = credentials ?? (http as? CredentialBackedHTTPClient)?.credentials
        self.schemaObserver = schemaObserver
    }

    static let readTimeout: TimeInterval = 30
    static let uploadTimeout: TimeInterval = 300

    // MARK: - Request building

    /// `HTTPRequest` for an endpoint. Priority defaults to the task-local `RequestContext.priority`.
    func makeRequest(_ endpoint: FanboxEndpoint, priority: RequestPriority? = nil) throws -> HTTPRequest {
        var headers: [String: String] = ["Referer": FanboxEndpoint.webOrigin + "/"]
        switch endpoint.host {
        case .api:
            headers["Accept"] = "application/json, text/plain, */*"
            headers["Origin"] = FanboxEndpoint.webOrigin
        case .www:
            headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        }
        var body: Data?
        if let json = endpoint.jsonBody {
            body = try json.encoded()
            headers["Content-Type"] = "application/json"
        }
        return HTTPRequest(method: endpoint.method, url: endpoint.url, headers: headers, body: body, timeout: Self.readTimeout,
                           priority: priority ?? RequestContext.priority, endpointKey: endpoint.key, requiresCSRF: endpoint.requiresCSRF)
    }

    // MARK: - Typed calls

    /// GET/POST returning a decoded body DTO.
    func send<Body: FanboxResponseBody>(_ endpoint: FanboxEndpoint, as type: Body.Type, accountID: String?) async throws -> Body {
        let response = try await execute(endpoint, accountID: accountID)
        do {
            return try decode(response, endpoint: endpoint, as: Body.self)
        } catch {
            // A 2xx response the DTO cannot use is the strongest API-change signal: make it a research event (SPEC §36).
            inspector.recordFailure(endpointKey: endpoint.key, accountID: accountID, statusCode: response.statusCode, error: error)
            throw error
        }
    }

    /// Write call whose response content is undocumented; returns the `body` JSON if any.
    @discardableResult
    func perform(_ endpoint: FanboxEndpoint, accountID: String?) async throws -> JSONValue? {
        let response = try await execute(endpoint, accountID: accountID)
        guard !response.data.isEmpty, let json = try? JSONValue.parse(response.data) else { return nil }
        if let code = json["error"]?.stringValue, json["body"] == nil {
            throw reportFailure(FanboxResponseHandling.mapErrorCode(code, statusCode: response.statusCode), endpoint, response, accountID)
        }
        observe(endpoint.key, data: response.data, known: [:])
        return json["body"]
    }

    /// Sends a multipart form built by `makeForm` for the account's CSRF token and returns the raw response. Used by
    /// post.update and the media endpoints (post.addImage / post.addFile / post.addUrlEmbed).
    ///
    /// - Every form carries the token in its `tt` field, the way FANBOX's web editor calls these endpoints
    ///   (docs/API.md §14.4 / §15.4); the transport also sends it as the `X-CSRF-Token` header (`requiresCSRF`). A missing
    ///   token is fetched first.
    /// - The token never touches the disk (SPEC §39 "CSRF Token: Keychain または Memory"): a form of plain fields is
    ///   encoded in memory and sent with `send`; a form with a file part is sent with `upload(_:streamedBody:...)`, the
    ///   fields and part headers from memory and the file read from disk while it is sent. No body file is written.
    /// - A write rejected as if the token were stale (400 / 403) is rebuilt with the refreshed token and sent once more,
    ///   only when the refresh returned a different token. `makeForm` errors (local validation) are thrown as they are.
    func sendMultipart(_ endpoint: FanboxEndpoint, accountID: String?, progress: (@Sendable (Double) -> Void)? = nil,
                       form makeForm: (_ csrfToken: String) throws -> MultipartFormData) async throws -> HTTPResponse {
        let response = try await transmitMultipart(endpoint, accountID: accountID, progress: progress, makeForm: makeForm)
        if let json = try? JSONValue.parse(response.data), json["body"] != nil {
            observe(endpoint.key, data: response.data, known: [:])
        }
        return response
    }

    /// `sendMultipart` returning a decoded body DTO (media endpoints). A 2xx answer the DTO cannot use is recorded as a
    /// research event, like `send(_:as:accountID:)`.
    func sendMultipart<Body: FanboxResponseBody>(_ endpoint: FanboxEndpoint, as type: Body.Type, accountID: String?,
                                                 progress: (@Sendable (Double) -> Void)? = nil,
                                                 form makeForm: (_ csrfToken: String) throws -> MultipartFormData) async throws -> Body {
        let response = try await transmitMultipart(endpoint, accountID: accountID, progress: progress, makeForm: makeForm)
        do {
            return try decode(response, endpoint: endpoint, as: Body.self)
        } catch {
            inspector.recordFailure(endpointKey: endpoint.key, accountID: accountID, statusCode: response.statusCode, error: error)
            throw error
        }
    }

    private func transmitMultipart(_ endpoint: FanboxEndpoint, accountID: String?, progress: (@Sendable (Double) -> Void)?,
                                   makeForm: (String) throws -> MultipartFormData) async throws -> HTTPResponse {
        guard let accountID, let token = try await csrfToken(accountID: accountID), !token.isEmpty else {
            throw RemoteError.unauthorized
        }
        let form = try makeForm(token)
        do {
            return try await transmit(endpoint, form: form, accountID: accountID, progress: progress)
        } catch let error as RemoteError {
            guard endpoint.requiresCSRF, Self.mayBeStaleCSRF(error),
                  let fresh = try? await refreshCSRFToken(accountID: accountID), !fresh.isEmpty, fresh != token else { throw error }
            AppLog.network.info("retrying \(endpoint.key, privacy: .public) once with a refreshed CSRF token")
            return try await transmit(endpoint, form: makeForm(fresh), accountID: accountID, progress: progress)
        }
    }

    /// One attempt: in memory for a field-only form, streamed for a form with a file part. Validates the answer.
    private func transmit(_ endpoint: FanboxEndpoint, form: MultipartFormData, accountID: String,
                          progress: (@Sendable (Double) -> Void)?) async throws -> HTTPResponse {
        var request = try makeRequest(endpoint)
        request.headers["Content-Type"] = form.contentType
        request.timeout = Self.uploadTimeout
        let streamed = form.hasFileParts ? try form.streamedBody() : nil
        if streamed == nil { request.body = try form.encodedData() }
        let sendable = request
        let response: HTTPResponse
        do {
            if let streamed {
                response = try await http.upload(sendable, streamedBody: streamed, accountID: accountID, progress: progress)
            } else {
                response = try await http.send(sendable, accountID: accountID)
            }
        } catch {
            throw Self.normalize(error)
        }
        try validate(response, endpoint: endpoint)
        progress?(1)
        return response
    }

    // MARK: - Session metadata / CSRF (www.fanbox.cc)

    /// Fetches the www.fanbox.cc page metadata (logged-in user summary + CSRF token). The token is a secret: it is redacted
    /// before the API Inspector sees the JSON and is never logged.
    func fetchMetadata(accountID: String?) async throws -> FanboxMetadataDTO {
        let endpoint = FanboxEndpoint.homepageMetadata()
        let response = try await execute(endpoint, accountID: accountID, allowCSRFRetry: false)
        guard let html = String(data: response.data, encoding: .utf8) ?? String(data: response.data, encoding: .isoLatin1) else {
            throw reportFailure(.decoding(endpoint: endpoint.key, detail: "HTMLを読めません"), endpoint, response, accountID)
        }
        guard let jsonText = FanboxMetadataParser.metadataJSON(fromHTML: html) else {
            // No metadata: a challenge page or an unexpected layout. Not proof of logout.
            throw reportFailure(.decoding(endpoint: endpoint.key, detail: "metadataが見つかりません"), endpoint, response, accountID)
        }
        let data = Data(jsonText.utf8)
        if let json = try? JSONValue.parse(data) {
            // Wrapped as { body: metadata } so every endpoint shares the "body" path convention.
            let wrapped: JSONValue = ["body": Self.redactingSecrets(json)]
            observe(endpoint.key, data: (try? wrapped.encoded()) ?? Data(), known: FanboxMetadataDTO.knownSchema(at: "body"))
        }
        let metadata: FanboxMetadataDTO
        do {
            metadata = try JSONDecoder().decode(FanboxMetadataDTO.self, from: data)
        } catch {
            throw reportFailure(.decoding(endpoint: endpoint.key, detail: FanboxResponseHandling.describe(error)), endpoint, response, accountID)
        }
        // The token is bound to the session that fetched the page: keep the account's stored token current.
        if let token = metadata.csrfToken, let accountID, let credentials {
            await credentials.updateCSRFToken(token, for: accountID)
        }
        return metadata
    }

    /// Re-reads the CSRF token from www.fanbox.cc metadata. When `credentials` is wired the token is stored for the
    /// account (the transport adds it as `X-CSRF-Token`). Returns the token so a caller without a wired store can save it.
    @discardableResult
    func refreshCSRFToken(accountID: String) async throws -> String? {
        try await fetchMetadata(accountID: accountID).csrfToken
    }

    /// Current CSRF token for the account (from the credential store, refreshed from metadata when missing).
    func csrfToken(accountID: String) async throws -> String? {
        if let credentials, let token = await credentials.credential(for: accountID)?.csrfToken, !token.isEmpty {
            return token
        }
        return try await refreshCSRFToken(accountID: accountID)
    }

    // MARK: - Execution

    func execute(_ endpoint: FanboxEndpoint, accountID: String?, allowCSRFRetry: Bool = true) async throws -> HTTPResponse {
        if endpoint.requiresCSRF, let accountID, let credentials,
           let credential = await credentials.credential(for: accountID), (credential.csrfToken ?? "").isEmpty {
            // Token never captured: fetch it before the write (the write would be rejected otherwise).
            _ = try? await refreshCSRFToken(accountID: accountID)
        }
        let request = try makeRequest(endpoint)
        do {
            let response: HTTPResponse
            do {
                response = try await http.send(request, accountID: accountID)
            } catch {
                throw Self.normalize(error)
            }
            try validate(response, endpoint: endpoint)
            return response
        } catch let error as RemoteError {
            guard allowCSRFRetry, endpoint.requiresCSRF, let accountID, let credentials, Self.mayBeStaleCSRF(error) else { throw error }
            let previous = await credentials.credential(for: accountID)?.csrfToken
            guard let fresh = try? await refreshCSRFToken(accountID: accountID), fresh != previous else { throw error }
            AppLog.network.info("retrying \(endpoint.key, privacy: .public) once after CSRF refresh")
            return try await execute(endpoint, accountID: accountID, allowCSRFRetry: false)
        }
    }

    /// Throws the mapped `RemoteError` for non-2xx responses: a CDN edge block (`.edgeBlocked`) is told apart from a
    /// FANBOX JSON refusal before the status is mapped (docs/API.md §1.6).
    func validate(_ response: HTTPResponse, endpoint: FanboxEndpoint) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        var errorCode: String?
        if let json = try? JSONValue.parse(response.data) { errorCode = json["error"]?.stringValue }
        let error = FanboxResponseHandling.map(statusCode: response.statusCode, headers: response.headers, errorCode: errorCode,
                                               body: response.data)
        var edge = false
        if case .edgeBlocked = error { edge = true }
        AppLog.network.notice("\(endpoint.key, privacy: .public) failed: HTTP \(response.statusCode)\(edge ? " (edge block)" : "", privacy: .public)")
        throw error
    }

    func decode<Body: FanboxResponseBody>(_ response: HTTPResponse, endpoint: FanboxEndpoint, as type: Body.Type) throws -> Body {
        // Observe BEFORE decoding: a schema change that breaks decoding is exactly what the inspector should record.
        observe(endpoint.key, data: response.data, known: Body.responseSchema)
        return try FanboxResponseHandling.decodeBody(Body.self, from: response.data, endpointKey: endpoint.key, statusCode: response.statusCode)
    }

    /// Records a 2xx response the client could not use as a research event, then returns the error to throw.
    private func reportFailure(_ error: RemoteError, _ endpoint: FanboxEndpoint, _ response: HTTPResponse, _ accountID: String?) -> RemoteError {
        inspector.recordFailure(endpointKey: endpoint.key, accountID: accountID, statusCode: response.statusCode, error: error)
        return error
    }

    private func observe(_ key: String, data: Data, known: [String: Set<String>]) {
        guard !data.isEmpty else { return }
        inspector.observe(endpointKey: key, rawJSON: data, known: known)
        schemaObserver?(key, data, known)
    }

    // MARK: - Helpers

    static func normalize(_ error: Error) -> RemoteError {
        if let remote = error as? RemoteError { return remote }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: return .offline
            default: return .network(code: urlError.code.rawValue, detail: "URLError \(urlError.code.rawValue)")
            }
        }
        return .network(code: -1, detail: String(describing: type(of: error)))
    }

    static func mayBeStaleCSRF(_ error: RemoteError) -> Bool {
        switch error {
        case .forbidden, .invalidRequest: return true
        default: return false
        }
    }

    /// Copy of metadata JSON with `csrfToken` (and any other token-like values) replaced.
    static func redactingSecrets(_ json: JSONValue) -> JSONValue {
        switch json {
        case .object(let dict):
            var out: [String: JSONValue] = [:]
            for (key, value) in dict {
                let lower = key.lowercased()
                if lower.contains("csrf") || lower.contains("token") || lower.contains("sessid") || lower.contains("password") {
                    out[key] = .string("<REDACTED>")
                } else {
                    out[key] = redactingSecrets(value)
                }
            }
            return .object(out)
        case .array(let items):
            return .array(items.map(redactingSecrets))
        default:
            return json
        }
    }
}

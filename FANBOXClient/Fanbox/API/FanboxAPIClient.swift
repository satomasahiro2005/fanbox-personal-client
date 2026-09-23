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
        return try decode(response, endpoint: endpoint, as: Body.self)
    }

    /// Write call whose response content is undocumented; returns the `body` JSON if any.
    @discardableResult
    func perform(_ endpoint: FanboxEndpoint, accountID: String?) async throws -> JSONValue? {
        let response = try await execute(endpoint, accountID: accountID)
        guard !response.data.isEmpty, let json = try? JSONValue.parse(response.data) else { return nil }
        if let code = json["error"]?.stringValue, json["body"] == nil {
            throw FanboxResponseHandling.mapErrorCode(code, statusCode: response.statusCode)
        }
        observe(endpoint.key, data: response.data, known: [:])
        return json["body"]
    }

    /// Sends a multipart form and returns the raw response. Used by post.update and any future media upload endpoint.
    ///
    /// A form of plain fields (post.update: title, text, and the CSRF token in `tt`) is encoded IN MEMORY and sent with
    /// `send`: the token never touches the disk (SPEC §39 "CSRF Token: Keychain または Memory"). Only forms with file
    /// parts are streamed from a temporary file, created with complete file protection and removed afterwards (stale
    /// ones are purged at launch, `MultipartFormData.removeStaleTemporaryFiles`).
    func sendMultipart(_ endpoint: FanboxEndpoint, form: MultipartFormData, accountID: String?,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> HTTPResponse {
        var request = try makeRequest(endpoint)
        request.headers["Content-Type"] = form.contentType
        request.timeout = Self.uploadTimeout
        let response: HTTPResponse
        if !form.hasFileParts {
            request.body = try form.encodedData()
            do {
                response = try await http.send(request, accountID: accountID)
            } catch {
                throw Self.normalize(error)
            }
            progress?(1)
        } else {
            let fileURL = try form.writeToTemporaryFile()
            defer { try? FileManager.default.removeItem(at: fileURL) }
            request.body = nil
            do {
                response = try await http.upload(request, bodyFileURL: fileURL, accountID: accountID, progress: progress)
            } catch {
                throw Self.normalize(error)
            }
        }
        try validate(response, endpoint: endpoint)
        if let json = try? JSONValue.parse(response.data), json["body"] != nil {
            observe(endpoint.key, data: response.data, known: [:])
        }
        return response
    }

    // MARK: - Session metadata / CSRF (www.fanbox.cc)

    /// Fetches the www.fanbox.cc page metadata (logged-in user summary + CSRF token). The token is a secret: it is redacted
    /// before the API Inspector sees the JSON and is never logged.
    func fetchMetadata(accountID: String?) async throws -> FanboxMetadataDTO {
        let endpoint = FanboxEndpoint.homepageMetadata()
        let response = try await execute(endpoint, accountID: accountID, allowCSRFRetry: false)
        guard let html = String(data: response.data, encoding: .utf8) ?? String(data: response.data, encoding: .isoLatin1) else {
            throw RemoteError.decoding(endpoint: endpoint.key, detail: "HTML を読めません")
        }
        guard let jsonText = FanboxMetadataParser.metadataJSON(fromHTML: html) else {
            // No metadata: a challenge page or an unexpected layout. Not proof of logout.
            throw RemoteError.decoding(endpoint: endpoint.key, detail: "metadata が見つかりません")
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
            throw RemoteError.decoding(endpoint: endpoint.key, detail: FanboxResponseHandling.describe(error))
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

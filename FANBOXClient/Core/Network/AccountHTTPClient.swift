import Foundation
import os

/// Per-account URLSession transport (SPEC §7.2 / §29 / §38). See `HTTPClient` for the contract.
///
/// - One ephemeral `URLSession` per account (lazily created, cached): no shared cookie storage, no URL cache,
///   cookies are attached manually from the account's `SessionCredential` and only for *.fanbox.cc (`FanboxHostPolicy`).
/// - Every request runs through `NetworkScheduler.run(priority, label: endpointKey)`; downloads / uploads are also
///   registered as pausable transfers so text-first requests can suspend them, and Offline cancels them (`.offline`).
/// - `send` / `upload` return non-2xx answers (the API client classifies them); `download` throws for them.
/// - `Set-Cookie` from responses (and redirects) is merged back into an EXISTING credential only. `invalidateSession`
///   (logout / removal) cancels the account's tasks and bumps a per-account epoch: a response that started before it is
///   dropped (`.cancelled`) without touching cookies, so nothing can resurrect a deleted credential.
/// - One redacted `ResearchEntry` is recorded per request; bodies only while Research Mode is on.
final class AccountHTTPClient: CredentialBackedHTTPClient, SessionRevoking, @unchecked Sendable {
    let credentials: CredentialStoring
    let scheduler: NetworkScheduler
    let recorder: ResearchRecorder

    /// Called (from any thread) when a response rotated the account's FANBOXSESSID, so the account's WebKit store can
    /// be updated too (the web view and the API must present the same session). Set once while wiring.
    var onSessionCookieChanged: (@Sendable (String) -> Void)? {
        get { callbacks.withLockUnchecked { $0 } }
        set { callbacks.withLockUnchecked { $0 = newValue } }
    }
    private let callbacks = OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(uncheckedState: nil)
    /// Per-account generation, bumped by `invalidateSession`.
    private let epochs = OSAllocatedUnfairLock(uncheckedState: [String: UInt64]())

    private struct SessionEntry {
        let session: URLSession
        let delegate: HTTPTransferDelegate
    }

    private let baseConfiguration: URLSessionConfiguration?
    private let sessions = OSAllocatedUnfairLock(uncheckedState: [String: SessionEntry]())
    /// Where finished downloads are moved before being handed to the caller.
    let downloadDirectory: URL

    private static let anonymousKey = "_anonymous"

    /// - Parameter configuration: base configuration (tests inject `protocolClasses`). Cookie / cache settings are
    ///   always overridden to keep accounts isolated.
    init(credentials: CredentialStoring, scheduler: NetworkScheduler, recorder: ResearchRecorder,
         configuration: URLSessionConfiguration? = nil, downloadDirectory: URL? = nil) {
        self.credentials = credentials
        self.scheduler = scheduler
        self.recorder = recorder
        self.baseConfiguration = configuration
        self.downloadDirectory = downloadDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("AccountHTTPClient-Downloads", isDirectory: true)
    }

    deinit {
        let all = sessions.withLockUnchecked { map -> [SessionEntry] in
            let values = Array(map.values)
            map.removeAll()
            return values
        }
        for entry in all { entry.session.finishTasksAndInvalidate() }
    }

    // MARK: - HTTPClient

    func send(_ request: HTTPRequest, accountID: String?) async throws -> HTTPResponse {
        try await scheduler.run(request.priority, label: request.endpointKey) { [self] in
            let (response, _) = try await self.perform(request, accountID: accountID, mode: .data, progress: nil)
            return response
        }
    }

    func download(_ request: HTTPRequest, accountID: String?, progress: (@Sendable (Double) -> Void)?) async throws -> (URL, HTTPResponse) {
        try await scheduler.run(request.priority, label: request.endpointKey) { [self] in
            let (response, file) = try await self.perform(request, accountID: accountID, mode: .download, progress: progress)
            guard let file else { throw RemoteError.network(code: URLError.cannotCreateFile.rawValue, detail: "download file missing") }
            return (file, response)
        }
    }

    func upload(_ request: HTTPRequest, bodyFileURL: URL, accountID: String?,
                progress: (@Sendable (Double) -> Void)?) async throws -> HTTPResponse {
        try await scheduler.run(request.priority, label: request.endpointKey) { [self] in
            let (response, _) = try await self.perform(request, accountID: accountID, mode: .upload(bodyFileURL), progress: progress)
            return response
        }
    }

    // MARK: - Session management

    /// Drops (and invalidates) the account's URLSession, e.g. after logout / account removal: in-flight tasks are
    /// cancelled and responses that were already on their way are discarded without merging cookies.
    func invalidateSession(accountID: String?) {
        let key = accountID ?? Self.anonymousKey
        epochs.withLockUnchecked { $0[key, default: 0] &+= 1 }
        let entry = sessions.withLockUnchecked { $0.removeValue(forKey: key) }
        entry?.session.invalidateAndCancel()
    }

    func revokeSession(accountID: String) async {
        invalidateSession(accountID: accountID)
    }

    private func epoch(for accountID: String?) -> UInt64 {
        epochs.withLockUnchecked { $0[accountID ?? Self.anonymousKey] ?? 0 }
    }

    /// Number of cached per-account sessions (tests / diagnostics).
    var sessionCount: Int { sessions.withLockUnchecked { $0.count } }

    /// The account's session (created on first use).
    func urlSession(for accountID: String?) -> URLSession { sessionEntry(for: accountID).session }

    private func sessionEntry(for accountID: String?) -> SessionEntry {
        let key = accountID ?? Self.anonymousKey
        return sessions.withLockUnchecked { map in
            if let existing = map[key] { return existing }
            let delegate = HTTPTransferDelegate()
            let session = URLSession(configuration: makeConfiguration(), delegate: delegate, delegateQueue: nil)
            session.sessionDescription = "account-session"
            let entry = SessionEntry(session: session, delegate: delegate)
            map[key] = entry
            return entry
        }
    }

    private func makeConfiguration() -> URLSessionConfiguration {
        let config = (baseConfiguration?.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 6
        return config
    }

    // MARK: - Request building

    /// Builds the URLRequest with caller headers + per-account session headers (see `FanboxRequestHeaders`).
    static func makeURLRequest(_ request: HTTPRequest, credential: SessionCredential?, includeBody: Bool = true) throws -> URLRequest {
        var r = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(1, request.timeout))
        r.httpMethod = request.method.uppercased()
        r.httpShouldHandleCookies = false
        if includeBody { r.httpBody = request.body }
        for (name, value) in request.headers where !FanboxRequestHeaders.controlledHeaders.contains(name.lowercased()) {
            r.setValue(value, forHTTPHeaderField: name)
        }
        try FanboxRequestHeaders.apply(to: &r, credential: credential, requiresCSRF: request.requiresCSRF,
                                       callerHeaders: request.headers, isMedia: isMediaRequest(request))
        return r
    }

    static func isMediaRequest(_ request: HTTPRequest) -> Bool { request.endpointKey.hasPrefix("media.") }

    /// URLSession task priority: large media (originals / attachments) below thumbnails and display images (SPEC §46).
    static func taskPriority(for request: HTTPRequest) -> Float {
        if MediaSizeClass.of(label: request.endpointKey, priority: request.priority) == .large {
            return min(request.priority.urlSessionTaskPriority, 0.3)
        }
        return request.priority.urlSessionTaskPriority
    }

    /// Cookies from a response's Set-Cookie header(s).
    static func cookies(from response: HTTPURLResponse, url: URL) -> [StoredCookie] {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            let name = String(describing: key)
            let v = String(describing: value)
            if name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
                fields["Set-Cookie"] = fields["Set-Cookie"].map { $0 + ", " + v } ?? v
            }
        }
        guard !fields.isEmpty else { return [] }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).map(StoredCookie.init)
    }

    static func headerDictionary(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            result[String(describing: key)] = String(describing: value)
        }
        return result
    }

    // MARK: - Transfer

    private enum Mode {
        case data
        case download
        case upload(URL)

        var isTransfer: Bool {
            if case .data = self { return false }
            return true
        }
    }

    private func perform(_ request: HTTPRequest, accountID: String?, mode: Mode,
                         progress: (@Sendable (Double) -> Void)?) async throws -> (HTTPResponse, URL?) {
        let started = Date()
        let startEpoch = epoch(for: accountID)
        let credential: SessionCredential?
        if let accountID { credential = await credentials.credential(for: accountID) } else { credential = nil }

        let urlRequest: URLRequest
        do {
            var includeBody = true
            if case .upload = mode { includeBody = false }
            urlRequest = try Self.makeURLRequest(request, credential: credential, includeBody: includeBody)
        } catch {
            let mapped = HTTPErrorMapper.map(error)
            recordEntry(request: request, urlRequest: nil, accountID: accountID, started: started, response: nil, data: nil,
                        bytes: nil, error: mapped)
            throw mapped
        }

        let entry = sessionEntry(for: accountID)
        let task: URLSessionTask
        switch mode {
        case .data: task = entry.session.dataTask(with: urlRequest)
        case .download: task = entry.session.downloadTask(with: urlRequest)
        case .upload(let file): task = entry.session.uploadTask(with: urlRequest, fromFile: file)
        }
        task.priority = Self.taskPriority(for: request)

        let handler = HTTPTransferHandler(credential: credential, requiresCSRF: request.requiresCSRF, callerHeaders: request.headers,
                                          progress: progress, downloadDirectory: mode.isTransfer ? downloadDirectory : nil,
                                          isMedia: Self.isMediaRequest(request))
        entry.delegate.add(handler, for: task)

        let outcome: HTTPTransferOutcome
        do {
            outcome = try await withTaskCancellationHandler {
                task.resume()
                var token: TransferToken?
                if mode.isTransfer { token = await scheduler.register(task: task, priority: request.priority) }
                do {
                    let result = try await handler.wait()
                    if let token { await scheduler.unregister(token) }
                    return result
                } catch {
                    if let token { await scheduler.unregister(token) }
                    throw error
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            var mapped = HTTPErrorMapper.map(error)
            if mapped == .cancelled, !scheduler.policy.current.allowsNetwork {
                // Cancelled because the app switched to Offline (not by the caller): report it as such (SPEC §30).
                mapped = .offline
            }
            recordEntry(request: request, urlRequest: urlRequest, accountID: accountID, started: started, response: nil, data: nil,
                        bytes: nil, error: mapped)
            throw mapped
        }

        if epoch(for: accountID) != startEpoch {
            // The account logged out / was removed while this request was in flight: drop the answer untouched.
            if let file = outcome.fileURL { try? FileManager.default.removeItem(at: file) }
            recordEntry(request: request, urlRequest: urlRequest, accountID: accountID, started: started, response: nil, data: nil,
                        bytes: nil, error: .cancelled)
            throw RemoteError.cancelled
        }

        guard let http = outcome.response as? HTTPURLResponse else {
            if let file = outcome.fileURL { try? FileManager.default.removeItem(at: file) }
            let mapped = RemoteError.network(code: URLError.badServerResponse.rawValue, detail: "non-HTTP response")
            recordEntry(request: request, urlRequest: urlRequest, accountID: accountID, started: started, response: nil, data: nil,
                        bytes: Int(outcome.bytesReceived), error: mapped)
            throw mapped
        }

        let headers = Self.headerDictionary(http)
        await mergeCookies(outcome: outcome, response: http, fallbackURL: request.url, accountID: accountID,
                           sentSession: credential?.sessionCookieValue)

        let duration = Date().timeIntervalSince(started)
        let isFileBody = mode.isTransfer && outcome.fileURL != nil
        let statusError = HTTPErrorMapper.error(status: http.statusCode, headers: headers, body: isFileBody ? nil : outcome.data)
        recordEntry(request: request, urlRequest: urlRequest, accountID: accountID, started: started, response: http,
                    data: isFileBody ? nil : outcome.data, bytes: Int(outcome.bytesReceived), error: statusError)
        if let statusError {
            AppLog.network.info("\(request.endpointKey, privacy: .public) → HTTP \(http.statusCode)")
            if case .download = mode {
                if let file = outcome.fileURL { try? FileManager.default.removeItem(at: file) }
                throw statusError
            }
        }
        let response = HTTPResponse(statusCode: http.statusCode, headers: headers, data: outcome.data, url: http.url,
                                    duration: duration)
        return (response, outcome.fileURL)
    }

    private func mergeCookies(outcome: HTTPTransferOutcome, response: HTTPURLResponse, fallbackURL: URL, accountID: String?,
                              sentSession: String?) async {
        guard let accountID else { return }
        var cookies = outcome.redirectCookies
        let url = response.url ?? fallbackURL
        if FanboxHostPolicy.isCookieEligible(url: url) {
            cookies.append(contentsOf: Self.cookies(from: response, url: url))
        }
        guard !cookies.isEmpty else { return }
        await credentials.mergeCookies(cookies, for: accountID)
        let rotated = cookies.contains {
            $0.name == SessionCredential.sessionCookieName && !$0.value.isEmpty && $0.value != sentSession
                && FanboxHostPolicy.isFanboxHost($0.normalizedDomain)
        }
        if rotated, let callback = onSessionCookieChanged { callback(accountID) }
    }

    // MARK: - Research

    private func recordEntry(request: HTTPRequest, urlRequest: URLRequest?, accountID: String?, started: Date,
                             response: HTTPURLResponse?, data: Data?, bytes: Int?, error: RemoteError?) {
        let captureBodies = recorder.capturesBodies
        var requestHeaders = "# transport: \(TransportKind.native.rawValue)\n"
            + SecretRedactor.formatHeaders(urlRequest?.allHTTPHeaderFields ?? request.headers)
        if captureBodies, let body = request.body, !body.isEmpty {
            let type = urlRequest?.value(forHTTPHeaderField: "Content-Type") ?? request.headers["Content-Type"]
            requestHeaders += "\n\n[request body]\n" + SecretRedactor.redactBody(body, contentType: type, limit: 16_000)
        }
        var responseBody = ""
        if captureBodies, let data, !data.isEmpty {
            responseBody = SecretRedactor.redactBody(data, contentType: response?.value(forHTTPHeaderField: "Content-Type"))
        }
        let entry = ResearchEntry(
            timestamp: started,
            kind: .request,
            accountID: accountID,
            method: request.method.uppercased(),
            endpoint: SecretRedactor.redactURL(response?.url ?? request.url),
            statusCode: response?.statusCode,
            durationMs: Int((Date().timeIntervalSince(started) * 1000).rounded()),
            priority: request.priority,
            requestHeaders: requestHeaders,
            responseHeaders: response.map { SecretRedactor.formatHeaders(Self.headerDictionary($0)) } ?? "",
            responseBody: responseBody,
            bytes: bytes,
            errorDescription: error.map { "\(request.endpointKey): \(Self.describe($0))" }
        )
        recorder.record(entry)
    }

    static func describe(_ error: RemoteError) -> String {
        switch error {
        case .offline: return "offline"
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .notFound: return "notFound"
        case .rateLimited(let retryAfter): return "rateLimited(retryAfter: \(retryAfter.map { String(Int($0)) } ?? "-"))"
        case .edgeBlocked(let retryAfter): return "edgeBlocked(retryAfter: \(retryAfter.map { String(Int($0)) } ?? "-"))"
        case .csrfUnavailable: return "csrfUnavailable"
        case .server(let status): return "server(\(status))"
        case .decoding(let endpoint, let detail): return "decoding(\(endpoint)): \(SecretRedactor.redact(detail))"
        case .network(let code, let detail): return "network(\(code)): \(SecretRedactor.redact(detail))"
        case .unsupported(let operation): return "unsupported(\(operation))"
        case .blockedByPolicy: return "blockedByPolicy"
        case .cancelled: return "cancelled"
        case .invalidRequest(let detail): return "invalidRequest: \(SecretRedactor.redact(detail))"
        }
    }
}

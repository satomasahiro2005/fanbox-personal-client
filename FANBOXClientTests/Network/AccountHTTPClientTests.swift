import XCTest
import SwiftData
@testable import FANBOXClient

/// URLProtocol stub injected through `URLSessionConfiguration.protocolClasses`.
final class NetModStubProtocol: URLProtocol {
    struct Stub {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data(#"{"body":{}}"#.utf8)
        /// Never answers (until cancelled).
        var hang = false
    }

    private static let lock = NSLock()
    private static var _handler: ((URLRequest) -> Stub)?
    private static var _requests: [URLRequest] = []
    private static var _streamedBodies: [String: Data] = [:]

    static func install(_ handler: @escaping (URLRequest) -> Stub) {
        lock.lock()
        _handler = handler
        _requests = []
        _streamedBodies = [:]
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        _handler = nil
        _requests = []
        _streamedBodies = [:]
        lock.unlock()
    }

    /// Bodies that reached the protocol as a stream (`uploadTask(withStreamedRequest:)`), read to the end, by URL path.
    static func streamedBody(path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return _streamedBodies[path]
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var streamed: Data?
        if let stream = request.httpBodyStream {
            // Read synchronously: the producer writes the other end of the bound pair on its own thread.
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            stream.open()
            while true {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            streamed = data
        }
        Self.lock.lock()
        if let streamed, let path = request.url?.path { Self._streamedBodies[path] = streamed }
        Self._requests.append(request)
        let handler = Self._handler
        Self.lock.unlock()
        let stub = handler?(request) ?? Stub()
        if stub.hang { return }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty { client?.urlProtocol(self, didLoad: stub.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class AccountHTTPClientTests: XCTestCase {
    private var store: LocalStore!
    private var settings: AppSettings!
    private var recorder: ResearchRecorder!
    private var credentials: InMemoryCredentialStore!
    private var policy: NetworkPolicyStore!
    private var scheduler: NetworkScheduler!
    private var client: AccountHTTPClient!
    private var downloadDir: URL!

    private let sessionValue = "12345_TOPSECRETSESSION"
    private let csrfValue = "csrf-TOPSECRET-token"

    override func setUp() async throws {
        try await super.setUp()
        let container = try PersistenceController.makeContainer(inMemory: true)
        store = LocalStore(container: container)
        settings = AppSettings(defaults: UserDefaults(suiteName: "nettest-\(UUID().uuidString)")!)
        settings.researchModeEnabled = true
        recorder = ResearchRecorder()
        recorder.attach(store: store, settings: settings)
        credentials = InMemoryCredentialStore()
        try await credentials.save(SessionCredential(cookies: [
            StoredCookie(name: "FANBOXSESSID", value: sessionValue, domain: ".fanbox.cc"),
            StoredCookie(name: "PHPSESSID", value: "pixiv-session", domain: ".pixiv.net"),
        ], userAgent: "TestUA/1.0", csrfToken: csrfValue), for: "A")
        try await credentials.save(SessionCredential(cookies: [
            StoredCookie(name: "FANBOXSESSID", value: "B_session", domain: ".fanbox.cc"),
        ]), for: "B")
        policy = NetworkPolicyStore()
        scheduler = NetworkScheduler(policy: policy)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NetModStubProtocol.self]
        downloadDir = FileManager.default.temporaryDirectory.appendingPathComponent("nettest-\(UUID().uuidString)")
        client = AccountHTTPClient(credentials: credentials, scheduler: scheduler, recorder: recorder, configuration: config,
                                   downloadDirectory: downloadDir)
        NetModStubProtocol.install { _ in .init() }
    }

    override func tearDown() async throws {
        NetModStubProtocol.reset()
        if let downloadDir { try? FileManager.default.removeItem(at: downloadDir) }
        client = nil
        try await super.tearDown()
    }

    private func header(_ name: String, _ request: URLRequest?) -> String? { request?.value(forHTTPHeaderField: name) }

    // MARK: Headers

    func testFanboxAPIRequestGetsSessionHeaders() async throws {
        let request = HTTPRequest(url: URL(string: "https://api.fanbox.cc/post.info?postId=1")!, priority: .interactiveRead,
                                  endpointKey: "post.info")
        let response = try await client.send(request, accountID: "A")
        XCTAssertEqual(response.statusCode, 200)
        let sent = NetModStubProtocol.requests.last
        XCTAssertEqual(header("Cookie", sent), "FANBOXSESSID=\(sessionValue)")
        XCTAssertEqual(header("Accept", sent), "application/json")
        XCTAssertEqual(header("Origin", sent), "https://www.fanbox.cc")
        XCTAssertEqual(header("Referer", sent), "https://www.fanbox.cc/")
        XCTAssertEqual(header("User-Agent", sent), "TestUA/1.0")
        XCTAssertNil(header("X-CSRF-Token", sent))
    }

    func testCookiesNeverSentToOtherHosts() async throws {
        var request = HTTPRequest(url: URL(string: "https://example.com/image.png")!, priority: .foregroundMedia, endpointKey: "external")
        request.headers["Cookie"] = "FANBOXSESSID=smuggled"
        _ = try await client.send(request, accountID: "A")
        let sent = NetModStubProtocol.requests.last
        XCTAssertNil(header("Cookie", sent))
        XCTAssertNil(header("Origin", sent))
        XCTAssertNil(header("Referer", sent))
        XCTAssertNil(header("Accept", sent))
        XCTAssertEqual(header("User-Agent", sent), "TestUA/1.0")

        // Look-alike domain is not a FANBOX host.
        _ = try await client.send(HTTPRequest(url: URL(string: "https://evilfanbox.cc/x")!, priority: .interactiveRead, endpointKey: "x"),
                                  accountID: "A")
        XCTAssertNil(header("Cookie", NetModStubProtocol.requests.last))

        // Updated for the transport fix (docs/API.md §1.3): pixiv.net cookies stay in the credential (for re-installing
        // into the web store) but the native transport never sends them; pximg gets a Referer only.
        _ = try await client.send(HTTPRequest(url: URL(string: "https://www.pixiv.net/ajax/x")!, priority: .interactiveRead,
                                              endpointKey: "pixiv"), accountID: "A")
        XCTAssertNil(header("Cookie", NetModStubProtocol.requests.last))
        _ = try await client.send(HTTPRequest(url: URL(string: "https://pixiv.pximg.net/c/1.jpg")!, priority: .foregroundMedia,
                                              endpointKey: "img"), accountID: "A")
        XCTAssertEqual(header("Referer", NetModStubProtocol.requests.last), "https://www.fanbox.cc/")
        XCTAssertNil(header("Cookie", NetModStubProtocol.requests.last))
    }

    func testDefaultUserAgentAndAnonymousRequests() async throws {
        _ = try await client.send(HTTPRequest(url: URL(string: "https://api.fanbox.cc/x")!, priority: .interactiveRead, endpointKey: "x"),
                                  accountID: "B")
        XCTAssertEqual(header("User-Agent", NetModStubProtocol.requests.last), FanboxHostPolicy.defaultUserAgent)
        XCTAssertEqual(header("Cookie", NetModStubProtocol.requests.last), "FANBOXSESSID=B_session")

        _ = try await client.send(HTTPRequest(url: URL(string: "https://api.fanbox.cc/x")!, priority: .interactiveRead, endpointKey: "x"),
                                  accountID: nil)
        XCTAssertNil(header("Cookie", NetModStubProtocol.requests.last))
    }

    func testCSRFTokenAddedWhenRequiredAndMissingTokenThrows() async throws {
        var post = HTTPRequest(method: "POST", url: URL(string: "https://api.fanbox.cc/post.likePost")!,
                               headers: ["Content-Type": "application/json"], body: Data(#"{"postId":"1"}"#.utf8),
                               priority: .interactiveWrite, endpointKey: "post.likePost", requiresCSRF: true)
        _ = try await client.send(post, accountID: "A")
        let sent = NetModStubProtocol.requests.last
        XCTAssertEqual(sent?.httpMethod, "POST")
        XCTAssertEqual(header("X-CSRF-Token", sent), csrfValue)

        let before = NetModStubProtocol.requests.count
        do {
            _ = try await client.send(post, accountID: "B")
            XCTFail("expected csrfUnavailable")
        } catch {
            // Updated for the transport fix: a missing token is transient and says nothing about the session.
            XCTAssertEqual(error as? RemoteError, .csrfUnavailable)
        }
        XCTAssertEqual(NetModStubProtocol.requests.count, before, "nothing sent without a CSRF token")

        post.url = URL(string: "https://example.com/post")!
        do {
            _ = try await client.send(post, accountID: "A")
            XCTFail("expected invalidRequest")
        } catch {
            guard case .invalidRequest = error as? RemoteError else { return XCTFail("\(error)") }
        }
    }

    // MARK: Status mapping

    /// Updated for the transport fix: `send` RETURNS non-2xx answers (status, headers and body reach
    /// `FanboxAPIClient.validate`, which tells FANBOX refusals from edge blocks); the mapping table is `HTTPErrorMapper`.
    func testStatusMapping() async throws {
        NetModStubProtocol.install { request in
            let code = Int(request.url?.lastPathComponent ?? "") ?? 200
            var stub = NetModStubProtocol.Stub(status: code)
            if code == 429 { stub.headers["Retry-After"] = "12" }
            return stub
        }
        for code in [204, 401, 403, 404, 429, 500, 503, 418] {
            let r = HTTPRequest(url: URL(string: "https://api.fanbox.cc/status/\(code)")!, priority: .interactiveRead, endpointKey: "status")
            let response = try await client.send(r, accountID: "A")
            XCTAssertEqual(response.statusCode, code)
        }
        let json = ["Content-Type": "application/json"]
        XCTAssertNil(HTTPErrorMapper.error(status: 204, headers: json))
        XCTAssertEqual(HTTPErrorMapper.error(status: 401, headers: json), .unauthorized)
        XCTAssertEqual(HTTPErrorMapper.error(status: 403, headers: json, body: Data(#"{"error":"x"}"#.utf8)), .forbidden)
        XCTAssertEqual(HTTPErrorMapper.error(status: 404, headers: json), .notFound)
        XCTAssertEqual(HTTPErrorMapper.error(status: 429, headers: ["Retry-After": "12"]), .rateLimited(retryAfter: 12))
        XCTAssertEqual(HTTPErrorMapper.error(status: 500, headers: json), .server(status: 500))
        XCTAssertEqual(HTTPErrorMapper.error(status: 503, headers: json), .server(status: 503))
        XCTAssertEqual(HTTPErrorMapper.error(status: 418, headers: json), .server(status: 418))
        XCTAssertEqual(HTTPErrorMapper.error(status: 403, headers: ["Content-Type": "text/html", "Server": "cloudflare"],
                                             body: Data("<html>Just a moment...</html>".utf8)), .edgeBlocked(retryAfter: nil))
    }

    func testURLErrorMapping() {
        XCTAssertEqual(HTTPErrorMapper.map(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(HTTPErrorMapper.map(URLError(.networkConnectionLost)), .offline)
        XCTAssertEqual(HTTPErrorMapper.map(URLError(.dataNotAllowed)), .offline)
        XCTAssertEqual(HTTPErrorMapper.map(URLError(.internationalRoamingOff)), .offline)
        XCTAssertEqual(HTTPErrorMapper.map(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(HTTPErrorMapper.map(CancellationError()), .cancelled)
        guard case .network(let code, _) = HTTPErrorMapper.map(URLError(.timedOut)) else { return XCTFail() }
        XCTAssertEqual(code, URLError.Code.timedOut.rawValue)
        XCTAssertEqual(HTTPErrorMapper.retryAfter("30"), 30)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(HTTPErrorMapper.retryAfter("Tue, 14 Nov 2023 22:14:20 GMT", now: now), 60)
        XCTAssertNil(HTTPErrorMapper.retryAfter("soon"))
    }

    // MARK: Cookies

    func testSetCookieMergedIntoCredentialOnlyForSessionHosts() async throws {
        NetModStubProtocol.install { request in
            var stub = NetModStubProtocol.Stub()
            stub.headers["Set-Cookie"] = request.url?.host == "example.com"
                ? "FANBOXSESSID=evil; Domain=.fanbox.cc; Path=/"
                : "FANBOXSESSID=rotated_999; Domain=.fanbox.cc; Path=/; Secure; HttpOnly"
            return stub
        }
        _ = try await client.send(HTTPRequest(url: URL(string: "https://example.com/x")!, priority: .interactiveRead, endpointKey: "x"),
                                  accountID: "A")
        var credential = await credentials.credential(for: "A")
        XCTAssertEqual(credential?.cookieHeader(for: "api.fanbox.cc"), "FANBOXSESSID=\(sessionValue)")

        _ = try await client.send(HTTPRequest(url: URL(string: "https://api.fanbox.cc/x")!, priority: .interactiveRead, endpointKey: "x"),
                                  accountID: "A")
        credential = await credentials.credential(for: "A")
        XCTAssertEqual(credential?.cookies.filter { $0.name == "FANBOXSESSID" }.map(\.value), ["rotated_999"])
        // Account B untouched.
        let b = await credentials.credential(for: "B")
        XCTAssertEqual(b?.cookieHeader(for: "api.fanbox.cc"), "FANBOXSESSID=B_session")
    }

    func testRedirectRecomputesSessionHeaders() throws {
        let delegate = HTTPTransferDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://www.fanbox.cc/start")!)
        let credential = SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "s", domain: ".fanbox.cc")], csrfToken: "c")
        delegate.add(HTTPTransferHandler(credential: credential, requiresCSRF: true, callerHeaders: [:], progress: nil,
                                         downloadDirectory: nil), for: task)
        let redirect = HTTPURLResponse(url: URL(string: "https://www.fanbox.cc/start")!, statusCode: 302, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": "https://example.com/landing",
                                                      "Set-Cookie": "rot=1; Domain=.fanbox.cc; Path=/"])!

        var offHost = URLRequest(url: URL(string: "https://example.com/landing")!)
        offHost.setValue("FANBOXSESSID=s", forHTTPHeaderField: "Cookie")
        offHost.setValue("c", forHTTPHeaderField: "X-CSRF-Token")
        offHost.setValue("https://www.fanbox.cc", forHTTPHeaderField: "Origin")
        var result: URLRequest?
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: offHost) { result = $0 }
        XCTAssertNotNil(result)
        XCTAssertNil(result?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(result?.value(forHTTPHeaderField: "X-CSRF-Token"))
        XCTAssertNil(result?.value(forHTTPHeaderField: "Origin"))

        result = nil
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                            newRequest: URLRequest(url: URL(string: "https://api.fanbox.cc/next")!)) { result = $0 }
        let cookie = result?.value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertTrue(cookie.contains("FANBOXSESSID=s"))
        XCTAssertTrue(cookie.contains("rot=1"), "cookie from the redirect response is used for the next hop")
        XCTAssertEqual(result?.value(forHTTPHeaderField: "X-CSRF-Token"), "c")
        task.cancel()
    }

    // MARK: Research

    func testResearchEntriesAreRedacted() async throws {
        NetModStubProtocol.install { _ in
            NetModStubProtocol.Stub(status: 200, headers: ["Content-Type": "application/json",
                                                           "Set-Cookie": "FANBOXSESSID=rotated_SECRET; Domain=.fanbox.cc; Path=/"],
                                    body: Data(#"{"body":{"csrfToken":"body-SECRET","title":"ok"}}"#.utf8))
        }
        let request = HTTPRequest(method: "POST", url: URL(string: "https://api.fanbox.cc/post.info?postId=7&token=url-SECRET")!,
                                  headers: ["Content-Type": "application/json"], body: Data(#"{"password":"pw-SECRET"}"#.utf8),
                                  priority: .interactiveWrite, endpointKey: "post.info", requiresCSRF: true)
        _ = try await client.send(request, accountID: "A")
        recorder.flush()

        let rows = store.fetch(FetchDescriptor<ResearchLog>())
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.kind, .request)
        XCTAssertEqual(row.method, "POST")
        XCTAssertEqual(row.statusCode, 200)
        XCTAssertEqual(row.priorityRaw, RequestPriority.interactiveWrite.rawValue)
        XCTAssertEqual(row.accountID, "A")
        XCTAssertNotNil(row.durationMs)
        XCTAssertEqual(row.endpoint, "https://api.fanbox.cc/post.info?postId=7&token=<REDACTED>")
        XCTAssertTrue(row.requestHeaders.contains("Cookie: <REDACTED>"), row.requestHeaders)
        XCTAssertTrue(row.requestHeaders.contains("X-CSRF-Token: <REDACTED>"), row.requestHeaders)
        XCTAssertTrue(row.responseHeaders.contains("Set-Cookie: <REDACTED>"), row.responseHeaders)
        XCTAssertTrue(row.responseBody.contains("\"title\" : \"ok\""), row.responseBody)
        let all = [row.endpoint, row.requestHeaders, row.responseHeaders, row.responseBody, row.errorDescription ?? ""].joined()
        for secret in [sessionValue, csrfValue, "url-SECRET", "pw-SECRET", "body-SECRET", "rotated_SECRET"] {
            XCTAssertFalse(all.contains(secret), "leaked \(secret)")
        }
    }

    func testResearchBodiesOnlyInResearchMode() async throws {
        settings.researchModeEnabled = false
        await netModWaitUntil { !self.recorder.capturesBodies }
        _ = try await client.send(HTTPRequest(url: URL(string: "https://api.fanbox.cc/x")!, priority: .interactiveRead, endpointKey: "x"),
                                  accountID: "A")
        recorder.flush()
        let row = try XCTUnwrap(store.fetch(FetchDescriptor<ResearchLog>()).first)
        XCTAssertEqual(row.responseBody, "")
        XCTAssertEqual(row.statusCode, 200)
    }

    func testFailedRequestIsRecordedWithError() async throws {
        NetModStubProtocol.install { _ in NetModStubProtocol.Stub(status: 403) }
        do {
            _ = try await client.send(HTTPRequest(url: URL(string: "https://api.fanbox.cc/plan.listSupporting")!, priority: .backgroundSync,
                                                  endpointKey: "plan.listSupporting"), accountID: "A")
        } catch {}
        recorder.flush()
        let row = try XCTUnwrap(store.fetch(FetchDescriptor<ResearchLog>()).first)
        XCTAssertEqual(row.statusCode, 403)
        XCTAssertEqual(row.errorDescription, "plan.listSupporting: forbidden")
    }

    // MARK: Scheduler / sessions / transfers

    func testOfflineFailsWithoutTouchingNetwork() async {
        policy.update { $0.mode = .offline }
        do {
            _ = try await client.send(HTTPRequest(url: URL(string: "https://api.fanbox.cc/x")!, priority: .interactiveWrite, endpointKey: "x"),
                                      accountID: "A")
            XCTFail("expected offline")
        } catch {
            XCTAssertEqual(error as? RemoteError, .offline)
        }
        XCTAssertTrue(NetModStubProtocol.requests.isEmpty)
    }

    func testOneIsolatedSessionPerAccount() async throws {
        for account in ["A", "B", nil] as [String?] {
            _ = try await client.send(HTTPRequest(url: URL(string: "https://api.fanbox.cc/x")!, priority: .interactiveRead, endpointKey: "x"),
                                      accountID: account)
        }
        XCTAssertEqual(client.sessionCount, 3)
        let a = client.urlSession(for: "A")
        XCTAssertTrue(a === client.urlSession(for: "A"), "sessions are cached")
        XCTAssertFalse(a === client.urlSession(for: "B"))
        XCTAssertNil(a.configuration.httpCookieStorage)
        XCTAssertFalse(a.configuration.httpShouldSetCookies)
        XCTAssertNil(a.configuration.urlCache)
        XCTAssertEqual(a.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        client.invalidateSession(accountID: "B")
        XCTAssertEqual(client.sessionCount, 2)
    }

    func testDownloadMovesFileAndReportsProgress() async throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 256) })
        NetModStubProtocol.install { _ in
            NetModStubProtocol.Stub(status: 200, headers: ["Content-Type": "image/jpeg", "Content-Length": "\(payload.count)"], body: payload)
        }
        let progress = NetModLog()
        let request = HTTPRequest(url: URL(string: "https://downloads.fanbox.cc/images/post/1/original.jpeg")!, priority: .foregroundMedia,
                                  endpointKey: "media.original")
        let (file, response) = try await client.download(request, accountID: "A") { progress.append(String($0)) }
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(file.path.hasPrefix(downloadDir.path))
        XCTAssertEqual(file.pathExtension, "jpeg")
        XCTAssertEqual(try Data(contentsOf: file), payload)
        let values = progress.values.compactMap { Double($0) }
        XCTAssertEqual(values, values.sorted())
        XCTAssertTrue(values.allSatisfy { (0...1).contains($0) })
        let counts = await scheduler.transferCounts()
        XCTAssertEqual(counts.registered, 0, "transfer unregistered after completion")

        recorder.flush()
        let row = try XCTUnwrap(store.fetch(FetchDescriptor<ResearchLog>()).first)
        XCTAssertEqual(row.bytes, payload.count)
        XCTAssertEqual(row.responseBody, "", "downloaded media is never copied into Research logs")
    }

    func testDownloadErrorStatusDeletesFile() async throws {
        NetModStubProtocol.install { _ in NetModStubProtocol.Stub(status: 404, headers: [:], body: Data("missing".utf8)) }
        do {
            _ = try await client.download(HTTPRequest(url: URL(string: "https://downloads.fanbox.cc/x.png")!, priority: .foregroundMedia,
                                                      endpointKey: "media"), accountID: "A", progress: nil)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? RemoteError, .notFound)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: downloadDir.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testUploadSendsFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nettest-upload-\(UUID().uuidString).bin")
        try Data(repeating: 7, count: 50_000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let request = HTTPRequest(method: "POST", url: URL(string: "https://api.fanbox.cc/post.uploadImage")!,
                                  headers: ["Content-Type": "multipart/form-data; boundary=x"], priority: .interactiveWrite,
                                  endpointKey: "post.uploadImage", requiresCSRF: true)
        let response = try await client.upload(request, bodyFileURL: file, accountID: "A", progress: nil)
        XCTAssertEqual(response.statusCode, 200)
        let sent = NetModStubProtocol.requests.last
        XCTAssertEqual(sent?.httpMethod, "POST")
        XCTAssertEqual(header("X-CSRF-Token", sent), csrfValue)
        XCTAssertEqual(header("Content-Type", sent), "multipart/form-data; boundary=x")
    }

    func testCancellingARequestInFlight() async throws {
        NetModStubProtocol.install { _ in NetModStubProtocol.Stub(hang: true) }
        let client = self.client!
        let task = Task {
            try await client.send(HTTPRequest(url: URL(string: "https://api.fanbox.cc/slow")!, priority: .interactiveRead, endpointKey: "slow"),
                                  accountID: "A")
        }
        await netModWaitUntil { NetModStubProtocol.requests.count == 1 }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? RemoteError, .cancelled)
        }
        let active = await scheduler.snapshot()
        XCTAssertTrue(active.isEmpty)
    }
}

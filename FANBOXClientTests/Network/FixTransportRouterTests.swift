import XCTest
@testable import FANBOXClient

/// Scripted WebView transport (the `WebFetching` seam).
final class FixTransportFakeWeb: WebFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var foreground = true
    private var handler: (HTTPRequest, String) throws -> HTTPResponse = { request, _ in
        HTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], data: Data(#"{"body":{"via":"web"}}"#.utf8),
                     url: request.url, duration: 0)
    }
    private var _calls: [String] = []
    private var _shutdowns: [String] = []

    var calls: [String] { lock.withLock { _calls } }
    var shutdowns: [String] { lock.withLock { _shutdowns } }

    func setForeground(_ value: Bool) { lock.withLock { foreground = value } }
    func respond(_ handler: @escaping (HTTPRequest, String) throws -> HTTPResponse) { lock.withLock { self.handler = handler } }

    var isForeground: Bool { lock.withLock { foreground } }

    func fetch(_ request: HTTPRequest, accountID: String) async throws -> HTTPResponse {
        let handler = lock.withLock { () -> (HTTPRequest, String) throws -> HTTPResponse in
            _calls.append("\(request.endpointKey)|\(accountID)")
            return self.handler
        }
        return try handler(request, accountID)
    }

    func shutdown(accountID: String) async {
        lock.withLock { _shutdowns.append(accountID) }
    }
}

/// `TransportRouter` decision table and `RoutingHTTPClient` fallback / cooldown behaviour over the real
/// `AccountHTTPClient` (URLProtocol stub) and a fake WebView transport.
final class FixTransportRouterTests: XCTestCase {
    private var credentials: InMemoryCredentialStore!
    private var native: AccountHTTPClient!
    private var web: FixTransportFakeWeb!
    private var gate: RateGate!
    private var preferences: TransportPreferences!
    private var router: RoutingHTTPClient!

    private static let cloudflare403 = NetModStubProtocol.Stub(
        status: 403, headers: ["Content-Type": "text/html", "Server": "cloudflare"], body: Data("<html>ブロックされました</html>".utf8))

    override func setUp() async throws {
        try await super.setUp()
        credentials = InMemoryCredentialStore()
        try await credentials.save(SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "1_s", domain: ".fanbox.cc")],
                                                     userAgent: "UA", csrfToken: "tok"), for: "A")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NetModStubProtocol.self]
        native = AccountHTTPClient(credentials: credentials, scheduler: NetworkScheduler(policy: NetworkPolicyStore()),
                                   recorder: ResearchRecorder(), configuration: config)
        web = FixTransportFakeWeb()
        var gateConfig = RateGate.Configuration()
        gateConfig.heavySpacing = 0
        gateConfig.lightSpacing = 0
        gate = RateGate(configuration: gateConfig)
        preferences = TransportPreferences(defaults: nil)
        router = RoutingHTTPClient(native: native, web: web, gate: gate, preferences: preferences)
        NetModStubProtocol.install { _ in .init() }
    }

    override func tearDown() async throws {
        NetModStubProtocol.reset()
        try await super.tearDown()
    }

    private func request(_ key: String, method: String = "GET", priority: RequestPriority = .interactiveRead,
                         csrf: Bool = false) -> HTTPRequest {
        HTTPRequest(method: method, url: URL(string: "https://api.fanbox.cc/\(key)")!, headers: ["Accept": "application/json"],
                    body: method == "POST" ? Data("{}".utf8) : nil, priority: priority, endpointKey: key, requiresCSRF: csrf)
    }

    // MARK: Decision table

    func testPlanTable() {
        func plan(_ key: String, host: String = "api.fanbox.cc", fg: Bool = true, web: Bool = true,
                  override: TransportOverride = .automatic, prefers: Bool = false) -> [TransportKind] {
            TransportRouter.plan(endpointKey: key, host: host, isForeground: fg, webAvailable: web, override: override, prefersWeb: prefers)
        }
        XCTAssertEqual(plan("post.info"), [.webView, .native], "post.info is web-first in the foreground")
        XCTAssertEqual(plan("post.getEditable"), [.webView, .native])
        XCTAssertEqual(plan("post.listHome"), [.native, .webView])
        XCTAssertEqual(plan("post.listHome", prefers: true), [.webView, .native], "remembered native edge block")
        XCTAssertEqual(plan("post.info", fg: false), [.native], "background: native only")
        XCTAssertEqual(plan("post.info", web: false), [.native])
        XCTAssertEqual(plan("post.info", override: .nativeOnly), [.native])
        XCTAssertEqual(plan("post.listHome", override: .webViewOnly), [.webView])
        XCTAssertEqual(plan("post.listHome", fg: false, override: .webViewOnly), [.native])
        XCTAssertEqual(plan("media.original", host: "downloads.fanbox.cc"), [.native])
        XCTAssertEqual(plan("www.metadata", host: "www.fanbox.cc"), [.native, .webView])
    }

    // MARK: Routing

    func testNativeEdgeBlockFallsBackToWebAndIsRemembered() async throws {
        NetModStubProtocol.install { _ in Self.cloudflare403 }
        let response = try await router.send(request("post.listHome"), accountID: "A")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(web.calls, ["post.listHome|A"])
        XCTAssertEqual(NetModStubProtocol.requests.count, 1)
        XCTAssertTrue(preferences.prefersWeb(endpointKey: "post.listHome"))
        let breaker = await gate.breakerRemaining(accountID: "B", endpointKey: "post.listHome", transport: .native)
        XCTAssertNotNil(breaker)

        // Next time: WebView first, the blocked native path is not hit again.
        _ = try await router.send(request("post.listHome"), accountID: "A")
        XCTAssertEqual(NetModStubProtocol.requests.count, 1)
        XCTAssertEqual(web.calls.count, 2)
    }

    /// A write that neither transport sent (no CSRF token for the URLSession, the page unusable) is a refusal, never a
    /// network error with an unknown outcome.
    func testWriteSentByNeitherTransportIsReportedAsNotSent() async throws {
        try await credentials.save(SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "1_c", domain: ".fanbox.cc")]),
                                   for: "C")
        web.respond { _, _ in throw WebFetchError.unavailable("page challenged") }
        do {
            _ = try await router.send(request("post.addComment", method: "POST", priority: .interactiveWrite, csrf: true), accountID: "C")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? RemoteError, .csrfUnavailable)
        }
        XCTAssertEqual(web.calls, ["post.addComment|C"])
        XCTAssertTrue(NetModStubProtocol.requests.isEmpty, "nothing was sent")
    }

    func testPostInfoGoesThroughWebAndFallsBackToNativeWhenWebIsUnavailable() async throws {
        _ = try await router.send(request("post.info"), accountID: "A")
        XCTAssertEqual(web.calls, ["post.info|A"])
        XCTAssertTrue(NetModStubProtocol.requests.isEmpty)

        web.respond { _, _ in throw WebFetchError.unavailable("page not ready") }
        let response = try await router.send(request("post.info"), accountID: "A")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(NetModStubProtocol.requests.count, 1, "nothing was sent by the WebView, so native is used")
    }

    func testBackgroundUsesNativeOnlyAndEdgeBlockSurfacesAsEdgeBlocked() async throws {
        web.setForeground(false)
        NetModStubProtocol.install { _ in Self.cloudflare403 }
        let api = FanboxAPIClient(http: router, inspector: SchemaInspector(), credentials: credentials)
        let source = FanboxRemoteDataSource(api: api)
        let context = AccountContext(accountID: "A", kind: .fanbox, pixivUserID: "1", fanboxUserID: nil, creatorID: nil)
        do {
            _ = try await source.post(id: "5", account: context)
            XCTFail("expected edgeBlocked")
        } catch {
            XCTAssertEqual(error as? RemoteError, .edgeBlocked(retryAfter: nil))
        }
        XCTAssertTrue(web.calls.isEmpty)
        XCTAssertEqual(NetModStubProtocol.requests.count, 1)

        // The device-wide native breaker stops further blocked calls (any account) without sending them.
        do {
            _ = try await source.post(id: "6", account: AccountContext(accountID: "B", kind: .fanbox, pixivUserID: "2",
                                                                        fanboxUserID: nil, creatorID: nil))
            XCTFail("expected edgeBlocked")
        } catch let error as RemoteError {
            guard case .edgeBlocked(let retryAfter) = error else { return XCTFail("\(error)") }
            XCTAssertNotNil(retryAfter)
        }
        XCTAssertEqual(NetModStubProtocol.requests.count, 1)
    }

    func testWriteIsResentOnTheWebOnlyAfterANativeEdgeBlock() async throws {
        NetModStubProtocol.install { _ in Self.cloudflare403 }
        let response = try await router.send(request("post.likePost", method: "POST", priority: .interactiveWrite, csrf: true),
                                             accountID: "A")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(web.calls, ["post.likePost|A"])

        // Ambiguous WebView failure of a write: never re-sent through the native transport.
        NetModStubProtocol.install { _ in .init() }
        preferences.markNativeEdgeBlocked(endpointKey: "post.addComment")
        web.respond { _, _ in throw RemoteError.network(code: -1001, detail: "timeout") }
        let before = NetModStubProtocol.requests.count
        do {
            _ = try await router.send(request("post.addComment", method: "POST", priority: .interactiveWrite, csrf: true), accountID: "A")
            XCTFail("expected network error")
        } catch {
            guard case .network = error as? RemoteError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(NetModStubProtocol.requests.count, before)
    }

    func testMissingNativeTokenUsesTheWebPageToken() async throws {
        try await credentials.save(SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "1_s", domain: ".fanbox.cc")]),
                                   for: "A")
        let response = try await router.send(request("follow.create", method: "POST", priority: .interactiveWrite, csrf: true),
                                             accountID: "A")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(NetModStubProtocol.requests.isEmpty, "nothing was sent without a token")
        XCTAssertEqual(web.calls, ["follow.create|A"])
    }

    func testRateLimitStartsACooldownThatStopsFurtherCalls() async throws {
        NetModStubProtocol.install { _ in NetModStubProtocol.Stub(status: 429, headers: ["Retry-After": "120"], body: Data()) }
        let response = try await router.send(request("bell.list"), accountID: "A")
        XCTAssertEqual(response.statusCode, 429)
        XCTAssertTrue(web.calls.isEmpty, "a 429 is never retried on the other transport")
        do {
            _ = try await router.send(request("post.addComment", method: "POST", priority: .interactiveWrite, csrf: true), accountID: "A")
            XCTFail("expected rateLimited")
        } catch let error as RemoteError {
            guard case .rateLimited(let retryAfter) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(retryAfter ?? 0, 120, accuracy: 2)
        }
        XCTAssertEqual(NetModStubProtocol.requests.count, 1)
    }

    func testWebEdgeBlockTripsTheAccountsWebBreaker() async throws {
        web.respond { _, _ in throw RemoteError.edgeBlocked(retryAfter: nil) }
        do {
            _ = try await router.send(request("post.info"), accountID: "A")
            XCTFail("expected edgeBlocked")
        } catch {
            XCTAssertEqual(error as? RemoteError, .edgeBlocked(retryAfter: nil))
        }
        XCTAssertTrue(NetModStubProtocol.requests.isEmpty, "no native retry after a WebView edge block")
        let breaker = await gate.breakerRemaining(accountID: "A", endpointKey: "post.info", transport: .webView)
        XCTAssertNotNil(breaker)
    }

    func testRevokeShutsDownBothTransports() async throws {
        _ = try await router.send(request("bell.list"), accountID: "A")
        XCTAssertEqual(native.sessionCount, 1)
        await router.revokeSession(accountID: "A")
        XCTAssertEqual(native.sessionCount, 0)
        XCTAssertEqual(web.shutdowns, ["A"])
    }

    func testAPIClientDiscoversCredentialsThroughTheRouter() {
        let api = FanboxAPIClient(http: router, inspector: SchemaInspector())
        XCTAssertTrue((api.credentials as? InMemoryCredentialStore) === credentials,
                      "wrapping the transport never silently disables CSRF storage / refresh")
    }
}

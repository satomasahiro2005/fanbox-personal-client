import XCTest
@testable import FANBOXClient

/// `FanboxAPIClient` over the REAL `AccountHTTPClient` (URLProtocol stub): the error paths the fake transport covers in
/// `FanboxClientTests` must behave the same with the production transport contract (non-2xx answers returned, then
/// classified by `validate`).
final class FixTransportIntegrationTests: XCTestCase {
    private var credentials: InMemoryCredentialStore!
    private var api: FanboxAPIClient!
    private var source: FanboxRemoteDataSource!
    private let account = AccountContext(accountID: "A", kind: .fanbox, pixivUserID: "11", fanboxUserID: nil, creatorID: "alice")

    override func setUp() async throws {
        try await super.setUp()
        credentials = InMemoryCredentialStore()
        try await credentials.save(SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "11_s", domain: ".fanbox.cc")],
                                                     userAgent: "UA", csrfToken: "stale"), for: "A")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NetModStubProtocol.self]
        let transport = AccountHTTPClient(credentials: credentials, scheduler: NetworkScheduler(policy: NetworkPolicyStore()),
                                          recorder: ResearchRecorder(), configuration: config)
        api = FanboxAPIClient(http: transport, inspector: SchemaInspector())
        source = FanboxRemoteDataSource(api: api)
    }

    override func tearDown() async throws {
        NetModStubProtocol.reset()
        try await super.tearDown()
    }

    private func stub(_ byPath: @escaping (String) -> NetModStubProtocol.Stub) {
        NetModStubProtocol.install { request in byPath(request.url?.path ?? "") }
    }

    private func expect(_ expected: RemoteError, file: StaticString = #filePath, line: UInt = #line,
                        _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RemoteError, expected, file: file, line: line)
        }
    }

    func testErrorStatusesAreClassifiedFromTheRealTransport() async throws {
        let json = ["Content-Type": "application/json", "Server": "cloudflare"]
        stub { path in
            switch path {
            case "/post.listHome": return .init(status: 401, headers: json, body: Data(#"{"error":"general_error"}"#.utf8))
            case "/post.listSupporting": return .init(status: 429, headers: ["Retry-After": "12"], body: Data())
            case "/creator.get": return .init(status: 403, headers: json, body: Data(#"{"error":"general_error"}"#.utf8))
            case "/post.info": return .init(status: 403, headers: ["Content-Type": "text/html", "Server": "cloudflare"],
                                            body: Data("<!DOCTYPE html><title>Just a moment...</title>".utf8))
            case "/plan.listSupporting": return .init(status: 400, headers: json, body: Data(#"{"error":"general_error"}"#.utf8))
            default: return .init()
            }
        }
        await expect(.unauthorized) { _ = try await self.source.homeTimeline(account: self.account, cursor: nil) }
        await expect(.rateLimited(retryAfter: 12)) { _ = try await self.source.supportingTimeline(account: self.account, cursor: nil) }
        await expect(.forbidden) { _ = try await self.source.creator(id: "x", account: self.account) }
        await expect(.edgeBlocked(retryAfter: nil)) { _ = try await self.source.post(id: "1", account: self.account) }
        do {
            _ = try await source.supportingPlans(account: account)
            XCTFail("expected invalidRequest")
        } catch let error as RemoteError {
            guard case .invalidRequest(let detail) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("400"), "the JSON error code of a non-2xx answer is read: \(detail)")
        }
    }

    func testCSRFIsRefreshedOnceAfterA400() async throws {
        var likeCalls = 0
        let lock = NSLock()
        stub { path in
            switch path {
            case "/post.likePost":
                let n = lock.withLock { () -> Int in likeCalls += 1; return likeCalls }
                return n == 1 ? .init(status: 400, headers: ["Content-Type": "application/json"], body: Data(#"{"error":"general_error"}"#.utf8))
                              : .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"body":null}"#.utf8))
            case "/":
                return .init(status: 200, headers: ["Content-Type": "text/html"], body: Data(FanboxFixtures.metadataHTML.utf8))
            default: return .init()
            }
        }
        try await source.setLike(postID: "1", liked: true, account: account)
        XCTAssertEqual(lock.withLock { likeCalls }, 2)
        let stored = await credentials.credential(for: "A")
        XCTAssertEqual(stored?.csrfToken, "tok-fresh-123")
        let sentTokens = NetModStubProtocol.requests.filter { $0.url?.path == "/post.likePost" }
            .compactMap { $0.value(forHTTPHeaderField: "X-CSRF-Token") }
        XCTAssertEqual(sentTokens, ["stale", "tok-fresh-123"])
    }

    func testMissingTokenWhenTheMetadataPageIsChallengedIsTransient() async throws {
        try await credentials.save(SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "11_s", domain: ".fanbox.cc")]),
                                   for: "A")
        stub { path in
            path == "/" ? .init(status: 403, headers: ["Content-Type": "text/html", "cf-mitigated": "challenge"], body: Data("<html>".utf8))
                        : .init()
        }
        await expect(.csrfUnavailable) { try await self.source.setFollow(creatorUserID: "11", follow: true, account: self.account) }
        XCTAssertFalse(NetModStubProtocol.requests.contains { $0.url?.path == "/follow.create" }, "nothing was sent")
    }

    func testPostUpdateFormIsSentFromMemoryWithoutATemporaryFile() async throws {
        stub { path in
            switch path {
            case "/post.create": return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"body":{"postId":"9"}}"#.utf8))
            default: return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"body":{"id":"9"}}"#.utf8))
            }
        }
        try await credentials.save(SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "11_s", domain: ".fanbox.cc")],
                                                     userAgent: "UA", csrfToken: "tok"), for: "A")
        let tempDir = FileManager.default.temporaryDirectory
        func bodyFiles() -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? [])
                .filter { $0.hasPrefix(MultipartFormData.temporaryFilePrefix) }.count
        }
        let before = bodyFiles()
        let draft = RemotePostDraft(title: "t", feeRequired: 0, planID: nil, tags: [], hasAdultContent: false,
                                    blocks: [RemoteDraftBlock(kind: .text, text: "本文", mediaID: nil, url: nil, embedProvider: nil,
                                                              embedContentID: nil)], publish: false)
        let id = try await source.createPost(draft, account: account)
        XCTAssertEqual(id, "9")
        XCTAssertEqual(bodyFiles(), before, "the CSRF token (multipart field tt) never touches the disk")
        let update = try XCTUnwrap(NetModStubProtocol.requests.last { $0.url?.path == "/post.update" })
        XCTAssertTrue(update.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") ?? false)
    }

    func testStaleMultipartFilesArePurged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fixtransport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var form = MultipartFormData()
        form.addField(name: "tt", value: "secret")
        XCTAssertFalse(form.hasFileParts)
        let file = try form.writeToTemporaryFile(directory: dir)
        let protection = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType
        XCTAssertTrue(protection == nil || protection == .complete, "created with complete protection where supported")
        try Data().write(to: dir.appendingPathComponent("unrelated.body"))
        XCTAssertEqual(MultipartFormData.removeStaleTemporaryFiles(in: dir), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("unrelated.body").path))
    }
}

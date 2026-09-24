import XCTest
@testable import FANBOXClient

/// Decodes one masked live response with the app's own DTOs and adapter. Returns how many domain items the adapter made
/// (1 for single objects), or nil for endpoint keys that are not part of the read contract.
enum LiveContract {
    static func mappedCount(endpointKey: String, responseJSON: Data) throws -> Int? {
        func body<T: Decodable>(_ type: T.Type) throws -> T {
            try FanboxResponseHandling.decodeBody(T.self, from: responseJSON, endpointKey: endpointKey)
        }
        switch endpointKey {
        case "post.listHome", "post.listSupporting", "post.listTagged":
            return FanboxAdapter.postSummaries(try body(FanboxPostListBody.self).items).count
        case "post.listCreator":
            return FanboxAdapter.postSummaries(try body(FanboxCreatorPostListBody.self).items).count
        case "post.info", "post.get":
            return FanboxAdapter.postDetail(try body(FanboxPostInfoBody.self).post) == nil ? 0 : 1
        case "creator.get":
            return FanboxAdapter.creator(try body(FanboxCreatorBody.self).creator) == nil ? 0 : 1
        case "creator.listFollowing":
            return try body(FanboxCreatorListBody.self).items.compactMap(FanboxAdapter.creator).count
        case "plan.listSupporting":
            return try body(FanboxPlanListBody.self).items.compactMap(FanboxAdapter.support).count
        case "plan.listCreator":
            return FanboxAdapter.plans(try body(FanboxPlanListBody.self).items, fallbackCreatorID: "x").count
        case "post.getComments":
            return FanboxAdapter.comments(try body(FanboxCommentListBody.self).items, postID: "p").count
        case "bell.list":
            return try body(FanboxBellListBody.self).items.compactMap(FanboxAdapter.notification).count
        case "bell.countUnread":
            return try body(FanboxCountBody.self).count == nil ? 0 : 1
        case "newsletter.list":
            return try body(FanboxNewsletterListBody.self).items.compactMap(FanboxAdapter.newsletter).count
        case "payment.listPaid", "payment.listUnpaid":
            return FanboxAdapter.payments(try body(FanboxPaymentListBody.self).items).count
        case "post.paginateCreator":
            return try body(FanboxPaginateCreatorBody.self).pageUrls.count
        case "post.listManaged":
            return try body(FanboxManagedPostListBody.self).items.count
        case "post.getEditable":
            _ = try body(FanboxEditablePostBody.self)
            return 1
        case "relationship.listFans":
            return try body(FanboxFanListBody.self).items.count
        case "www.metadata":
            let root = try JSONSerialization.jsonObject(with: responseJSON) as? [String: Any]
            let inner = try JSONSerialization.data(withJSONObject: root?["body"] ?? [:])
            _ = try FanboxAdapter.user(try JSONDecoder().decode(FanboxMetadataDTO.self, from: inner))
            return 1
        default:
            return nil
        }
    }

    /// Top-level list length of the raw response body (to tell "empty list" from "the adapter dropped every item").
    static func rawItemCount(_ responseJSON: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: responseJSON) as? [String: Any] else { return nil }
        let b = root["body"]
        if let list = b as? [Any] { return list.count }
        if let dict = b as? [String: Any] {
            for key in ["items", "posts", "creators", "plans", "payments", "newsletters", "supporters", "fans"] {
                if let list = dict[key] as? [Any] { return list.count }
            }
        }
        return nil
    }
}

final class LiveAPIShapeTests: XCTestCase {
    let shaper = LiveAPIShape(salt: 42)

    func testTextIsMaskedStructureIsKept() throws {
        let raw = #"""
        {"body":{"title":"秘密の日記","feeRequired":500,"isRestricted":false,"type":"article","status":"published",
         "publishedDatetime":"2026-09-10T10:00:00+09:00","jst":"2026-04-26 04:19:57","tags":["a","b","c","d"],
         "csrfToken":"tok-123","user":{"userId":"12345678","name":"Alice"},"cover":null}}
        """#
        let masked = try XCTUnwrap(shaper.maskedJSON(Data(raw.utf8)))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: masked) as? [String: Any])
        let body = try XCTUnwrap(root["body"] as? [String: Any])
        XCTAssertEqual(body["title"] as? String, "<text:5>")
        XCTAssertEqual(body["feeRequired"] as? Int, 500)
        XCTAssertEqual(body["isRestricted"] as? Bool, false)
        XCTAssertEqual(body["type"] as? String, "article", "structural enum values are kept")
        XCTAssertEqual(body["status"] as? String, "published")
        XCTAssertEqual(body["publishedDatetime"] as? String, "2026-09-10T10:00:00+09:00", "date formats are kept")
        XCTAssertEqual(body["jst"] as? String, "2026-04-26 04:19:57")
        XCTAssertEqual((body["tags"] as? [Any])?.count, LiveAPIShape.maxArrayElements)
        XCTAssertEqual(body["csrfToken"] as? String, "<secret>")
        let user = try XCTUnwrap(body["user"] as? [String: Any])
        let id = try XCTUnwrap(user["userId"] as? String)
        XCTAssertEqual(id.count, 8)
        XCTAssertTrue(id.allSatisfy(\.isNumber), "numeric ids stay numeric strings")
        XCTAssertNotEqual(id, "12345678")
        XCTAssertEqual(user["name"] as? String, "<text:5>")
        XCTAssertTrue(body["cover"] is NSNull)
        let text = String(decoding: masked, as: UTF8.self)
        for secret in ["秘密", "Alice", "tok-123", "12345678"] { XCTAssertFalse(text.contains(secret), secret) }
    }

    func testPseudonymsAreConsistentSoReferencesSurvive() throws {
        let masked = try XCTUnwrap(shaper.maskedJSON(Data(FanboxFixtures.envelope(FanboxFixtures.articlePost).utf8)))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: masked) as? [String: Any])
        let body = try XCTUnwrap(((root["body"] as? [String: Any])?["post"] as? [String: Any])?["body"] as? [String: Any])
        let blocks = try XCTUnwrap(body["blocks"] as? [[String: Any]])
        let imageMap = try XCTUnwrap(body["imageMap"] as? [String: Any])
        let imageID = try XCTUnwrap(blocks.compactMap { $0["imageId"] as? String }.first)
        XCTAssertNotNil(imageMap[imageID], "the block's imageId still points at its imageMap entry")
        XCTAssertNotEqual(imageID, "img1")
    }

    func testURLsKeepHostAndShapeOnly() {
        let s = shaper.maskString("https://alice.fanbox.cc/posts/6001?token=abc&x=1", key: "url")
        XCTAssertTrue(s.hasPrefix("https://id"), s)
        XCTAssertTrue(s.hasSuffix(".fanbox.cc/posts/" + shaper.pseudonymDigits("6001") + "?token&x"), s)
        XCTAssertFalse(s.contains("alice"))
        XCTAssertFalse(s.contains("abc"))
        let image = shaper.maskString("https://downloads.fanbox.cc/images/post/6001/0123456789abcdefghij.jpeg", key: "originalUrl")
        XCTAssertTrue(image.hasPrefix("https://downloads.fanbox.cc/images/post/"), image)
        XCTAssertTrue(image.hasSuffix(".jpeg"), image)
    }

    /// A masked response must still be a valid decoding fixture (that is what makes shared reports useful).
    func testMaskedFixturesStillDecodeWithTheAppDecoders() throws {
        let cases: [(String, String)] = [
            ("post.listHome", FanboxFixtures.homeTimeline),
            ("post.info", FanboxFixtures.articlePost),
            ("creator.get", FanboxFixtures.creator),
            ("plan.listSupporting", FanboxFixtures.supportingPlansWrapped),
            ("post.getComments", FanboxFixtures.comments),
            ("bell.list", FanboxFixtures.bells),
            ("newsletter.list", FanboxFixtures.newsletters),
            ("payment.listPaid", FanboxFixtures.payments),
            ("post.listManaged", FanboxFixtures.managedPosts),
            ("post.getEditable", FanboxFixtures.editablePost),
            ("relationship.listFans", FanboxFixtures.fans),
        ]
        for (key, fixture) in cases {
            let raw = Data(FanboxFixtures.envelope(fixture).utf8)
            let original = try XCTUnwrap(LiveContract.mappedCount(endpointKey: key, responseJSON: raw), key)
            let masked = try XCTUnwrap(shaper.maskedJSON(raw), key)
            let afterMask = try XCTUnwrap(LiveContract.mappedCount(endpointKey: key, responseJSON: masked), key)
            // Arrays are shortened; everything that remains must still map.
            if original > 0 { XCTAssertGreaterThan(afterMask, 0, key) }
            XCTAssertLessThanOrEqual(afterMask, original, key)
        }
        // The masked article still resolves its blocks through the maps.
        let masked = try XCTUnwrap(shaper.maskedJSON(Data(FanboxFixtures.envelope(FanboxFixtures.articlePost).utf8)))
        let post = try FanboxResponseHandling.decodeBody(FanboxPostInfoBody.self, from: masked, endpointKey: "post.info").post
        let detail = try XCTUnwrap(FanboxAdapter.postDetail(post))
        XCTAssertTrue(detail.blocks.contains { $0.kind == .image && $0.originalURL != nil }, "image block resolved via imageMap")
        XCTAssertTrue(detail.blocks.contains { $0.kind == .audio }, "file block resolved via fileMap")
    }
}

@MainActor
final class LiveAPICheckTests: XCTestCase {
    private func stubAll(_ http: FanboxFakeHTTPClient, creator: Bool = true, except: Set<String> = []) {
        let metadata = creator ? FanboxFixtures.metadataHTML : FanboxFixtures.metadataHTML
            .replacingOccurrences(of: "&quot;isCreator&quot;:true", with: "&quot;isCreator&quot;:false")
            .replacingOccurrences(of: "&quot;creatorId&quot;:&quot;alice&quot;", with: "&quot;creatorId&quot;:null")
        http.stub("www.metadata", data: Data(metadata.utf8), headers: ["Content-Type": "text/html"])
        http.stub("bell.countUnread", json: FanboxFixtures.envelope(#"{"count":3}"#))
        http.stub("bell.list", json: FanboxFixtures.envelope(FanboxFixtures.bells))
        http.stub("newsletter.list", json: FanboxFixtures.envelope(FanboxFixtures.newsletters))
        http.stub("post.listHome", json: FanboxFixtures.envelope(FanboxFixtures.homeTimeline))
        http.stub("post.listSupporting", json: FanboxFixtures.envelope(FanboxFixtures.homeTimeline))
        http.stub("creator.listFollowing", json: FanboxFixtures.envelope(#"{"creators":[\#(FanboxFixtures.creator)]}"#))
        http.stub("plan.listSupporting", json: FanboxFixtures.envelope(FanboxFixtures.supportingPlansWrapped))
        http.stub("payment.listPaid", json: FanboxFixtures.envelope(FanboxFixtures.payments))
        http.stub("payment.listUnpaid", json: FanboxFixtures.envelope(#"{"payments":[]}"#))
        if !except.contains("post.info") { http.stub("post.info", json: FanboxFixtures.envelope(FanboxFixtures.articlePost)) }
        http.stub("post.get", json: FanboxFixtures.envelope(FanboxFixtures.articlePost))
        http.stub("post.getComments", json: FanboxFixtures.envelope(FanboxFixtures.comments))
        http.stub("creator.get", json: FanboxFixtures.envelope(FanboxFixtures.creator))
        http.stub("plan.listCreator", json: FanboxFixtures.envelope(FanboxFixtures.supportingPlansWrapped))
        let page = "https://api.fanbox.cc/post.listCreator?creatorId=alice&firstPublishedDatetime=2026-09-10T10%3A00%3A00%2B09%3A00&firstId=6001&sort=newest&limit=10"
        http.stub("post.paginateCreator", json: FanboxFixtures.envelope(#"{"pageUrls":["\#(page)"]}"#))
        http.stub("post.listCreator", json: FanboxFixtures.envelope(#"{"posts":[{"id":"6001","creatorId":"alice","publishedDatetime":"2026-09-10T10:00:00+09:00"}]}"#))
        http.stub("post.listManaged", json: FanboxFixtures.envelope(FanboxFixtures.managedPosts.replacingOccurrences(of: "MONTH", with: "2026-09")))
        http.stub("post.getEditable", json: FanboxFixtures.envelope(FanboxFixtures.editablePost))
        http.stub("relationship.listFans", json: FanboxFixtures.envelope(FanboxFixtures.fans))
        http.stub("relationship.listFilterOptions", json: FanboxFixtures.envelope(FanboxFixtures.filterOptions))
        http.stub("legacy.manage.pledge.monthly", json: FanboxFixtures.envelope(FanboxFixtures.pledgeMonthly(month: "2026-09")))
    }

    func testRunsEveryReadStepAndProducesAMaskedReport() async throws {
        let inspector = SchemaInspector(persistInterval: 0)
        let http = FanboxFakeHTTPClient()
        stubAll(http)
        let api = FanboxAPIClient(http: http, inspector: inspector, credentials: InMemoryCredentialStore())
        let source = FanboxRemoteDataSource(api: api, pageCache: FanboxPageURLCache(), nativePostWritesEnabled: true)
        let check = LiveAPICheck(remote: DefaultRemoteDataSourceProvider(fanbox: source, demo: DemoRemoteDataSource()), inspector: inspector)
        check.stepDelay = .zero

        await check.run(account: FanboxTestHarness.creator)

        XCTAssertFalse(check.isRunning)
        let failed = check.steps.filter { $0.status == .failed }
        XCTAssertTrue(failed.isEmpty, failed.map { "\($0.id): \($0.error ?? "")" }.joined(separator: "\n"))
        XCTAssertTrue(check.isCreatorAccount)
        XCTAssertEqual(check.steps.first { $0.id == "post.info" }?.endpointKeys, ["post.info"])
        XCTAssertTrue(http.requests.allSatisfy { $0.method == "GET" || $0.endpointKey == "www.metadata" }, "read-only")
        XCTAssertFalse(http.requests.contains { ["post.create", "post.update", "post.addComment", "post.addImage"].contains($0.endpointKey) })

        // The fixtures carry fields the DTOs do not know ("brandNewField", "someNewFlag"): reported as new.
        let info = try XCTUnwrap(check.endpoints.first { $0.endpointKey == "post.info" })
        XCTAssertTrue(info.newFields.values.flatMap { $0 }.contains("someNewFlag"), "\(info.newFields)")

        let report = try XCTUnwrap(check.reportJSON(appVersion: "test"))
        let text = String(decoding: report, as: UTF8.self)
        for secret in ["Alice", "tok-fresh-123", "イラストを描いています", "いつも応援ありがとうございます", "secret_value"] {
            XCTAssertFalse(text.contains(secret), "report leaks \(secret)")
        }
        // The report's shapes are contract fixtures: every endpoint decodes with the app's decoders.
        try LiveContractTests.verify(report: report, file: "generated")
    }

    func testDemoAccountsAreNotChecked() async {
        let inspector = SchemaInspector(persistInterval: 0)
        let api = FanboxAPIClient(http: FanboxFakeHTTPClient(), inspector: inspector, credentials: InMemoryCredentialStore())
        let source = FanboxRemoteDataSource(api: api, pageCache: FanboxPageURLCache(), nativePostWritesEnabled: true)
        let check = LiveAPICheck(remote: DefaultRemoteDataSourceProvider(fanbox: source, demo: DemoRemoteDataSource()), inspector: inspector)
        await check.run(account: AccountContext(accountID: "d", kind: .demo, pixivUserID: "demo-1", fanboxUserID: nil, creatorID: nil))
        XCTAssertTrue(check.steps.allSatisfy { $0.status == .skipped })
    }

    func testAFailingEndpointIsReportedAndTheRunContinues() async throws {
        let inspector = SchemaInspector(persistInterval: 0)
        let http = FanboxFakeHTTPClient()
        stubAll(http, creator: false, except: ["post.info"])
        http.stub("post.info", status: 403, data: Data("<html>ブロックされました cf-chl-</html>".utf8), headers: ["Content-Type": "text/html", "Server": "cloudflare"])
        let api = FanboxAPIClient(http: http, inspector: inspector, credentials: InMemoryCredentialStore())
        let source = FanboxRemoteDataSource(api: api, pageCache: FanboxPageURLCache(), nativePostWritesEnabled: true)
        let check = LiveAPICheck(remote: DefaultRemoteDataSourceProvider(fanbox: source, demo: DemoRemoteDataSource()), inspector: inspector)
        check.stepDelay = .zero
        await check.run(account: FanboxTestHarness.fan)
        XCTAssertEqual(check.steps.first { $0.id == "post.info" }?.status, .failed)
        XCTAssertEqual(check.steps.first { $0.id == "post.getComments" }?.status, .passed, "later steps still run")
        XCTAssertTrue(check.steps.first { $0.id == "post.info" }?.error?.contains("edgeBlocked") ?? false,
                      check.steps.first { $0.id == "post.info" }?.error ?? "")
        XCTAssertEqual(check.steps.first { $0.id == "post.listManaged" }?.status, .skipped, "creator-only steps skip for a fan account")
    }
}

/// Contract tests against reports captured on a device with the Live API check (Research Mode → Live API チェック →
/// レポートを共有). Put a report into FANBOXClientTests/Research/LiveReports/ as `live-report-*.json`; every endpoint shape in
/// it must decode with the app's DTOs, and a non-empty list must not map to zero items.
final class LiveContractTests: XCTestCase {
    func testCapturedLiveReportsDecode() throws {
        let bundle = Bundle(for: LiveContractTests.self)
        let urls = (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("live-report-") }
        if urls.isEmpty {
            throw XCTSkip("No live reports yet. Run Research Mode → Live API チェック on a device and add the shared report to FANBOXClientTests/Research/LiveReports/.")
        }
        for url in urls {
            try Self.verify(report: Data(contentsOf: url), file: url.lastPathComponent)
        }
    }

    static func verify(report: Data, file: String) throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: report) as? [String: Any], file)
        XCTAssertEqual(root["format"] as? String, "fanbox-live-api-report/1", file)
        let endpoints = try XCTUnwrap(root["endpoints"] as? [String: Any], file)
        for (key, value) in endpoints.sorted(by: { $0.key < $1.key }) {
            guard let record = value as? [String: Any], let shape = record["shape"] else { continue }
            let data = try JSONSerialization.data(withJSONObject: shape, options: [.fragmentsAllowed])
            do {
                guard let mapped = try LiveContract.mappedCount(endpointKey: key, responseJSON: data) else { continue }
                if let raw = LiveContract.rawItemCount(data), raw > 0 {
                    XCTAssertGreaterThan(mapped, 0, "\(file) \(key): \(raw) items in the response, none mapped")
                }
            } catch {
                XCTFail("\(file) \(key): the app's decoder rejects the live shape: \(error)")
            }
        }
    }
}

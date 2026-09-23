import XCTest
@testable import FANBOXClient

/// Tolerant decoding (SPEC §37), envelopes, error mapping, dates, wrapped / bare list shapes.
final class FanboxDecodingTests: XCTestCase {
    // MARK: JSONValue / lenient scalars

    func testJSONValueRoundTripAndAccessors() throws {
        let value = try JSONValue.parse(Data(#"{"a":1,"b":"2","c":[true,null,1.5],"d":{"e":"x"}}"#.utf8))
        XCTAssertEqual(value["a"]?.stringValue, "1")
        XCTAssertEqual(value["a"]?.intValue, 1)
        XCTAssertEqual(value["b"]?.intValue, 2)
        XCTAssertEqual(value["c"]?[0]?.boolValue, true)
        XCTAssertEqual(value["c"]?[1], .null)
        XCTAssertEqual(value["c"]?[2]?.stringValue, "1.5")
        XCTAssertEqual(value["d"]?["e"], "x")
        let encoded = String(data: try JSONValue.object(["b": "x", "a": 1]).encoded(), encoding: .utf8)
        XCTAssertEqual(encoded, #"{"a":1,"b":"x"}"#)
    }

    func testLenientIDsCountsAndBools() throws {
        struct Probe: Decodable {
            var id: String?
            var fee: Int?
            var flag: Bool?
            var flag2: Bool?
            var missing: String?
            var wrongType: Int?
            init(from decoder: Decoder) throws {
                let o = try LenientObject(decoder)
                id = o.string("id")
                fee = o.int("fee")
                flag = o.bool("flag")
                flag2 = o.bool("flag2")
                missing = o.string("missing")
                wrongType = o.int("wrongType")
            }
        }
        let p = try JSONDecoder().decode(Probe.self, from: Data(#"{"id":123456789012,"fee":"1,000","flag":1,"flag2":"false","wrongType":{"x":1}}"#.utf8))
        XCTAssertEqual(p.id, "123456789012")
        XCTAssertEqual(p.fee, 1000)
        XCTAssertEqual(p.flag, true)
        XCTAssertEqual(p.flag2, false)
        XCTAssertNil(p.missing)
        XCTAssertNil(p.wrongType)
    }

    func testDateParsingVariants() {
        let base = FanboxDateParser.parse("2026-09-01T12:34:56+09:00")
        XCTAssertEqual(base, Date(timeIntervalSince1970: 1_788_233_696))
        XCTAssertEqual(FanboxDateParser.parse("2026-09-01T03:34:56Z"), base)
        XCTAssertEqual(FanboxDateParser.parse("2026-09-01T03:34:56.000Z"), base)
        XCTAssertEqual(FanboxDateParser.parse("2026-09-01T12:34:56+0900"), base)
        XCTAssertEqual(FanboxDateParser.parse("2026-09-01 12:34:56"), base, "no offset ⇒ JST")
        let fractional = FanboxDateParser.parse("2026-09-01T12:34:56.250+09:00")!
        XCTAssertEqual(fractional.timeIntervalSince(base!), 0.25, accuracy: 0.0001)
        let micro = FanboxDateParser.parse("2026-09-01T12:34:56.123456+09:00")!
        XCTAssertEqual(micro.timeIntervalSince(base!), 0.123456, accuracy: 0.00001)
        XCTAssertEqual(FanboxDateParser.parse("2026-09-01T00:00:00-05:00"), FanboxDateParser.parse("2026-09-01T14:00:00+09:00"))
        XCTAssertNotNil(FanboxDateParser.parse("2026-09-01"))
        XCTAssertEqual(FanboxDateParser.parse("1788233696"), base)
        XCTAssertNil(FanboxDateParser.parse("yesterday"))
        XCTAssertNil(FanboxDateParser.parse("2026-13-01T00:00:00Z"))
        XCTAssertEqual(FanboxDateParser.monthKey(FanboxDateParser.parse("2026-08-31T20:00:00Z")!), "2026-09", "JST month")
    }

    // MARK: Envelope / errors

    func testEnvelopeErrorAndDecodingFailures() {
        XCTAssertThrowsError(try FanboxResponseHandling.decodeBody(FanboxPostListBody.self, from: Data(#"{"error":"general_error"}"#.utf8),
                                                                   endpointKey: "post.listHome", statusCode: 400)) { error in
            guard case .invalidRequest? = error as? RemoteError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try FanboxResponseHandling.decodeBody(FanboxPostListBody.self, from: Data(#"{"error":"x"}"#.utf8),
                                                                   endpointKey: "k", statusCode: 401)) { error in
            XCTAssertEqual(error as? RemoteError, .unauthorized)
        }
        XCTAssertThrowsError(try FanboxResponseHandling.decodeBody(FanboxPostListBody.self, from: Data("<html>".utf8), endpointKey: "k")) { error in
            guard case .decoding(let endpoint, _)? = error as? RemoteError else { return XCTFail("\(error)") }
            XCTAssertEqual(endpoint, "k")
        }
        // A changed shape is a decoding error, never an empty list.
        XCTAssertThrowsError(try FanboxFixtures.decodeBody(FanboxPlanListBody.self, #"{"somethingElse":[]}"#)) { error in
            guard case .decoding? = error as? RemoteError else { return XCTFail("\(error)") }
        }
    }

    func testStatusMapping() {
        XCTAssertEqual(FanboxResponseHandling.map(statusCode: 401, headers: [:]), .unauthorized)
        XCTAssertEqual(FanboxResponseHandling.map(statusCode: 403, headers: [:]), .forbidden)
        XCTAssertEqual(FanboxResponseHandling.map(statusCode: 404, headers: [:]), .notFound)
        XCTAssertEqual(FanboxResponseHandling.map(statusCode: 503, headers: [:]), .server(status: 503))
        XCTAssertEqual(FanboxResponseHandling.map(statusCode: 429, headers: ["retry-after": "120"]), .rateLimited(retryAfter: 120))
        XCTAssertEqual(FanboxResponseHandling.map(statusCode: 429, headers: [:]), .rateLimited(retryAfter: nil))
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(FanboxResponseHandling.retryAfter(from: ["Retry-After": "Mon, 12 Jan 1970 13:47:10 GMT"], now: now) ?? -1, 30, accuracy: 1)
        XCTAssertTrue(FanboxResponseHandling.isCloudflareBlock(statusCode: 403, headers: ["cf-mitigated": "challenge"]))
        XCTAssertTrue(FanboxResponseHandling.isCloudflareBlock(statusCode: 403, headers: ["Content-Type": "text/html", "Server": "cloudflare"]))
        XCTAssertFalse(FanboxResponseHandling.isCloudflareBlock(statusCode: 403, headers: ["Content-Type": "application/json"]))
        if case .invalidRequest = FanboxResponseHandling.map(statusCode: 400, headers: [:], errorCode: "general_error") {} else { XCTFail() }
    }

    // MARK: Wrapped / bare shapes (docs/API.md §1.10)

    func testWrappedAndBareListShapes() throws {
        let wrapped = try FanboxFixtures.decodeBody(FanboxPlanListBody.self, FanboxFixtures.supportingPlansWrapped)
        XCTAssertEqual(wrapped.wrapperKey, "plans")
        XCTAssertEqual(wrapped.items.count, 3)
        let bare = try FanboxFixtures.decodeBody(FanboxPlanListBody.self, FanboxFixtures.supportingPlansBare)
        XCTAssertNil(bare.wrapperKey)
        XCTAssertEqual(bare.items.first?.id, "100")
        let legacy = try FanboxFixtures.decodeBody(FanboxPlanListBody.self, #"{"supportingPlans":[{"id":"1","fee":100,"creatorId":"x"}]}"#)
        XCTAssertEqual(legacy.wrapperKey, "supportingPlans")
        XCTAssertEqual(legacy.items.first?.fee, 100)

        let creatorsWrapped = try FanboxFixtures.decodeBody(FanboxCreatorListBody.self, #"{"creators":[\#(FanboxFixtures.creator)]}"#)
        let creatorsBare = try FanboxFixtures.decodeBody(FanboxCreatorListBody.self, "[\(FanboxFixtures.creator)]")
        XCTAssertEqual(creatorsWrapped.items.first?.creatorId, "alice")
        XCTAssertEqual(creatorsBare.items.first?.creatorId, "alice")

        let postsWrapped = try FanboxFixtures.decodeBody(FanboxCreatorPostListBody.self, #"{"posts":[{"id":"1","isPinned":true}]}"#)
        let postsBare = try FanboxFixtures.decodeBody(FanboxCreatorPostListBody.self, #"[{"id":"1"},{"id":"2"}]"#)
        let postsOld = try FanboxFixtures.decodeBody(FanboxCreatorPostListBody.self, #"{"items":[{"id":"1"}],"nextUrl":null}"#)
        XCTAssertEqual(postsWrapped.items.first?.isPinned, true)
        XCTAssertEqual(postsBare.items.count, 2)
        XCTAssertEqual(postsOld.items.count, 1)

        let pagesWrapped = try FanboxFixtures.decodeBody(FanboxPaginateCreatorBody.self, #"{"pageUrls":["https://api.fanbox.cc/post.listCreator?creatorId=a&limit=10"]}"#)
        let pagesBare = try FanboxFixtures.decodeBody(FanboxPaginateCreatorBody.self, #"["u1","u2"]"#)
        XCTAssertEqual(pagesWrapped.pageUrls.count, 1)
        XCTAssertEqual(pagesBare.pageUrls, ["u1", "u2"])

        let paymentsBare = try FanboxFixtures.decodeBody(FanboxPaymentListBody.self, #"[{"id":1,"paidAmount":100,"paymentDatetime":"2026-01-01T00:00:00+09:00"}]"#)
        XCTAssertEqual(paymentsBare.items.first?.id, "1")

        let taggedAsPosts = try FanboxFixtures.decodeBody(FanboxPostListBody.self, #"{"count":1,"posts":[{"id":"9"}],"nextUrl":null}"#)
        XCTAssertEqual(taggedAsPosts.items.first?.id, "9")
        XCTAssertEqual(taggedAsPosts.count, 1)
    }

    func testPostInfoCurrentAndLegacyShapes() throws {
        let current = try FanboxFixtures.decodeBody(FanboxPostInfoBody.self, FanboxFixtures.articlePost)
        XCTAssertTrue(current.isWrapped)
        XCTAssertEqual(current.post.id, "6001")
        XCTAssertEqual(current.post.body?.imageMap?["img1"]?.height, 800)
        XCTAssertNil(current.post.body?.fileMap?["nope"])
        let legacy = try FanboxFixtures.decodeBody(FanboxPostInfoBody.self, FanboxFixtures.legacyTextPost)
        XCTAssertFalse(legacy.isWrapped)
        XCTAssertEqual(legacy.post.type, "text")
        XCTAssertNil(legacy.post.user, "missing optional fields decode as nil")
    }

    func testArticleWithoutEmbedMapAndEmptyMapAsArray() throws {
        let body = try FanboxFixtures.decodeBody(FanboxPostInfoBody.self, #"""
        {"post":{"id":"1","type":"article","body":{"blocks":[{"type":"p","text":"a"}],"imageMap":[],"fileMap":{},"urlEmbedMap":{}}}}
        """#)
        XCTAssertEqual(body.post.body?.imageMap?.count, 0)
        XCTAssertNil(body.post.body?.embedMap)
        let detail = try XCTUnwrap(FanboxAdapter.postDetail(body.post))
        XCTAssertEqual(detail.blocks.map(\.text), ["a"])
    }

    func testCountBodies() throws {
        XCTAssertEqual(try FanboxFixtures.decodeBody(FanboxCountBody.self, "7").count, 7)
        XCTAssertEqual(try FanboxFixtures.decodeBody(FanboxCountBody.self, #"{"count":"3"}"#).count, 3)
    }

    func testCommentListLegacyFlatShape() throws {
        let flat = try FanboxFixtures.decodeBody(FanboxCommentListBody.self, #"{"items":[{"id":"1","body":"x"}],"nextUrl":null}"#)
        XCTAssertEqual(flat.items.first?.id, "1")
        let nullList = try FanboxFixtures.decodeBody(FanboxCommentListBody.self, #"{"viewMode":"CLOSED","commentList":null}"#)
        XCTAssertTrue(nullList.items.isEmpty)
    }

    // MARK: Schema description

    func testKnownSchemaPaths() {
        let schema = FanboxPostInfoBody.responseSchema
        XCTAssertEqual(schema["body"], ["post"])
        XCTAssertTrue(schema["body.post"]?.contains("coverImageUrl") ?? false)
        XCTAssertTrue(schema["body.post.user"]?.contains("iconUrl") ?? false)
        XCTAssertTrue(schema["body.post.body.blocks[]"]?.contains("urlEmbedId") ?? false)
        XCTAssertTrue(schema["body.post.body.imageMap{}"]?.contains("thumbnailUrl") ?? false)
        XCTAssertTrue(schema["body.post.body.urlEmbedMap{}.postInfo"]?.contains("feeRequired") ?? false)
        XCTAssertTrue(schema["body.post.body.blocks[].styles[]"]?.contains("offset") ?? false)

        let plans = FanboxPlanListBody.responseSchema
        XCTAssertTrue(plans["body.plans[]"]?.contains("paymentMethod") ?? false)
        XCTAssertTrue(plans["body[]"]?.contains("fee") ?? false, "legacy bare array path")
        let comments = FanboxCommentListBody.responseSchema
        XCTAssertTrue(comments["body.commentList.items[].replies[]"]?.contains("rootCommentId") ?? false)
        XCTAssertNil(comments["body.commentList.items[].replies[].replies[]"], "recursion stops after one level")
    }

    // MARK: Metadata HTML

    func testMetadataParsing() throws {
        let metadata = try FanboxMetadataParser.parse(html: FanboxFixtures.metadataHTML)
        XCTAssertEqual(metadata.csrfToken, "tok-fresh-123")
        XCTAssertEqual(metadata.user?.userId, "11")
        XCTAssertEqual(metadata.user?.creatorId, "alice")
        XCTAssertEqual(metadata.user?.name, "Alice & Co > 1")
        XCTAssertEqual(metadata.user?.planCount, 2)
        XCTAssertEqual(metadata.apiUrl, "https://api.fanbox.cc")

        let loggedOut = try FanboxMetadataParser.parse(html: FanboxFixtures.loggedOutMetadataHTML)
        XCTAssertNil(loggedOut.user?.userId)
        XCTAssertThrowsError(try FanboxAdapter.user(loggedOut)) { XCTAssertEqual($0 as? RemoteError, .unauthorized) }
        XCTAssertThrowsError(try FanboxMetadataParser.parse(html: "<html><title>Just a moment...</title></html>"))
        XCTAssertEqual(FanboxMetadataParser.unescapeEntities("&#x41;&#66;&lt;&unknown;"), "AB<&unknown;")
    }

    // MARK: Multipart

    func testMultipartEncoding() throws {
        var form = MultipartFormData(boundary: "B")
        form.addField(name: "postId", value: "1")
        form.addData(name: "file", data: Data("xyz".utf8), fileName: "a.txt", mimeType: "text/plain")
        let body = String(data: try form.encodedData(), encoding: .utf8)
        XCTAssertEqual(body, "--B\r\nContent-Disposition: form-data; name=\"postId\"\r\n\r\n1\r\n"
                       + "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nxyz\r\n--B--\r\n")
        XCTAssertEqual(try form.contentLength(), Int64(try form.encodedData().count))
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=B")

        let dir = FileManager.default.temporaryDirectory
        let source = dir.appendingPathComponent("fanbox-mp-\(UUID().uuidString).png")
        try Data(repeating: 7, count: 300_000).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        var fileForm = MultipartFormData(boundary: "C")
        fileForm.addFile(name: "image", fileURL: source)
        let out = try fileForm.writeToTemporaryFile()
        defer { try? FileManager.default.removeItem(at: out) }
        let written = try Data(contentsOf: out)
        XCTAssertEqual(Int64(written.count), try fileForm.contentLength())
        XCTAssertTrue(String(decoding: written.prefix(200), as: UTF8.self).contains("Content-Type: image/png"))
    }

    func testCursorRoundTrip() {
        for cursor in [FanboxCursor.nextURL("https://api.fanbox.cc/post.listHome?limit=10&maxId=1"), .creatorPage(index: 3, url: "u"),
                       .offset(40), .page(2)] {
            XCTAssertEqual(FanboxCursor(encoded: cursor.encoded), cursor)
        }
        XCTAssertNil(FanboxCursor(encoded: "garbage"))
        XCTAssertNil(FanboxCursor(encoded: nil))
        XCTAssertEqual(FanboxCursor.queryValue("offset", in: "https://api.fanbox.cc/post.getComments?postId=1&offset=20&limit=20"), "20")
    }
}

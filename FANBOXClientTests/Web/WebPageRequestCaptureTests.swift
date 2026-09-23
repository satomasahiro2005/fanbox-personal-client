import XCTest
import WebKit
@testable import FANBOXClient

final class WebPageRequestCaptureTests: XCTestCase {
    func testParsesAStructureOnlyMessage() throws {
        let body: [String: Any] = [
            "via": "xhr", "method": "post", "url": "/post.uploadImage?postId=1", "status": 200, "ct": "application/json",
            "body": ["kind": "formdata", "fields": ["postId"], "files": ["file:image/png:12345"], "jsonKeys": []],
            "responseKeys": ["imageId", "url"], "ms": 321,
        ]
        let c = try XCTUnwrap(WebPageRequestCapture.parse(body))
        XCTAssertEqual(c.method, "POST")
        XCTAssertEqual(c.bodyKind, "formdata")
        XCTAssertEqual(c.files, ["file:image/png:12345"])
        XCTAssertEqual(c.responseKeys, ["imageId", "url"])
        let entry = WebPageRequestCapture.entry(for: c, accountID: "a1", pageURL: URL(string: "https://www.fanbox.cc/manage/posts/1"))
        XCTAssertEqual(entry.kind, .request)
        XCTAssertEqual(entry.endpoint, "https://www.fanbox.cc/post.uploadImage?postId=1")
        XCTAssertTrue(entry.requestHeaders.contains("# form fields: postId"))
        XCTAssertTrue(entry.requestHeaders.contains("file:image/png:12345"))
        XCTAssertTrue(entry.responseHeaders.contains("imageId"))
    }

    func testRejectsMalformedMessagesAndCapsLists() {
        XCTAssertNil(WebPageRequestCapture.parse("not a dictionary"))
        XCTAssertNil(WebPageRequestCapture.parse(["method": "GET"]))
        let many = (0..<500).map { "k\($0)" }
        let c = WebPageRequestCapture.parse(["method": "GET", "url": "https://api.fanbox.cc/x", "responseKeys": many])
        XCTAssertEqual(c?.responseKeys.count, WebPageRequestCapture.maxNames)
    }

    func testOnlyFanboxAndPixivOriginsAreAccepted() {
        XCTAssertTrue(WebPageRequestCapture.acceptsOrigin(host: "www.fanbox.cc"))
        XCTAssertTrue(WebPageRequestCapture.acceptsOrigin(host: "accounts.pixiv.net"))
        XCTAssertFalse(WebPageRequestCapture.acceptsOrigin(host: "evil-fanbox.cc"))
        XCTAssertFalse(WebPageRequestCapture.acceptsOrigin(host: "example.com"))
        XCTAssertFalse(WebPageRequestCapture.acceptsOrigin(host: nil))
    }

    func testSecretsInCapturedURLsAreRedacted() throws {
        let c = try XCTUnwrap(WebPageRequestCapture.parse(["method": "GET", "url": "https://api.fanbox.cc/x?token=abc123secret"]))
        let entry = WebPageRequestCapture.entry(for: c, accountID: "a1", pageURL: nil)
        XCTAssertFalse(entry.endpoint.contains("abc123secret"), entry.endpoint)
    }

    /// The injected script must parse (a syntax error would silently disable the capture).
    @MainActor
    func testCaptureScriptIsValidJavaScript() async throws {
        let webView = WKWebView()
        let result = try await webView.evaluateJavaScript("typeof new Function(\(Self.jsString(WebPageRequestCapture.source)))")
        XCTAssertEqual(result as? String, "function")
    }

    private static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let array = String(data: data, encoding: .utf8)!
        return String(array.dropFirst().dropLast())
    }
}

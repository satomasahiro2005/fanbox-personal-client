import XCTest
@testable import FANBOXClient

final class WebPageMetadataTests: XCTestCase {
    private func scriptResult(metadata: String?, nextData: String? = nil, ua: String = "Mozilla/5.0 Test") -> String {
        var object: [String: Any] = ["userAgent": ua, "href": "https://www.fanbox.cc/"]
        object["metadata"] = metadata ?? NSNull()
        object["nextData"] = nextData ?? NSNull()
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    func testParsesLoggedInMetadata() {
        let meta = #"{"csrfToken":"abc123","context":{"user":{"isLoggedIn":true,"userId":"4242","name":"Alice","iconUrl":"https://example.test/a.png","creatorId":"alice"}}}"#
        let parsed = WebPageMetadata.fromScriptResult(scriptResult(metadata: meta))
        XCTAssertEqual(parsed?.userAgent, "Mozilla/5.0 Test")
        XCTAssertEqual(parsed?.csrfToken, "abc123")
        XCTAssertEqual(parsed?.isLoggedIn, true)
        XCTAssertEqual(parsed?.user, WebLoginMetadata(pixivUserID: "4242", name: "Alice", iconURL: "https://example.test/a.png", creatorID: "alice"))
        XCTAssertEqual(parsed?.user?.remoteUser.pixivUserID, "4242")
        XCTAssertEqual(parsed?.user?.remoteUser.creatorID, "alice")
    }

    func testNumericUserIDAndMissingCreator() {
        let meta = #"{"csrfToken":"t","context":{"user":{"userId":98765,"name":"Bob","iconUrl":null}}}"#
        let parsed = WebPageMetadata.fromScriptResult(scriptResult(metadata: meta))
        XCTAssertEqual(parsed?.user?.pixivUserID, "98765")
        XCTAssertNil(parsed?.user?.creatorID)
        XCTAssertNil(parsed?.user?.iconURL)
        XCTAssertEqual(parsed?.isLoggedIn, true)
    }

    func testLoggedOutMetadataHasNoUser() {
        let meta = #"{"csrfToken":"anon","context":{"user":{"isLoggedIn":false,"userId":null,"name":null}}}"#
        let parsed = WebPageMetadata.fromScriptResult(scriptResult(metadata: meta))
        XCTAssertEqual(parsed?.csrfToken, "anon")
        XCTAssertEqual(parsed?.isLoggedIn, false)
        XCTAssertNil(parsed?.user)
    }

    func testMissingOrBrokenMetadata() {
        let none = WebPageMetadata.fromScriptResult(scriptResult(metadata: nil))
        XCTAssertNotNil(none)
        XCTAssertNil(none?.user)
        XCTAssertNil(none?.csrfToken)
        let broken = WebPageMetadata.fromScriptResult(scriptResult(metadata: "{not json"))
        XCTAssertNil(broken?.user)
        XCTAssertNil(WebPageMetadata.fromScriptResult("garbage"))
    }

    func testNextDataFallbackUsesOnlyLoginUserKeys() {
        // Creator objects also carry userId + name: they must NOT be taken as the logged-in user.
        let next = #"{"props":{"pageProps":{"creator":{"user":{"userId":"1","name":"Creator"}},"context":{"user":{"userId":"555","name":"Me"}},"csrfToken":"next-token"}}}"#
        let parsed = WebPageMetadata.fromScriptResult(scriptResult(metadata: nil, nextData: next))
        XCTAssertEqual(parsed?.user?.pixivUserID, "555")
        XCTAssertEqual(parsed?.user?.name, "Me")
        XCTAssertEqual(parsed?.csrfToken, "next-token")

        let onlyCreator = #"{"props":{"creator":{"user":{"userId":"1","name":"Creator"}}}}"#
        let none = WebPageMetadata.fromScriptResult(scriptResult(metadata: nil, nextData: onlyCreator))
        XCTAssertNil(none?.user)

        let currentUser = #"{"props":{"currentUser":{"userId":"77","name":"Viewer"}}}"#
        XCTAssertEqual(WebPageMetadata.fromScriptResult(scriptResult(metadata: nil, nextData: currentUser))?.user?.pixivUserID, "77")
    }

    func testMetadataWinsOverNextData() {
        let meta = #"{"csrfToken":"meta-token","context":{"user":{"userId":"1","name":"Meta"}}}"#
        let next = #"{"context":{"user":{"userId":"2","name":"Next"}},"csrfToken":"next-token"}"#
        let parsed = WebPageMetadata.fromScriptResult(scriptResult(metadata: meta, nextData: next))
        XCTAssertEqual(parsed?.user?.pixivUserID, "1")
        XCTAssertEqual(parsed?.csrfToken, "meta-token")
    }

    func testInspectorScriptDoesNotSendQueryStrings() {
        // The page URL reported back is origin + path only (queries may carry tokens).
        XCTAssertTrue(WebPageInspector.script.contains("location.origin + location.pathname"))
        XCTAssertFalse(WebPageInspector.script.contains("document.cookie"))
    }
}

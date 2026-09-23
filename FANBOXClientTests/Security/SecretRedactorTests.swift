import XCTest
@testable import FANBOXClient

final class SecretRedactorTests: XCTestCase {
    private let R = SecretRedactor.placeholder

    // MARK: Headers

    func testSensitiveHeadersAreRedactedOthersKept() {
        let headers = [
            "Cookie": "FANBOXSESSID=12345_secretvalue; p_ab_id=1",
            "Set-Cookie": "FANBOXSESSID=abc; Domain=.fanbox.cc",
            "Authorization": "Bearer abc.def",
            "Proxy-Authorization": "Basic Zm9vOmJhcg==",
            "X-CSRF-Token": "csrf-secret",
            "x-xsrf-token": "xsrf-secret",
            "X-Session-Hint": "s",
            "X-My-Password": "p",
            "X-Client-Secret": "s",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "Mozilla/5.0",
            "Referer": "https://www.fanbox.cc/?token=leak",
        ]
        let out = SecretRedactor.redactHeaders(headers)
        for name in ["Cookie", "Set-Cookie", "Authorization", "Proxy-Authorization", "X-CSRF-Token", "x-xsrf-token", "X-Session-Hint",
                     "X-My-Password", "X-Client-Secret"] {
            XCTAssertEqual(out[name], R, name)
        }
        XCTAssertEqual(out["Accept"], "application/json")
        XCTAssertEqual(out["Content-Type"], "application/json")
        XCTAssertEqual(out["User-Agent"], "Mozilla/5.0")
        XCTAssertEqual(out["Referer"], "https://www.fanbox.cc/?token=\(R)")
    }

    func testFormatHeadersUsesSpecDisplay() {
        let text = SecretRedactor.formatHeaders(["Cookie": "FANBOXSESSID=abc", "X-CSRF-Token": "t0k3n", "Accept": "*/*"])
        XCTAssertEqual(text, "Accept: */*\nCookie: <REDACTED>\nX-CSRF-Token: <REDACTED>")
    }

    // MARK: URLs

    func testURLQueryValuesRedactedNamesKept() {
        XCTAssertEqual(SecretRedactor.redactURLString("https://api.fanbox.cc/post.info?postId=1&token=abc"),
                       "https://api.fanbox.cc/post.info?postId=1&token=\(R)")
        let url = URL(string: "https://x.example/cb?access_token=a1&csrfToken=b2&sessid=c3&api_key=d4&X-Amz-Signature=e5&code=f6&password=g7&keyword=cats&author=me&limit=10")!
        let out = SecretRedactor.redactURL(url)
        for secret in ["a1", "b2", "c3", "d4", "e5", "f6", "g7"] {
            XCTAssertFalse(out.contains("=\(secret)"), "leaked \(secret) in \(out)")
        }
        XCTAssertTrue(out.contains("access_token=\(R)"))
        XCTAssertTrue(out.contains("keyword=cats"))
        XCTAssertTrue(out.contains("author=me"))
        XCTAssertTrue(out.contains("limit=10"))
    }

    func testURLUserInfoAndFragmentRedacted() {
        XCTAssertEqual(SecretRedactor.redactURLString("https://user:pass@example.com/path?a=1"), "https://\(R)@example.com/path?a=1")
        XCTAssertEqual(SecretRedactor.redactURLString("https://example.com/cb#access_token=zzz&state=1"),
                       "https://example.com/cb#access_token=\(R)&state=1")
    }

    func testFANBOXSESSIDInURL() {
        let out = SecretRedactor.redactURLString("https://www.fanbox.cc/?FANBOXSESSID=12345_abcdef&x=1")
        XCTAssertFalse(out.contains("12345_abcdef"))
        XCTAssertTrue(out.contains("FANBOXSESSID=\(R)"))
        XCTAssertTrue(out.contains("x=1"))
    }

    func testURLWithoutSecretsIsUnchanged() {
        let s = "https://api.fanbox.cc/post.listCreator?creatorId=abc&maxPublishedDatetime=2024-09-24%2012%3A00%3A00&maxId=1234567&limit=10"
        XCTAssertEqual(SecretRedactor.redactURLString(s), s)
    }

    // MARK: Free text

    func testFANBOXSESSIDInTextAndCookieHeaderLine() {
        let text = "sending p_ab_id=1; FANBOXSESSID=12345_abcdef; privacy_policy_agreement=0"
        let out = SecretRedactor.redact(text)
        XCTAssertFalse(out.contains("12345_abcdef"))
        XCTAssertTrue(out.contains("FANBOXSESSID=\(R)"))
        XCTAssertTrue(out.contains("p_ab_id=1"))

        XCTAssertEqual(SecretRedactor.redact("Cookie: FANBOXSESSID=abc; other=1"), "Cookie: \(R)")
        XCTAssertEqual(SecretRedactor.redact("Set-Cookie: FANBOXSESSID=abc; Path=/"), "Set-Cookie: \(R)")
        XCTAssertEqual(SecretRedactor.redact("FANBOXSESSID: 999_zzz"), "FANBOXSESSID: \(R)")
        XCTAssertEqual(SecretRedactor.redact("GET /\nCookie: a=b\nAccept: */*"), "GET /\nCookie: \(R)\nAccept: */*")
    }

    func testAuthorizationBearerAndCSRF() {
        XCTAssertEqual(SecretRedactor.redact("Authorization: Bearer abc.def-ghi"), "Authorization: \(R)")
        XCTAssertEqual(SecretRedactor.redact("using Bearer abc.def-ghi now"), "using Bearer \(R) now")
        XCTAssertEqual(SecretRedactor.redact("X-CSRF-Token: 0123abcd"), "X-CSRF-Token: \(R)")
        XCTAssertEqual(SecretRedactor.redact(#"{"csrfToken":"0123abcd","x":1}"#), #"{"csrfToken":"<REDACTED>","x":1}"#)
        let html = #"<meta name="metadata" content="{&quot;urlContext&quot;:{},&quot;csrfToken&quot;:&quot;deadbeef1234&quot;}">"#
        let out = SecretRedactor.redact(html)
        XCTAssertFalse(out.contains("deadbeef1234"))
        XCTAssertTrue(out.contains("csrfToken&quot;:&quot;\(R)&quot;"))
        XCTAssertEqual(SecretRedactor.redact("csrfToken = 'abc123'"), "csrfToken = \(R)")
    }

    func testPasswordAndCVC() {
        XCTAssertEqual(SecretRedactor.redact("password=hunter2&user=me"), "password=\(R)&user=me")
        XCTAssertEqual(SecretRedactor.redact("cvc: 123"), "cvc: \(R)")
        XCTAssertEqual(SecretRedactor.redact("CVV=4567"), "CVV=\(R)")
        XCTAssertEqual(SecretRedactor.redact("security code 987"), "security code \(R)")
        XCTAssertEqual(SecretRedactor.redact("セキュリティコード: 321"), "セキュリティコード: \(R)")
    }

    func testCardNumbersWithLuhn() {
        XCTAssertTrue(SecretRedactor.luhnValid("4111111111111111"))
        XCTAssertFalse(SecretRedactor.luhnValid("4111111111111112"))

        for card in ["4111 1111 1111 1111", "4111-1111-1111-1111", "4111111111111111"] {
            let out = SecretRedactor.redact("card \(card) end")
            XCTAssertEqual(out, "card <REDACTED CARD ••••1111> end", card)
        }
        XCTAssertEqual(SecretRedactor.redact("amex 378282246310005."), "amex <REDACTED CARD ••••0005>.")
        // A card preceded by another number group is still found (sub-span Luhn check).
        XCTAssertFalse(SecretRedactor.redact("order 12 4111 1111 1111 1111").contains("4111 1111"))
        // Not Luhn-valid → kept.
        XCTAssertEqual(SecretRedactor.redact("n 4111111111111112"), "n 4111111111111112")
        XCTAssertEqual(SecretRedactor.redact("id 1234567890123"), "id 1234567890123")
    }

    func testNoFalsePositivesOnOrdinaryNumbers() {
        let samples = [
            "postId 1234567",
            "posts 1234567 7654321 2345678",
            "¥6,500 / 500円プラン",
            "2024-09-24 12:34:56",
            "090-1234-5678",
            "https://www.fanbox.cc/@creator/posts/1234567",
            "https://twitter.com/x/status/4111111111111111",
            "fee: 1000, count: 42",
            "keyword=cats author=me",
        ]
        for s in samples {
            XCTAssertEqual(SecretRedactor.redact(s), s, s)
        }
    }

    func testRedactIsIdempotent() {
        let samples = [
            "Cookie: FANBOXSESSID=abc", "X-CSRF-Token: t", "password=x", "token: y", "card 4111 1111 1111 1111",
            #"{"csrfToken" : "abc", "password": 12}"#, "Bearer abc", "cvc 123",
        ]
        for s in samples {
            let once = SecretRedactor.redact(s)
            XCTAssertEqual(SecretRedactor.redact(once), once, s)
        }
    }

    // MARK: Bodies

    func testJSONBodyRedactedRecursivelyAndPretty() throws {
        let json: [String: Any] = [
            "body": [
                "postId": "1234567",
                "user": ["name": "Alice", "password": "p@ss", "FANBOXSESSID": "sess"],
                "items": [["cardNumber": "4111111111111111", "cvc": "123", "note": "Cookie: a=b"],
                          ["card_number": "5555555555554444", "pan": "4242424242424242", "securityCode": 999]],
                "csrfToken": "tok",
                "accessToken": "at", "refreshToken": "rt",
                "threeDSecure": ["acsURL": "https://acs.example/x", "creq": "c"],
                "3dsTransID": "tid",
                "otp": "908172", "pin": "0000",
                "authorization": "Bearer zzz",
                "cookie": ["FANBOXSESSID": "x"],
                "secret": "s", "fee": 500,
                "title": "hello",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let text = SecretRedactor.redactBody(data, contentType: "application/json; charset=utf-8")
        for leaked in ["p@ss", "\"sess\"", "4111111111111111", "5555555555554444", "4242424242424242", "\"123\"", "999", "\"tok\"", "\"at\"",
                       "\"rt\"", "acs.example", "\"tid\"", "908172", "\"0000\"", "zzz", "a=b"] {
            XCTAssertFalse(text.contains(leaked), "leaked \(leaked)\n\(text)")
        }
        XCTAssertTrue(text.contains("\"postId\" : \"1234567\""), text)
        XCTAssertTrue(text.contains("\"title\" : \"hello\""), text)
        XCTAssertTrue(text.contains("\"fee\" : 500"), text)
        XCTAssertTrue(text.contains("\n"), "pretty printed")
        // Sorted keys: "3dsTransID" < "accessToken" < "authorization".
        let a = try XCTUnwrap(text.range(of: "\"accessToken\""))
        let b = try XCTUnwrap(text.range(of: "\"authorization\""))
        XCTAssertLessThan(a.lowerBound, b.lowerBound)
        // Still valid JSON.
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    func testBodyTruncatedToLimit() {
        let long = String(repeating: "abcdefghij ", count: 1_000)
        let out = SecretRedactor.redactBody(Data(long.utf8), contentType: "text/plain", limit: 100)
        XCTAssertTrue(out.hasPrefix(String(long.prefix(100))))
        XCTAssertTrue(out.contains("truncated"))
        XCTAssertLessThan(out.count, 160)
    }

    func testNonJSONAndBinaryAndFormBodies() {
        let html = #"<html><meta content="{&quot;csrfToken&quot;:&quot;abcdef&quot;}"> FANBOXSESSID=zzz</html>"#
        let htmlOut = SecretRedactor.redactBody(Data(html.utf8), contentType: "text/html")
        XCTAssertFalse(htmlOut.contains("abcdef"))
        XCTAssertFalse(htmlOut.contains("zzz"))

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xFE])
        XCTAssertTrue(SecretRedactor.redactBody(png, contentType: "image/png").hasPrefix("<binary 7 bytes"))
        XCTAssertTrue(SecretRedactor.redactBody(png, contentType: nil).hasPrefix("<binary"))

        let form = "postId=1234567&password=secret1&code=998877&body=hello"
        let formOut = SecretRedactor.redactBody(Data(form.utf8), contentType: "application/x-www-form-urlencoded")
        XCTAssertEqual(formOut, "postId=1234567&password=\(R)&code=\(R)&body=hello")
    }

    func testTotalOnHostileInput() {
        XCTAssertEqual(SecretRedactor.redact(""), "")
        XCTAssertEqual(SecretRedactor.redactURLString(""), "")
        XCTAssertEqual(SecretRedactor.redactBody(Data(), contentType: nil), "")
        _ = SecretRedactor.redact(String(repeating: "=", count: 10_000))
        _ = SecretRedactor.redact(String(repeating: "4", count: 5_000))
        _ = SecretRedactor.redact("🙂 Cookie: 🍪 \u{0} token=\u{FFFF}")
        _ = SecretRedactor.redactURLString("://@@??##==&&")
        _ = SecretRedactor.redactBody(Data("{\"a\": [1, 2, {\"password\": null}]".utf8), contentType: "application/json")
        _ = SecretRedactor.redactBody(Data((0..<4096).map { UInt8($0 % 256) }), contentType: "application/json")
        XCTAssertEqual(SecretRedactor.redactBody(Data("\"just a string token=abc\"".utf8), contentType: "application/json"),
                       "just a string token=\(R)")
        XCTAssertEqual(SecretRedactor.redactBody(Data("42".utf8), contentType: "application/json"), "42")
    }

    func testSensitiveKeyClassification() {
        for key in ["csrfToken", "token", "accessToken", "refresh_token", "password", "cardNumber", "card_number", "pan", "cvc", "cvv",
                    "securityCode", "pin", "FANBOXSESSID", "cookie", "Authorization", "secret", "threeDSecure", "3dsServerTransID", "otp"] {
            XCTAssertTrue(SecretRedactor.isSensitiveJSONKey(key), key)
        }
        for key in ["postId", "title", "creatorId", "authorId", "company", "isPinned", "spinner", "pinnedPosts", "coverImageUrl",
                    "feeRequired", "japan"] {
            XCTAssertFalse(SecretRedactor.isSensitiveJSONKey(key), key)
        }
    }
}

import XCTest
@testable import FANBOXClient

/// CSRF token in every quote encoding, similar latent leaks, and research fidelity (no over-redaction) — SPEC §37 / §38.
final class FixSecurityRedactorTests: XCTestCase {
    private let R = SecretRedactor.placeholder
    private let token = "deadbeef1234cafe"

    // MARK: CSRF token in HTML-entity / escape forms

    func testCSRFTokenInEveryQuoteEncodingIsRedacted() {
        let forms: [String] = [
            "&quot;", "&QUOT;", "&#34;", "&#034;", "&#0034;", "&#x22;", "&#X22;", "&#x0022;", "&apos;", "&#39;", "&#039;", "&#x27;",
            "\\\"", "\\\\\\\"", "\\u0022", "\\U0022", "\\x22", "%22", "%27",
        ]
        for q in forms {
            let json = "{\(q)urlContext\(q):{},\(q)csrfToken\(q):\(q)\(token)\(q),\(q)user\(q):{\(q)userId\(q):\(q)11\(q)}}"
            let html = "<meta name=\"metadata\" content=\"\(json)\">"
            let out = SecretRedactor.redact(html)
            XCTAssertFalse(out.contains(token), "\(q) leaked: \(out)")
            XCTAssertTrue(out.contains(R), q)
            // Fidelity: the rest of the metadata stays readable.
            XCTAssertTrue(out.contains("userId") && out.contains("11"), "\(q) over-redacted: \(out)")
            XCTAssertEqual(SecretRedactor.redact(out), out, "idempotent for \(q)")
            // Display layer (defense in depth) catches it on its own as well.
            XCTAssertFalse(ResearchDisplayRedaction.apply(html).contains(token), "display \(q)")
        }
    }

    func testEncodedColonAndNumericValues() {
        XCTAssertFalse(SecretRedactor.redact("state=%7B%22csrfToken%22%3A%22\(token)%22%7D").contains(token))
        XCTAssertFalse(SecretRedactor.redact("{&#34;csrfToken&#34;&#58;&#34;\(token)&#34;}").contains(token))
        XCTAssertEqual(SecretRedactor.redact("{&quot;pin&quot;:1234,&quot;x&quot;:1}"), "{&quot;pin&quot;:\(R),&quot;x&quot;:1}")
    }

    func testUnquotedKeyWithEncodedQuoteValue() {
        let out = SecretRedactor.redact("window.__DATA__ = {csrfToken:&quot;\(token)&quot;,page:1}")
        XCTAssertFalse(out.contains(token), out)
        XCTAssertTrue(out.contains("page:1"), out)
    }

    /// Fail-safe decode pass: encodings no pattern knows (double-encoded entities, key letters as numeric entities).
    func testDoubleEncodedAndEntityEncodedKeysAreCaught() {
        let doubleEncoded = "content=\"{&amp;quot;csrfToken&amp;quot;:&amp;quot;\(token)&amp;quot;}\""
        XCTAssertFalse(SecretRedactor.redact(doubleEncoded).contains(token))
        let lettersEncoded = "{&#34;&#99;srf&#84;oken&#34;:&#34;\(token)&#34;}"
        XCTAssertFalse(SecretRedactor.redact(lettersEncoded).contains(token))
        let unicodeEscaped = #"{"note":"{\u0022\u0063srfToken\u0022:\u0022"# + token + #"\u0022}"}"#
        XCTAssertFalse(SecretRedactor.redact(unicodeEscaped).contains(token))
    }

    func testHTMLMetaAndHiddenInputTokens() {
        for html in [
            "<meta name=\"csrf-token\" content=\"\(token)\">",
            "<meta content='\(token)' name='csrf-token'>",
            "<input type=\"hidden\" name=\"_token\" value=\"\(token)\">",
            "<input value=\"\(token)\" type=\"hidden\" name=\"authenticity_token\"/>",
            "<meta property=csrfToken content=\"\(token)\">",
        ] {
            let out = SecretRedactor.redact(html)
            XCTAssertFalse(out.contains(token), "leaked: \(out)")
            XCTAssertEqual(SecretRedactor.redact(out), out)
        }
        // Ordinary attributes are untouched.
        let plain = "<meta name=\"description\" content=\"FANBOX の投稿\"><input name=\"q\" value=\"cats\">"
        XCTAssertEqual(SecretRedactor.redact(plain), plain)
    }

    func testQueryParameterCarryingJSONIsScanned() {
        let url = "https://www.fanbox.cc/cb?state=%7B%22csrfToken%22%3A%22\(token)%22%2C%22page%22%3A2%7D&x=1"
        let out = SecretRedactor.redactURLString(url)
        XCTAssertFalse(out.contains(token), out)
        XCTAssertTrue(out.contains("x=1"))
    }

    func testRedactBodyOfMetadataPageWithNumericEntities() {
        let page = "<!DOCTYPE html><html><head><meta name=\"metadata\" content=\"{&#34;csrfToken&#34;:&#34;\(token)&#34;,"
            + "&#34;context&#34;:{&#34;user&#34;:{&#34;userId&#34;:&#34;11&#34;}}}\"><title>pixivFANBOX</title></head></html>"
        let out = SecretRedactor.redactBody(Data(page.utf8), contentType: "text/html; charset=utf-8")
        XCTAssertFalse(out.contains(token))
        XCTAssertTrue(out.contains("pixivFANBOX"))
        XCTAssertTrue(out.contains("&#34;userId&#34;:&#34;11&#34;"), "untouched parts keep their encoding: \(out)")
    }

    // MARK: Header rules on single-line HTML / JS

    func testHeaderNameInsideMinifiedLineDoesNotWipeTheRest() {
        let js = "!function(){var a={cookie:e.cookie,authorization:t};return fetch(u,{headers:a})}();var title=\"after\";"
        let out = SecretRedactor.redact(js)
        XCTAssertTrue(out.contains("var title=\"after\";"), out)
        XCTAssertTrue(out.contains("return fetch(u,{headers:a})"), out)
        let html = "<div>Cookie: 有効</div><p>本文はここから</p><a href=\"/posts/1234567\">続き</a>"
        let htmlOut = SecretRedactor.redact(html)
        XCTAssertTrue(htmlOut.contains("<p>本文はここから</p><a href=\"/posts/1234567\">続き</a>"), htmlOut)
    }

    func testMidLineHeaderValuesAreStillRedacted() {
        let out = SecretRedactor.redact("request failed; Cookie: FANBOXSESSID=\(token); p_ab_id=\(token)x; then retried")
        XCTAssertFalse(out.contains(token), out)
        XCTAssertTrue(out.hasSuffix("then retried"), out)
        let auth = SecretRedactor.redact("curl -H 'Authorization: Basic \(token)' -H 'Accept: */*'")
        XCTAssertFalse(auth.contains(token), auth)
        XCTAssertTrue(auth.contains("Accept: */*"), auth)
        let csrf = SecretRedactor.redact("sent X-CSRF-Token: \(token) with the request")
        XCTAssertFalse(csrf.contains(token), csrf)
        XCTAssertTrue(csrf.contains("with the request"), csrf)
        // Header dumps (line start) keep the whole-line rule.
        XCTAssertEqual(SecretRedactor.redact("> Cookie: a=1; b=2\n> Accept: */*"), "> Cookie: \(R)\n> Accept: */*")
    }

    // MARK: Card numbers vs ids / URLs / timestamps

    func testCardLikeDigitsInURLsIdsAndTimestampsAreKept() {
        let kept = [
            "https://x/4111111111111111.png",
            "id_4111111111111111",
            "file-4111111111111111.jpeg",
            "hash 4111111111111111abc",
            "created 1726000000009",     // Luhn-valid millisecond timestamp (starts with 1)
            "snowflake 1790000000000000009",
        ]
        XCTAssertTrue(SecretRedactor.luhnValid("1726000000009"))
        for s in kept {
            XCTAssertEqual(SecretRedactor.redact(s), s, s)
            XCTAssertEqual(ResearchDisplayRedaction.apply(s), s, "display: \(s)")
        }
        XCTAssertEqual(SecretRedactor.redact("card 4111111111111111"), "card <REDACTED CARD ••••1111>")
        XCTAssertEqual(ResearchDisplayRedaction.apply("card 4111111111111111"), "card \(R)")
        XCTAssertEqual(ResearchDisplayRedaction.apply("jcb 3530111333300000."), "jcb \(R).")
        XCTAssertEqual(ResearchDisplayRedaction.apply("mc 2223003122003222"), "mc \(R)")
    }

    func testDisplayKeepsPlanNamesAfterBasic() {
        for s in ["Basic プラン 500円", "basic plan for supporters", "Basic Membership"] {
            XCTAssertEqual(ResearchDisplayRedaction.apply(s), s)
        }
        XCTAssertFalse(ResearchDisplayRedaction.apply("auth Basic Zm9vOmJhcg==").contains("Zm9vOmJhcg"))
    }

    // MARK: Decoding helper

    func testDecodeEscapes() {
        XCTAssertEqual(SecretRedactor.decodeEscapes("a&quot;b&#34;c&#x22;d&amp;e&lt;f"), "a\"b\"c\"d&e<f")
        XCTAssertEqual(SecretRedactor.decodeEscapes(#"\"x\" \u0041 \x42 \/ \\"#), #""x" A B / \"#)
        XCTAssertNil(SecretRedactor.decodeEscapes("plain text & more"))
        XCTAssertNil(SecretRedactor.decodeEscapes("&unknown; &#xZZ; \\q"))
        _ = SecretRedactor.decodeEscapes("&#xD800; \\uD800 &#99999999999; &")
    }

    func testNoFalsePositivesOnOrdinaryHTML() {
        let html = "<p>It&#39;s &quot;great&quot; &amp; fun</p><a href=\"https://www.fanbox.cc/@creator/posts/1234567?utm=a&amp;b=c\">"
            + "link</a><script>var o={&quot;title&quot;:&quot;x&quot;,&quot;count&quot;:3}</script>"
        XCTAssertEqual(SecretRedactor.redact(html), html)
    }
}

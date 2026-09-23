import XCTest
@testable import FANBOXClient

final class NewsletterExcerptTests: XCTestCase {
    func testCollapsesWhitespaceAndNewlines() {
        XCTAssertEqual(NewsletterExcerpt.make("  いつも\n\n支援ありがとう\tございます  "), "いつも 支援ありがとう ございます")
        XCTAssertEqual(NewsletterExcerpt.make("a\r\nb"), "a b")
        XCTAssertEqual(NewsletterExcerpt.make("全角\u{3000}スペース"), "全角 スペース")
    }

    func testTruncatesWithEllipsis() {
        let body = String(repeating: "あ", count: 100)
        let excerpt = NewsletterExcerpt.make(body, limit: 10)
        XCTAssertEqual(excerpt, String(repeating: "あ", count: 10) + "…")
        // Exactly at the limit: unchanged.
        XCTAssertEqual(NewsletterExcerpt.make("12345", limit: 5), "12345")
        // No trailing space before the ellipsis.
        XCTAssertEqual(NewsletterExcerpt.make("abcd efgh", limit: 5), "abcd…")
    }

    func testGraphemeClustersAreNotSplit() {
        let excerpt = NewsletterExcerpt.make("👨‍👩‍👧‍👦🇯🇵abc", limit: 2)
        XCTAssertEqual(excerpt, "👨‍👩‍👧‍👦🇯🇵…")
    }

    func testEmptyAndLimits() {
        XCTAssertEqual(NewsletterExcerpt.make(""), "")
        XCTAssertEqual(NewsletterExcerpt.make(" \n "), "")
        XCTAssertEqual(NewsletterExcerpt.make("abc", limit: 0), "")
    }

    func testRowTextPlaceholders() {
        XCTAssertEqual(NewsletterExcerpt.rowText(body: "", bodyFetched: false), "本文は未取得です")
        XCTAssertEqual(NewsletterExcerpt.rowText(body: "", bodyFetched: true), "(本文なし)")
        XCTAssertEqual(NewsletterExcerpt.rowText(body: "こんにちは\n元気？", bodyFetched: true), "こんにちは 元気？")
    }
}

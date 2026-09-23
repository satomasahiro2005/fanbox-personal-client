import XCTest
import SwiftUI
@testable import FANBOXClient

final class HomePostTextStylerTests: XCTestCase {
    private func style(_ type: String, _ offset: Int, _ length: Int, size: Int? = nil) -> RemoteTextStyle {
        RemoteTextStyle(type: type, offset: offset, length: length, size: size)
    }

    func testNoStylesIsOnePlainSegment() {
        let segs = PostTextStyler.segments(text: "hello", styles: [])
        XCTAssertEqual(segs, [.init(text: "hello", isBold: false, fontSize: nil)])
        XCTAssertEqual(PostTextStyler.segments(text: "", styles: [style("bold", 0, 3)]), [])
    }

    func testBoldRange() {
        let segs = PostTextStyler.segments(text: "abcdef", styles: [style("bold", 2, 2)])
        XCTAssertEqual(segs, [
            .init(text: "ab", isBold: false, fontSize: nil),
            .init(text: "cd", isBold: true, fontSize: nil),
            .init(text: "ef", isBold: false, fontSize: nil),
        ])
    }

    func testFontSizeAndOverlapWithBold() {
        let segs = PostTextStyler.segments(text: "0123456789",
                                           styles: [style("fontSize", 0, 6, size: 24), style("bold", 4, 4)])
        XCTAssertEqual(segs, [
            .init(text: "0123", isBold: false, fontSize: 24),
            .init(text: "45", isBold: true, fontSize: 24),
            .init(text: "67", isBold: true, fontSize: nil),
            .init(text: "89", isBold: false, fontSize: nil),
        ])
    }

    func testFontSizeClampingAndDefault() {
        XCTAssertEqual(PostTextStyler.segments(text: "ab", styles: [style("fontSize", 0, 2, size: 400)]).first?.fontSize,
                       PostTextStyler.maxFontSize)
        XCTAssertEqual(PostTextStyler.segments(text: "ab", styles: [style("fontSize", 0, 2, size: 1)]).first?.fontSize,
                       PostTextStyler.minFontSize)
        XCTAssertEqual(PostTextStyler.segments(text: "ab", styles: [style("fontSize", 0, 2)]).first?.fontSize,
                       PostTextStyler.defaultLargeFontSize)
    }

    func testOutOfRangeStylesAreClampedOrIgnored() {
        let text = "abc"
        // Negative offset → clamped to 0; length past the end → clamped.
        XCTAssertEqual(PostTextStyler.segments(text: text, styles: [style("bold", -5, 7)]),
                       [.init(text: "ab", isBold: true, fontSize: nil), .init(text: "c", isBold: false, fontSize: nil)])
        XCTAssertEqual(PostTextStyler.segments(text: text, styles: [style("bold", 2, 1000)]),
                       [.init(text: "ab", isBold: false, fontSize: nil), .init(text: "c", isBold: true, fontSize: nil)])
        // Entirely outside / zero or negative length / absurd values → ignored, text intact.
        for bad in [style("bold", 3, 2), style("bold", 100, 1), style("bold", 1, 0), style("bold", 1, -4),
                    style("bold", Int.max, Int.max), style("bold", Int.min, 1)] {
            let segs = PostTextStyler.segments(text: text, styles: [bad])
            XCTAssertEqual(segs, [.init(text: "abc", isBold: false, fontSize: nil)], "\(bad)")
        }
        // Unknown style type is ignored.
        XCTAssertEqual(PostTextStyler.segments(text: text, styles: [style("italic", 0, 3)]),
                       [.init(text: "abc", isBold: false, fontSize: nil)])
    }

    func testOffsetsAreUTF16AndNeverSplitSurrogatePairs() {
        // "😀" is 2 UTF-16 units. JS offsets: "a"=0, "😀"=1..2, "b"=3.
        let text = "a😀b"
        XCTAssertEqual(PostTextStyler.segments(text: text, styles: [style("bold", 3, 1)]),
                       [.init(text: "a😀", isBold: false, fontSize: nil), .init(text: "b", isBold: true, fontSize: nil)])
        // A range ending inside the pair keeps the emoji whole.
        let segs = PostTextStyler.segments(text: text, styles: [style("bold", 1, 1)])
        XCTAssertEqual(segs.map(\.text).joined(), text)
        XCTAssertEqual(segs, [.init(text: "a", isBold: false, fontSize: nil), .init(text: "😀", isBold: true, fontSize: nil),
                              .init(text: "b", isBold: false, fontSize: nil)])
        // Japanese text (BMP) offsets.
        XCTAssertEqual(PostTextStyler.segments(text: "こんにちは", styles: [style("bold", 2, 3)]).last,
                       .init(text: "にちは", isBold: true, fontSize: nil))
    }

    func testSegmentsAlwaysReassembleText() {
        let text = "FANBOX 投稿 🎨 テスト\nnext line"
        let styles = [style("bold", 0, 6), style("fontSize", 3, 12, size: 20), style("bold", 9, 50), style("bold", -3, 2)]
        XCTAssertEqual(PostTextStyler.segments(text: text, styles: styles).map(\.text).joined(), text)
    }

    func testDecodeStylesJSON() {
        let json = #"[{"type":"bold","offset":1,"length":2},{"type":"fontSize","offset":0,"length":1,"size":20}]"#
        let styles = PostTextStyler.decodeStyles(json)
        XCTAssertEqual(styles.count, 2)
        XCTAssertEqual(styles[1].size, 20)
        XCTAssertEqual(PostTextStyler.decodeStyles(nil), [])
        XCTAssertEqual(PostTextStyler.decodeStyles(""), [])
        XCTAssertEqual(PostTextStyler.decodeStyles("{not json"), [])
        XCTAssertEqual(PostTextStyler.decodeStyles(PostTextStyler.encodeStyles(styles)), styles)
    }

    func testAttributedStringMarksBoldAndKeepsText() {
        let json = PostTextStyler.encodeStyles([style("bold", 0, 2)])
        let attributed = PostTextStyler.attributedString(text: "abcd", stylesJSON: json)
        XCTAssertEqual(String(attributed.characters), "abcd")
        let boldText = attributed.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(attributed[$0.range].characters) }
        XCTAssertEqual(boldText, ["ab"])
    }

    func testAttributedStringWithMalformedJSONStillRendersText() {
        let attributed = PostTextStyler.attributedString(text: "plain text", stylesJSON: "garbage")
        XCTAssertEqual(String(attributed.characters), "plain text")
    }

    func testLinkDetection() {
        let attributed = PostTextStyler.attributedString(text: "see https://example.com/a now", styles: [])
        let links = attributed.runs.compactMap(\.link)
        XCTAssertEqual(links, [URL(string: "https://example.com/a")!])
        XCTAssertTrue(PostTextStyler.attributedString(text: "no links", styles: []).runs.allSatisfy { $0.link == nil })
    }
}

import Foundation
import SwiftUI

/// Converts a paragraph's text + FANBOX style ranges (`PostBlock.stylesJSON` = `[RemoteTextStyle]`) into an
/// `AttributedString` (SPEC §6 native rendering).
///
/// Offsets / lengths are interpreted as UTF-16 code units (JavaScript string indices, which is what the web editor
/// produces). Every range is clamped to the text, so malformed or out-of-range styles never crash and never drop text.
enum PostTextStyler {
    /// A run of text with uniform style.
    struct Segment: Equatable, Sendable {
        var text: String
        var isBold: Bool
        /// Point size requested by a "fontSize" style (nil = body size).
        var fontSize: Int?
    }

    static let minFontSize = 10
    static let maxFontSize = 40
    /// Size used for a "fontSize" style without an explicit size.
    static let defaultLargeFontSize = 22

    // MARK: - Decoding

    static func decodeStyles(_ json: String?) -> [RemoteTextStyle] {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([RemoteTextStyle].self, from: data)) ?? []
    }

    static func encodeStyles(_ styles: [RemoteTextStyle]) -> String? {
        guard !styles.isEmpty, let data = try? JSONEncoder().encode(styles) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Segmentation (pure)

    /// Splits `text` into uniformly styled segments. Unknown style types are ignored.
    /// The concatenation of all segment texts is always exactly `text`.
    static func segments(text: String, styles: [RemoteTextStyle]) -> [Segment] {
        let utf16 = Array(text.utf16)
        let count = utf16.count
        guard count > 0 else { return [] }

        var bold = [Bool](repeating: false, count: count)
        var size = [Int?](repeating: nil, count: count)

        for style in styles {
            guard let range = clampedRange(offset: style.offset, length: style.length, count: count) else { continue }
            switch style.type.lowercased() {
            case "bold":
                for i in range { bold[i] = true }
            case "fontsize", "font_size", "size":
                let s = clampFontSize(style.size)
                for i in range { size[i] = s }
            default:
                continue
            }
        }

        // Never split a surrogate pair: a low surrogate inherits the style of the preceding high surrogate.
        for i in 1..<max(count, 1) where UTF16.isTrailSurrogate(utf16[i]) && UTF16.isLeadSurrogate(utf16[i - 1]) {
            bold[i] = bold[i - 1]
            size[i] = size[i - 1]
        }

        var result: [Segment] = []
        var start = 0
        for i in 1...count {
            if i == count || bold[i] != bold[start] || size[i] != size[start] {
                let slice = Array(utf16[start..<i])
                let piece = String(decoding: slice, as: UTF16.self)
                result.append(Segment(text: piece, isBold: bold[start], fontSize: size[start]))
                start = i
            }
        }
        return result
    }

    /// Clamps (offset, length) to 0..<count. Returns nil for empty / fully out-of-range styles.
    static func clampedRange(offset: Int, length: Int, count: Int) -> Range<Int>? {
        guard count > 0, length > 0 else { return nil }
        let lower = max(0, offset)
        // Avoid overflow for absurd values.
        let upperUnclamped = offset > Int.max - length ? Int.max : offset + length
        let upper = min(count, upperUnclamped)
        guard lower < upper else { return nil }
        return lower..<upper
    }

    static func clampFontSize(_ size: Int?) -> Int {
        guard let size, size > 0 else { return defaultLargeFontSize }
        return min(maxFontSize, max(minFontSize, size))
    }

    // MARK: - AttributedString

    /// Styled paragraph for SwiftUI `Text`. Bold runs carry `.stronglyEmphasized` and a bold font; fontSize runs a sized font.
    /// URLs in the text become tappable links.
    static func attributedString(text: String, stylesJSON: String?, detectLinks: Bool = true) -> AttributedString {
        attributedString(text: text, styles: decodeStyles(stylesJSON), detectLinks: detectLinks)
    }

    static func attributedString(text: String, styles: [RemoteTextStyle], detectLinks: Bool = true) -> AttributedString {
        var result = AttributedString()
        for segment in segments(text: text, styles: styles) {
            var piece = AttributedString(segment.text)
            if segment.isBold {
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            switch (segment.isBold, segment.fontSize) {
            case (true, let s?): piece.font = .system(size: CGFloat(s), weight: .bold)
            case (false, let s?): piece.font = .system(size: CGFloat(s))
            case (true, nil): piece.font = .body.bold()
            case (false, nil): break
            }
            result.append(piece)
        }
        if detectLinks { addLinks(to: &result) }
        return result
    }

    /// Created once: `NSDataDetector` is expensive to build and immutable (safe to share).
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Adds `.link` to http(s) URLs found in the text.
    static func addLinks(to attributed: inout AttributedString) {
        let plain = String(attributed.characters)
        guard plain.contains("http"), let detector = linkDetector else { return }
        let ns = plain as NSString
        for match in detector.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let stringRange = Range(match.range, in: plain),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(stringRange.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].link = url
        }
    }
}

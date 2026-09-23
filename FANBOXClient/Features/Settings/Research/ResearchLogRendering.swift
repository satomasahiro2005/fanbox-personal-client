import Foundation

/// Everything the Research detail screen shows for one log entry, computed ONCE off the main actor (SPEC §36).
///
/// Redacting a stored body (up to 64k characters) runs ~20 regex passes plus a card scan; pretty-printing JSON parses and
/// re-serializes it. Doing that inside `View.body` blocked the main actor on every evaluation (each background save,
/// each "JSON を整形" toggle). The detail view now builds a `ResearchLogRendering` in a detached task and only switches
/// between cached strings. Bodies are split into line-wise chunks (long single lines — minified HTML / JS — are cut into
/// fixed-size pieces) so a `List` renders only the rows on screen.
struct ResearchLogRendering: Sendable, Equatable {
    struct Chunk: Identifiable, Sendable, Equatable {
        let id: Int
        let text: String
    }

    struct Block: Identifiable, Sendable, Equatable {
        let label: String
        let chunks: [Chunk]
        var id: String { label }
    }

    struct Body: Sendable, Equatable {
        var chunks: [Chunk]
        var truncatedCount: Int
    }

    /// Non-block fields (status, endpoint, method, …, error), all redacted.
    var summary: [ResearchLogFormatter.Field]
    /// Request / response headers (redacted, chunked).
    var headerBlocks: [Block]
    /// Body as stored (redacted, truncated to the display limit).
    var plainBody: Body
    /// Pretty-printed JSON body; nil when the body is not JSON.
    var prettyBody: Body?
    /// Whether the log carries a response body at all.
    var hasBody: Bool
    /// Plain-text rendering for the share sheet (same limit as the screen).
    var shareText: String

    static let bodyLabel = "Safe Response Body"
    /// Characters per rendered row.
    static let chunkCharacterLimit = 2_000

    /// Pure and Sendable: safe to call from a detached task.
    static func make(_ entry: ResearchLogSnapshot, bodyLimit: Int = ResearchLogFormatter.displayBodyLimit) -> ResearchLogRendering {
        let safeBody = ResearchLogFormatter.safe(entry.responseBody)
        let plain = ResearchLogFormatter.truncated(safeBody, limit: bodyLimit)
        let fields = ResearchLogFormatter.fields(for: entry, body: plain)
        let pretty = ResearchLogFormatter.prettyPrintedJSON(safeBody).map {
            ResearchLogFormatter.truncated(ResearchLogFormatter.safe($0), limit: bodyLimit)
        }
        let headerBlocks = fields.filter { $0.isBlock && $0.label != bodyLabel }.map { Block(label: $0.label, chunks: chunks($0.value)) }
        return ResearchLogRendering(
            summary: fields.filter { !$0.isBlock },
            headerBlocks: headerBlocks,
            plainBody: Body(chunks: chunks(plain.text.isEmpty ? "(なし)" : plain.text), truncatedCount: plain.truncatedCount),
            prettyBody: pretty.map { Body(chunks: chunks($0.text), truncatedCount: $0.truncatedCount) },
            hasBody: !entry.responseBody.isEmpty,
            shareText: ResearchLogFormatter.text(for: entry, fields: fields))
    }

    /// Splits text into rows of whole lines, each at most `limit` characters; a longer line is cut into `limit`-sized pieces.
    /// Joining the rows with "\n" gives the original text back, except that cut lines become several rows.
    static func chunks(_ text: String, limit: Int = chunkCharacterLimit) -> [Chunk] {
        let limit = max(1, limit)
        var pieces: [String] = []
        var buffer: [Substring] = []
        var bufferCount = 0
        func flush() {
            guard !buffer.isEmpty else { return }
            pieces.append(buffer.joined(separator: "\n"))
            buffer.removeAll(keepingCapacity: true)
            bufferCount = 0
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = line
            while let cut = rest.index(rest.startIndex, offsetBy: limit, limitedBy: rest.endIndex), cut < rest.endIndex {
                flush()
                pieces.append(String(rest[..<cut]))
                rest = rest[cut...]
            }
            let length = rest.count
            let cost = length + (buffer.isEmpty ? 0 : 1)
            if !buffer.isEmpty, bufferCount + cost > limit { flush() }
            bufferCount += length + (buffer.isEmpty ? 0 : 1)
            buffer.append(rest)
        }
        flush()
        return pieces.enumerated().map { Chunk(id: $0.offset, text: $0.element) }
    }
}

import Foundation

/// Sendable copy of one `ResearchLog` row, taken on the main actor for display / export.
/// Holds the stored (already recorder-redacted) strings; `ResearchLogFormatter` redacts them again before display.
struct ResearchLogSnapshot: Sendable, Equatable, Identifiable {
    var id: String
    var timestamp: Date
    var kind: ResearchLogKind
    var accountID: String?
    /// Local display name of the account (not a secret, but still passed through the redactor when shown).
    var accountName: String?
    var method: String?
    var endpoint: String
    var statusCode: Int?
    var durationMs: Int?
    var priorityRaw: Int?
    var requestHeaders: String
    var responseHeaders: String
    var responseBody: String
    var bytes: Int?
    var errorDescription: String?

    init(id: String = UUID().uuidString, timestamp: Date = .now, kind: ResearchLogKind, accountID: String? = nil,
         accountName: String? = nil, method: String? = nil, endpoint: String, statusCode: Int? = nil, durationMs: Int? = nil,
         priorityRaw: Int? = nil, requestHeaders: String = "", responseHeaders: String = "", responseBody: String = "",
         bytes: Int? = nil, errorDescription: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.accountID = accountID
        self.accountName = accountName
        self.method = method
        self.endpoint = endpoint
        self.statusCode = statusCode
        self.durationMs = durationMs
        self.priorityRaw = priorityRaw
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.bytes = bytes
        self.errorDescription = errorDescription
    }

    @MainActor
    init(_ log: ResearchLog, accountName: String? = nil) {
        self.init(id: log.id, timestamp: log.timestamp, kind: log.kind, accountID: log.accountID, accountName: accountName,
                  method: log.method, endpoint: log.endpoint, statusCode: log.statusCode, durationMs: log.durationMs,
                  priorityRaw: log.priorityRaw, requestHeaders: log.requestHeaders, responseHeaders: log.responseHeaders,
                  responseBody: log.responseBody, bytes: log.bytes, errorDescription: log.errorDescription)
    }
}

/// Pure formatting of Research Mode data (SPEC §36 / §44).
///
/// Every string that originates from a log, a response or an error goes through `safe(_:)`, which runs
/// `SecretRedactor.redact` AGAIN (the recorder already redacted it before storing) and then a second,
/// display-side pass (`ResearchDisplayRedaction`). Defense in depth: a bug in one layer must not leak a secret.
enum ResearchLogFormatter {
    struct Field: Identifiable, Equatable, Sendable {
        let label: String
        let value: String
        /// Long text (headers / bodies) rendered in a monospaced block.
        var isBlock: Bool = false
        var id: String { label }
    }

    /// Default number of body characters shown on screen / put into an export per entry.
    static let displayBodyLimit = 30_000
    static let exportBodyLimit = 8_000

    // MARK: - Redaction

    /// SecretRedactor + display-side redaction. Use for EVERY log-derived string shown or exported.
    static func safe(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return ResearchDisplayRedaction.apply(SecretRedactor.redact(text))
    }

    static func safe(_ text: String?) -> String? {
        text.map { safe($0) }
    }

    // MARK: - Small formatters

    static func statusText(_ code: Int?) -> String {
        guard let code else { return "—" }
        return "\(code)"
    }

    static func durationText(_ ms: Int?) -> String {
        guard let ms else { return "—" }
        if ms >= 1000 { return String(format: "%.2f s", Double(ms) / 1000) }
        return "\(ms) ms"
    }

    static func bytesText(_ bytes: Int?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func priorityText(_ raw: Int?) -> String {
        guard let raw else { return "—" }
        if let p = RequestPriority(rawValue: raw) { return "\(p.displayName) (\(raw))" }
        return "\(raw)"
    }

    /// "2026-09-24 01:32:05.123" in the device time zone (stable, locale-independent).
    static func timestampText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: date)
    }

    /// Status class used for tinting rows.
    enum StatusClass: Equatable, Sendable {
        case success, redirect, clientError, serverError, failed, pending
    }

    static func statusClass(code: Int?, error: String?) -> StatusClass {
        if let code {
            switch code {
            case 200..<300: return .success
            case 300..<400: return .redirect
            case 400..<500: return .clientError
            default: return .serverError
            }
        }
        return (error?.isEmpty == false) ? .failed : .pending
    }

    /// Body text for display: pretty-printed when it is JSON, truncated to `limit` characters, redacted.
    static func displayBody(_ body: String, prettyJSON: Bool, limit: Int = displayBodyLimit) -> (text: String, truncatedCount: Int) {
        let text = safe(body)
        if prettyJSON, let pretty = prettyPrintedJSON(text) { return truncated(safe(pretty), limit: limit) }
        return truncated(text, limit: limit)
    }

    /// First `limit` characters and the number of characters cut off.
    static func truncated(_ text: String, limit: Int) -> (text: String, truncatedCount: Int) {
        let limit = max(0, limit)
        guard let cut = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex), cut < text.endIndex else {
            return (text, 0)
        }
        return (String(text[..<cut]), text[cut...].count)
    }

    /// Pretty-prints a JSON document; nil when `text` is not valid JSON.
    static func prettyPrintedJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: out, encoding: .utf8)
    }

    // MARK: - Detail fields (SPEC §44 Research display)

    /// Fields of the detail screen in display order. All strings are redacted.
    static func fields(for entry: ResearchLogSnapshot, bodyLimit: Int = displayBodyLimit) -> [Field] {
        fields(for: entry, body: displayBody(entry.responseBody, prettyJSON: false, limit: bodyLimit))
    }

    /// Fields with an already redacted + truncated body (`displayBody` / `truncated(safe(…))`), so callers that also need
    /// the body text on its own do the expensive body pass only once.
    static func fields(for entry: ResearchLogSnapshot, body: (text: String, truncatedCount: Int)) -> [Field] {
        var fields: [Field] = [
            Field(label: "HTTP Status", value: statusText(entry.statusCode)),
            Field(label: "Endpoint", value: safe(entry.endpoint)),
            Field(label: "Method", value: safe(entry.method) ?? "—"),
            Field(label: "Priority", value: priorityText(entry.priorityRaw)),
            Field(label: "Duration", value: durationText(entry.durationMs)),
            Field(label: "Bytes", value: bytesText(entry.bytes)),
            Field(label: "Account", value: accountText(entry)),
            Field(label: "Timestamp", value: timestampText(entry.timestamp)),
            Field(label: "Kind", value: entry.kind.rawValue),
        ]
        if let error = entry.errorDescription, !error.isEmpty {
            fields.append(Field(label: "Error", value: safe(error)))
        }
        fields.append(Field(label: "Request Headers", value: blockText(entry.requestHeaders), isBlock: true))
        fields.append(Field(label: "Response Headers", value: blockText(entry.responseHeaders), isBlock: true))
        var bodyText = body.text.isEmpty ? "(なし)" : body.text
        if body.truncatedCount > 0 { bodyText += "\n…（\(body.truncatedCount)文字省略）" }
        fields.append(Field(label: "Safe Response Body", value: bodyText, isBlock: true))
        return fields
    }

    static func accountText(_ entry: ResearchLogSnapshot) -> String {
        switch (entry.accountName, entry.accountID) {
        case let (name?, id?): return "\(safe(name)) (\(safe(id)))"
        case let (nil, id?): return safe(id)
        case let (name?, nil): return safe(name)
        case (nil, nil): return "—"
        }
    }

    private static func blockText(_ text: String) -> String {
        let s = safe(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "(なし)" : s
    }

    /// One-line summary used in lists and exports: "GET 200 123 ms https://api.fanbox.cc/post.info?..."
    static func summaryLine(_ entry: ResearchLogSnapshot) -> String {
        var parts: [String] = []
        if let method = entry.method, !method.isEmpty { parts.append(safe(method)) }
        if entry.kind == .request || entry.statusCode != nil { parts.append(statusText(entry.statusCode)) }
        if entry.durationMs != nil { parts.append(durationText(entry.durationMs)) }
        parts.append(safe(entry.endpoint))
        return parts.joined(separator: " ")
    }

    // MARK: - Plain-text rendering / export

    /// Full plain-text rendering of one entry (share sheet / export). Redacted.
    static func text(for entry: ResearchLogSnapshot, bodyLimit: Int = exportBodyLimit) -> String {
        text(for: entry, fields: fields(for: entry, bodyLimit: bodyLimit))
    }

    /// Plain-text rendering from fields computed by `fields(for:…)`. Redacted again as a whole.
    static func text(for entry: ResearchLogSnapshot, fields: [Field]) -> String {
        var lines: [String] = ["[\(timestampText(entry.timestamp))] \(entry.kind.rawValue.uppercased()) \(summaryLine(entry))"]
        for field in fields {
            if field.isBlock {
                lines.append("\(field.label):")
                lines.append(contentsOf: field.value.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 })
            } else {
                lines.append("\(field.label): \(field.value)")
            }
        }
        // Final pass over the assembled text: nothing may bypass redaction.
        return safe(lines.joined(separator: "\n"))
    }

    /// Export of many entries (newest first) with a header. Redacted.
    static func export(_ entries: [ResearchLogSnapshot], schemaLines: [String] = [], researchModeEnabled: Bool,
                       appVersion: String, generatedAt: Date = .now, bodyLimit: Int = exportBodyLimit) -> String {
        var out: [String] = [
            "FANBOX Personal Client — Research Log",
            "Generated: \(timestampText(generatedAt))",
            "App version: \(appVersion)",
            "Research Mode: \(researchModeEnabled ? "ON (redacted response bodies captured)" : "OFF (metadata only)")",
            "Entries: \(entries.count)",
            "All values are redacted (Cookie / FANBOXSESSID / Authorization / CSRF / passwords / card data).",
            "",
        ]
        if !schemaLines.isEmpty {
            out.append("== API Schema ==")
            out.append(contentsOf: schemaLines)
            out.append("")
        }
        out.append("== Logs ==")
        for entry in entries {
            out.append(text(for: entry, bodyLimit: bodyLimit))
            out.append("")
        }
        return safe(out.joined(separator: "\n"))
    }
}

/// Display-side secret redaction applied after `SecretRedactor.redact` (defense in depth, SPEC §38).
/// Masks values of sensitive headers, cookie pairs, JSON secret keys, bearer tokens and Luhn-valid card numbers.
/// Idempotent: running it on already-redacted text changes nothing.
enum ResearchDisplayRedaction {
    static let placeholder = SecretRedactor.placeholder

    private static let sensitiveHeaderNames = [
        "cookie", "set-cookie", "authorization", "proxy-authorization", "x-csrf-token", "x-xsrf-token", "csrf-token",
        "x-auth-token", "x-api-key",
    ]

    private static let sensitiveKeyNames = [
        "FANBOXSESSID", "PHPSESSID", "cf_clearance", "__cf_bm", "device_token", "csrf[_-]?token", "xsrf[_-]?token",
        "access[_-]?token", "refresh[_-]?token", "id[_-]?token", "auth[_-]?token", "session[_-]?id", "token", "password",
        "passwd", "pass", "cvc", "cvv", "cvc2", "card[_-]?number", "security[_-]?code", "pin",
    ]

    private static let jsonKeyNames = [
        "csrfToken", "csrf_token", "xsrfToken", "token", "accessToken", "access_token", "refreshToken", "refresh_token",
        "idToken", "id_token", "authToken", "password", "passwd", "cardNumber", "card_number", "cvc", "cvv", "securityCode",
        "security_code", "pin", "cookie", "set-cookie", "authorization", "x-csrf-token", "FANBOXSESSID", "PHPSESSID",
        "sessionId", "session_id",
    ]

    private static let rules: [(NSRegularExpression, String)] = {
        let headers = sensitiveHeaderNames.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let keys = sensitiveKeyNames.joined(separator: "|")
        let jsonKeys = jsonKeyNames.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let quote = SecretRedactor.encodedQuotePattern
        let colon = SecretRedactor.encodedColonPattern
        let specs: [(String, String)] = [
            // "Cookie: a=b; c=d" / "X-CSRF-Token: …" header lines (whole value). Line-anchored: single-line HTML / JS keeps
            // everything after a mid-line "cookie:".
            ("(?im)^([ \\t]*\"?(?:\(headers))\"?[ \\t]*[:=][ \\t]*)(?!\(placeholder)$)(\\S.*)$", "$1\(placeholder)"),
            // "\"Cookie\": \"…\"" (JSON-style header dumps / bodies).
            ("(?i)(\"(?:\(jsonKeys))\"\\s*:\\s*)\"(?:[^\"\\\\]|\\\\.)*\"", "$1\"\(placeholder)\""),
            // Escaped JSON in HTML attributes / JS strings / URLs: &quot;csrfToken&quot;:&quot;…&quot;, &#34;…, &#x22;…, \\"…\\".
            ("(?i)(\(quote)(?:\(jsonKeys))\(quote)[ \\t]*\(colon)[ \\t]*)(\(quote))(?:(?!\\2)[^\\r\\n])*", "$1$2\(placeholder)"),
            // key=value / key: value pairs anywhere (cookies, query strings, form bodies).
            ("(?i)(?<![A-Za-z0-9_])((?:\(keys)))(\\s*[=:]\\s*)[^\\s;&,\"'<>]+", "$1$2\(placeholder)"),
            // Authorization schemes. "Basic" only before a credential-looking token (so "Basic プラン" / "basic plan" stay).
            ("(?i)\\b(bearer)\\s+[A-Za-z0-9\\-._~+/]+=*", "$1 \(placeholder)"),
            ("(?i)\\b(basic)\\s+(?=[A-Za-z0-9+/]*[0-9+/=])[A-Za-z0-9+/]{8,}={0,2}", "$1 \(placeholder)"),
        ]
        return specs.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                assertionFailure("invalid redaction pattern")
                return nil
            }
            return (regex, template)
        }
    }()

    static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for (regex, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return redactCardNumbers(result)
    }

    /// Replaces Luhn-valid card numbers (SPEC §12 / §38) with the placeholder. Uses `SecretRedactor`'s guarded candidate
    /// scan, so digits inside URL paths, file names, hashes and `id_…` identifiers, shorter ids (post / user ids) and
    /// millisecond timestamps are kept.
    static func redactCardNumbers(_ text: String) -> String {
        SecretRedactor.redactCardNumbers(text, mask: { _ in placeholder })
    }

    static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        for (index, ch) in digits.reversed().enumerated() {
            guard let d = ch.wholeNumberValue else { return false }
            if index % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }
}

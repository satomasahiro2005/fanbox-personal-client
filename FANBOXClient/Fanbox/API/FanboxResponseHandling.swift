import Foundation

/// `{ "body": ... }` / `{ "error": "..." }` envelope handling and HTTP status ⇒ `RemoteError` mapping (SPEC §44).
enum FanboxResponseHandling {
    /// Envelope as far as the client needs it: the raw body JSON and the error code, if any.
    struct Envelope: Decodable {
        var hasBody: Bool
        var error: String?

        init(from decoder: Decoder) throws {
            let o = try LenientObject(decoder)
            hasBody = o.has("body")
            error = o.string("error")
        }
    }

    /// Decodes `Body` from `{ "body": Body }`. Throws `RemoteError` for error envelopes and undecodable payloads.
    static func decodeBody<Body: Decodable>(_ type: Body.Type, from data: Data, endpointKey: String, statusCode: Int = 200) throws -> Body {
        let decoder = JSONDecoder()
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw RemoteError.decoding(endpoint: endpointKey, detail: "レスポンスが JSON オブジェクトではありません")
        }
        if let code = envelope.error, !envelope.hasBody {
            throw mapErrorCode(code, statusCode: statusCode)
        }
        guard envelope.hasBody else {
            throw RemoteError.decoding(endpoint: endpointKey, detail: "body がありません")
        }
        do {
            return try decoder.decode(BodyWrapper<Body>.self, from: data).body
        } catch {
            throw RemoteError.decoding(endpoint: endpointKey, detail: describe(error))
        }
    }

    private struct BodyWrapper<Body: Decodable>: Decodable {
        var body: Body
        enum CodingKeys: String, CodingKey { case body }
    }

    /// Short, secret-free description of a decoding error (key path + reason; never the payload).
    static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return String(describing: type(of: error)) }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch decodingError {
        case .typeMismatch(let type, let ctx): return "型不一致 \(type) at \(path(ctx))"
        case .valueNotFound(let type, let ctx): return "値なし \(type) at \(path(ctx))"
        case .keyNotFound(let key, let ctx): return "キーなし \(key.stringValue) at \(path(ctx))"
        case .dataCorrupted(let ctx): return "形式不明 at \(path(ctx)): \(ctx.debugDescription.prefix(160))"
        @unknown default: return "decoding error"
        }
    }

    /// FANBOX error codes (`general_error`, `general`, ...) combined with the HTTP status.
    static func mapErrorCode(_ code: String, statusCode: Int) -> RemoteError {
        if (200..<300).contains(statusCode) || statusCode == 0 {
            // Error envelope with a success status: treat as a rejected request.
            return .invalidRequest("FANBOX がリクエストを拒否しました (\(code.prefix(40)))")
        }
        return map(statusCode: statusCode, headers: [:], errorCode: code)
    }

    /// Maps a non-2xx response. `headers` keys are matched case-insensitively. `body` lets a CDN edge block (HTML
    /// challenge / "ブロックされました") be told apart from a FANBOX JSON refusal (docs/API.md §1.6).
    static func map(statusCode: Int, headers: [String: String], errorCode: String? = nil, body: Data? = nil) -> RemoteError {
        if errorCode == nil, EdgeBlockDetector.isEdgeBlock(status: statusCode, headers: headers, body: body) {
            return .edgeBlocked(retryAfter: retryAfter(from: headers))
        }
        switch statusCode {
        case 300..<400:
            // Redirects are never followed for writes (and capped for reads): a 3xx here is a refusal.
            return .invalidRequest("FANBOX がリダイレクトを返しました (\(statusCode))")
        case 400:
            // Missing Origin, bad parameters, or (on some endpoints) a logged-out session.
            return .invalidRequest("FANBOX がリクエストを拒否しました (400\(errorCode.map { " \($0.prefix(40))" } ?? ""))")
        case 401:
            return .unauthorized
        case 403:
            // Either FANBOX refused the resource (JSON) or a Cloudflare challenge (HTML). Neither proves the session is invalid.
            return .forbidden
        case 404:
            return .notFound
        case 408:
            return .network(code: 408, detail: "timeout")
        case 429:
            return .rateLimited(retryAfter: retryAfter(from: headers))
        case 500...599:
            return .server(status: statusCode)
        default:
            return .server(status: statusCode)
        }
    }

    /// `Retry-After` as seconds or an HTTP-date.
    static func retryAfter(from headers: [String: String], now: Date = .now) -> TimeInterval? {
        guard let raw = header("Retry-After", in: headers)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) { return max(0, date.timeIntervalSince(now)) }
        return nil
    }

    static func header(_ name: String, in headers: [String: String]) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }

    /// True when a 403 / 503 is a Cloudflare edge block / challenge rather than a FANBOX JSON refusal (see `EdgeBlockDetector`).
    static func isCloudflareBlock(statusCode: Int, headers: [String: String], body: Data? = nil) -> Bool {
        EdgeBlockDetector.isEdgeBlock(status: statusCode, headers: headers, body: body)
    }
}

/// Extracts the `<meta name="metadata" content="...">` JSON from a www.fanbox.cc page.
enum FanboxMetadataParser {
    private static let metaRegex = try! NSRegularExpression(pattern: #"<meta\b(?:[^>"']|"[^"]*"|'[^']*')*>"#, options: [.caseInsensitive])
    private static let attrRegex = try! NSRegularExpression(
        pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#, options: [])

    /// Raw (unescaped) JSON text of the metadata tag, or nil when the page has none (e.g. logged-out / challenge page).
    static func metadataJSON(fromHTML html: String) -> String? {
        let ns = html as NSString
        for match in metaRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            let attrs = attributes(of: tag)
            let isMetadata = attrs["name"]?.lowercased() == "metadata" || attrs["id"]?.lowercased() == "metadata"
            if isMetadata, let content = attrs["content"] {
                return unescapeEntities(content)
            }
        }
        return nil
    }

    static func parse(html: String) throws -> FanboxMetadataDTO {
        guard let json = metadataJSON(fromHTML: html) else {
            throw RemoteError.decoding(endpoint: "www.metadata", detail: "metadata が見つかりません")
        }
        do {
            return try JSONDecoder().decode(FanboxMetadataDTO.self, from: Data(json.utf8))
        } catch {
            throw RemoteError.decoding(endpoint: "www.metadata", detail: FanboxResponseHandling.describe(error))
        }
    }

    private static func attributes(of tag: String) -> [String: String] {
        let ns = tag as NSString
        var result: [String: String] = [:]
        for m in attrRegex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            let valueRange = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 3)
            result[name] = valueRange.location != NSNotFound ? ns.substring(with: valueRange) : ""
        }
        return result
    }

    /// Decodes the HTML entities FANBOX uses inside attribute values (&quot; &amp; &#39; &#x27; &lt; &gt; ...).
    static func unescapeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let entity = String(s[s.index(after: i)..<semi])
                if let decoded = decodeEntity(entity) {
                    out.append(decoded)
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(ch)
            i = s.index(after: i)
        }
        return out
    }

    private static func decodeEntity(_ entity: String) -> String? {
        switch entity {
        case "quot": return "\""
        case "amp": return "&"
        case "apos": return "'"
        case "lt": return "<"
        case "gt": return ">"
        case "nbsp": return "\u{00A0}"
        default: break
        }
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            return UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if entity.hasPrefix("#") {
            return UInt32(entity.dropFirst(1)).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return nil
    }
}

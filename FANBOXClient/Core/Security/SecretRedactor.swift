import Foundation

/// Redacts secrets before anything is logged or shown in Research Mode (SPEC §38).
/// There is NO debug-build exception. Every log / ResearchLog string must pass through here.
///
/// All entry points are total: they never throw and never crash, whatever the input.
/// Display format follows SPEC §38, e.g. `Cookie: <REDACTED>`, `FANBOXSESSID: <REDACTED>`, `X-CSRF-Token: <REDACTED>`.
enum SecretRedactor {
    static let placeholder = "<REDACTED>"

    // MARK: - Headers

    /// Redacts sensitive header values (Cookie, Set-Cookie, Authorization, X-CSRF-Token, ...).
    /// Non-sensitive headers are kept, but their values are still scanned as free text.
    static func redactHeaders(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(headers.count)
        for (name, value) in headers {
            if isSensitiveHeader(name) {
                result[name] = placeholder
            } else if value.hasPrefix("http://") || value.hasPrefix("https://") {
                result[name] = redact(redactURLString(value))
            } else {
                result[name] = redact(value)
            }
        }
        return result
    }

    /// Redacted headers rendered as sorted `Name: value` lines (Research Mode display).
    static func formatHeaders(_ headers: [String: String]) -> String {
        redactHeaders(headers)
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    private static let sensitiveHeaderNames: Set<String> = [
        "cookie", "set-cookie", "set-cookie2", "authorization", "proxy-authorization", "x-csrf-token", "x-xsrf-token",
        "x-api-key", "api-key", "x-auth-token", "x-amz-security-token",
    ]
    private static let sensitiveHeaderFragments = ["token", "secret", "session", "password", "auth", "cookie", "csrf", "xsrf",
                                                   "sessid", "apikey", "api-key", "api_key"]

    static func isSensitiveHeader(_ name: String) -> Bool {
        let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        if sensitiveHeaderNames.contains(lower) { return true }
        return sensitiveHeaderFragments.contains { lower.contains($0) }
    }

    // MARK: - URLs

    /// Redacts sensitive query parameters / credentials in a URL.
    static func redactURL(_ url: URL) -> String { redactURLString(url.absoluteString) }

    /// Redacts userinfo (`user:pass@`) and the values of sensitive query / fragment parameters, keeping their names:
    /// `https://api.fanbox.cc/post.info?postId=1&token=<REDACTED>`.
    static func redactURLString(_ string: String) -> String {
        guard !string.isEmpty else { return string }
        var s = string

        // userinfo: scheme://user:pass@host → scheme://<REDACTED>@host
        if let schemeRange = s.range(of: "://") {
            let authorityStart = schemeRange.upperBound
            let authorityEnd = s[authorityStart...].firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? s.endIndex
            let authority = s[authorityStart..<authorityEnd]
            if let at = authority.lastIndex(of: "@") {
                s.replaceSubrange(authorityStart..<at, with: placeholder)
            }
        }

        // Fragment first (so the query range below stays valid), then query.
        if let hash = s.firstIndex(of: "#") {
            let fragment = String(s[s.index(after: hash)...])
            if fragment.contains("=") {
                s = String(s[..<hash]) + "#" + redactParameterString(fragment)
            }
        }
        if let q = s.firstIndex(of: "?") {
            let end = s[q...].firstIndex(of: "#") ?? s.endIndex
            let query = String(s[s.index(after: q)..<end])
            s.replaceSubrange(s.index(after: q)..<end, with: redactParameterString(query))
        }
        // Secrets that ended up in the path (e.g. ";jsessionid=…" or "FANBOXSESSID=…").
        return redactInlineSecrets(s)
    }

    /// `a=1&token=xyz` → `a=1&token=<REDACTED>` (also used for form-urlencoded bodies).
    static func redactParameterString(_ query: String) -> String {
        guard !query.isEmpty else { return query }
        return query.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            guard let eq = pair.firstIndex(of: "=") else { return String(pair) }
            let rawName = String(pair[..<eq])
            let name = rawName.removingPercentEncoding ?? rawName
            let value = pair[pair.index(after: eq)...]
            if value.isEmpty { return String(pair) }
            if isSensitiveParameterName(name) { return rawName + "=" + placeholder }
            let decoded = String(value).removingPercentEncoding ?? String(value)
            let scanned = redactCardNumbers(redactInlineSecrets(decoded))
            return scanned == decoded ? String(pair) : rawName + "=" + scanned
        }.joined(separator: "&")
    }

    /// Words that make a query / form parameter sensitive when they appear as a whole word of the name
    /// (`api_key`, `sessionId`, `code`), while avoiding look-alikes such as `keyword` or `author`.
    private static let sensitiveParameterWords: Set<String> = [
        "token", "csrf", "xsrf", "session", "sessid", "password", "passwd", "pwd", "key", "apikey", "auth", "authorization",
        "signature", "sig", "secret", "code", "otp", "cvc", "cvv", "pin", "pan", "cookie", "credential", "credentials",
    ]
    /// Fragments that make a parameter sensitive anywhere in its (compacted) name.
    private static let sensitiveParameterFragments = ["token", "password", "passwd", "secret", "sessid", "csrf", "xsrf",
                                                      "signature", "apikey", "cardnumber", "securitycode", "cookie"]

    static func isSensitiveParameterName(_ name: String) -> Bool {
        let compact = compactName(name)
        if compact.isEmpty { return false }
        if sensitiveParameterFragments.contains(where: { compact.contains($0) }) { return true }
        if isSensitiveJSONKey(name) { return true }
        return nameWords(name).contains { sensitiveParameterWords.contains($0) }
    }

    // MARK: - JSON keys

    /// Exact (compacted) JSON / form keys that hold secrets.
    private static let sensitiveKeysExact: Set<String> = [
        "csrftoken", "token", "accesstoken", "refreshtoken", "idtoken", "password", "passwd", "pwd", "cardnumber", "pan",
        "cvc", "cvc2", "cvv", "cvv2", "csc", "securitycode", "pin", "pincode", "fanboxsessid", "phpsessid", "sessid",
        "sessionid", "cookie", "cookies", "setcookie", "authorization", "proxyauthorization", "secret", "clientsecret",
        "otp", "onetimepassword", "apikey", "xcsrftoken", "threedsecure", "credential", "credentials",
    ]
    /// Fragments that make a JSON key sensitive anywhere in its compacted name.
    private static let sensitiveKeyFragments = ["token", "password", "passwd", "secret", "csrf", "xsrf", "sessid",
                                                "cardnumber", "securitycode", "cvc", "cvv", "threeds", "authorization",
                                                "cookie", "apikey"]

    /// Whether a JSON / form key holds a secret (csrfToken, password, cardNumber, cvc, FANBOXSESSID, 3ds…, otp, …).
    static func isSensitiveJSONKey(_ key: String) -> Bool {
        let compact = compactName(key)
        if compact.isEmpty { return false }
        if sensitiveKeysExact.contains(compact) { return true }
        if compact.hasPrefix("3ds") || compact.hasPrefix("threeds") { return true }
        return sensitiveKeyFragments.contains { compact.contains($0) }
    }

    /// Lowercased name without separators: "X-CSRF-Token" → "xcsrftoken", "card_number" → "cardnumber".
    private static func compactName(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Splits camelCase / snake_case / kebab-case names into lowercase words: "sessionId" → ["session", "id"].
    private static func nameWords(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousWasLower = false
        for ch in name {
            if ch.isLetter || ch.isNumber {
                if ch.isUppercase && previousWasLower && !current.isEmpty {
                    words.append(current.lowercased())
                    current = ""
                }
                current.append(ch)
                previousWasLower = ch.isLowercase || ch.isNumber
            } else {
                if !current.isEmpty { words.append(current.lowercased()) }
                current = ""
                previousWasLower = false
            }
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    // MARK: - Bodies

    /// Redacts a request / response body. JSON keys such as csrfToken, password, cardNumber, cvc are replaced;
    /// free text is scanned for secrets. Output is truncated to `limit` characters.
    static func redactBody(_ data: Data, contentType: String?, limit: Int = 64_000) -> String {
        let limit = max(0, limit)
        guard !data.isEmpty else { return "" }
        let type = (contentType ?? "").lowercased()

        if isBinaryContentType(type) {
            return "<binary \(data.count) bytes\(type.isEmpty ? "" : ", \(type)")>"
        }

        if type.contains("json") || looksLikeJSON(data),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            let redacted = redactJSONValue(object)
            if JSONSerialization.isValidJSONObject(redacted),
               let out = try? JSONSerialization.data(withJSONObject: redacted,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               let text = String(data: out, encoding: .utf8) {
                return truncate(text, limit: limit, totalBytes: data.count)
            }
            if let fragment = redacted as? String { return truncate(fragment, limit: limit, totalBytes: data.count) }
            if let number = redacted as? NSNumber { return number.stringValue }
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return "<binary \(data.count) bytes>"
        }
        if text.contains("\u{0}") { return "<binary \(data.count) bytes>" }

        // Pre-cut very large text so regex work stays bounded, dropping a possibly half-cut token at the edge.
        var working = text
        let budget = limit * 2 + 1_024
        if working.count > budget {
            working = dropTrailingPartialToken(String(working.prefix(budget)))
        }
        if type.contains("x-www-form-urlencoded") {
            working = redactParameterString(working)
        }
        return truncate(redact(working), limit: limit, totalBytes: data.count)
    }

    /// Recursively replaces sensitive keys in parsed JSON; every string value is also scanned as free text.
    static func redactJSONValue(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, v) in dict {
                if isSensitiveJSONKey(key) {
                    out[key] = (v is NSNull) ? v : placeholder
                } else {
                    out[key] = redactJSONValue(v)
                }
            }
            return out
        case let array as [Any]:
            return array.map(redactJSONValue)
        case let string as String:
            return redact(string)
        default:
            return value
        }
    }

    private static func isBinaryContentType(_ type: String) -> Bool {
        guard !type.isEmpty else { return false }
        if type.hasPrefix("image/") || type.hasPrefix("video/") || type.hasPrefix("audio/") || type.hasPrefix("font/") { return true }
        return ["application/octet-stream", "application/zip", "application/pdf", "multipart/form-data"].contains { type.hasPrefix($0) }
    }

    private static func looksLikeJSON(_ data: Data) -> Bool {
        for byte in data.prefix(64) {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF: continue   // whitespace / BOM
            case UInt8(ascii: "{"), UInt8(ascii: "["): return true
            default: return false
            }
        }
        return false
    }

    private static func truncate(_ text: String, limit: Int, totalBytes: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…(truncated, \(totalBytes) bytes total)"
    }

    private static func dropTrailingPartialToken(_ text: String) -> String {
        var s = Substring(text)
        var dropped = 0
        while let last = s.last, !last.isWhitespace, dropped < 512 {
            s = s.dropLast()
            dropped += 1
        }
        return String(s)
    }

    // MARK: - Free text

    /// Redacts secrets in arbitrary text (cookie pairs, tokens, card numbers, ...).
    static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var s = text
        s = replace(headerLineRegex, in: s, template: "$1$2\(placeholder)")
        s = replace(jsonQuotedKeyRegex, in: s, template: "$1\"\(placeholder)\"")
        s = replace(jsonSingleQuotedKeyRegex, in: s, template: "$1'\(placeholder)'")
        s = replace(htmlEntityKeyRegex, in: s, template: "$1\(placeholder)")
        s = redactInlineSecrets(s)
        s = replace(bearerRegex, in: s, template: "$1 \(placeholder)")
        s = replace(cvcRegex, in: s, template: "$1\(placeholder)")
        s = redactCardNumbers(s)
        return s
    }

    /// key=value / key: value secrets (FANBOXSESSID=…, password=…, csrfToken: …, access_token=…).
    private static func redactInlineSecrets(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return replace(inlineKeyValueRegex, in: text, template: "$1$2\(placeholder)")
    }

    // Header-like lines: "Cookie: …", "Set-Cookie: …", "Authorization: …", "X-CSRF-Token: …" (rest of the line).
    private static let headerLineRegex = makeRegex(
        #"(?i)(?<![A-Za-z0-9_-])(Set-Cookie2?|Cookie|Proxy-Authorization|Authorization|X-CSRF-Token|X-XSRF-Token|X-Auth-Token|X-API-Key)(\s*:[ \t]*+)(?!<REDACTED>)[^\r\n]+"#)

    private static let sensitiveKeyPattern =
        #"[A-Za-z0-9_\-]*(?:token|password|passwd|secret|csrf|xsrf|sessid|cookie|authorization|card_?number|security_?code|cvc|cvv|threeds|3ds|api_?key)[A-Za-z0-9_\-]*|pan|pin|otp|pwd"#

    // JSON fragments: "csrfToken":"…", "password": 123, "cookie": {…} is handled structurally in redactBody.
    private static let jsonQuotedKeyRegex = makeRegex(
        #"(?i)("(?:"# + sensitiveKeyPattern + #")"\s*:\s*)(?:"(?:[^"\\]|\\.)*"|-?[0-9][0-9.eE+-]*|true|false)"#)
    private static let jsonSingleQuotedKeyRegex = makeRegex(
        #"(?i)('(?:"# + sensitiveKeyPattern + #")'\s*:\s*)'(?:[^'\\]|\\.)*'"#)
    // HTML-escaped JSON in meta tags: &quot;csrfToken&quot;:&quot;…&quot;
    private static let htmlEntityKeyRegex = makeRegex(
        #"(?i)(&quot;(?:"# + sensitiveKeyPattern + #")&quot;\s*:\s*&quot;)(?:(?!&quot;).)*"#)

    // Unquoted key=value / key: value. The key must not be preceded by a word character (so "keyword=" or "author=" never match).
    private static let inlineKeyValueRegex = makeRegex(
        #"(?i)(?<![A-Za-z0-9])((?:[A-Za-z0-9_\-]*(?:token|password|passwd|secret|csrf|xsrf|sessid|api_?key|card_?number)[A-Za-z0-9_\-]*|pwd|otp))(\s*[=:]\s*+)(?!<REDACTED>)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s&;,"'<>(){}\[\]]+)"#)

    private static let bearerRegex = makeRegex(#"(?i)\b(Bearer)\s+(?!<REDACTED>)[A-Za-z0-9\-._~+/]+=*"#)

    // 3–4 digit values after cvc / cvv / security code keywords.
    private static let cvcRegex = makeRegex(
        #"(?i)(?<![A-Za-z])((?:cvc2?|cvv2?|csc|security[ _-]?code|セキュリティ(?:ー)?コード)["']?\s*[:=：]?\s*["']?)\d{3,4}(?!\d)"#)

    // 13–19 digits, optionally grouped by single spaces or hyphens, not glued to other word characters or path slashes.
    private static let cardCandidateRegex = makeRegex(#"(?<![0-9A-Za-z/_.])\d(?:[ -]?\d){12,18}(?![0-9A-Za-z/_])"#)

    /// Masks Luhn-valid card-like numbers, keeping at most the last 4 digits: `<REDACTED CARD ••••1234>`.
    /// A candidate run (13–19 digits, optionally grouped by spaces / hyphens) is masked when the whole run, or any
    /// contiguous span of its groups (≥ 3 digits each) holding 13–19 digits, passes the Luhn check.
    static func redactCardNumbers(_ text: String) -> String {
        guard let regex = cardCandidateRegex, text.utf16.count >= 13 else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            let candidate = ns.substring(with: match.range)
            guard let last4 = luhnCardLast4(in: candidate), let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "<REDACTED CARD ••••\(last4)>")
        }
        return result
    }

    /// Last 4 digits of the card number found in a candidate run, or nil when none passes Luhn.
    private static func luhnCardLast4(in candidate: String) -> String? {
        let digits = candidate.filter(\.isASCIIDigitCharacter)
        if (13...19).contains(digits.count), luhnValid(digits) { return String(digits.suffix(4)) }
        let groups = candidate.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        guard groups.count > 1 else { return nil }
        for length in stride(from: groups.count, through: 1, by: -1) {
            for start in 0...(groups.count - length) {
                let span = groups[start..<(start + length)]
                guard span.allSatisfy({ $0.count >= 3 }) else { continue }
                let joined = span.joined()
                if (13...19).contains(joined.count), luhnValid(joined) { return String(joined.suffix(4)) }
            }
        }
        return nil
    }

    /// Luhn checksum on an ASCII digit string.
    static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        var double = false
        var count = 0
        for ch in digits.reversed() {
            guard let d = ch.asciiDigitValue else { return false }
            var v = d
            if double {
                v *= 2
                if v > 9 { v -= 9 }
            }
            sum += v
            double.toggle()
            count += 1
        }
        return count > 0 && sum % 10 == 0
    }

    // MARK: - Regex helpers

    private static func makeRegex(_ pattern: String) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            AppLog.security.fault("invalid redaction pattern")
            return nil
        }
    }

    private static func replace(_ regex: NSRegularExpression?, in text: String, template: String) -> String {
        guard let regex else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { asciiDigitValue != nil }

    var asciiDigitValue: Int? {
        guard let ascii = asciiValue, ascii >= 48, ascii <= 57 else { return nil }
        return Int(ascii - 48)
    }
}

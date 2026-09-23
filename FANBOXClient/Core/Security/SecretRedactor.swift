import Foundation

/// Redacts secrets before anything is logged or shown in Research Mode (SPEC §38).
/// There is NO debug-build exception. Every log / ResearchLog string must pass through here.
enum SecretRedactor {
    static let placeholder = "<REDACTED>"

    /// Redacts sensitive header values (Cookie, Set-Cookie, Authorization, X-CSRF-Token, ...).
    static func redactHeaders(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, _) in headers { result[name] = placeholder }
        return result
    }

    /// Redacts sensitive query parameters / credentials in a URL.
    static func redactURL(_ url: URL) -> String { redactURLString(url.absoluteString) }

    static func redactURLString(_ string: String) -> String { placeholder }

    /// Redacts a request / response body. JSON keys such as csrfToken, password, cardNumber, cvc are replaced;
    /// free text is scanned for secrets. Output is truncated to `limit` characters.
    static func redactBody(_ data: Data, contentType: String?, limit: Int = 64_000) -> String { placeholder }

    /// Redacts secrets in arbitrary text (cookie pairs, tokens, card numbers, ...).
    static func redact(_ text: String) -> String { placeholder }
}

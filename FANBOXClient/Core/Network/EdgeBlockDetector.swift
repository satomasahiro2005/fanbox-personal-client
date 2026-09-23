import Foundation

/// Tells CDN edge blocks (Cloudflare challenge / "ブロックされました" pages) apart from FANBOX's own refusals
/// (docs/API.md §1.6 / §1.7). Pure and unit-tested.
///
/// - A FANBOX refusal is JSON (`{"error": ...}`) with 401 / 403 / 404: the session or the entitlement decides.
/// - An edge block is a 403 / 503 that did not come from FANBOX: `cf-mitigated`, or an HTML page from
///   `Server: cloudflare`, or an HTML body with a challenge / block marker. It says nothing about the session and the
///   request never reached FANBOX, so it may be retried through another transport (the account WebView).
/// - 429 is always rate limiting (`RemoteError.rateLimited`), never an edge block: it is per IP address, so switching
///   transports would only add load.
enum EdgeBlockDetector {
    /// Lower-cased markers of challenge / block pages (checked in the first `sniffLength` bytes).
    static let bodyMarkers = [
        "just a moment", "cf-chl-", "challenge-platform", "attention required", "cloudflare ray id", "cf-error-details",
        "__cf_chl", "ブロックされました",
    ]
    static let sniffLength = 4096

    /// Statuses an edge block can have.
    static func isCandidateStatus(_ status: Int) -> Bool { status == 403 || status == 503 }

    /// True when the response is an edge block rather than a FANBOX answer.
    static func isEdgeBlock(status: Int, headers: [String: String], body: Data?) -> Bool {
        guard isCandidateStatus(status) else { return false }
        if header("cf-mitigated", in: headers) != nil { return true }
        let contentType = header("Content-Type", in: headers)?.lowercased() ?? ""
        if contentType.contains("json") || bodyLooksLikeJSON(body) { return false }
        let server = header("Server", in: headers)?.lowercased() ?? ""
        let html = contentType.contains("text/html") || bodyLooksLikeHTML(body)
        if html && server.contains("cloudflare") { return true }
        return containsMarker(body)
    }

    /// Retry-After (seconds or HTTP-date) when the edge sent one.
    static func retryAfter(headers: [String: String], now: Date = .now) -> TimeInterval? {
        HTTPErrorMapper.retryAfter(header("Retry-After", in: headers), now: now)
    }

    static func containsMarker(_ body: Data?) -> Bool {
        guard let head = sniff(body) else { return false }
        return bodyMarkers.contains { head.contains($0) }
    }

    // MARK: - Helpers

    private static func sniff(_ body: Data?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        let prefix = body.prefix(sniffLength)
        let text = String(decoding: prefix, as: UTF8.self)
        return text.lowercased()
    }

    private static func bodyLooksLikeJSON(_ body: Data?) -> Bool {
        guard let body else { return false }
        for byte in body.prefix(64) {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D: continue
            case UInt8(ascii: "{"), UInt8(ascii: "["): return true
            default: return false
            }
        }
        return false
    }

    private static func bodyLooksLikeHTML(_ body: Data?) -> Bool {
        guard let head = sniff(body) else { return false }
        return head.contains("<html") || head.contains("<!doctype html")
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        HTTPErrorMapper.header(named: name, in: headers)
    }
}

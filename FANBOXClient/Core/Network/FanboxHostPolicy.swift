import Foundation

/// Which hosts may receive the account's session (SPEC §7.2 / §38) and which browser-like headers they get.
/// Cookies are sent ONLY to hosts under fanbox.cc / pixiv.net / pximg.net — never anywhere else.
enum FanboxHostPolicy {
    static let cookieDomains = ["fanbox.cc", "pixiv.net", "pximg.net"]
    static let apiHost = "api.fanbox.cc"
    static let origin = "https://www.fanbox.cc"
    static let referer = "https://www.fanbox.cc/"

    /// Fixed iOS Safari User-Agent used when the account has no captured WKWebView UA.
    static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    static func isUnder(_ host: String?, domain: String) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        return h == domain || h.hasSuffix("." + domain)
    }

    /// fanbox.cc / pixiv.net / pximg.net and their subdomains.
    static func isCookieEligible(host: String?) -> Bool {
        cookieDomains.contains { isUnder(host, domain: $0) }
    }

    static func isCookieEligible(url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return isCookieEligible(host: url.host)
    }

    static func isFanboxHost(_ host: String?) -> Bool { isUnder(host, domain: "fanbox.cc") }

    static func isAPIHost(_ host: String?) -> Bool { host?.lowercased() == apiHost }

    static func isPximgHost(_ host: String?) -> Bool { isUnder(host, domain: "pximg.net") }
}

/// Builds the per-account request headers. Pure (no I/O), shared by the client and its redirect handling.
enum FanboxRequestHeaders {
    /// Headers the client always controls; values supplied by callers are dropped.
    static let controlledHeaders: Set<String> = ["cookie", "x-csrf-token"]

    /// Adds Accept / Origin / Referer / User-Agent / Cookie / X-CSRF-Token for `request.url`.
    /// - Throws: `RemoteError.unauthorized` when `requiresCSRF` and the credential has no token;
    ///   `RemoteError.invalidRequest` when a CSRF token is requested for a non-FANBOX host.
    static func apply(to request: inout URLRequest, credential: SessionCredential?, requiresCSRF: Bool,
                      callerHeaders: [String: String] = [:]) throws {
        let url = request.url
        let host = url?.host?.lowercased()

        // Session headers are recomputed for every URL (including redirects).
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.setValue(nil, forHTTPHeaderField: "X-CSRF-Token")

        let callerHas: (String) -> Bool = { name in callerHeaders.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }

        if FanboxHostPolicy.isAPIHost(host), !callerHas("Accept") {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        if FanboxHostPolicy.isFanboxHost(host) {
            request.setValue(FanboxHostPolicy.origin, forHTTPHeaderField: "Origin")
            if !callerHas("Referer") { request.setValue(FanboxHostPolicy.referer, forHTTPHeaderField: "Referer") }
        } else if FanboxHostPolicy.isPximgHost(host) {
            request.setValue(nil, forHTTPHeaderField: "Origin")
            if !callerHas("Referer") { request.setValue(FanboxHostPolicy.referer, forHTTPHeaderField: "Referer") }
        } else {
            // Never leak FANBOX page context to third-party hosts.
            request.setValue(nil, forHTTPHeaderField: "Origin")
            if !callerHas("Referer") { request.setValue(nil, forHTTPHeaderField: "Referer") }
        }
        if !callerHas("User-Agent") {
            let ua = credential?.userAgent.flatMap { $0.isEmpty ? nil : $0 } ?? FanboxHostPolicy.defaultUserAgent
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }

        let eligible = FanboxHostPolicy.isCookieEligible(url: url)
        if eligible, let url, let cookie = credential?.cookieHeader(for: url) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if requiresCSRF {
            guard FanboxHostPolicy.isFanboxHost(host) else {
                throw RemoteError.invalidRequest("CSRF token requested for a non-FANBOX host")
            }
            guard let token = credential?.csrfToken, !token.isEmpty else { throw RemoteError.unauthorized }
            request.setValue(token, forHTTPHeaderField: "X-CSRF-Token")
        }
    }
}

/// Maps HTTP statuses and transport errors to `RemoteError` (SPEC §44).
enum HTTPErrorMapper {
    /// nil for 2xx.
    static func error(status: Int, headers: [String: String], now: Date = .now) -> RemoteError? {
        switch status {
        case 200..<300: return nil
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 429: return .rateLimited(retryAfter: retryAfter(header(named: "Retry-After", in: headers), now: now))
        default: return .server(status: status)
        }
    }

    /// Retry-After as delta-seconds or HTTP-date.
    static func retryAfter(_ value: String?, now: Date = .now) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) { return max(0, date.timeIntervalSince(now)) }
        return nil
    }

    static func map(_ error: Error) -> RemoteError {
        if let remote = error as? RemoteError { return remote }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError { return map(urlError) }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return map(URLError(URLError.Code(rawValue: ns.code))) }
        return .network(code: ns.code, detail: SecretRedactor.redact(ns.localizedDescription))
    }

    static func map(_ error: URLError) -> RemoteError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .cancelled:
            return .cancelled
        default:
            return .network(code: error.code.rawValue, detail: SecretRedactor.redact(error.localizedDescription))
        }
    }

    /// Case-insensitive header lookup.
    static func header(named name: String, in headers: [String: String]) -> String? {
        if let exact = headers[name] { return exact }
        return headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

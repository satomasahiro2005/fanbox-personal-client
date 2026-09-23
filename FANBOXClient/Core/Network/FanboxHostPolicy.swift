import Foundation

/// Which hosts may receive the account's session (SPEC §7.2 / §38, docs/API.md §1.3) and which browser-like headers they get.
/// The native transport sends cookies ONLY to hosts under fanbox.cc (www / api / downloads) — never to pixiv.net,
/// pximg.net or anywhere else. pixiv.net cookies captured from the web store stay in the credential only so they can be
/// re-installed into the account's own WebKit store.
enum FanboxHostPolicy {
    static let cookieDomains = ["fanbox.cc"]
    static let apiHost = "api.fanbox.cc"
    static let origin = "https://www.fanbox.cc"
    static let referer = "https://www.fanbox.cc/"

    /// Fallback User-Agent when the account has no captured WKWebView UA yet. Shaped like a WKWebView UA (no
    /// "Version/… Safari/…" suffix) so it matches what the account's web view presents; replaced by the real
    /// `navigator.userAgent` as soon as any account web view (login, browse, WebView transport) reports it.
    static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    static func isUnder(_ host: String?, domain: String) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        return h == domain || h.hasSuffix("." + domain)
    }

    /// fanbox.cc and its subdomains (the only hosts that get cookies / accept Set-Cookie into the credential).
    static func isCookieEligible(host: String?) -> Bool {
        cookieDomains.contains { isUnder(host, domain: $0) }
    }

    static func isCookieEligible(url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return isCookieEligible(host: url.host)
    }

    static func isFanboxHost(_ host: String?) -> Bool { isUnder(host, domain: "fanbox.cc") }

    static func isAPIHost(_ host: String?) -> Bool { host?.lowercased() == apiHost }

    static func isWWWHost(_ host: String?) -> Bool { host?.lowercased() == "www.fanbox.cc" }

    static func isPximgHost(_ host: String?) -> Bool { isUnder(host, domain: "pximg.net") }

    /// Hosts whose requests share the device-wide FANBOX request budget (RateGate): the JSON API and the www pages.
    static func isBudgetedHost(_ host: String?) -> Bool { isAPIHost(host) || isWWWHost(host) }
}

/// Builds the per-account request headers. Pure (no I/O), shared by the client and its redirect handling.
enum FanboxRequestHeaders {
    /// Headers the client always controls; values supplied by callers are dropped.
    static let controlledHeaders: Set<String> = ["cookie", "x-csrf-token"]

    /// Accept header for media downloads (images first, anything else accepted: attachments share the endpoint keys).
    static let mediaAccept = "image/avif,image/webp,image/*,*/*;q=0.8"

    /// Adds Accept / Origin / Referer / User-Agent / Cookie / X-CSRF-Token for `request.url`.
    /// - `Origin` goes to api.fanbox.cc only (a browser sends none on page / image GETs); `Referer` to FANBOX and pximg.
    /// - `isMedia`: adds an image `Accept` when the caller set none.
    /// - Throws: `RemoteError.csrfUnavailable` when `requiresCSRF` and the credential has no token (nothing is sent; the
    ///   session is not known to be invalid); `RemoteError.invalidRequest` when a CSRF token is requested for a non-FANBOX host.
    static func apply(to request: inout URLRequest, credential: SessionCredential?, requiresCSRF: Bool,
                      callerHeaders: [String: String] = [:], isMedia: Bool = false) throws {
        let url = request.url
        let host = url?.host?.lowercased()

        // Session headers are recomputed for every URL (including redirects).
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.setValue(nil, forHTTPHeaderField: "X-CSRF-Token")

        let callerHas: (String) -> Bool = { name in callerHeaders.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }

        if FanboxHostPolicy.isAPIHost(host), !callerHas("Accept") {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        } else if isMedia, !callerHas("Accept") {
            request.setValue(mediaAccept, forHTTPHeaderField: "Accept")
        }
        if FanboxHostPolicy.isFanboxHost(host) {
            // docs/API.md §1.2: Origin is required by the JSON API; www pages and downloads get none (browser-like).
            if FanboxHostPolicy.isAPIHost(host) {
                request.setValue(FanboxHostPolicy.origin, forHTTPHeaderField: "Origin")
            } else {
                request.setValue(nil, forHTTPHeaderField: "Origin")
            }
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
            guard let token = credential?.csrfToken, !token.isEmpty else { throw RemoteError.csrfUnavailable }
            request.setValue(token, forHTTPHeaderField: "X-CSRF-Token")
        }
    }
}

/// Maps HTTP statuses and transport errors to `RemoteError` (SPEC §44).
enum HTTPErrorMapper {
    /// nil for 2xx. `body` (when available) lets an edge block be told apart from a FANBOX 403 (`EdgeBlockDetector`).
    static func error(status: Int, headers: [String: String], body: Data? = nil, now: Date = .now) -> RemoteError? {
        if (200..<300).contains(status) { return nil }
        if EdgeBlockDetector.isEdgeBlock(status: status, headers: headers, body: body) {
            return .edgeBlocked(retryAfter: retryAfter(header(named: "Retry-After", in: headers), now: now))
        }
        switch status {
        case 300..<400: return .invalidRequest("FANBOX がリダイレクトを返しました (\(status))")
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

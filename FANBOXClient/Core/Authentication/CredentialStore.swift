import Foundation

/// Cookie captured from the account's WebKit store (or updated via Set-Cookie).
struct StoredCookie: Codable, Sendable, Hashable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expiresAt: Date?
    var isSecure: Bool
    var isHTTPOnly: Bool

    init(name: String, value: String, domain: String, path: String = "/", expiresAt: Date? = nil, isSecure: Bool = true,
         isHTTPOnly: Bool = true) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresAt = expiresAt
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }

    init(_ cookie: HTTPCookie) {
        self.init(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, expiresAt: cookie.expiresDate,
                  isSecure: cookie.isSecure, isHTTPOnly: cookie.isHTTPOnly)
    }

    /// RFC 6265 domain match: cookie domain ".fanbox.cc" matches "api.fanbox.cc".
    func matches(host: String) -> Bool {
        let d = normalizedDomain
        let h = host.lowercased()
        return h == d || h.hasSuffix("." + d)
    }

    /// Domain without the leading dot, lowercased (identity for merging).
    var normalizedDomain: String {
        (domain.hasPrefix(".") ? String(domain.dropFirst()) : domain).lowercased()
    }

    /// RFC 6265 path match: cookie path "/a" matches "/a", "/a/", "/a/b" but not "/ab".
    func matches(path requestPath: String) -> Bool {
        let cookiePath = path.isEmpty ? "/" : path
        let p = requestPath.isEmpty ? "/" : requestPath
        if p == cookiePath { return true }
        guard p.hasPrefix(cookiePath) else { return false }
        return cookiePath.hasSuffix("/") || p.dropFirst(cookiePath.count).hasPrefix("/")
    }

    func isExpired(now: Date = .now) -> Bool { expiresAt.map { $0 <= now } ?? false }
}

/// Session secret bundle for ONE account. Stored only in the Keychain (never in SwiftData / UserDefaults / logs).
struct SessionCredential: Codable, Sendable, Hashable {
    var cookies: [StoredCookie]
    /// User-Agent of the account's WKWebView (keeps API requests consistent with the web session).
    var userAgent: String?
    var csrfToken: String?
    var capturedAt: Date

    init(cookies: [StoredCookie], userAgent: String? = nil, csrfToken: String? = nil, capturedAt: Date = .now) {
        self.cookies = cookies
        self.userAgent = userAgent
        self.csrfToken = csrfToken
        self.capturedAt = capturedAt
    }

    static let sessionCookieName = "FANBOXSESSID"

    var hasSessionCookie: Bool { cookies.contains { $0.name == Self.sessionCookieName && !$0.value.isEmpty && !$0.isExpired() } }

    /// Current FANBOXSESSID value on a fanbox.cc domain (a secret: never log it).
    var sessionCookieValue: String? {
        cookies.first { $0.name == Self.sessionCookieName && !$0.value.isEmpty && !$0.isExpired()
            && ($0.normalizedDomain == "fanbox.cc" || $0.normalizedDomain.hasSuffix(".fanbox.cc")) }?.value
    }

    /// Cookies minted by the CDN for ONE client (bound to its UA / IP / TLS fingerprint, docs/API.md §1.3). They are
    /// never copied between the URLSession and the WebKit store.
    static func isEdgeCookie(name: String) -> Bool {
        let n = name.lowercased()
        return n == "cf_clearance" || n == "__cf_bm" || n.hasPrefix("cf_chl") || n.hasPrefix("__cf")
    }

    /// Merges Set-Cookie values like `merge(_:)`; when the session cookie changes, the CSRF token (bound to the old
    /// session, docs/API.md §1.4) is dropped so the next write fetches a fresh one.
    mutating func mergeResponseCookies(_ newCookies: [StoredCookie], now: Date = .now) {
        let before = sessionCookieValue
        merge(newCookies, now: now)
        if sessionCookieValue != before { csrfToken = nil }
    }

    /// `Cookie` header value for a host, or nil when no cookie matches.
    func cookieHeader(for host: String, now: Date = .now) -> String? {
        let pairs = cookies
            .filter { $0.matches(host: host) && !$0.isExpired(now: now) }
            .map { "\($0.name)=\($0.value)" }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    /// `Cookie` header value for a full URL: host + path match, and `Secure` cookies only over https.
    func cookieHeader(for url: URL, now: Date = .now) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let isHTTPS = url.scheme?.lowercased() == "https"
        let path = url.path.isEmpty ? "/" : url.path
        let pairs = cookies
            .filter { $0.matches(host: host) && $0.matches(path: path) && !$0.isExpired(now: now) && (isHTTPS || !$0.isSecure) }
            // RFC 6265 §5.4: longer paths first.
            .sorted { $0.path.count > $1.path.count }
            .map { "\($0.name)=\($0.value)" }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    /// Merges cookies (e.g. from Set-Cookie) by (name, domain, path). An already-expired cookie deletes the stored one.
    mutating func merge(_ newCookies: [StoredCookie], now: Date = .now) {
        for c in newCookies {
            cookies.removeAll { $0.name == c.name && $0.normalizedDomain == c.normalizedDomain && $0.path == c.path }
            if !c.isExpired(now: now) {
                cookies.append(c)
            }
        }
    }

    /// Drops expired cookies.
    mutating func removeExpired(now: Date = .now) {
        cookies.removeAll { $0.isExpired(now: now) }
    }
}

/// Per-account session secrets.
///
/// `updateCSRFToken` and `mergeCookies` only UPDATE an existing credential: a credential is created exclusively by an
/// explicit, verified `save` (login). A late response for a logged-out / removed account therefore can never re-create
/// its Keychain item.
protocol CredentialStoring: Sendable {
    func credential(for accountID: String) async -> SessionCredential?
    func save(_ credential: SessionCredential, for accountID: String) async throws
    func delete(for accountID: String) async throws
    func updateCSRFToken(_ token: String?, for accountID: String) async
    func mergeCookies(_ cookies: [StoredCookie], for accountID: String) async
    /// Sets the User-Agent of an EXISTING credential (the account WebView's UA). No credential → no-op.
    func updateUserAgent(_ userAgent: String, for accountID: String) async
    /// Account ids that currently have a stored credential (nil = the store cannot enumerate).
    func storedAccountIDs() async -> [String]?
}

extension CredentialStoring {
    func storedAccountIDs() async -> [String]? { nil }

    /// Default for test doubles (not atomic; the real stores override it).
    func updateUserAgent(_ userAgent: String, for accountID: String) async {
        guard var credential = await credential(for: accountID), credential.userAgent != userAgent else { return }
        credential.userAgent = userAgent
        try? await save(credential, for: accountID)
    }
}

/// Keychain-backed credential store, one Keychain item per account (SPEC §39).
///
/// - Item key: `credential.<accountID>`; value: JSON-encoded `SessionCredential`.
/// - Reads are served from an in-memory cache after the first Keychain hit (the HTTP client asks for every request).
/// - Nothing here is ever logged except Keychain status codes.
actor CredentialStore: CredentialStoring {
    static let keyPrefix = "credential."

    private let keychain: KeychainStore
    private var cache: [String: SessionCredential] = [:]
    /// Accounts known to have no Keychain item (avoids a Keychain query per request).
    private var knownMissing: Set<String> = []

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    static func key(for accountID: String) -> String { keyPrefix + accountID }

    func credential(for accountID: String) async -> SessionCredential? {
        if let cached = cache[accountID] { return cached }
        if knownMissing.contains(accountID) { return nil }
        do {
            guard let data = try keychain.data(for: Self.key(for: accountID)) else {
                knownMissing.insert(accountID)
                return nil
            }
            let credential = try Self.decoder.decode(SessionCredential.self, from: data)
            cache[accountID] = credential
            return credential
        } catch {
            // Unreadable item (e.g. device locked before first unlock, or corrupt JSON): do not cache the miss.
            AppLog.auth.error("credential load failed: \(Self.describe(error), privacy: .public)")
            return nil
        }
    }

    func save(_ credential: SessionCredential, for accountID: String) async throws {
        let data = try Self.encoder.encode(credential)
        try keychain.set(data, for: Self.key(for: accountID))
        cache[accountID] = credential
        knownMissing.remove(accountID)
    }

    func delete(for accountID: String) async throws {
        cache[accountID] = nil
        knownMissing.insert(accountID)
        try keychain.remove(Self.key(for: accountID))
    }

    /// Sets (or clears with nil) the CSRF token of an EXISTING credential and persists it. No credential → no-op.
    func updateCSRFToken(_ token: String?, for accountID: String) async {
        guard var updated = await credential(for: accountID) else { return }
        guard updated.csrfToken != token else { return }
        updated.csrfToken = token
        persist(updated, for: accountID)
    }

    /// Merges cookies (e.g. from Set-Cookie) into an EXISTING credential and persists. No credential → no-op.
    func mergeCookies(_ cookies: [StoredCookie], for accountID: String) async {
        guard !cookies.isEmpty, var updated = await credential(for: accountID) else { return }
        let before = updated
        updated.mergeResponseCookies(cookies)
        guard updated != before else { return }
        persist(updated, for: accountID)
    }

    func updateUserAgent(_ userAgent: String, for accountID: String) async {
        guard !userAgent.isEmpty, var updated = await credential(for: accountID), updated.userAgent != userAgent else { return }
        updated.userAgent = userAgent
        persist(updated, for: accountID)
    }

    /// Account IDs that have a stored credential.
    func storedAccountIDs() async -> [String]? {
        guard let keys = try? keychain.allKeys() else { return nil }
        return keys.filter { $0.hasPrefix(Self.keyPrefix) }.map { String($0.dropFirst(Self.keyPrefix.count)) }
    }

    /// Drops the in-memory cache (next read goes to the Keychain).
    func invalidateCache() {
        cache.removeAll()
        knownMissing.removeAll()
    }

    private func persist(_ credential: SessionCredential, for accountID: String) {
        cache[accountID] = credential
        knownMissing.remove(accountID)
        do {
            try keychain.set(try Self.encoder.encode(credential), for: Self.key(for: accountID))
        } catch {
            AppLog.auth.error("credential persist failed: \(Self.describe(error), privacy: .public)")
        }
    }

    private static func describe(_ error: Error) -> String {
        if let k = error as? KeychainError, case .unexpectedStatus(let status) = k { return "keychain status \(status)" }
        return String(describing: type(of: error))
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

/// In-memory store for tests / previews.
actor InMemoryCredentialStore: CredentialStoring {
    private var storage: [String: SessionCredential] = [:]

    init() {}

    func credential(for accountID: String) async -> SessionCredential? { storage[accountID] }
    func save(_ credential: SessionCredential, for accountID: String) async throws { storage[accountID] = credential }
    func delete(for accountID: String) async throws { storage[accountID] = nil }

    func updateCSRFToken(_ token: String?, for accountID: String) async {
        guard storage[accountID] != nil else { return }
        storage[accountID]?.csrfToken = token
    }

    func mergeCookies(_ cookies: [StoredCookie], for accountID: String) async {
        guard !cookies.isEmpty, var credential = storage[accountID] else { return }
        credential.mergeResponseCookies(cookies)
        storage[accountID] = credential
    }

    func updateUserAgent(_ userAgent: String, for accountID: String) async {
        guard storage[accountID] != nil else { return }
        storage[accountID]?.userAgent = userAgent
    }

    func storedAccountIDs() async -> [String]? { Array(storage.keys) }
}

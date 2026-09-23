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

protocol CredentialStoring: Sendable {
    func credential(for accountID: String) async -> SessionCredential?
    func save(_ credential: SessionCredential, for accountID: String) async throws
    func delete(for accountID: String) async throws
    func updateCSRFToken(_ token: String?, for accountID: String) async
    func mergeCookies(_ cookies: [StoredCookie], for accountID: String) async
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

    /// Sets (or clears with nil) the CSRF token and persists it. Creates a cookie-less credential when none exists yet.
    func updateCSRFToken(_ token: String?, for accountID: String) async {
        var credential = await credential(for: accountID)
        if credential == nil {
            guard let token, !token.isEmpty else { return }
            credential = SessionCredential(cookies: [])
        }
        guard var updated = credential else { return }
        guard updated.csrfToken != token else { return }
        updated.csrfToken = token
        persist(updated, for: accountID)
    }

    /// Merges cookies (e.g. from Set-Cookie) and persists. Creates the credential when none exists yet.
    func mergeCookies(_ cookies: [StoredCookie], for accountID: String) async {
        guard !cookies.isEmpty else { return }
        var updated = await credential(for: accountID) ?? SessionCredential(cookies: [])
        let before = updated
        updated.merge(cookies)
        guard updated != before else { return }
        persist(updated, for: accountID)
    }

    /// Account IDs that have a stored credential.
    func storedAccountIDs() -> [String] {
        let keys = (try? keychain.allKeys()) ?? []
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
        if storage[accountID] == nil {
            guard let token, !token.isEmpty else { return }
            storage[accountID] = SessionCredential(cookies: [])
        }
        storage[accountID]?.csrfToken = token
    }

    func mergeCookies(_ cookies: [StoredCookie], for accountID: String) async {
        guard !cookies.isEmpty else { return }
        var credential = storage[accountID] ?? SessionCredential(cookies: [])
        credential.merge(cookies)
        storage[accountID] = credential
    }
}

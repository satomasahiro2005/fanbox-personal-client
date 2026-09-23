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
        let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == d || host.hasSuffix("." + d)
    }
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

    var hasSessionCookie: Bool { cookies.contains { $0.name == Self.sessionCookieName && !$0.value.isEmpty } }

    /// `Cookie` header value for a host, or nil when no cookie matches.
    func cookieHeader(for host: String, now: Date = .now) -> String? {
        let pairs = cookies
            .filter { $0.matches(host: host) && ($0.expiresAt.map { $0 > now } ?? true) }
            .map { "\($0.name)=\($0.value)" }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    /// Merges cookies (e.g. from Set-Cookie) by (name, domain, path).
    mutating func merge(_ newCookies: [StoredCookie]) {
        for c in newCookies {
            cookies.removeAll { $0.name == c.name && $0.domain == c.domain && $0.path == c.path }
            cookies.append(c)
        }
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
actor CredentialStore: CredentialStoring {
    private let keychain: KeychainStore
    private var cache: [String: SessionCredential] = [:]

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    func credential(for accountID: String) async -> SessionCredential? { cache[accountID] }

    func save(_ credential: SessionCredential, for accountID: String) async throws { cache[accountID] = credential }

    func delete(for accountID: String) async throws { cache[accountID] = nil }

    func updateCSRFToken(_ token: String?, for accountID: String) async { cache[accountID]?.csrfToken = token }

    func mergeCookies(_ cookies: [StoredCookie], for accountID: String) async { cache[accountID]?.merge(cookies) }
}

/// In-memory store for tests / previews.
actor InMemoryCredentialStore: CredentialStoring {
    private var storage: [String: SessionCredential] = [:]

    init() {}

    func credential(for accountID: String) async -> SessionCredential? { storage[accountID] }
    func save(_ credential: SessionCredential, for accountID: String) async throws { storage[accountID] = credential }
    func delete(for accountID: String) async throws { storage[accountID] = nil }
    func updateCSRFToken(_ token: String?, for accountID: String) async { storage[accountID]?.csrfToken = token }
    func mergeCookies(_ cookies: [StoredCookie], for accountID: String) async { storage[accountID]?.merge(cookies) }
}

import Foundation
import WebKit

/// Which cookies belong to an account's FANBOX / pixiv session (SPEC §7.1 / §7.2).
/// Only these domains are ever copied between the WebKit store and the Keychain credential.
enum WebCookieScope {
    static let sessionDomains = ["fanbox.cc", "pixiv.net"]

    /// "fanbox.cc", ".fanbox.cc", "www.fanbox.cc", "accounts.pixiv.net" → true. "evilfanbox.cc" / "fanbox.cc.example" → false.
    static func isSessionDomain(_ domain: String) -> Bool {
        var d = domain.lowercased()
        while d.hasPrefix(".") { d.removeFirst() }
        guard !d.isEmpty else { return false }
        return sessionDomains.contains { d == $0 || d.hasSuffix("." + $0) }
    }

    /// Hosts that serve FANBOX pages (page metadata + CSRF live there).
    static func isFanboxHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "fanbox.cc" || host.hasSuffix(".fanbox.cc")
    }

    /// The FANBOX session cookie (non-empty `FANBOXSESSID` on a fanbox.cc domain).
    static func isFanboxSessionCookie(name: String, domain: String, value: String) -> Bool {
        guard name == SessionCredential.sessionCookieName, !value.isEmpty else { return false }
        var d = domain.lowercased()
        while d.hasPrefix(".") { d.removeFirst() }
        return d == "fanbox.cc" || d.hasSuffix(".fanbox.cc")
    }
}

/// One `WKWebsiteDataStore` per account (SPEC §7.1), keyed by `Account.webProfileID`.
/// Prevents cookie mixing, wrong-account payments and creator/viewer confusion.
///
/// Cookie values are secrets: this type never logs them (SPEC §38).
@MainActor
final class WebSessionStore {
    private var stores: [String: WKWebsiteDataStore] = [:]
    /// true → every profile gets its own `WKWebsiteDataStore.nonPersistent()` (unit tests / previews). Nothing touches disk.
    let usesEphemeralStores: Bool
    private let defaults: UserDefaults
    /// In-memory mirror of identifiers whose removal failed (store still in use by a WKWebView).
    private var pendingRemovals: Set<String>

    private static let pendingRemovalsKey = "web.pendingDataStoreRemovals"

    init(ephemeral: Bool = false, defaults: UserDefaults = .standard) {
        self.usesEphemeralStores = ephemeral
        self.defaults = defaults
        if ephemeral {
            pendingRemovals = []
        } else {
            pendingRemovals = Set(defaults.stringArray(forKey: Self.pendingRemovalsKey) ?? [])
        }
    }

    func dataStore(webProfileID: String) -> WKWebsiteDataStore {
        if let s = stores[webProfileID] { return s }
        let store: WKWebsiteDataStore
        if !usesEphemeralStores, let uuid = UUID(uuidString: webProfileID) {
            store = WKWebsiteDataStore(forIdentifier: uuid)
        } else {
            store = .nonPersistent()
        }
        stores[webProfileID] = store
        return store
    }

    /// FANBOX / pixiv cookies currently in the account's web store.
    func cookies(webProfileID: String) async -> [HTTPCookie] {
        let all = await dataStore(webProfileID: webProfileID).httpCookieStore.allCookies()
        return all.filter { WebCookieScope.isSessionDomain($0.domain) }
    }

    /// True when the account's web store holds a non-empty FANBOXSESSID cookie (i.e. a FANBOX login happened).
    func hasSessionCookie(webProfileID: String) async -> Bool {
        await cookies(webProfileID: webProfileID).contains {
            WebCookieScope.isFanboxSessionCookie(name: $0.name, domain: $0.domain, value: $0.value)
        }
    }

    /// Captures a `SessionCredential` (cookies + UA + CSRF) from the account's web store.
    /// Only fanbox.cc / pixiv.net cookies are captured. Returns nil when the store has none.
    func captureCredential(webProfileID: String, userAgent: String?, csrfToken: String?) async -> SessionCredential? {
        let cookies = await cookies(webProfileID: webProfileID)
        guard !cookies.isEmpty else { return nil }
        let stored = cookies.map(StoredCookie.init)
        return SessionCredential(cookies: stored, userAgent: Self.nonEmpty(userAgent), csrfToken: Self.nonEmpty(csrfToken))
    }

    /// Pushes cookies from the API credential back into the web store (keeps both in sync).
    /// Cookies outside fanbox.cc / pixiv.net are ignored.
    func install(_ credential: SessionCredential, webProfileID: String) async {
        let cookieStore = dataStore(webProfileID: webProfileID).httpCookieStore
        let now = Date()
        for cookie in credential.cookies where WebCookieScope.isSessionDomain(cookie.domain) {
            if let expiresAt = cookie.expiresAt, expiresAt <= now { continue }
            guard let httpCookie = Self.makeHTTPCookie(cookie) else { continue }
            await cookieStore.setCookie(httpCookie)
        }
    }

    /// Clears every kind of website data of the account but keeps its store identifier (logout).
    func clearData(webProfileID: String) async {
        let store = dataStore(webProfileID: webProfileID)
        await Self.wipe(store)
    }

    /// Deletes all website data of this account and its persistent store (account removal / abandoned login).
    /// If WebKit refuses to delete the store because a WKWebView still uses it, the data is still wiped and the
    /// identifier is retried by `purgePendingRemovals()`.
    func removeData(webProfileID: String) async {
        if let cached = stores.removeValue(forKey: webProfileID) {
            await Self.wipe(cached)
        } else if !usesEphemeralStores, let uuid = UUID(uuidString: webProfileID) {
            await Self.wipe(WKWebsiteDataStore(forIdentifier: uuid))
        }
        guard !usesEphemeralStores, let uuid = UUID(uuidString: webProfileID) else { return }
        await removePersistentStore(uuid, webProfileID: webProfileID)
    }

    /// Retries deleting stores whose removal failed earlier (called after web sessions close / on the accounts screen).
    func purgePendingRemovals() async {
        for webProfileID in pendingRemovals where stores[webProfileID] == nil {
            guard let uuid = UUID(uuidString: webProfileID) else {
                setPending(webProfileID, false)
                continue
            }
            await removePersistentStore(uuid, webProfileID: webProfileID)
        }
    }

    /// Identifiers waiting for deletion (diagnostics / tests).
    var pendingRemovalIDs: Set<String> { pendingRemovals }

    // MARK: - Helpers

    private func removePersistentStore(_ uuid: UUID, webProfileID: String) async {
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: uuid)
            setPending(webProfileID, false)
        } catch {
            let ns = error as NSError
            AppLog.web.notice("data store removal deferred (\(ns.domain, privacy: .public) \(ns.code, privacy: .public))")
            setPending(webProfileID, true)
        }
    }

    private func setPending(_ webProfileID: String, _ pending: Bool) {
        if pending { pendingRemovals.insert(webProfileID) } else { pendingRemovals.remove(webProfileID) }
        guard !usesEphemeralStores else { return }
        defaults.set(Array(pendingRemovals).sorted(), forKey: Self.pendingRemovalsKey)
    }

    private static func wipe(_ store: WKWebsiteDataStore) async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        // Cookies are also deleted one by one: `removeData` may leave session cookies of a live process behind.
        let cookieStore = store.httpCookieStore
        for cookie in await cookieStore.allCookies() {
            await cookieStore.deleteCookie(cookie)
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// `StoredCookie` → `HTTPCookie` for the WebKit cookie store.
    static func makeHTTPCookie(_ cookie: StoredCookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: cookie.value,
            .domain: cookie.domain,
            .path: cookie.path.isEmpty ? "/" : cookie.path,
        ]
        if let expiresAt = cookie.expiresAt { properties[.expires] = expiresAt }
        if cookie.isSecure { properties[.secure] = "TRUE" }
        if cookie.isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }
}

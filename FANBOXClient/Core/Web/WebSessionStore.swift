import Foundation
import WebKit

/// One `WKWebsiteDataStore` per account (SPEC §7.1), keyed by `Account.webProfileID`.
/// Prevents cookie mixing, wrong-account payments and creator/viewer confusion.
@MainActor
final class WebSessionStore {
    private var stores: [String: WKWebsiteDataStore] = [:]

    init() {}

    func dataStore(webProfileID: String) -> WKWebsiteDataStore {
        if let s = stores[webProfileID] { return s }
        let store: WKWebsiteDataStore
        if let uuid = UUID(uuidString: webProfileID) {
            store = WKWebsiteDataStore(forIdentifier: uuid)
        } else {
            store = .nonPersistent()
        }
        stores[webProfileID] = store
        return store
    }

    /// FANBOX / pixiv cookies currently in the account's web store.
    func cookies(webProfileID: String) async -> [HTTPCookie] { [] }

    /// Captures a `SessionCredential` (cookies + UA + CSRF) from the account's web store.
    func captureCredential(webProfileID: String, userAgent: String?, csrfToken: String?) async -> SessionCredential? { nil }

    /// Pushes cookies from the API credential back into the web store (keeps both in sync).
    func install(_ credential: SessionCredential, webProfileID: String) async {}

    /// Deletes all website data of this account (logout / account removal).
    func removeData(webProfileID: String) async {}
}

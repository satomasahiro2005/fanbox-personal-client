import Foundation
import Observation

/// Account lifecycle: add (login via account-aware WebView) / demo / remove / main / enable / session validation.
@MainActor
@Observable
final class AccountService {
    private(set) var loginInProgressAccountID: String?

    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let credentials: CredentialStoring
    @ObservationIgnored let webSessions: WebSessionStore
    @ObservationIgnored let remote: RemoteDataSourceProvider

    init(store: LocalStore, credentials: CredentialStoring, webSessions: WebSessionStore, remote: RemoteDataSourceProvider) {
        self.store = store
        self.credentials = credentials
        self.webSessions = webSessions
        self.remote = remote
    }

    /// Creates a disabled placeholder account whose isolated web store is used for the login WebView.
    func beginLogin() -> Account {
        let account = Account(displayName: "ログイン中…", enabled: false, sortOrder: store.accounts(includeDisabled: true).count)
        store.context.insert(account)
        store.save()
        loginInProgressAccountID = account.id
        return account
    }

    /// Captures the session from the account's web store, verifies it, fills profile fields and enables the account.
    func completeLogin(accountID: String, userAgent: String?, csrfToken: String?) async throws {}

    func cancelLogin(accountID: String) async {}

    @discardableResult
    func addDemoAccount(name: String = "Demo") -> Account {
        let isFirst = store.accounts(includeDisabled: true).isEmpty
        let account = Account(kind: .demo, displayName: name, pixivUserID: "demo-\(UUID().uuidString.prefix(6))", isMain: isFirst,
                              sortOrder: store.accounts(includeDisabled: true).count, sessionState: .valid)
        store.context.insert(account)
        store.save()
        return account
    }

    func remove(accountID: String) async {}

    func setMain(accountID: String) {
        for a in store.accounts(includeDisabled: true) { a.isMain = (a.id == accountID) }
        store.save()
    }

    func setEnabled(accountID: String, _ enabled: Bool) {
        store.account(id: accountID)?.enabled = enabled
        store.save()
    }

    /// Checks the session with a lightweight request and updates `Account.sessionState`.
    @discardableResult
    func validateSession(accountID: String) async -> SessionState { .unknown }

    /// Re-captures cookies from the web store after WebView navigation (e.g. re-login / Cloudflare challenge).
    func refreshCredentialFromWeb(accountID: String, userAgent: String?, csrfToken: String?) async {}
}

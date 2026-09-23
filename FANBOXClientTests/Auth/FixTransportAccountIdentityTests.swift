import SwiftData
import WebKit
import XCTest
@testable import FANBOXClient

/// Records revocations and whether the account still had its credential at that moment.
final class FixTransportRevoker: SessionRevoking, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(accountID: String, hadCredential: Bool)] = []
    let credentials: CredentialStoring

    init(credentials: CredentialStoring) { self.credentials = credentials }

    var calls: [(accountID: String, hadCredential: Bool)] { lock.withLock { _calls } }

    func revokeSession(accountID: String) async {
        let had = await credentials.credential(for: accountID) != nil
        lock.withLock { _calls.append((accountID, had)) }
    }
}

/// SPEC §3.2 / §7.1 / §40: a web session of another pixiv user never becomes an account's credential, and a detected
/// mismatch stops the account instead of letting it operate as the other user.
@MainActor
final class FixTransportAccountIdentityTests: XCTestCase {
    private var store: LocalStore!
    private var credentials: InMemoryCredentialStore!
    private var sessions: WebSessionStore!
    private var remote: AuthMockRemote!
    private var service: AccountService!
    private var revoker: FixTransportRevoker!

    private let oldCredential = SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "1001_old", domain: ".fanbox.cc",
                                                                         expiresAt: Date().addingTimeInterval(86400))],
                                                  userAgent: "UA/old", csrfToken: "old-token")

    override func setUp() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        store = LocalStore(container: container)
        credentials = InMemoryCredentialStore()
        sessions = WebSessionStore(ephemeral: true)
        remote = AuthMockRemote(user: .success(RemoteUser(pixivUserID: "1001", fanboxUserID: nil, name: "Alice", iconURL: nil, creatorID: nil)))
        service = AccountService(store: store, credentials: credentials, webSessions: sessions, remote: AuthMockProvider(mock: remote))
        revoker = FixTransportRevoker(credentials: credentials)
        service.sessionRevoker = revoker
    }

    override func tearDown() async throws {
        service = nil
        sessions = nil
        store = nil
    }

    private func makeAccount(pixivUserID: String, name: String) async throws -> Account {
        let account = Account(displayName: name, pixivUserID: pixivUserID, isMain: true, sessionState: .valid)
        store.context.insert(account)
        store.save()
        try await credentials.save(oldCredential, for: account.id)
        await sessions.install(oldCredential, webProfileID: account.webProfileID)
        return account
    }

    /// Simulates a login inside the account's web store: its session cookie is replaced by `value`.
    private func logInWebStore(_ account: Account, as value: String) async {
        await sessions.clearData(webProfileID: account.webProfileID)
        await sessions.install(SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: value, domain: ".fanbox.cc",
                                                                        expiresAt: Date().addingTimeInterval(86400))]),
                               webProfileID: account.webProfileID)
    }

    private func webSession(_ account: Account) async -> String? {
        await sessions.cookies(webProfileID: account.webProfileID).first { $0.name == "FANBOXSESSID" }?.value
    }

    // MARK: Re-login

    func testReloginAsAnotherUserPerPageNeverTouchesTheCredential() async throws {
        let a = try await makeAccount(pixivUserID: "1001", name: "Alice")
        await logInWebStore(a, as: "9999_bob")
        do {
            try await service.completeLogin(accountID: a.id, userAgent: nil, csrfToken: "bob-token",
                                            metadata: WebLoginMetadata(pixivUserID: "9999", name: "Bob"))
            XCTFail("expected mismatch")
        } catch let error as AccountLoginError {
            XCTAssertEqual(error, .accountMismatch(expectedName: "Alice"))
        }
        XCTAssertEqual(remote.currentUserCalls, 0, "rejected before the session is used for anything")
        let stored = await credentials.credential(for: a.id)
        XCTAssertEqual(stored, oldCredential)
        let web = await webSession(a)
        XCTAssertEqual(web, "1001_old", "the web store is reset to the account's own session")
        XCTAssertEqual(a.pixivUserID, "1001")
    }

    func testReloginAsAnotherUserPerProbeNeverTouchesTheCredential() async throws {
        let a = try await makeAccount(pixivUserID: "1001", name: "Alice")
        await logInWebStore(a, as: "9999_bob")
        remote.userResult = .success(RemoteUser(pixivUserID: "9999", fanboxUserID: nil, name: "Bob", iconURL: nil, creatorID: nil))
        do {
            try await service.completeLogin(accountID: a.id, userAgent: nil, csrfToken: nil, metadata: nil)
            XCTFail("expected mismatch")
        } catch let error as AccountLoginError {
            XCTAssertEqual(error, .accountMismatch(expectedName: "Alice"))
        }
        let stored = await credentials.credential(for: a.id)
        XCTAssertEqual(stored, oldCredential, "the credential was never overwritten, not even temporarily")
        let web = await webSession(a)
        XCTAssertEqual(web, "1001_old")
        let keys = await credentials.storedAccountIDs() ?? []
        XCTAssertEqual(keys, [a.id], "the probe key is removed")
        XCTAssertTrue(revoker.calls.contains { $0.accountID.hasPrefix(AccountService.probeKeyPrefix) })
    }

    func testDuplicateReloginResetsTheWebStoreAndKeepsTheCredential() async throws {
        let a = try await makeAccount(pixivUserID: "1001", name: "Alice")
        let b = Account(displayName: "Bob", pixivUserID: "2002", sessionState: .valid)
        store.context.insert(b)
        store.save()
        await logInWebStore(a, as: "2002_bob")
        remote.userResult = .success(RemoteUser(pixivUserID: "2002", fanboxUserID: nil, name: "Bob", iconURL: nil, creatorID: nil))
        do {
            try await service.completeLogin(accountID: a.id, userAgent: nil, csrfToken: nil)
            XCTFail("expected duplicate")
        } catch let error as AccountLoginError {
            guard case .duplicate = error else { return XCTFail("\(error)") }
        }
        let stored = await credentials.credential(for: a.id)
        XCTAssertEqual(stored, oldCredential)
        let web = await webSession(a)
        XCTAssertEqual(web, "1001_old")
    }

    func testVerifiedReloginRevokesInFlightWorkBeforeSaving() async throws {
        let a = try await makeAccount(pixivUserID: "1001", name: "Alice")
        a.sessionState = .error
        store.save()
        await logInWebStore(a, as: "1001_new")
        try await service.completeLogin(accountID: a.id, userAgent: "UA/new", csrfToken: "new-token")
        let stored = await credentials.credential(for: a.id)
        XCTAssertEqual(stored?.sessionCookieValue, "1001_new")
        XCTAssertEqual(a.sessionState, .valid, "a verified re-login clears the identity mismatch")
        XCTAssertTrue(revoker.calls.contains { $0.accountID == a.id })
    }

    // MARK: Browse / payment sessions

    func testBrowseSessionOfAnotherUserIsNotMergedAndIsReset() async throws {
        let a = try await makeAccount(pixivUserID: "1001", name: "Alice")
        await logInWebStore(a, as: "9999_bob")
        let result = await service.refreshCredentialFromWeb(accountID: a.id, userAgent: "UA", csrfToken: "bob-token", pageUserID: "9999")
        XCTAssertEqual(result, .identityMismatch(pageUserID: "9999"))
        let stored = await credentials.credential(for: a.id)
        XCTAssertEqual(stored, oldCredential)
        XCTAssertEqual(service.identityWarnings[a.id], "9999")
        let web = await webSession(a)
        XCTAssertEqual(web, "1001_old", "the payment / browse web view cannot keep operating as another user")
    }

    func testNewWebSessionWithoutPageIdentityIsVerifiedBeforeStoring() async throws {
        let a = try await makeAccount(pixivUserID: "1001", name: "Alice")
        await logInWebStore(a, as: "9999_bob")
        remote.userResult = .success(RemoteUser(pixivUserID: "9999", fanboxUserID: nil, name: "Bob", iconURL: nil, creatorID: nil))
        var result = await service.refreshCredentialFromWeb(accountID: a.id, userAgent: nil, csrfToken: nil)
        XCTAssertEqual(result, .identityMismatch(pageUserID: "9999"))
        var stored = await credentials.credential(for: a.id)
        XCTAssertEqual(stored, oldCredential)

        await logInWebStore(a, as: "1001_rotated")
        remote.userResult = .failure(.network(code: -1, detail: "x"))
        result = await service.refreshCredentialFromWeb(accountID: a.id, userAgent: nil, csrfToken: nil)
        XCTAssertEqual(result, .rejected, "an unverifiable new session never replaces the stored one")
        stored = await credentials.credential(for: a.id)
        XCTAssertEqual(stored, oldCredential)

        remote.userResult = .success(RemoteUser(pixivUserID: "1001", fanboxUserID: nil, name: "Alice", iconURL: nil, creatorID: nil))
        result = await service.refreshCredentialFromWeb(accountID: a.id, userAgent: nil, csrfToken: nil)
        XCTAssertEqual(result, .updated)
        stored = await credentials.credential(for: a.id)
        XCTAssertEqual(stored?.sessionCookieValue, "1001_rotated")
        XCTAssertNil(stored?.csrfToken, "the token of the previous session is not kept")
    }

    // MARK: Session check

    func testSessionOfAnotherUserIsQuarantined() async throws {
        let a = try await makeAccount(pixivUserID: "1001", name: "Alice")
        remote.userResult = .success(RemoteUser(pixivUserID: "9999", fanboxUserID: nil, name: "Bob", iconURL: nil, creatorID: nil))
        let result = await service.checkSession(accountID: a.id)
        XCTAssertEqual(result, .updated(.error))
        XCTAssertEqual(a.sessionState, .error)
        let stored = await credentials.credential(for: a.id)
        XCTAssertNil(stored, "a credential of another user is never kept for this account")
        let web = await webSession(a)
        XCTAssertNil(web)
        XCTAssertEqual(service.identityWarnings[a.id], "9999")
        XCTAssertEqual(a.pixivUserID, "1001")
    }

    // MARK: Logout / removal

    func testLogoutAndRemoveRevokeBeforeSecretsAreDeletedAndNothingComesBack() async throws {
        let a = try await makeAccount(pixivUserID: "1001", name: "Alice")
        await service.logout(accountID: a.id)
        XCTAssertEqual(revoker.calls.first?.accountID, a.id)
        XCTAssertEqual(revoker.calls.first?.hadCredential, true, "in-flight work is cancelled before the credential goes away")
        // A late Set-Cookie / CSRF refresh for the logged-out account cannot resurrect its credential.
        await credentials.mergeCookies([StoredCookie(name: "FANBOXSESSID", value: "late", domain: ".fanbox.cc")], for: a.id)
        await credentials.updateCSRFToken("late-token", for: a.id)
        await credentials.updateUserAgent("UA/late", for: a.id)
        let afterLogout = await credentials.credential(for: a.id)
        XCTAssertNil(afterLogout)

        let b = try await makeAccount(pixivUserID: "2002", name: "Bob")
        let bID = b.id
        await service.remove(accountID: bID)
        XCTAssertTrue(revoker.calls.contains { $0.accountID == bID && $0.hadCredential })
        await credentials.mergeCookies([StoredCookie(name: "FANBOXSESSID", value: "late", domain: ".fanbox.cc")], for: bID)
        let afterRemove = await credentials.credential(for: bID)
        XCTAssertNil(afterRemove)
    }

    func testInterruptedProbeCredentialsArePurged() async throws {
        let a = try await makeAccount(pixivUserID: "1001", name: "Alice")
        try await credentials.save(oldCredential, for: AccountService.probeKeyPrefix + "stale")
        try await credentials.save(oldCredential, for: "unknown-account")
        await service.purgeOrphanCredentials()
        let ids = await credentials.storedAccountIDs() ?? []
        XCTAssertEqual(Set(ids), [a.id, "unknown-account"], "only probe keys are purged")
    }

    func testRotatedAPISessionIsCopiedIntoTheWebStoreWithoutEdgeCookies() async throws {
        let a = try await makeAccount(pixivUserID: "1001", name: "Alice")
        var rotated = oldCredential
        rotated.cookies = [StoredCookie(name: "FANBOXSESSID", value: "1001_rotated", domain: ".fanbox.cc",
                                        expiresAt: Date().addingTimeInterval(3600)),
                           StoredCookie(name: "cf_clearance", value: "native-only", domain: ".fanbox.cc",
                                        expiresAt: Date().addingTimeInterval(3600))]
        try await credentials.save(rotated, for: a.id)
        await service.installAPISessionIntoWeb(accountID: a.id)
        let cookies = await sessions.cookies(webProfileID: a.webProfileID)
        XCTAssertEqual(cookies.first { $0.name == "FANBOXSESSID" }?.value, "1001_rotated")
        XCTAssertNil(cookies.first { $0.name == "cf_clearance" }, "CDN cookies minted by URLSession stay out of the web store")
    }
}

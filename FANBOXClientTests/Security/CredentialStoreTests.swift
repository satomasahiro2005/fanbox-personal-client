import XCTest
@testable import FANBOXClient

final class CredentialStoreTests: XCTestCase {
    private var keychain: KeychainStore!

    override func setUp() {
        super.setUp()
        keychain = KeychainStore(service: "ai.nemut.FANBOXClient.tests.cred.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? keychain.removeAll()
        keychain = nil
        super.tearDown()
    }

    private func sampleCredential() -> SessionCredential {
        SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "111_secret", domain: ".fanbox.cc"),
                                    StoredCookie(name: "p_ab_id", value: "1", domain: ".pixiv.net")],
                          userAgent: "UA", csrfToken: "csrf-1", capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testSavePersistsToKeychainAndReloads() async throws {
        let store = CredentialStore(keychain: keychain)
        let missing = await store.credential(for: "acc")
        XCTAssertNil(missing)
        try await store.save(sampleCredential(), for: "acc")
        XCTAssertEqual(try keychain.allKeys(), ["credential.acc"])

        // A fresh instance (no cache) reads the Keychain item.
        let reloaded = await CredentialStore(keychain: keychain).credential(for: "acc")
        XCTAssertEqual(reloaded, sampleCredential())
        let ids = await store.storedAccountIDs()
        XCTAssertEqual(ids, ["acc"])
        // Stored as JSON, but never in plain UserDefaults.
        XCTAssertNil(UserDefaults.standard.object(forKey: "credential.acc"))
    }

    func testUpdateCSRFTokenPersists() async throws {
        let store = CredentialStore(keychain: keychain)
        try await store.save(sampleCredential(), for: "acc")
        await store.updateCSRFToken("csrf-2", for: "acc")
        let reloaded = await CredentialStore(keychain: keychain).credential(for: "acc")
        XCTAssertEqual(reloaded?.csrfToken, "csrf-2")
        XCTAssertTrue(reloaded?.hasSessionCookie ?? false)

        await store.updateCSRFToken(nil, for: "acc")
        let cleared = await CredentialStore(keychain: keychain).credential(for: "acc")
        XCTAssertNil(cleared?.csrfToken)
    }

    func testMergeCookiesPersistsReplacesAndDeletesExpired() async throws {
        let store = CredentialStore(keychain: keychain)
        try await store.save(sampleCredential(), for: "acc")
        await store.mergeCookies([StoredCookie(name: "FANBOXSESSID", value: "222_new", domain: "fanbox.cc"),
                                  StoredCookie(name: "new_cookie", value: "x", domain: ".fanbox.cc")], for: "acc")
        var reloaded = await CredentialStore(keychain: keychain).credential(for: "acc")
        XCTAssertEqual(reloaded?.cookies.filter { $0.name == "FANBOXSESSID" }.map(\.value), ["222_new"])
        XCTAssertEqual(reloaded?.cookies.count, 3)

        // An already-expired Set-Cookie deletes the stored cookie.
        await store.mergeCookies([StoredCookie(name: "new_cookie", value: "", domain: ".fanbox.cc",
                                               expiresAt: Date(timeIntervalSinceNow: -60))], for: "acc")
        reloaded = await CredentialStore(keychain: keychain).credential(for: "acc")
        XCTAssertFalse(reloaded?.cookies.contains { $0.name == "new_cookie" } ?? true)
    }

    /// Updated for the transport fix: Set-Cookie / CSRF updates never CREATE a credential (a late response for a
    /// logged-out or removed account must not resurrect its Keychain item). Only an explicit `save` creates one.
    func testMergeNeverCreatesCredentialAndDeleteRemoves() async throws {
        let store = CredentialStore(keychain: keychain)
        await store.mergeCookies([StoredCookie(name: "FANBOXSESSID", value: "v", domain: ".fanbox.cc")], for: "new")
        await store.updateCSRFToken("t", for: "new")
        let notCreated = await CredentialStore(keychain: keychain).credential(for: "new")
        XCTAssertNil(notCreated)
        XCTAssertEqual(try keychain.allKeys(), [])

        try await store.save(SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "v", domain: ".fanbox.cc")]),
                             for: "new")
        await store.mergeCookies([StoredCookie(name: "x", value: "1", domain: ".fanbox.cc")], for: "new")
        let created = await CredentialStore(keychain: keychain).credential(for: "new")
        XCTAssertEqual(created?.cookies.count, 2)

        try await store.delete(for: "new")
        // A late Set-Cookie after the delete does not bring it back.
        await store.mergeCookies([StoredCookie(name: "FANBOXSESSID", value: "late", domain: ".fanbox.cc")], for: "new")
        let afterDelete = await store.credential(for: "new")
        XCTAssertNil(afterDelete)
        let fresh = await CredentialStore(keychain: keychain).credential(for: "new")
        XCTAssertNil(fresh)
        XCTAssertEqual(try keychain.allKeys(), [])
    }

    func testAccountsAreIsolated() async throws {
        let store = CredentialStore(keychain: keychain)
        try await store.save(sampleCredential(), for: "A")
        var b = sampleCredential()
        b.cookies = [StoredCookie(name: "FANBOXSESSID", value: "B_only", domain: ".fanbox.cc")]
        try await store.save(b, for: "B")
        let a = await store.credential(for: "A")
        let bb = await store.credential(for: "B")
        XCTAssertEqual(a?.cookieHeader(for: "api.fanbox.cc"), "FANBOXSESSID=111_secret")
        XCTAssertEqual(bb?.cookieHeader(for: "api.fanbox.cc"), "FANBOXSESSID=B_only")
    }

    func testCookieHeaderForURLHonorsHostPathSecureAndExpiry() {
        let credential = SessionCredential(cookies: [
            StoredCookie(name: "a", value: "1", domain: ".fanbox.cc"),
            StoredCookie(name: "b", value: "2", domain: "api.fanbox.cc", path: "/post"),
            StoredCookie(name: "c", value: "3", domain: ".fanbox.cc", isSecure: false),
            StoredCookie(name: "old", value: "x", domain: ".fanbox.cc", expiresAt: Date(timeIntervalSinceNow: -1)),
            StoredCookie(name: "px", value: "p", domain: ".pixiv.net"),
        ])
        XCTAssertEqual(credential.cookieHeader(for: URL(string: "https://api.fanbox.cc/post.info")!), "a=1; c=3")
        XCTAssertEqual(credential.cookieHeader(for: URL(string: "https://api.fanbox.cc/post/1")!), "b=2; a=1; c=3")
        XCTAssertEqual(credential.cookieHeader(for: URL(string: "http://www.fanbox.cc/")!), "c=3")
        XCTAssertNil(credential.cookieHeader(for: URL(string: "https://notfanbox.cc/")!))
        XCTAssertNil(credential.cookieHeader(for: URL(string: "https://example.com/")!))
        XCTAssertEqual(credential.cookieHeader(for: URL(string: "https://www.pixiv.net/")!), "px=p")
    }

    /// Updated for the transport fix: like the Keychain store, the in-memory store only updates existing credentials,
    /// and a rotated FANBOXSESSID drops the CSRF token bound to the old session.
    func testInMemoryStoreMergeAndCSRF() async throws {
        let store = InMemoryCredentialStore()
        await store.updateCSRFToken("t", for: "x")
        await store.mergeCookies([StoredCookie(name: "FANBOXSESSID", value: "v", domain: ".fanbox.cc")], for: "x")
        let missing = await store.credential(for: "x")
        XCTAssertNil(missing)

        try await store.save(SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "v", domain: ".fanbox.cc")]), for: "x")
        await store.updateCSRFToken("t", for: "x")
        await store.mergeCookies([StoredCookie(name: "__cf_bm", value: "b", domain: ".fanbox.cc")], for: "x")
        var c = await store.credential(for: "x")
        XCTAssertEqual(c?.csrfToken, "t", "an unrelated cookie keeps the token")
        XCTAssertTrue(c?.hasSessionCookie ?? false)
        await store.mergeCookies([StoredCookie(name: "FANBOXSESSID", value: "v2", domain: ".fanbox.cc")], for: "x")
        c = await store.credential(for: "x")
        XCTAssertNil(c?.csrfToken, "the token of the previous session is dropped")
        XCTAssertEqual(c?.sessionCookieValue, "v2")
    }
}

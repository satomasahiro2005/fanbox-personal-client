import WebKit
import XCTest
@testable import FANBOXClient

@MainActor
final class WebSessionStoreTests: XCTestCase {
    private func cookie(_ name: String, _ value: String, domain: String, path: String = "/") -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: path,
                                .expires: Date().addingTimeInterval(3600)])!
    }

    func testSessionDomainFilter() {
        XCTAssertTrue(WebCookieScope.isSessionDomain("fanbox.cc"))
        XCTAssertTrue(WebCookieScope.isSessionDomain(".fanbox.cc"))
        XCTAssertTrue(WebCookieScope.isSessionDomain("www.fanbox.cc"))
        XCTAssertTrue(WebCookieScope.isSessionDomain("api.fanbox.cc"))
        XCTAssertTrue(WebCookieScope.isSessionDomain(".pixiv.net"))
        XCTAssertTrue(WebCookieScope.isSessionDomain("accounts.pixiv.net"))
        XCTAssertTrue(WebCookieScope.isSessionDomain("WWW.FANBOX.CC"))
        XCTAssertFalse(WebCookieScope.isSessionDomain("evilfanbox.cc"))
        XCTAssertFalse(WebCookieScope.isSessionDomain("fanbox.cc.example.com"))
        XCTAssertFalse(WebCookieScope.isSessionDomain(".google.com"))
        XCTAssertFalse(WebCookieScope.isSessionDomain(""))
        XCTAssertFalse(WebCookieScope.isSessionDomain("."))

        XCTAssertTrue(WebCookieScope.isFanboxHost("www.fanbox.cc"))
        XCTAssertTrue(WebCookieScope.isFanboxHost("fanbox.cc"))
        XCTAssertFalse(WebCookieScope.isFanboxHost("accounts.pixiv.net"))
        XCTAssertFalse(WebCookieScope.isFanboxHost("notfanbox.cc"))
        XCTAssertFalse(WebCookieScope.isFanboxHost(nil))

        XCTAssertTrue(WebCookieScope.isFanboxSessionCookie(name: "FANBOXSESSID", domain: ".fanbox.cc", value: "x"))
        XCTAssertFalse(WebCookieScope.isFanboxSessionCookie(name: "FANBOXSESSID", domain: ".fanbox.cc", value: ""))
        XCTAssertFalse(WebCookieScope.isFanboxSessionCookie(name: "FANBOXSESSID", domain: ".pixiv.net", value: "x"))
        XCTAssertFalse(WebCookieScope.isFanboxSessionCookie(name: "PHPSESSID", domain: ".fanbox.cc", value: "x"))
    }

    func testCaptureKeepsOnlyFanboxAndPixivCookies() async {
        let sessions = WebSessionStore(ephemeral: true)
        let profile = UUID().uuidString
        let cookieStore = sessions.dataStore(webProfileID: profile).httpCookieStore
        await cookieStore.setCookie(cookie("FANBOXSESSID", "sess-value", domain: ".fanbox.cc"))
        await cookieStore.setCookie(cookie("PHPSESSID", "pixiv-value", domain: ".pixiv.net"))
        await cookieStore.setCookie(cookie("tracker", "other", domain: ".example.com"))
        await cookieStore.setCookie(cookie("fake", "evil", domain: "evilfanbox.cc"))

        let cookies = await sessions.cookies(webProfileID: profile)
        XCTAssertEqual(Set(cookies.map(\.name)), ["FANBOXSESSID", "PHPSESSID"])
        let hasSession = await sessions.hasSessionCookie(webProfileID: profile)
        XCTAssertTrue(hasSession)

        let credential = await sessions.captureCredential(webProfileID: profile, userAgent: "UA/1", csrfToken: "csrf-1")
        XCTAssertNotNil(credential)
        XCTAssertEqual(credential?.userAgent, "UA/1")
        XCTAssertEqual(credential?.csrfToken, "csrf-1")
        XCTAssertEqual(credential?.hasSessionCookie, true)
        XCTAssertEqual(Set(credential?.cookies.map(\.name) ?? []), ["FANBOXSESSID", "PHPSESSID"])
        XCTAssertFalse(credential?.cookies.contains { $0.domain.contains("example.com") || $0.domain.contains("evil") } ?? true)
        XCTAssertEqual(credential?.cookieHeader(for: "api.fanbox.cc"), "FANBOXSESSID=sess-value")
    }

    func testCaptureReturnsNilForEmptyStoreAndEmptyStringsBecomeNil() async {
        let sessions = WebSessionStore(ephemeral: true)
        let empty = await sessions.captureCredential(webProfileID: UUID().uuidString, userAgent: "UA", csrfToken: "t")
        XCTAssertNil(empty)

        let profile = UUID().uuidString
        await sessions.dataStore(webProfileID: profile).httpCookieStore.setCookie(cookie("p_ab_id", "1", domain: ".pixiv.net"))
        let credential = await sessions.captureCredential(webProfileID: profile, userAgent: "", csrfToken: "")
        XCTAssertNil(credential?.userAgent)
        XCTAssertNil(credential?.csrfToken)
        XCTAssertEqual(credential?.hasSessionCookie, false)
    }

    func testInstallRoundTripIntoAnotherProfile() async {
        let sessions = WebSessionStore(ephemeral: true)
        let credential = SessionCredential(cookies: [
            StoredCookie(name: "FANBOXSESSID", value: "12345_abc", domain: ".fanbox.cc", expiresAt: Date().addingTimeInterval(86400)),
            StoredCookie(name: "PHPSESSID", value: "p-1", domain: ".pixiv.net", expiresAt: Date().addingTimeInterval(86400), isHTTPOnly: false),
            StoredCookie(name: "foreign", value: "nope", domain: ".example.com"),
            StoredCookie(name: "stale", value: "old", domain: ".fanbox.cc", expiresAt: Date().addingTimeInterval(-60)),
        ], userAgent: "UA", csrfToken: "token")
        let profile = UUID().uuidString
        await sessions.install(credential, webProfileID: profile)

        let captured = await sessions.captureCredential(webProfileID: profile, userAgent: "UA", csrfToken: "token")
        let byName = Dictionary(uniqueKeysWithValues: (captured?.cookies ?? []).map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["FANBOXSESSID", "PHPSESSID"])
        XCTAssertEqual(byName["FANBOXSESSID"]?.value, "12345_abc")
        XCTAssertEqual(byName["FANBOXSESSID"]?.isSecure, true)
        XCTAssertEqual(byName["FANBOXSESSID"]?.isHTTPOnly, true)
        XCTAssertEqual(byName["PHPSESSID"]?.isHTTPOnly, false)
        XCTAssertEqual(captured?.hasSessionCookie, true)
    }

    func testProfilesAreIsolated() async {
        let sessions = WebSessionStore(ephemeral: true)
        let a = UUID().uuidString
        let b = UUID().uuidString
        XCTAssertFalse(sessions.dataStore(webProfileID: a) === sessions.dataStore(webProfileID: b))
        XCTAssertTrue(sessions.dataStore(webProfileID: a) === sessions.dataStore(webProfileID: a))
        await sessions.dataStore(webProfileID: a).httpCookieStore.setCookie(cookie("FANBOXSESSID", "a-session", domain: ".fanbox.cc"))
        let aHas = await sessions.hasSessionCookie(webProfileID: a)
        let bHas = await sessions.hasSessionCookie(webProfileID: b)
        XCTAssertTrue(aHas)
        XCTAssertFalse(bHas)
    }

    func testRemoveAndClearDataDeleteCookies() async {
        let sessions = WebSessionStore(ephemeral: true)
        let profile = UUID().uuidString
        let store = sessions.dataStore(webProfileID: profile)
        await store.httpCookieStore.setCookie(cookie("FANBOXSESSID", "x", domain: ".fanbox.cc"))
        await sessions.clearData(webProfileID: profile)
        let afterClear = await sessions.cookies(webProfileID: profile)
        XCTAssertTrue(afterClear.isEmpty)

        await store.httpCookieStore.setCookie(cookie("FANBOXSESSID", "y", domain: ".fanbox.cc"))
        await sessions.removeData(webProfileID: profile)
        let remaining = await store.httpCookieStore.allCookies()
        XCTAssertTrue(remaining.isEmpty)
        // A fresh store is handed out afterwards (the removed one is no longer cached).
        XCTAssertFalse(sessions.dataStore(webProfileID: profile) === store)
    }

    func testMakeHTTPCookieCarriesAttributes() {
        let expires = Date().addingTimeInterval(1000)
        let made = WebSessionStore.makeHTTPCookie(StoredCookie(name: "n", value: "v", domain: ".fanbox.cc", path: "", expiresAt: expires,
                                                               isSecure: true, isHTTPOnly: true))
        XCTAssertEqual(made?.name, "n")
        XCTAssertEqual(made?.path, "/")
        XCTAssertEqual(made?.isSecure, true)
        XCTAssertEqual(made?.isHTTPOnly, true)
        XCTAssertEqual(made?.expiresDate?.timeIntervalSince1970 ?? 0, expires.timeIntervalSince1970, accuracy: 1)
    }
}

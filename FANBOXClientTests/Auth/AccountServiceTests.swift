import SwiftData
import WebKit
import XCTest
@testable import FANBOXClient

@MainActor
final class AccountServiceTests: XCTestCase {
    private var store: LocalStore!
    private var credentials: InMemoryCredentialStore!
    private var sessions: WebSessionStore!
    private var remote: AuthMockRemote!
    private var service: AccountService!

    override func setUp() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        store = LocalStore(container: container)
        credentials = InMemoryCredentialStore()
        sessions = WebSessionStore(ephemeral: true)
        remote = AuthMockRemote(user: .success(RemoteUser(pixivUserID: "1001", fanboxUserID: "f-1001", name: "Alice",
                                                           iconURL: "https://example.test/alice.png", creatorID: nil)))
        service = AccountService(store: store, credentials: credentials, webSessions: sessions, remote: AuthMockProvider(mock: remote))
    }

    override func tearDown() async throws {
        service = nil
        sessions = nil
        store = nil
    }

    // MARK: Helpers

    private func putSessionCookie(for account: Account, value: String = "1001_sessionvalue") async {
        let cookie = HTTPCookie(properties: [.name: "FANBOXSESSID", .value: value, .domain: ".fanbox.cc", .path: "/",
                                             .expires: Date().addingTimeInterval(86400)])!
        await sessions.dataStore(webProfileID: account.webProfileID).httpCookieStore.setCookie(cookie)
    }

    private func makeRealAccount(pixivUserID: String, name: String, main: Bool = false) -> Account {
        let account = Account(displayName: name, pixivUserID: pixivUserID, isMain: main, sessionState: .valid)
        store.context.insert(account)
        store.save()
        return account
    }

    // MARK: Demo / main

    func testAddDemoAccountsFirstIsMainAndColorsDiffer() {
        let a = service.addDemoAccount(name: "Demo A")
        let b = service.addDemoAccount(name: "Demo B")
        XCTAssertEqual(a.kind, .demo)
        XCTAssertTrue(a.enabled)
        XCTAssertEqual(a.sessionState, .valid)
        XCTAssertTrue(a.isMain)
        XCTAssertFalse(b.isMain)
        XCTAssertNotNil(a.colorHex)
        XCTAssertNotNil(b.colorHex)
        XCTAssertNotEqual(a.colorHex, b.colorHex)
        XCTAssertGreaterThan(b.sortOrder, a.sortOrder)
        XCTAssertEqual(store.accounts().count, 2)
        XCTAssertEqual(service.nextDemoName(), "Demo 3")
    }

    func testMainAccountIsAlwaysUnique() {
        let a = service.addDemoAccount(name: "A")
        let b = service.addDemoAccount(name: "B")
        let c = service.addDemoAccount(name: "C")
        service.setMain(accountID: b.id)
        XCTAssertEqual(store.accounts(includeDisabled: true).filter(\.isMain).map(\.id), [b.id])

        // Disabling the main account moves "main" to another enabled account.
        service.setEnabled(accountID: b.id, false)
        let mains = store.accounts(includeDisabled: true).filter(\.isMain)
        XCTAssertEqual(mains.count, 1)
        XCTAssertNotEqual(mains.first?.id, b.id)
        XCTAssertTrue(mains.first?.enabled ?? false)

        // Making a disabled account main re-enables it.
        service.setMain(accountID: b.id)
        XCTAssertTrue(b.enabled)
        XCTAssertEqual(store.accounts(includeDisabled: true).filter(\.isMain).map(\.id), [b.id])
        XCTAssertFalse(a.isMain)
        XCTAssertFalse(c.isMain)
    }

    func testReorderAndPaletteAssignment() {
        let a = service.addDemoAccount(name: "A")
        let b = service.addDemoAccount(name: "B")
        let c = service.addDemoAccount(name: "C")
        service.move([a.id, b.id, c.id], fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(store.accounts().map(\.id), [c.id, a.id, b.id])

        XCTAssertEqual(AccountColorPalette.next(used: []), "#8B5CF6")
        XCTAssertEqual(AccountColorPalette.next(used: ["#8b5cf6"]), "#2DD4BF")
        let all = AccountColorPalette.hexes.map { Optional($0) }
        XCTAssertTrue(AccountColorPalette.hexes.contains(AccountColorPalette.next(used: all)))
    }

    // MARK: Login

    func testBeginLoginCreatesDisabledPlaceholder() {
        let placeholder = service.beginLogin()
        XCTAssertTrue(AccountService.isPlaceholder(placeholder))
        XCTAssertFalse(placeholder.enabled)
        XCTAssertEqual(service.loginInProgressAccountID, placeholder.id)
        XCTAssertNotNil(placeholder.colorHex)
        XCTAssertTrue(store.accounts().isEmpty, "placeholders are not enabled accounts")
    }

    func testCompleteLoginFailsWithoutSessionCookie() async {
        let placeholder = service.beginLogin()
        do {
            try await service.completeLogin(accountID: placeholder.id, userAgent: "UA", csrfToken: "t")
            XCTFail("expected noSessionCookie")
        } catch let error as AccountLoginError {
            XCTAssertEqual(error, .noSessionCookie)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertNotNil(store.account(id: placeholder.id), "placeholder stays so the user can keep logging in")
        let saved = await credentials.credential(for: placeholder.id)
        XCTAssertNil(saved)
        XCTAssertEqual(remote.currentUserCalls, 0)
    }

    func testCompleteLoginFillsProfileAndBecomesFirstRealMain() async throws {
        let demo = service.addDemoAccount(name: "Demo A")
        XCTAssertTrue(demo.isMain)
        remote.userResult = .success(RemoteUser(pixivUserID: "1001", fanboxUserID: "f-1001", name: "Alice",
                                                iconURL: "https://example.test/alice.png", creatorID: "alice"))
        let placeholder = service.beginLogin()
        await putSessionCookie(for: placeholder)

        try await service.completeLogin(accountID: placeholder.id, userAgent: "UA/1", csrfToken: "csrf-x")

        let account = try XCTUnwrap(store.account(id: placeholder.id))
        XCTAssertEqual(account.pixivUserID, "1001")
        XCTAssertEqual(account.fanboxUserID, "f-1001")
        XCTAssertEqual(account.displayName, "Alice")
        XCTAssertEqual(account.avatarURL, "https://example.test/alice.png")
        XCTAssertEqual(account.creatorID, "alice")
        XCTAssertEqual(account.sessionState, .valid)
        XCTAssertNotNil(account.sessionCheckedAt)
        XCTAssertTrue(account.enabled)
        XCTAssertTrue(account.isMain, "first real account becomes main")
        XCTAssertFalse(demo.isMain)
        XCTAssertFalse(AccountService.isPlaceholder(account))
        XCTAssertNil(service.loginInProgressAccountID)
        XCTAssertEqual(store.creator(id: "alice")?.ownedByAccountID, account.id)

        let maybeSaved = await credentials.credential(for: account.id)
        let saved = try XCTUnwrap(maybeSaved)
        XCTAssertTrue(saved.hasSessionCookie)
        XCTAssertEqual(saved.userAgent, "UA/1")
        XCTAssertEqual(saved.csrfToken, "csrf-x")
        XCTAssertEqual(remote.currentUserCalls, 1)

        // A second real account does not steal "main".
        remote.userResult = .success(RemoteUser(pixivUserID: "2002", fanboxUserID: nil, name: "Bob", iconURL: nil, creatorID: nil))
        let second = service.beginLogin()
        await putSessionCookie(for: second, value: "2002_x")
        try await service.completeLogin(accountID: second.id, userAgent: nil, csrfToken: nil)
        XCTAssertFalse(try XCTUnwrap(store.account(id: second.id)).isMain)
        XCTAssertTrue(account.isMain)
        XCTAssertEqual(store.accounts(includeDisabled: true).filter(\.isMain).count, 1)
    }

    func testCompleteLoginFallsBackToPageMetadata() async throws {
        remote.userResult = .failure(.decoding(endpoint: "user", detail: "x"))
        let placeholder = service.beginLogin()
        await putSessionCookie(for: placeholder)
        let metadata = WebLoginMetadata(pixivUserID: "3003", name: "Carol", iconURL: nil, creatorID: "carol")
        try await service.completeLogin(accountID: placeholder.id, userAgent: "UA", csrfToken: "t", metadata: metadata)
        let account = try XCTUnwrap(store.account(id: placeholder.id))
        XCTAssertEqual(account.pixivUserID, "3003")
        XCTAssertEqual(account.displayName, "Carol")
        XCTAssertEqual(account.creatorID, "carol")
        XCTAssertTrue(account.enabled)
    }

    func testCompleteLoginWithoutAnyProfileSourceFailsAndRollsBackCredential() async {
        remote.userResult = .failure(.unauthorized)
        let placeholder = service.beginLogin()
        await putSessionCookie(for: placeholder)
        do {
            try await service.completeLogin(accountID: placeholder.id, userAgent: nil, csrfToken: nil)
            XCTFail("expected profileUnavailable")
        } catch let error as AccountLoginError {
            guard case .profileUnavailable = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
        let saved = await credentials.credential(for: placeholder.id)
        XCTAssertNil(saved)
        XCTAssertTrue(AccountService.isPlaceholder(try XCTUnwrap(store.account(id: placeholder.id))))
    }

    func testDuplicateLoginIsRejectedAndPlaceholderCleanedUp() async {
        let existing = makeRealAccount(pixivUserID: "1001", name: "Alice (existing)", main: true)
        remote.userResult = .success(RemoteUser(pixivUserID: "1001", fanboxUserID: nil, name: "Alice", iconURL: nil, creatorID: nil))
        let placeholder = service.beginLogin()
        let placeholderID = placeholder.id
        let profile = placeholder.webProfileID
        await putSessionCookie(for: placeholder)

        do {
            try await service.completeLogin(accountID: placeholderID, userAgent: nil, csrfToken: nil)
            XCTFail("expected duplicate")
        } catch let error as AccountLoginError {
            XCTAssertEqual(error, .duplicate(existingAccountID: existing.id, existingName: "Alice (existing)"))
            XCTAssertTrue(error.userMessage.contains("Alice (existing)"))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertNil(store.account(id: placeholderID), "placeholder removed")
        XCTAssertNil(service.loginInProgressAccountID)
        let saved = await credentials.credential(for: placeholderID)
        XCTAssertNil(saved)
        let hasSession = await sessions.hasSessionCookie(webProfileID: profile)
        XCTAssertFalse(hasSession, "web data of the placeholder removed")
        XCTAssertEqual(store.accounts(includeDisabled: true).map(\.id), [existing.id])
    }

    func testReloginWithDifferentUserIsRejected() async throws {
        let account = makeRealAccount(pixivUserID: "1001", name: "Alice")
        let old = SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "old", domain: ".fanbox.cc")])
        try await credentials.save(old, for: account.id)
        remote.userResult = .success(RemoteUser(pixivUserID: "9999", fanboxUserID: nil, name: "Mallory", iconURL: nil, creatorID: nil))
        await putSessionCookie(for: account, value: "9999_new")
        do {
            try await service.completeLogin(accountID: account.id, userAgent: nil, csrfToken: nil)
            XCTFail("expected mismatch")
        } catch let error as AccountLoginError {
            XCTAssertEqual(error, .accountMismatch(expectedName: "Alice"))
        }
        XCTAssertEqual(account.pixivUserID, "1001")
        XCTAssertEqual(account.displayName, "Alice")
        let restored = await credentials.credential(for: account.id)
        XCTAssertEqual(restored, old, "previous credential restored")
    }

    func testCancelLoginRemovesOnlyPlaceholders() async {
        let real = makeRealAccount(pixivUserID: "1001", name: "Alice")
        await service.cancelLogin(accountID: real.id)
        XCTAssertNotNil(store.account(id: real.id))

        let placeholder = service.beginLogin()
        let id = placeholder.id
        await putSessionCookie(for: placeholder)
        await service.cancelLogin(accountID: id)
        XCTAssertNil(store.account(id: id))
        XCTAssertNil(service.loginInProgressAccountID)

        let orphan = Account(displayName: "ログイン中…", enabled: false)
        store.context.insert(orphan)
        store.save()
        await service.cleanupAbandonedPlaceholders()
        XCTAssertNil(store.account(id: orphan.id))
        XCTAssertNotNil(store.account(id: real.id))
    }

    // MARK: Remove

    func testRemoveCleansAccountScopedRowsButKeepsContent() async throws {
        let a = makeRealAccount(pixivUserID: "1001", name: "A", main: true)
        let b = makeRealAccount(pixivUserID: "2002", name: "B")
        let aID = a.id
        let bID = b.id
        try await credentials.save(SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "x", domain: ".fanbox.cc")]), for: aID)
        let ctx = store.context

        let post = Post(postID: "p1", creatorID: "c1", creatorName: "C1", title: "Hello", publishedAt: .now)
        post.accessAccountIDs = [aID, bID]
        post.seenByAccountIDs = [aID]
        post.detailAccountID = aID
        post.bodyText = "body text"
        post.isFromSupportedCreator = true
        ctx.insert(post)
        let creator = Creator(creatorID: "c1", name: "C1")
        creator.followedByAccountIDs = [aID, bID]
        creator.supportedByAccountIDs = [aID]
        creator.isFollowed = true
        creator.isSupported = true
        ctx.insert(creator)
        let owned = Creator(creatorID: "a-self", name: "A self")
        owned.ownedByAccountID = aID
        ctx.insert(owned)
        ctx.insert(PostAccess(postID: "p1", accountID: aID, canView: true, feeRequired: 500))
        ctx.insert(PostAccess(postID: "p1", accountID: bID, canView: false, feeRequired: 500))
        ctx.insert(Support(accountID: aID, creatorID: "c1", creatorName: "C1", planID: "pl", planTitle: "Plan", amount: 500))
        ctx.insert(SupportPaymentAssignment(accountID: aID, creatorID: "c1", planID: "pl", paymentProfileID: nil, verificationState: .manual))
        ctx.insert(PaymentRecord(paymentID: "pay1", accountID: aID, creatorID: "c1", creatorName: "C1", amount: 500, paidAt: .now))
        ctx.insert(SyncState(accountID: aID, resource: .timeline))
        ctx.insert(SyncState(accountID: bID, resource: .timeline))
        ctx.insert(Fan(accountID: aID, userID: "u1", name: "Fan"))
        ctx.insert(CreatorDashboardSnapshot(accountID: aID, month: "2026-09"))
        ctx.insert(OutgoingComment(accountID: aID, postID: "p1", body: "draft reply"))
        let event = NotificationEvent(id: "newPost|p1", type: .newPost, accountIDs: [aID, bID], title: "New", message: "m", timestamp: .now)
        event.remoteIDs = ["\(aID):r1", "\(bID):r2"]
        ctx.insert(event)
        ctx.insert(Newsletter(newsletterID: "n1", creatorID: "c1", creatorName: "C1", body: "letter", createdAt: .now, accountIDs: [aID]))
        let comment = Comment(commentID: "cm1", postID: "p1", fetchedByAccountID: aID, authorUserID: "u", authorName: "U",
                              body: "comment text", createdAt: .now)
        ctx.insert(comment)
        let draft = Draft(accountID: aID, title: "my draft")
        ctx.insert(draft)
        let job = UploadJob(draftID: draft.id, draftBlockID: "blk", accountID: aID, fileName: "a.png", localFileName: "a.png", kind: .image)
        ctx.insert(job)
        store.save()

        await service.remove(accountID: aID)

        XCTAssertNil(store.account(id: aID))
        XCTAssertTrue(b.isMain, "main moves to the remaining account")
        XCTAssertEqual(store.fetch(FetchDescriptor<PostAccess>()).map(\.accountID), [bID])
        XCTAssertTrue(store.fetch(FetchDescriptor<Support>()).isEmpty)
        XCTAssertTrue(store.fetch(FetchDescriptor<SupportPaymentAssignment>()).isEmpty)
        XCTAssertTrue(store.fetch(FetchDescriptor<PaymentRecord>()).isEmpty)
        XCTAssertEqual(store.fetch(FetchDescriptor<SyncState>()).map(\.accountID), [bID])
        XCTAssertTrue(store.fetch(FetchDescriptor<Fan>()).isEmpty)
        XCTAssertTrue(store.fetch(FetchDescriptor<CreatorDashboardSnapshot>()).isEmpty)
        XCTAssertTrue(store.fetch(FetchDescriptor<OutgoingComment>()).isEmpty)

        // Content kept, account id stripped.
        XCTAssertEqual(post.accessAccountIDs, [bID])
        XCTAssertEqual(post.seenByAccountIDs, [])
        XCTAssertNil(post.detailAccountID)
        XCTAssertEqual(post.bodyText, "body text")
        XCTAssertFalse(post.isFromSupportedCreator)
        XCTAssertEqual(creator.followedByAccountIDs, [bID])
        XCTAssertTrue(creator.isFollowed)
        XCTAssertEqual(creator.supportedByAccountIDs, [])
        XCTAssertFalse(creator.isSupported)
        XCTAssertNil(owned.ownedByAccountID)
        XCTAssertEqual(event.accountIDs, [bID])
        XCTAssertEqual(event.remoteIDs, ["\(bID):r2"])
        XCTAssertNotNil(store.newsletter(id: "n1"))
        XCTAssertEqual(store.newsletter(id: "n1")?.accountIDs, [])
        XCTAssertEqual(store.comments(postID: "p1").first?.body, "comment text")
        XCTAssertNotNil(store.draft(id: draft.id))
        XCTAssertEqual(job.state, .failed)

        let credential = await credentials.credential(for: aID)
        XCTAssertNil(credential)
    }

    func testLogoutKeepsAccountButDropsSecrets() async throws {
        let a = makeRealAccount(pixivUserID: "1001", name: "A", main: true)
        try await credentials.save(SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "x", domain: ".fanbox.cc")]), for: a.id)
        await putSessionCookie(for: a)
        await service.logout(accountID: a.id)
        XCTAssertNotNil(store.account(id: a.id))
        XCTAssertEqual(a.sessionState, .loggedOut)
        let credential = await credentials.credential(for: a.id)
        XCTAssertNil(credential)
        let hasSession = await sessions.hasSessionCookie(webProfileID: a.webProfileID)
        XCTAssertFalse(hasSession)
    }

    // MARK: Session

    func testValidateSessionStateMapping() async {
        let a = makeRealAccount(pixivUserID: "1001", name: "A", main: true)
        a.sessionState = .unknown
        store.save()

        remote.userResult = .success(RemoteUser(pixivUserID: "1001", fanboxUserID: nil, name: "A renamed", iconURL: nil, creatorID: nil))
        let valid = await service.validateSession(accountID: a.id)
        XCTAssertEqual(valid, .valid)
        XCTAssertEqual(a.displayName, "A renamed")
        let checkedAt = a.sessionCheckedAt
        XCTAssertNotNil(checkedAt)

        remote.userResult = .failure(.offline)
        let offline = await service.checkSession(accountID: a.id)
        XCTAssertEqual(a.sessionState, .valid, "offline leaves the state unchanged")
        XCTAssertEqual(a.sessionCheckedAt, checkedAt)
        guard case .unchanged = offline else { return XCTFail("expected unchanged") }

        remote.userResult = .failure(.network(code: -1001, detail: "timeout"))
        let transient = await service.validateSession(accountID: a.id)
        XCTAssertEqual(transient, .valid)

        remote.userResult = .failure(.unauthorized)
        let expired = await service.validateSession(accountID: a.id)
        XCTAssertEqual(expired, .expired)

        remote.userResult = .success(RemoteUser(pixivUserID: "other", fanboxUserID: nil, name: "X", iconURL: nil, creatorID: nil))
        let mismatch = await service.validateSession(accountID: a.id)
        XCTAssertEqual(mismatch, .error, "a session of another user is never accepted")
        XCTAssertEqual(a.displayName, "A renamed")
        XCTAssertTrue(service.validatingAccountIDs.isEmpty)
    }

    func testDemoSessionIsValidatedLocally() async {
        let demo = service.addDemoAccount(name: "Demo")
        let state = await service.validateSession(accountID: demo.id)
        XCTAssertEqual(state, .valid)
        XCTAssertEqual(remote.currentUserCalls, 0)
    }

    func testRefreshCredentialFromWebMergesCookiesAndToken() async throws {
        let a = makeRealAccount(pixivUserID: "1001", name: "A", main: true)
        try await credentials.save(SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "old", domain: ".fanbox.cc"),
                                                               StoredCookie(name: "keep", value: "k", domain: ".fanbox.cc")],
                                                     userAgent: "UA/old", csrfToken: "old-token"), for: a.id)
        await putSessionCookie(for: a, value: "rotated")
        await service.refreshCredentialFromWeb(accountID: a.id, userAgent: "UA/new", csrfToken: "new-token")
        let maybeUpdated = await credentials.credential(for: a.id)
        let updated = try XCTUnwrap(maybeUpdated)
        XCTAssertEqual(updated.cookies.first { $0.name == "FANBOXSESSID" }?.value, "rotated")
        XCTAssertEqual(updated.cookies.first { $0.name == "keep" }?.value, "k")
        XCTAssertEqual(updated.userAgent, "UA/new")
        XCTAssertEqual(updated.csrfToken, "new-token")
    }

    func testPrepareWebSessionInstallsKeychainSessionIntoEmptyWebStore() async throws {
        let a = makeRealAccount(pixivUserID: "1001", name: "A", main: true)
        try await credentials.save(SessionCredential(cookies: [StoredCookie(name: "FANBOXSESSID", value: "from-keychain", domain: ".fanbox.cc",
                                                                            expiresAt: Date().addingTimeInterval(3600))]), for: a.id)
        let before = await sessions.hasSessionCookie(webProfileID: a.webProfileID)
        XCTAssertFalse(before)
        await service.prepareWebSession(accountID: a.id)
        let cookies = await sessions.cookies(webProfileID: a.webProfileID)
        XCTAssertEqual(cookies.first { $0.name == "FANBOXSESSID" }?.value, "from-keychain")
    }

    /// Updated for the transport fix (docs/API.md §4.2): only a 401 changes the state; a challenge / edge block / FANBOX
    /// 403 is "unknown" and never demotes a healthy account. `.error` is reserved for an identity mismatch.
    func testSessionStateMappingTable() {
        XCTAssertEqual(AccountService.sessionState(for: RemoteError.unauthorized), .expired)
        XCTAssertNil(AccountService.sessionState(for: RemoteError.forbidden))
        XCTAssertNil(AccountService.sessionState(for: RemoteError.edgeBlocked(retryAfter: nil)))
        XCTAssertNil(AccountService.sessionState(for: RemoteError.decoding(endpoint: "www.metadata", detail: "no metadata")))
        XCTAssertNil(AccountService.sessionState(for: RemoteError.csrfUnavailable))
        XCTAssertNil(AccountService.sessionState(for: RemoteError.offline))
        XCTAssertNil(AccountService.sessionState(for: RemoteError.rateLimited(retryAfter: nil)))
        XCTAssertNil(AccountService.sessionState(for: RemoteError.server(status: 503)))
        XCTAssertNil(AccountService.sessionState(for: RemoteError.server(status: 400)))
        XCTAssertNil(AccountService.sessionState(for: CancellationError()))
    }
}

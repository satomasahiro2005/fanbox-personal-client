import Foundation
import Observation
import SwiftData

/// Why adding / re-logging an account failed. Messages never contain secrets.
enum AccountLoginError: Error, Equatable, LocalizedError {
    case accountNotFound
    /// The account's web store has no FANBOXSESSID cookie yet (login not finished).
    case noSessionCookie
    /// Neither the API nor the page metadata could tell who is logged in.
    case profileUnavailable(String)
    /// The pixiv account is already managed by another local account.
    case duplicate(existingAccountID: String, existingName: String)
    /// Re-login produced a different pixiv user than the one this account belongs to.
    case accountMismatch(expectedName: String)
    case credentialStorage

    var userMessage: String {
        switch self {
        case .accountNotFound:
            return "アカウントが見つかりません。"
        case .noSessionCookie:
            return "ログインがまだ完了していません。pixiv の画面でログインしてください。"
        case .profileUnavailable(let detail):
            return "ログインしたユーザーを確認できませんでした（\(detail)）。"
        case .duplicate(_, let name):
            return "この pixiv アカウントは「\(name)」として既に追加されています。"
        case .accountMismatch(let name):
            return "「\(name)」とは別の pixiv アカウントでログインしています。一度ログアウトしてから、正しいアカウントでログインしてください。"
        case .credentialStorage:
            return "セッション情報を安全に保存できませんでした。"
        }
    }

    var errorDescription: String? { userMessage }
}

/// Outcome of an explicit session check.
enum SessionCheckResult: Equatable, Sendable {
    /// The check reached FANBOX and set this state.
    case updated(SessionState)
    /// Offline / transient failure: the stored state was left as it was.
    case unchanged(reason: String)
}

/// Account label colors (SPEC §7: tell accounts apart at a glance). Aura-like purple / mint first.
enum AccountColorPalette {
    struct Entry: Hashable, Identifiable {
        let hex: String
        let name: String
        var id: String { hex }
    }

    static let entries: [Entry] = [
        Entry(hex: "#8B5CF6", name: "パープル"),
        Entry(hex: "#2DD4BF", name: "ミント"),
        Entry(hex: "#F59E0B", name: "アンバー"),
        Entry(hex: "#EC4899", name: "ピンク"),
        Entry(hex: "#38BDF8", name: "スカイ"),
        Entry(hex: "#84CC16", name: "ライム"),
        Entry(hex: "#F97316", name: "オレンジ"),
        Entry(hex: "#6366F1", name: "インディゴ"),
        Entry(hex: "#F43F5E", name: "ローズ"),
        Entry(hex: "#14B8A6", name: "ティール"),
    ]

    static var hexes: [String] { entries.map(\.hex) }

    /// First palette color not used yet; cycles once all are taken.
    static func next(used: [String?]) -> String {
        let taken = Set(used.compactMap { $0?.uppercased() })
        if let free = hexes.first(where: { !taken.contains($0.uppercased()) }) { return free }
        return hexes[used.count % hexes.count]
    }
}

/// Account lifecycle: add (login via account-aware WebView) / demo / remove / main / enable / session validation.
///
/// Secrets: session cookies / CSRF go to `CredentialStoring` (Keychain) and the account's own `WKWebsiteDataStore`
/// only — never to SwiftData, UserDefaults or logs (SPEC §7 / §38 / §39).
@MainActor
@Observable
final class AccountService {
    private(set) var loginInProgressAccountID: String?
    /// Accounts whose session is being checked right now (UI spinners).
    private(set) var validatingAccountIDs: Set<String> = []

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

    // MARK: - Placeholders

    /// A login placeholder: a disabled FANBOX account that has not been bound to a pixiv user yet.
    static func isPlaceholder(_ account: Account) -> Bool {
        account.kind == .fanbox && account.pixivUserID == nil && !account.enabled
    }

    func isPlaceholder(accountID: String) -> Bool {
        store.account(id: accountID).map(Self.isPlaceholder) ?? false
    }

    /// Next unused palette color.
    func nextColorHex(excluding accountID: String? = nil) -> String {
        AccountColorPalette.next(used: store.accounts(includeDisabled: true).filter { $0.id != accountID }.map(\.colorHex))
    }

    // MARK: - Login

    /// Creates a disabled placeholder account whose isolated web store is used for the login WebView.
    func beginLogin() -> Account {
        if let previous = loginInProgressAccountID, previous != "", isPlaceholder(accountID: previous) {
            let prev = previous
            Task { await self.cancelLogin(accountID: prev) }
        }
        let account = Account(displayName: "ログイン中…", enabled: false, sortOrder: nextSortOrder(), colorHex: nextColorHex())
        store.context.insert(account)
        store.save()
        loginInProgressAccountID = account.id
        AppLog.auth.info("login started for new account \(account.id, privacy: .public)")
        return account
    }

    /// Captures the session from the account's web store, verifies it, fills profile fields and enables the account.
    func completeLogin(accountID: String, userAgent: String?, csrfToken: String?) async throws {
        try await completeLogin(accountID: accountID, userAgent: userAgent, csrfToken: csrfToken, metadata: nil)
    }

    /// Same as `completeLogin(accountID:userAgent:csrfToken:)`; `metadata` (the user read from the FANBOX page) is used
    /// when the API profile request fails.
    func completeLogin(accountID: String, userAgent: String?, csrfToken: String?, metadata: WebLoginMetadata?) async throws {
        guard let initial = store.account(id: accountID) else { throw AccountLoginError.accountNotFound }
        let webProfileID = initial.webProfileID
        let wasPlaceholder = Self.isPlaceholder(initial)

        guard let captured = await webSessions.captureCredential(webProfileID: webProfileID, userAgent: userAgent, csrfToken: csrfToken),
              captured.hasSessionCookie else {
            throw AccountLoginError.noSessionCookie
        }

        let previous = await credentials.credential(for: accountID)
        do {
            try await credentials.save(captured, for: accountID)
        } catch {
            AppLog.auth.error("credential save failed for \(accountID, privacy: .public)")
            throw AccountLoginError.credentialStorage
        }

        // Who is logged in? API first (authoritative), page metadata as fallback.
        var context = initial.context
        context.kind = .fanbox
        let user: RemoteUser
        do {
            let source = remote.dataSource(for: context)
            let ctx = context
            user = try await RequestContext.$priority.withValue(.interactiveRead) {
                try await source.currentUser(account: ctx)
            }
        } catch {
            if let metadata, !metadata.pixivUserID.isEmpty {
                AppLog.auth.notice("profile API failed during login; using page metadata")
                user = metadata.remoteUser
            } else {
                await restoreCredential(previous, accountID: accountID)
                throw AccountLoginError.profileUnavailable(Self.describe(error))
            }
        }

        guard let account = store.account(id: accountID) else {
            try? await credentials.delete(for: accountID)
            throw AccountLoginError.accountNotFound
        }

        if let existing = store.accounts(includeDisabled: true).first(where: { $0.id != accountID && $0.pixivUserID == user.pixivUserID }) {
            let existingID = existing.id
            let existingName = existing.displayName
            AppLog.auth.notice("duplicate login rejected; already managed by \(existingID, privacy: .public)")
            if wasPlaceholder {
                await discardPlaceholder(accountID: accountID)
            } else {
                await restoreCredential(previous, accountID: accountID)
            }
            throw AccountLoginError.duplicate(existingAccountID: existingID, existingName: existingName)
        }

        if let current = account.pixivUserID, current != user.pixivUserID {
            await restoreCredential(previous, accountID: accountID)
            throw AccountLoginError.accountMismatch(expectedName: account.displayName)
        }

        account.kind = .fanbox
        account.pixivUserID = user.pixivUserID
        if let fanboxUserID = user.fanboxUserID ?? metadata?.fanboxUserID { account.fanboxUserID = fanboxUserID }
        let name = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            account.displayName = name
        } else if wasPlaceholder {
            account.displayName = "pixiv \(user.pixivUserID)"
        }
        if let icon = user.iconURL ?? metadata?.iconURL { account.avatarURL = icon }
        if let creatorID = user.creatorID ?? metadata?.creatorID, !creatorID.isEmpty { account.creatorID = creatorID }
        account.sessionState = .valid
        account.sessionCheckedAt = .now
        account.enabled = true
        if account.colorHex == nil { account.colorHex = nextColorHex(excluding: accountID) }

        let others = store.accounts(includeDisabled: true).filter { $0.id != accountID }
        let hasOtherRealEnabled = others.contains { $0.enabled && $0.kind == .fanbox }
        let hasEnabledMain = others.contains { $0.enabled && $0.isMain }
        if (wasPlaceholder && !hasOtherRealEnabled) || !hasEnabledMain {
            for a in store.accounts(includeDisabled: true) { a.isMain = (a.id == accountID) }
        }

        if let creatorID = account.creatorID {
            let creator: Creator
            if let existing = store.creator(id: creatorID) {
                creator = existing
            } else {
                creator = Creator(creatorID: creatorID, name: account.displayName, pixivUserID: user.pixivUserID, iconURL: account.avatarURL)
                store.context.insert(creator)
            }
            creator.ownedByAccountID = accountID
        }

        if loginInProgressAccountID == accountID { loginInProgressAccountID = nil }
        store.save()
        AppLog.auth.info("login completed for account \(accountID, privacy: .public)")
    }

    /// Abandons a login: removes the placeholder, its credential and its web data. Real accounts are left untouched.
    func cancelLogin(accountID: String) async {
        if loginInProgressAccountID == accountID { loginInProgressAccountID = nil }
        guard let account = store.account(id: accountID), Self.isPlaceholder(account) else { return }
        await discardPlaceholder(accountID: accountID)
    }

    /// Removes placeholders left behind by an interrupted login (app killed during login, ...).
    func cleanupAbandonedPlaceholders() async {
        let abandoned = store.accounts(includeDisabled: true).filter { Self.isPlaceholder($0) && $0.id != loginInProgressAccountID }
        for account in abandoned {
            await discardPlaceholder(accountID: account.id)
        }
    }

    private func discardPlaceholder(accountID: String) async {
        guard let account = store.account(id: accountID) else { return }
        let webProfileID = account.webProfileID
        store.context.delete(account)
        store.save()
        if loginInProgressAccountID == accountID { loginInProgressAccountID = nil }
        try? await credentials.delete(for: accountID)
        await webSessions.removeData(webProfileID: webProfileID)
    }

    private func restoreCredential(_ previous: SessionCredential?, accountID: String) async {
        if let previous {
            try? await credentials.save(previous, for: accountID)
        } else {
            try? await credentials.delete(for: accountID)
        }
    }

    // MARK: - Demo

    @discardableResult
    func addDemoAccount(name: String = "Demo") -> Account {
        let all = store.accounts(includeDisabled: true)
        let isFirst = all.isEmpty || !all.contains { $0.enabled && $0.isMain }
        let account = Account(kind: .demo, displayName: name, pixivUserID: "demo-\(UUID().uuidString.prefix(6))", isMain: isFirst,
                              sortOrder: nextSortOrder(), sessionState: .valid, colorHex: nextColorHex())
        store.context.insert(account)
        store.save()
        return account
    }

    /// Default name for the next demo account ("Demo 2", "Demo 3", ...).
    func nextDemoName() -> String {
        let count = store.accounts(includeDisabled: true).filter { $0.kind == .demo }.count
        return count == 0 ? "Demo" : "Demo \(count + 1)"
    }

    // MARK: - Remove / logout

    /// Removes the account: Keychain credential, web data store, the Account row and all account-scoped rows.
    /// Downloaded text content (posts, comments, newsletters, drafts) is kept; the account id is removed from it.
    func remove(accountID: String) async {
        guard let account = store.account(id: accountID) else { return }
        let webProfileID = account.webProfileID
        let wasMain = account.isMain
        let context = store.context

        // Account-scoped rows.
        deleteAll(FetchDescriptor<PostAccess>(predicate: #Predicate { $0.accountID == accountID }))
        deleteAll(FetchDescriptor<Support>(predicate: #Predicate { $0.accountID == accountID }))
        deleteAll(FetchDescriptor<SupportPaymentAssignment>(predicate: #Predicate { $0.accountID == accountID }))
        deleteAll(FetchDescriptor<PaymentRecord>(predicate: #Predicate { $0.accountID == accountID }))
        deleteAll(FetchDescriptor<SyncState>(predicate: #Predicate { $0.accountID == accountID }))
        deleteAll(FetchDescriptor<Fan>(predicate: #Predicate { $0.accountID == accountID }))
        deleteAll(FetchDescriptor<CreatorDashboardSnapshot>(predicate: #Predicate { $0.accountID == accountID }))
        deleteAll(FetchDescriptor<OutgoingComment>(predicate: #Predicate { $0.accountID == accountID }))

        // Upload jobs can no longer be sent; keep drafts (user text) but stop their uploads.
        for job in store.fetch(FetchDescriptor<UploadJob>(predicate: #Predicate { $0.accountID == accountID })) where job.state != .completed {
            job.state = .failed
            job.lastError = "アカウントが削除されました"
            job.updatedAt = .now
        }

        // Denormalized account id arrays (filtered in memory: no #Predicate on arrays).
        var creatorFlags: [String: (followed: Bool, supported: Bool)] = [:]
        var ownedCreatorIDs: Set<String> = []
        for creator in store.fetch(FetchDescriptor<Creator>()) {
            var touched = false
            if creator.followedByAccountIDs.contains(accountID) {
                creator.followedByAccountIDs.removeAll { $0 == accountID }
                creator.isFollowed = !creator.followedByAccountIDs.isEmpty
                touched = true
            }
            if creator.supportedByAccountIDs.contains(accountID) {
                creator.supportedByAccountIDs.removeAll { $0 == accountID }
                creator.isSupported = !creator.supportedByAccountIDs.isEmpty
                touched = true
            }
            if creator.ownedByAccountID == accountID {
                creator.ownedByAccountID = nil
                ownedCreatorIDs.insert(creator.creatorID)
            }
            if touched { creatorFlags[creator.creatorID] = (creator.isFollowed, creator.isSupported) }
        }
        for post in store.fetch(FetchDescriptor<Post>()) {
            if post.accessAccountIDs.contains(accountID) { post.accessAccountIDs.removeAll { $0 == accountID } }
            if post.seenByAccountIDs.contains(accountID) { post.seenByAccountIDs.removeAll { $0 == accountID } }
            if post.detailAccountID == accountID { post.detailAccountID = nil }
            if let flags = creatorFlags[post.creatorID] {
                if !flags.supported && post.isFromSupportedCreator { post.isFromSupportedCreator = false }
                if !flags.followed && post.isFromFollowedCreator { post.isFromFollowedCreator = false }
            }
            if ownedCreatorIDs.contains(post.creatorID) && post.isOwnPost { post.isOwnPost = false }
        }
        let remotePrefix = "\(accountID):"
        for event in store.fetch(FetchDescriptor<NotificationEvent>()) {
            if event.accountIDs.contains(accountID) { event.accountIDs.removeAll { $0 == accountID } }
            if event.remoteIDs.contains(where: { $0.hasPrefix(remotePrefix) }) { event.remoteIDs.removeAll { $0.hasPrefix(remotePrefix) } }
        }
        for newsletter in store.fetch(FetchDescriptor<Newsletter>()) where newsletter.accountIDs.contains(accountID) {
            newsletter.accountIDs.removeAll { $0 == accountID }
        }

        context.delete(account)
        if loginInProgressAccountID == accountID { loginInProgressAccountID = nil }
        if wasMain { assignMainIfNeeded() }
        store.save()
        AppLog.auth.info("account removed \(accountID, privacy: .public)")

        // Secrets last (after the UI already reflects the removal).
        try? await credentials.delete(for: accountID)
        await webSessions.removeData(webProfileID: webProfileID)
    }

    /// Logs the account out locally: deletes its Keychain credential and web data but keeps the account and its cache.
    func logout(accountID: String) async {
        guard let account = store.account(id: accountID) else { return }
        let webProfileID = account.webProfileID
        account.sessionState = .loggedOut
        account.sessionCheckedAt = .now
        store.save()
        try? await credentials.delete(for: accountID)
        await webSessions.clearData(webProfileID: webProfileID)
    }

    private func deleteAll<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) {
        for model in store.fetch(descriptor) { store.context.delete(model) }
    }

    // MARK: - Main / enabled / order / color

    func setMain(accountID: String) {
        guard let target = store.account(id: accountID), !Self.isPlaceholder(target) else { return }
        target.enabled = true
        for a in store.accounts(includeDisabled: true) { a.isMain = (a.id == accountID) }
        store.save()
    }

    func setEnabled(accountID: String, _ enabled: Bool) {
        guard let account = store.account(id: accountID), !Self.isPlaceholder(account) else { return }
        account.enabled = enabled
        if !enabled && account.isMain {
            account.isMain = false
            assignMainIfNeeded()
        } else if enabled {
            assignMainIfNeeded()
        }
        store.save()
    }

    /// Ensures exactly one enabled account is main (prefers real accounts, then sort order).
    private func assignMainIfNeeded() {
        let all = store.accounts(includeDisabled: true)
        let enabled = all.filter { $0.enabled && !Self.isPlaceholder($0) }
        let mains = enabled.filter(\.isMain)
        if mains.count == 1 {
            for a in all where a.isMain && a.id != mains[0].id { a.isMain = false }
            return
        }
        let candidate = mains.first ?? enabled.first(where: { $0.kind == .fanbox }) ?? enabled.first
        for a in all { a.isMain = (a.id == candidate?.id) }
    }

    /// Applies a new order (e.g. from `List.onMove`). Accounts not listed keep their relative order after the listed ones.
    func reorder(_ orderedIDs: [String]) {
        let all = store.accounts(includeDisabled: true)
        var index = 0
        for id in orderedIDs {
            guard let account = all.first(where: { $0.id == id }) else { continue }
            account.sortOrder = index
            index += 1
        }
        for account in all where !orderedIDs.contains(account.id) {
            account.sortOrder = index
            index += 1
        }
        store.save()
    }

    func move(_ visibleIDs: [String], fromOffsets source: IndexSet, toOffset destination: Int) {
        var ids = visibleIDs
        ids.move(fromOffsets: source, toOffset: destination)
        reorder(ids)
    }

    func setColor(accountID: String, hex: String?) {
        store.account(id: accountID)?.colorHex = hex
        store.save()
    }

    private func nextSortOrder() -> Int {
        (store.accounts(includeDisabled: true).map(\.sortOrder).max() ?? -1) + 1
    }

    // MARK: - Session

    /// Checks the session with a lightweight request and updates `Account.sessionState`.
    /// valid → `.valid`; 401 → `.expired`; offline / transient failures leave the state unchanged.
    @discardableResult
    func validateSession(accountID: String) async -> SessionState {
        _ = await checkSession(accountID: accountID)
        return store.account(id: accountID)?.sessionState ?? .unknown
    }

    /// Same as `validateSession` but tells whether the state was actually determined (for UI messages).
    func checkSession(accountID: String) async -> SessionCheckResult {
        guard let account = store.account(id: accountID) else { return .unchanged(reason: "アカウントが見つかりません") }
        if Self.isPlaceholder(account) { return .unchanged(reason: "ログインが完了していません") }
        let context = account.context
        let source = remote.dataSource(for: context)
        validatingAccountIDs.insert(accountID)
        defer { validatingAccountIDs.remove(accountID) }

        let outcome: Result<RemoteUser, Error>
        do {
            let user = try await RequestContext.$priority.withValue(.interactiveRead) {
                try await source.currentUser(account: context)
            }
            outcome = .success(user)
        } catch {
            outcome = .failure(error)
        }

        guard let account = store.account(id: accountID) else { return .unchanged(reason: "アカウントが見つかりません") }
        let result: SessionCheckResult
        switch outcome {
        case .success(let user):
            if let known = account.pixivUserID, known != user.pixivUserID {
                // The stored session belongs to someone else: never treat it as this account.
                AppLog.auth.error("session user mismatch for \(accountID, privacy: .public)")
                account.sessionState = .error
            } else {
                account.sessionState = .valid
                if account.kind == .fanbox {
                    if !user.name.isEmpty { account.displayName = user.name }
                    if let icon = user.iconURL { account.avatarURL = icon }
                    if let creatorID = user.creatorID, !creatorID.isEmpty { account.creatorID = creatorID }
                    if let fanboxUserID = user.fanboxUserID { account.fanboxUserID = fanboxUserID }
                }
            }
            account.sessionCheckedAt = .now
            result = .updated(account.sessionState)
        case .failure(let error):
            if let state = Self.sessionState(for: error) {
                account.sessionState = state
                account.sessionCheckedAt = .now
                result = .updated(state)
            } else {
                result = .unchanged(reason: Self.describe(error))
            }
        }
        store.save()
        return result
    }

    /// Validates every enabled account (sequentially; each is a single lightweight request).
    func validateAllSessions() async {
        for account in store.accounts() where !Self.isPlaceholder(account) {
            await validateSession(accountID: account.id)
        }
    }

    /// Maps a failed session check to a new state; nil = leave unchanged (offline / transient / not checkable).
    static func sessionState(for error: Error) -> SessionState? {
        guard let remoteError = error as? RemoteError else { return nil }
        switch remoteError {
        case .unauthorized:
            return .expired
        case .forbidden, .notFound, .decoding, .invalidRequest:
            return .error
        case .server(let status):
            return status >= 500 ? nil : .error
        case .offline, .rateLimited, .network, .blockedByPolicy, .cancelled, .unsupported:
            return nil
        }
    }

    /// Re-captures cookies from the web store after WebView navigation (e.g. re-login / Cloudflare challenge).
    func refreshCredentialFromWeb(accountID: String, userAgent: String?, csrfToken: String?) async {
        guard let account = store.account(id: accountID), account.kind == .fanbox, !Self.isPlaceholder(account) else { return }
        guard let captured = await webSessions.captureCredential(webProfileID: account.webProfileID, userAgent: userAgent,
                                                                  csrfToken: csrfToken) else { return }
        let existing = await credentials.credential(for: accountID)
        var updated = existing ?? SessionCredential(cookies: [])
        updated.merge(captured.cookies)
        if let ua = captured.userAgent { updated.userAgent = ua }
        if let token = captured.csrfToken { updated.csrfToken = token }

        let oldSession = existing?.cookies.first { $0.name == SessionCredential.sessionCookieName }?.value
        let newSession = captured.cookies.first { $0.name == SessionCredential.sessionCookieName }?.value
        guard existing == nil || !Self.sameContent(existing!, updated) else { return }
        guard updated.hasSessionCookie else { return }
        updated.capturedAt = .now
        do {
            try await credentials.save(updated, for: accountID)
        } catch {
            AppLog.auth.error("credential refresh failed for \(accountID, privacy: .public)")
            return
        }
        // A new session cookie after an expired state (e.g. re-login in "browse" mode) → re-check it.
        if newSession != nil, newSession != oldSession,
           let current = store.account(id: accountID), current.sessionState != .valid {
            await validateSession(accountID: accountID)
        }
    }

    /// Before showing a web session: if the account's web store lost its FANBOX session but the Keychain still has one,
    /// install it so the web view opens logged in as this account (SPEC §40).
    func prepareWebSession(accountID: String) async {
        guard let account = store.account(id: accountID), account.kind == .fanbox, !Self.isPlaceholder(account) else { return }
        let webProfileID = account.webProfileID
        if await webSessions.hasSessionCookie(webProfileID: webProfileID) { return }
        guard let credential = await credentials.credential(for: accountID), credential.hasSessionCookie else { return }
        await webSessions.install(credential, webProfileID: webProfileID)
    }

    private static func sameContent(_ a: SessionCredential, _ b: SessionCredential) -> Bool {
        a.userAgent == b.userAgent && a.csrfToken == b.csrfToken && Set(a.cookies) == Set(b.cookies)
    }

    private static func describe(_ error: Error) -> String {
        if let remote = error as? RemoteError { return remote.userMessage }
        return "通信エラー"
    }
}

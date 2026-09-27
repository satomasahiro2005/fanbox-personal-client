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
            return "ログインがまだ完了していません。pixivの画面でログインしてください。"
        case .profileUnavailable(let detail):
            return "ログインしたユーザーを確認できませんでした（\(detail)）。"
        case .duplicate(_, let name):
            return "このpixivアカウントは「\(name)」として既に追加されています。"
        case .accountMismatch(let name):
            return "「\(name)」とは別のpixivアカウントでログインしています。このアカウントのセッションは変更せず、Webセッションを元に戻しました。"
                + "「\(name)」のpixivアカウントでログインし直してください。"
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

/// Outcome of copying a web session into the account's Keychain credential.
enum WebCredentialRefreshResult: Equatable, Sendable {
    case unchanged
    case updated
    /// The web store is logged in as another pixiv user: nothing was copied, the web store was reset.
    case identityMismatch(pageUserID: String)
    /// A new session could not be verified: the stored credential was kept.
    case rejected
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
///
/// Account identity (SPEC §3.2 / §7.1 / §40 "誤 Account 操作を防ぐ"): a session captured from a web store is written to an
/// account's credential only after the logged-in pixiv user was verified to be the account's own `pixivUserID` — by
/// the page metadata and/or a probe request made with the captured session under a temporary key. A web store found
/// logged in as another user is reset (cleared, then the account's own verified session is re-installed); a stored
/// credential found to belong to another user is deleted and the account is set to `.error` (identity mismatch), which
/// sync skips until a successful re-login.
@MainActor
@Observable
final class AccountService {
    private(set) var loginInProgressAccountID: String?
    /// Accounts whose session is being checked right now (UI spinners).
    private(set) var validatingAccountIDs: Set<String> = []
    /// accountID → pixiv user id seen in its web store / session instead of its own (UI warnings). Cleared by a
    /// verified re-login or session check.
    private(set) var identityWarnings: [String: String] = [:]

    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let credentials: CredentialStoring
    @ObservationIgnored let webSessions: WebSessionStore
    @ObservationIgnored let remote: RemoteDataSourceProvider
    /// Cancels an account's in-flight network work (native URLSession + WebView transport). Wired by AppEnvironment.
    @ObservationIgnored var sessionRevoker: SessionRevoking?
    /// Called after the set of enabled accounts changed (enable / disable / remove), e.g. to refresh the app badge.
    @ObservationIgnored var onEnabledAccountsChanged: (() -> Void)?
    /// Called by `remove` before the account's rows are deleted: stops and awaits the account's running syncs and reply
    /// sends. Wired by AppEnvironment.
    @ObservationIgnored var prepareRemoval: ((String) async -> Void)?

    /// Temporary credential keys used to verify a captured session before it is stored for an account.
    static let probeKeyPrefix = "login-probe-"

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

    /// Same as `completeLogin(accountID:userAgent:csrfToken:)`. `metadata` is the user read from the FANBOX page: it is
    /// checked against the account BEFORE anything is stored, and used as the profile when the API request fails.
    ///
    /// Order: page identity check → capture → probe the captured session under a temporary key (`currentUser`) →
    /// duplicate / mismatch checks → only then save the credential for the account. A rejected re-login never touches
    /// the account's credential; its web store is reset to the account's own session.
    func completeLogin(accountID: String, userAgent: String?, csrfToken: String?, metadata: WebLoginMetadata?) async throws {
        guard let initial = store.account(id: accountID) else { throw AccountLoginError.accountNotFound }
        let webProfileID = initial.webProfileID
        let wasPlaceholder = Self.isPlaceholder(initial)
        let wasEnabled = initial.enabled
        let boundUserID = initial.pixivUserID
        let expectedName = initial.displayName

        // 1. The page already says who is logged in: a different user never gets near the credential.
        if let pageUser = metadata?.pixivUserID, !pageUser.isEmpty, let boundUserID, pageUser != boundUserID {
            AppLog.auth.notice("re-login page shows another pixiv user for \(accountID, privacy: .public); rejected")
            await resetWebSession(accountID: accountID, webProfileID: webProfileID)
            throw AccountLoginError.accountMismatch(expectedName: expectedName)
        }

        guard var captured = await webSessions.captureCredential(webProfileID: webProfileID, userAgent: userAgent, csrfToken: csrfToken),
              captured.hasSessionCookie else {
            throw AccountLoginError.noSessionCookie
        }
        let previous = await credentials.credential(for: accountID)
        if captured.userAgent == nil { captured.userAgent = previous?.userAgent }

        // 2. Who does the captured session belong to? API probe first (authoritative), page metadata as fallback.
        var context = initial.context
        context.kind = .fanbox
        let user: RemoteUser
        switch await probeUser(with: captured, context: context) {
        case .success(let probe):
            user = probe.user
            if captured.csrfToken == nil { captured.csrfToken = probe.csrfToken }
        case .failure(let error):
            let isAuthFailure = (error as? RemoteError) == .unauthorized
            if !isAuthFailure, let metadata, !metadata.pixivUserID.isEmpty {
                AppLog.auth.notice("profile API failed during login; using page metadata")
                user = metadata.remoteUser
            } else {
                throw AccountLoginError.profileUnavailable(Self.describe(error))
            }
        }

        guard let target = store.account(id: accountID) else { throw AccountLoginError.accountNotFound }

        // 3. Already managed by another local account.
        if let existing = store.accounts(includeDisabled: true).first(where: { $0.id != accountID && $0.pixivUserID == user.pixivUserID }) {
            let existingID = existing.id
            let existingName = existing.displayName
            AppLog.auth.notice("duplicate login rejected; already managed by \(existingID, privacy: .public)")
            if wasPlaceholder {
                await discardPlaceholder(accountID: accountID)
            } else {
                await resetWebSession(accountID: accountID, webProfileID: webProfileID)
            }
            throw AccountLoginError.duplicate(existingAccountID: existingID, existingName: existingName)
        }

        // 4. Re-login as a different user than the one this account belongs to.
        if let current = target.pixivUserID, current != user.pixivUserID {
            AppLog.auth.notice("re-login produced another pixiv user for \(accountID, privacy: .public); rejected")
            await resetWebSession(accountID: accountID, webProfileID: webProfileID)
            throw AccountLoginError.accountMismatch(expectedName: target.displayName)
        }

        // 5. Verified: requests still running with the previous session must not write into the new one.
        await sessionRevoker?.revokeSession(accountID: accountID)
        do {
            captured.capturedAt = .now
            try await credentials.save(captured, for: accountID)
        } catch {
            AppLog.auth.error("credential save failed for \(accountID, privacy: .public)")
            throw AccountLoginError.credentialStorage
        }
        guard let account = store.account(id: accountID) else {
            try? await credentials.delete(for: accountID)
            throw AccountLoginError.accountNotFound
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
        identityWarnings[accountID] = nil
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
        // A re-login enables a disabled account again: its stored relations count again.
        if !wasEnabled && !wasPlaceholder { enabledAccountsChanged() }
        AppLog.auth.info("login completed for account \(accountID, privacy: .public)")
    }

    /// Result of a probe request made with a captured session.
    struct ProbeResult: Sendable {
        var user: RemoteUser
        /// CSRF token the probe read from the page metadata (bound to the probed session).
        var csrfToken: String?
    }

    /// Asks FANBOX who `credential` belongs to without storing it for any account: the credential is saved under a
    /// temporary key, `currentUser` runs with that key, and the key (and its URLSession) is removed again.
    func probeUser(with credential: SessionCredential, context: AccountContext) async -> Result<ProbeResult, Error> {
        let probeID = Self.probeKeyPrefix + UUID().uuidString
        do {
            try await credentials.save(credential, for: probeID)
        } catch {
            return .failure(AccountLoginError.credentialStorage)
        }
        var probeContext = context
        probeContext.accountID = probeID
        probeContext.kind = .fanbox
        let source = remote.dataSource(for: probeContext)
        let result: Result<ProbeResult, Error>
        do {
            let ctx = probeContext
            let user = try await RequestContext.$priority.withValue(.interactiveRead) {
                try await source.currentUser(account: ctx)
            }
            let token = await credentials.credential(for: probeID)?.csrfToken
            result = .success(ProbeResult(user: user, csrfToken: token))
        } catch {
            result = .failure(error)
        }
        try? await credentials.delete(for: probeID)
        await sessionRevoker?.revokeSession(accountID: probeID)
        return result
    }

    /// Clears the account's web store and re-installs its own (verified) Keychain session, so the web view can never
    /// keep operating as another pixiv user (SPEC §7.1 "決済画面の誤 Account 防止").
    func resetWebSession(accountID: String, webProfileID: String) async {
        await sessionRevoker?.revokeSession(accountID: accountID)
        await webSessions.clearData(webProfileID: webProfileID)
        if let credential = await credentials.credential(for: accountID), credential.hasSessionCookie {
            await webSessions.install(credential, webProfileID: webProfileID)
        }
    }

    /// The account's web store is logged in as `pageUserID` (another pixiv user): reset it and remember the warning.
    func handleWebIdentityMismatch(accountID: String, pageUserID: String) async {
        guard let account = store.account(id: accountID), account.kind == .fanbox else { return }
        AppLog.auth.error("web store of \(accountID, privacy: .public) is logged in as another pixiv user; resetting it")
        identityWarnings[accountID] = pageUserID
        await resetWebSession(accountID: accountID, webProfileID: account.webProfileID)
    }

    /// The stored credential itself belongs to another user: delete it (it can never be this account's), clear the web
    /// store and set `.error` so nothing runs as that user; the account needs a re-login.
    func quarantineMismatchedSession(accountID: String, observedUserID: String) async {
        guard let account = store.account(id: accountID) else { return }
        AppLog.auth.error("stored session of \(accountID, privacy: .public) belongs to another pixiv user; removed")
        let webProfileID = account.webProfileID
        account.sessionState = .error
        account.sessionCheckedAt = .now
        identityWarnings[accountID] = observedUserID
        store.save()
        await sessionRevoker?.revokeSession(accountID: accountID)
        try? await credentials.delete(for: accountID)
        await webSessions.clearData(webProfileID: webProfileID)
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
        await sessionRevoker?.revokeSession(accountID: accountID)
        try? await credentials.delete(for: accountID)
        await webSessions.removeData(webProfileID: webProfileID)
    }

    /// Deletes temporary probe credentials left behind by an interrupted login (app killed mid-probe). Credentials of
    /// unknown account ids are deliberately kept: after a store recovery the accounts may come back, and late responses
    /// can no longer create credentials (`CredentialStoring` merges only into existing ones).
    func purgeOrphanCredentials() async {
        guard let stored = await credentials.storedAccountIDs() else { return }
        let known = Set(store.accounts(includeDisabled: true).map(\.id))
        for id in stored where id.hasPrefix(Self.probeKeyPrefix) && !known.contains(id) {
            try? await credentials.delete(for: id)
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
        // Stop in-flight requests first: a late answer must not write cookies / rows for the removed account.
        await sessionRevoker?.revokeSession(accountID: accountID)
        // Running syncs / reply sends of the account finish (cancelled) before its rows are deleted: a write to a deleted
        // row is fatal, and a late result would recreate rows for the removed account.
        await prepareRemoval?(accountID)
        guard store.account(id: accountID) != nil else { return }

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

        // Denormalized account id arrays (filtered in memory: no #Predicate on arrays). The flags count enabled accounts only.
        let remaining = store.enabledAccountIDs().subtracting([accountID])
        var creatorFlags: [String: (followed: Bool, supported: Bool)] = [:]
        var ownedCreatorIDs: Set<String> = []
        for creator in store.fetch(FetchDescriptor<Creator>()) {
            var touched = false
            if creator.followedByAccountIDs.contains(accountID) {
                creator.followedByAccountIDs.removeAll { $0 == accountID }
                creator.isFollowed = creator.followedByAccountIDs.contains(where: remaining.contains)
                touched = true
            }
            if creator.supportedByAccountIDs.contains(accountID) {
                creator.supportedByAccountIDs.removeAll { $0 == accountID }
                creator.isSupported = creator.supportedByAccountIDs.contains(where: remaining.contains)
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
            post.backfillFeedListings()
            if post.homeListedByAccountIDs?.contains(accountID) == true { post.homeListedByAccountIDs?.removeAll { $0 == accountID } }
            if post.supportingListedByAccountIDs?.contains(accountID) == true {
                post.supportingListedByAccountIDs?.removeAll { $0 == accountID }
            }
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
        identityWarnings[accountID] = nil
        if wasMain { assignMainIfNeeded() }
        store.save()
        // Posts only the removed account's feeds listed (creator relation never stored) leave the timeline too.
        store.refreshRelationFlags(recomputeAllPosts: true)
        onEnabledAccountsChanged?()
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
        identityWarnings[accountID] = nil
        store.save()
        // Cancel in-flight work (and the hidden WebView holding the store) BEFORE the secrets are deleted.
        await sessionRevoker?.revokeSession(accountID: accountID)
        try? await credentials.delete(for: accountID)
        await webSessions.clearData(webProfileID: webProfileID)
    }

    private func deleteAll<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) {
        for model in store.fetch(descriptor) { store.context.delete(model) }
    }

    // MARK: - Main / enabled / order / color

    func setMain(accountID: String) {
        guard let target = store.account(id: accountID), !Self.isPlaceholder(target) else { return }
        let wasEnabled = target.enabled
        target.enabled = true
        for a in store.accounts(includeDisabled: true) { a.isMain = (a.id == accountID) }
        store.save()
        if !wasEnabled { enabledAccountsChanged() }
    }

    /// A disabled account keeps its local data, but it is hidden from every screen (feeds, creators, supports and totals,
    /// notifications, badge) until the account is enabled again; Settings → アカウント still lists it.
    func setEnabled(accountID: String, _ enabled: Bool) {
        guard let account = store.account(id: accountID), !Self.isPlaceholder(account) else { return }
        let changed = account.enabled != enabled
        account.enabled = enabled
        if !enabled && account.isMain {
            account.isMain = false
            assignMainIfNeeded()
        } else if enabled {
            assignMainIfNeeded()
        }
        store.save()
        if changed { enabledAccountsChanged() }
        if changed && !enabled {
            // Stop the account's in-flight requests: a sync that was already running must not store results for (or
            // announce) an account the user just turned off. The credential is kept.
            let revoker = sessionRevoker
            Task { await revoker?.revokeSession(accountID: accountID) }
        }
    }

    /// Re-derives the creator / feed relation flags (they count enabled accounts only) and notifies the observer.
    private func enabledAccountsChanged() {
        store.refreshRelationFlags(recomputeAllPosts: true)
        onEnabledAccountsChanged?()
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
        // Logged out / quarantined: the credential was deleted, so a check could only send a guest request (and would
        // turn a logout into "expired", or clear a quarantine). Both states end only with a verified login.
        if account.kind == .fanbox, account.sessionState == .loggedOut { return .updated(.loggedOut) }
        if account.kind == .fanbox, account.sessionState == .error {
            return .unchanged(reason: "別のpixivアカウントのセッションを検出したため同期を止めています")
        }
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
                await quarantineMismatchedSession(accountID: accountID, observedUserID: user.pixivUserID)
                return .updated(.error)
            }
            account.sessionState = .valid
            identityWarnings[accountID] = nil
            if account.kind == .fanbox {
                if !user.name.isEmpty { account.displayName = user.name }
                if let icon = user.iconURL { account.avatarURL = icon }
                if let creatorID = user.creatorID, !creatorID.isEmpty { account.creatorID = creatorID }
                if let fanboxUserID = user.fanboxUserID { account.fanboxUserID = fanboxUserID }
            }
            account.sessionCheckedAt = .now
            result = .updated(account.sessionState)
        case .failure(let error):
            if account.sessionState == .error || account.sessionState == .loggedOut {
                // Quarantined or logged out while the check ran: only a verified login ends these states.
                result = .updated(account.sessionState)
            } else if let state = Self.sessionState(for: error) {
                account.sessionState = state
                account.sessionCheckedAt = .now
                result = .updated(state)
            } else if let probed = await probeWithBellCount(source: source, context: context, after: error) {
                // docs/API.md §4.2: the page was not readable (challenge / edge block), the cheap API probe decides.
                guard let account = store.account(id: accountID) else { return .unchanged(reason: "アカウントが見つかりません") }
                if probed == .expired {
                    account.sessionState = .expired
                    account.sessionCheckedAt = .now
                    result = .updated(.expired)
                } else {
                    result = .unchanged(reason: "ページを確認できませんでしたが、APIではログイン中です")
                }
            } else {
                result = .unchanged(reason: Self.describe(error))
            }
        }
        store.save()
        return result
    }

    /// bell.countUnread as a session probe after the page metadata could not be read (not for offline / cancelled).
    /// Returns `.expired` for a 401, `.valid` for a 200, nil when it could not decide.
    private func probeWithBellCount(source: RemoteDataSource, context: AccountContext, after error: Error) async -> SessionState? {
        guard let fanbox = source as? FanboxRemoteDataSource else { return nil }
        switch error as? RemoteError {
        case .offline?, .cancelled?, .blockedByPolicy?, .rateLimited?: return nil
        default: break
        }
        do {
            _ = try await RequestContext.$priority.withValue(.interactiveRead) {
                try await fanbox.unreadNotificationCount(account: context)
            }
            return .valid
        } catch let probeError as RemoteError where probeError == .unauthorized {
            return .expired
        } catch {
            return nil
        }
    }

    /// Validates every enabled account (sequentially; each is a single lightweight request). Logged-out and quarantined
    /// accounts have no session to check.
    func validateAllSessions() async {
        for account in store.accounts() where !Self.isPlaceholder(account)
            && !(account.kind == .fanbox && (account.sessionState == .loggedOut || account.sessionState == .error)) {
            await validateSession(accountID: account.id)
        }
    }

    /// Maps a failed session check to a new state; nil = leave unchanged.
    ///
    /// Only a 401 proves anything (`.expired`). A Cloudflare challenge (HTML 403 / page without metadata), an edge
    /// block, a FANBOX 403 or any other failure is "unknown" (docs/API.md §4.2) and never demotes the account.
    /// `.error` is reserved for an identity mismatch (set by `quarantineMismatchedSession`).
    static func sessionState(for error: Error) -> SessionState? {
        guard let remoteError = error as? RemoteError else { return nil }
        switch remoteError {
        case .unauthorized:
            return .expired
        case .forbidden, .notFound, .decoding, .invalidRequest, .server, .edgeBlocked, .csrfUnavailable,
             .offline, .rateLimited, .network, .blockedByPolicy, .cancelled, .unsupported:
            return nil
        }
    }

    /// Re-captures cookies from the web store after a FANBOX page finished loading in a browse / payment session
    /// (e.g. a Cloudflare challenge that minted cf_clearance, or a re-login in browse mode).
    ///
    /// - `pageUserID`: the logged-in user read from that page. A different user than the account's own → nothing is
    ///   copied, the web store is reset and `.identityMismatch` is returned (the session UI then warns and stops).
    /// - When the web store holds a DIFFERENT FANBOXSESSID than the Keychain and the page did not name the user, the new
    ///   session is verified with a probe request before it replaces the stored one (`.rejected` if that fails).
    @discardableResult
    func refreshCredentialFromWeb(accountID: String, userAgent: String?, csrfToken: String?,
                                  pageUserID: String? = nil) async -> WebCredentialRefreshResult {
        guard let account = store.account(id: accountID), account.kind == .fanbox, !Self.isPlaceholder(account) else { return .unchanged }
        let boundUserID = account.pixivUserID
        let context = account.context
        if let pageUserID, !pageUserID.isEmpty, let boundUserID, pageUserID != boundUserID {
            await handleWebIdentityMismatch(accountID: accountID, pageUserID: pageUserID)
            return .identityMismatch(pageUserID: pageUserID)
        }
        guard let captured = await webSessions.captureCredential(webProfileID: account.webProfileID, userAgent: userAgent,
                                                                  csrfToken: csrfToken) else { return .unchanged }
        let existing = await credentials.credential(for: accountID)
        var updated = existing ?? SessionCredential(cookies: [])
        updated.merge(captured.cookies)
        if let ua = captured.userAgent { updated.userAgent = ua }
        let oldSession = existing?.sessionCookieValue
        let newSession = updated.sessionCookieValue
        let sessionChanged = newSession != nil && newSession != oldSession
        if let token = captured.csrfToken {
            updated.csrfToken = token
        } else if sessionChanged {
            updated.csrfToken = nil       // bound to the previous session
        }
        guard existing == nil || !Self.sameContent(existing!, updated) else { return .unchanged }
        guard updated.hasSessionCookie else { return .unchanged }

        if sessionChanged && (pageUserID ?? "").isEmpty {
            // A new session appeared in the web store without a page naming its user: verify before storing it.
            switch await probeUser(with: updated, context: context) {
            case .success(let probe):
                if let boundUserID, probe.user.pixivUserID != boundUserID {
                    await handleWebIdentityMismatch(accountID: accountID, pageUserID: probe.user.pixivUserID)
                    return .identityMismatch(pageUserID: probe.user.pixivUserID)
                }
                if updated.csrfToken == nil { updated.csrfToken = probe.csrfToken }
            case .failure:
                AppLog.auth.notice("new web session of \(accountID, privacy: .public) could not be verified; kept the stored one")
                return .rejected
            }
        }
        if sessionChanged {
            // Requests still running with the old session must not write into the new credential.
            await sessionRevoker?.revokeSession(accountID: accountID)
        }
        updated.capturedAt = .now
        do {
            try await credentials.save(updated, for: accountID)
        } catch {
            AppLog.auth.error("credential refresh failed for \(accountID, privacy: .public)")
            return .unchanged
        }
        // A verified new session (re-login in browse mode) makes the account usable again.
        if sessionChanged, let current = store.account(id: accountID), current.sessionState != .valid {
            current.sessionState = .valid
            current.sessionCheckedAt = .now
            identityWarnings[accountID] = nil
            store.save()
        }
        return .updated
    }

    /// Copies a FANBOXSESSID rotated by an API response into the account's web store (the web view and the API keep
    /// presenting the same session, docs/API.md §1.3). CDN cookies minted by URLSession are never copied.
    func installAPISessionIntoWeb(accountID: String) async {
        guard let account = store.account(id: accountID), account.kind == .fanbox, !Self.isPlaceholder(account),
              account.sessionState != .error,
              let credential = await credentials.credential(for: accountID), credential.hasSessionCookie else { return }
        var session = credential
        // Only the session cookie: other pixiv / FANBOX cookies in the web store may be newer than the Keychain copy, and
        // CDN cookies (cf_clearance, __cf_bm) are bound to the client that earned them.
        session.cookies = credential.cookies.filter {
            $0.name == SessionCredential.sessionCookieName && FanboxHostPolicy.isFanboxHost($0.normalizedDomain)
        }
        await webSessions.install(session, webProfileID: account.webProfileID)
    }

    /// Before showing a web session: if the account's web store lost its FANBOX session but the Keychain still has one,
    /// install it so the web view opens logged in as this account (SPEC §40).
    func prepareWebSession(accountID: String) async {
        guard let account = store.account(id: accountID), account.kind == .fanbox, !Self.isPlaceholder(account) else { return }
        let webProfileID = account.webProfileID
        if await webSessions.hasSessionCookie(webProfileID: webProfileID) { return }
        guard let credential = await credentials.credential(for: accountID), credential.hasSessionCookie else { return }
        // Logged out / removed / quarantined while the credential was read: its cleared web store never gets it back.
        guard let current = store.account(id: accountID), current.sessionState != .loggedOut, current.sessionState != .error else {
            return
        }
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

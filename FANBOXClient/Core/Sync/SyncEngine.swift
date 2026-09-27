import Foundation
import Observation
import SwiftData

struct SyncOutcome: Sendable, Equatable {
    var resource: SyncResource
    var accountID: String
    var scope: String
    /// New item ids discovered (posts / notification event ids / newsletter ids ...).
    var newItemIDs: [String]
    var error: RemoteError?
    /// The sync succeeded but part of it could not be read (a dashboard source): shown where the data is, not as a failure.
    var partialError: RemoteError? = nil

    static func skipped(_ resource: SyncResource, accountID: String, scope: String = "") -> SyncOutcome {
        SyncOutcome(resource: resource, accountID: accountID, scope: scope, newItemIDs: [], error: nil)
    }

    static func failed(_ resource: SyncResource, accountID: String, scope: String = "", error: RemoteError) -> SyncOutcome {
        SyncOutcome(resource: resource, accountID: accountID, scope: scope, newItemIDs: [], error: error)
    }
}

/// Differential sync engine (SPEC §3.7 / §34).
/// - Per account / resource `SyncState` bookkeeping.
/// - Newest-first paging that STOPS at the first known post id (no mass crawling).
/// - Concurrent requests for the same (account, resource, scope) are coalesced into one.
/// - Errors are recorded in SyncState; local cache is never deleted on error.
@MainActor
@Observable
final class SyncEngine {
    private(set) var isSyncing = false
    private(set) var lastError: RemoteError?
    private(set) var lastSuccessAt: Date?

    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let remote: RemoteDataSourceProvider
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let network: NetworkModeController
    /// Called with ids of newly detected NotificationEvents (wired to NotificationService by AppEnvironment).
    @ObservationIgnored var onNewNotificationEvents: (([String]) async -> Void)?
    /// Called with ids of events whose text prefetch was re-armed but that were never announced: prefetched, no banner.
    @ObservationIgnored var onPrefetchOnlyEvents: (([String]) async -> Void)?
    /// Called once per finished (coalesced) `sync`, success or failure. Wired by AppEnvironment to the offline
    /// "recent N" rules and media prefetch; implementations must not block (they schedule their own work).
    @ObservationIgnored var onSyncFinished: ((SyncOutcome, SyncReason) -> Void)?
    /// Called for every failed sync / refresh except cancellation (wired to Research Mode events by AppEnvironment).
    @ObservationIgnored var onFailure: ((_ operation: String, _ accountID: String, _ error: RemoteError) -> Void)?
    /// The session of a FANBOX account turned out to belong to another pixiv user (accountID, observed user id).
    /// Wired to `AccountService.quarantineMismatchedSession` (SPEC §3.2): nothing is stored under the wrong account.
    @ObservationIgnored var onIdentityMismatch: ((String, String) async -> Void)?
    /// A FANBOX account's session just moved to `.expired` (wired to a one-time local notification).
    @ObservationIgnored var onSessionExpired: ((String) -> Void)?

    /// Hard cap for differential feed paging (SPEC §3.7: never crawl history).
    static let maxFeedPages = 3
    /// Own-data listings (fans) may page further, but still bounded.
    static let maxFanPages = 20
    static let maxCommentPages = 3
    /// bell.list pages read after a gap (about 20 bells each), stopping at the first known bell.
    static let maxNotificationPages = 5
    /// Bells older than the previous listing by more than this (clock skew) are known to have been listed already.
    static let notificationOverlap: TimeInterval = 10 * 60

    /// bell.list is fetched at least this often even when bell.countUnread reports no change (docs/API.md §10.2).
    static let notificationFullRefreshInterval: TimeInterval = 15 * 60
    /// newsletter.list during automatic polling at most this often.
    static let newsletterPollInterval: TimeInterval = 10 * 60
    /// payment.listPaid / payment status: user-initiated refreshes within this window reuse the previous answer
    /// (the Support screen asks for supports and payments back to back).
    static let userRefreshDedupeInterval: TimeInterval = 2 * 60
    /// Automatic payment.listPaid refresh interval (docs/API.md §19.2: low frequency) and the tighter one early in the month.
    static let paymentsAutomaticInterval: TimeInterval = 24 * 60 * 60
    static let paymentsEarlyMonthInterval: TimeInterval = 6 * 60 * 60
    /// Automatic unpaid-payment check interval (page metadata + payment.listUnpaid) and the tighter one on the 1st–5th.
    static let paymentStatusInterval: TimeInterval = 6 * 60 * 60
    static let paymentStatusEarlyMonthInterval: TimeInterval = 60 * 60
    /// Automatic fan-list refresh interval (docs/API.md §1.8: pull the fan list about daily at most).
    static let fansAutomaticInterval: TimeInterval = 24 * 60 * 60
    /// Screens that open with `.onDemand` reuse a fan list fetched within this window.
    static let fansOnDemandInterval: TimeInterval = 10 * 60
    /// After a 403 from the post detail endpoint, automatic (non-interactive) detail fetches pause
    /// (docs/API.md §1.7: post.info can be edge-blocked for non-browser clients; repeated calls risk the session).
    static let postDetailBlockCooldown: TimeInterval = 15 * 60
    /// Sub-scope of the notifications SyncState that stores the last unread count and the last full listing.
    static let unreadCountScope = "unreadCount"
    /// Sub-scope of the payments SyncState that tracks the unpaid-payment check.
    static let paymentStatusScope = "status"

    /// Time source (tests pin it to exercise day-of-month rules).
    @ObservationIgnored var clock: @MainActor () -> Date = { Date.now }

    @ObservationIgnored private var inFlight: [String: Task<SyncOutcome, Never>] = [:]
    @ObservationIgnored private var inFlightOps: [String: Task<RemoteError?, Never>] = [:]
    @ObservationIgnored private var syncAllTask: Task<Void, Never>?
    /// Priority of the running `syncAll` batch, and a raised floor when a more urgent caller joined it (SPEC §29).
    @ObservationIgnored private var syncAllPriority: RequestPriority?
    @ObservationIgnored private(set) var batchPriorityFloor: RequestPriority?
    /// Device-wide: an edge block follows the device / IP, not the account (docs/API.md §1.7 / §1.8).
    @ObservationIgnored private var postDetailBlockedUntil: Date?
    @ObservationIgnored private var activeCount = 0

    init(store: LocalStore, remote: RemoteDataSourceProvider, settings: AppSettings, network: NetworkModeController) {
        self.store = store
        self.remote = remote
        self.settings = settings
        self.network = network
    }

    /// Text / JSON requests allowed right now (Offline mode or no path → false).
    var canReachNetwork: Bool { MediaPolicy.allowsText(policy: network.policy) }

    // MARK: - Public API

    /// Accounts being removed (`prepareForRemoval`): nothing new starts for them.
    @ObservationIgnored private var removingAccountIDs: Set<String> = []
    /// Account each running post fetch is sending as, by operation key (an automatic fetch "post|*|…" picks it per attempt).
    @ObservationIgnored private var postFetchAccounts: [String: String] = [:]

    /// Called by account removal before the account's rows are deleted: no new sync starts for the account, and its
    /// running syncs / operations are cancelled and awaited, so none of them writes to rows that are about to go (a write
    /// to a deleted SwiftData model is fatal) or recreates rows for the removed account. Automatic post fetches are
    /// cancelled only while they are sending as that account (they skip it from then on).
    func prepareForRemoval(accountID: String) async {
        removingAccountIDs.insert(accountID)
        let syncs = inFlight.filter { $0.key.hasPrefix("\(accountID)|") }.map(\.value)
        let ops = inFlightOps.filter { $0.key.contains("|\(accountID)|") || postFetchAccounts[$0.key] == accountID }.map(\.value)
        for task in syncs { task.cancel() }
        for task in ops { task.cancel() }
        for task in syncs { _ = await task.value }
        for task in ops { _ = await task.value }
    }

    @discardableResult
    func sync(_ resource: SyncResource, accountID: String, scope: String = "", reason: SyncReason) async -> SyncOutcome {
        let key = Self.key(accountID: accountID, resource: resource, scope: scope)
        if let running = inFlight[key] { return await running.value }
        guard !removingAccountIDs.contains(accountID) else { return .skipped(resource, accountID: accountID, scope: scope) }

        guard let account = store.account(id: accountID) else {
            return .failed(resource, accountID: accountID, scope: scope, error: .invalidRequest("アカウントが見つかりません"))
        }
        guard account.enabled else { return .skipped(resource, accountID: accountID, scope: scope) }
        if Self.skipsForSessionState(account, reason: reason) {
            // Identity mismatch: never sync as another user. Expired / logged out: no automatic requests that are
            // known to fail (the re-login banner asks the user); explicit refreshes still run.
            return .skipped(resource, accountID: accountID, scope: scope)
        }
        guard canReachNetwork else {
            // Offline: return immediately; local data stays exactly as it is.
            return .failed(resource, accountID: accountID, scope: scope, error: .offline)
        }
        if Self.requiresCreatorAccount(resource, scope: scope), account.creatorID == nil {
            return .skipped(resource, accountID: accountID, scope: scope)
        }
        // Creator reads on screen appear / launch are bounded by a minimum interval (CreatorReadPolicy, docs/API.md §1.8).
        if CreatorReadPolicy.isFresh(resource, scope: scope, reason: reason,
                                     lastSuccess: store.existingSyncState(accountID: accountID, resource: resource, scope: scope)?.lastSuccessfulSync,
                                     now: clock()) {
            return .skipped(resource, accountID: accountID, scope: scope)
        }

        let context = account.context
        let priority = max(RequestContext.priority, Self.priority(for: resource, reason: reason))
        let task = Task { @MainActor [weak self] () -> SyncOutcome in
            guard let self else { return .skipped(resource, accountID: accountID, scope: scope) }
            self.beginActivity()
            let (outcome, deliver, prefetchOnly) = await RequestContext.$priority.withValue(priority) {
                await self.perform(resource, context: context, scope: scope, reason: reason)
            }
            self.inFlight[key] = nil
            self.endActivity()
            self.onSyncFinished?(outcome, reason)
            // Notification pipeline runs after the coalesced sync finished (no re-entrancy into this key). An account
            // turned off (or removed) while its request was running is not announced.
            let stillEnabled = self.store.account(id: accountID)?.enabled == true
            if stillEnabled, !deliver.isEmpty, let callback = self.onNewNotificationEvents {
                await callback(deliver)
            }
            if stillEnabled, !prefetchOnly.isEmpty, let callback = self.onPrefetchOnlyEvents {
                await callback(prefetchOnly)
            }
            return outcome
        }
        inFlight[key] = task
        return await task.value
    }

    /// Full lightweight refresh of all enabled accounts (launch / pull-to-refresh).
    func syncAll(reason: SyncReason) async {
        let wanted = max(RequestContext.priority, Self.priority(for: .timeline, reason: reason))
        if let running = syncAllTask {
            // Joining a running batch (e.g. pull-to-refresh right after the launch refresh): the batch's remaining
            // requests are raised to the caller's priority instead of the user waiting behind backgroundSync (SPEC §29).
            if wanted > (batchPriorityFloor ?? syncAllPriority ?? .backgroundSync) { batchPriorityFloor = wanted }
            await running.value
            return
        }
        guard canReachNetwork else {
            lastError = .offline
            return
        }
        syncAllPriority = wanted
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcomes = await self.runForAllAccounts(reason: reason) { account in
                var plan: [SyncResource] = [.notifications, .supports, .timeline, .supportingTimeline, .creators]
                if account.creatorID != nil { plan += [.creatorDashboard, .creatorComments, .fans] }
                return plan
            }
            self.finishBatch(outcomes)
            self.syncAllTask = nil
            self.syncAllPriority = nil
            self.batchPriorityFloor = nil
        }
        syncAllTask = task
        await task.value
    }

    /// Background refresh: notifications, supports, timeline metadata only (SPEC §35).
    func syncLightweight(reason: SyncReason) async {
        await syncLightweightOutcomes(reason: reason)
    }

    /// Same as `syncLightweight` but returns every outcome (used by background refresh / silent push to report results).
    @discardableResult
    func syncLightweightOutcomes(reason: SyncReason) async -> [SyncOutcome] {
        guard canReachNetwork else {
            lastError = .offline
            return []
        }
        // Creator accounts also check the fan list (throttled to `fansAutomaticInterval`) so 新規支援 is detected.
        let outcomes = await runForAllAccounts(reason: reason) { account in
            account.creatorID == nil ? [.notifications, .supports, .timeline] : [.notifications, .supports, .timeline, .fans]
        }
        finishBatch(outcomes)
        return outcomes
    }

    /// Fetches the post body into the local DB using the best account (SPEC §8) unless `accountID` is given.
    /// Automatic selection: if the chosen account only gets a restricted detail (or its session fails), other enabled
    /// accounts whose PostAccess.canView is true / unknown are tried in AccountSelector order.
    @discardableResult
    func refreshPost(postID: String, accountID: String? = nil, priority: RequestPriority = .interactiveRead) async -> RemoteError? {
        guard canReachNetwork else { return .offline }
        let wanted = max(priority, RequestContext.priority)
        // Interactive fetches (the post screen) have keys of their own and never wait on a background fetch of the post
        // (notification prefetch / offline rule), which is subject to the background budget (it may wait up to 30 s, or
        // fail fast with "rate limited"). That fetch is cancelled (one still queued in the gate is never sent) and its
        // callers get the interactive result. Background callers do join a running interactive fetch.
        let key = Self.postFetchKey(postID: postID, accountID: accountID, interactive: wanted.isInteractive)
        if wanted.isInteractive {
            for (running, task) in inFlightOps where Self.isPostFetchKey(running, postID: postID, interactive: false) {
                task.cancel()
            }
        }
        if inFlightOps[key] == nil {
            // Another fetch of the same post is running with a different account choice (notification prefetch vs. the
            // post screen): wait for it instead of issuing a second GET, and only fetch again when it did not yield a body.
            let others = inFlightOps.filter { entry in
                Self.isPostFetchKey(entry.key, postID: postID, interactive: true)
                    || (!wanted.isInteractive && Self.isPostFetchKey(entry.key, postID: postID, interactive: false))
            }.map(\.value)
            if !others.isEmpty {
                var result: RemoteError?
                for other in others { result = await other.value }
                if result == nil, store.post(id: postID)?.hasCachedBody == true { return nil }
            }
        }
        return await coalescedOperation(key) { [weak self] in
            guard let self else { return .cancelled }
            let fetchedBefore = self.store.post(id: postID)?.bodyFetchedAt
            let result = await RequestContext.$priority.withValue(wanted) {
                await self.fetchPostDetail(postID: postID, explicitAccountID: accountID, operationKey: key)
            }
            guard result == .cancelled, !wanted.isInteractive else { return result }
            // Cancelled for an interactive fetch of the same post: that fetch's result is this one's (a body it already
            // stored is a success).
            if let interactive = self.inFlightOps.first(where: { Self.isPostFetchKey($0.key, postID: postID, interactive: true) }) {
                return await interactive.value.value
            }
            let fetchedNow = self.store.post(id: postID)?.bodyFetchedAt
            return fetchedNow != nil && fetchedNow != fetchedBefore ? nil : result
        }
    }

    /// "post|<account or *>|<postID>", plus "|interactive" for fetches at an interactive priority.
    private static func postFetchKey(postID: String, accountID: String?, interactive: Bool) -> String {
        "post|\(accountID ?? "*")|\(postID)" + (interactive ? "|interactive" : "")
    }

    /// Whether `key` is a running fetch of `postID` (any account choice) of the given class.
    private static func isPostFetchKey(_ key: String, postID: String, interactive: Bool) -> Bool {
        key.hasPrefix("post|") && key.hasSuffix(interactive ? "|\(postID)|interactive" : "|\(postID)")
    }

    @discardableResult
    func refreshComments(postID: String, accountID: String? = nil, priority: RequestPriority = .interactiveRead) async -> RemoteError? {
        guard canReachNetwork else { return .offline }
        guard let account = accountID ?? commentAccount(postID: postID) else { return .invalidRequest("アカウントがありません") }
        // A logged-out / quarantined account is skipped by `sync`; say so instead of reporting a refresh that never ran.
        if let row = store.account(id: account), Self.skipsForSessionState(row, reason: .onDemand) { return .unauthorized }
        let key = Self.key(accountID: account, resource: .comments, scope: postID)
        if inFlight[key] == nil {
            // The same thread is already being fetched through another account: share that result.
            let others = inFlight.filter { $0.key.hasSuffix("|\(SyncResource.comments.rawValue)|\(postID)") }.map(\.value)
            if !others.isEmpty {
                var succeeded = false
                for other in others {
                    if await other.value.error == nil { succeeded = true }
                }
                if succeeded { return nil }
            }
        }
        let outcome = await RequestContext.$priority.withValue(max(priority, RequestContext.priority)) {
            await self.sync(.comments, accountID: account, scope: postID, reason: .onDemand)
        }
        return outcome.error
    }

    /// Creator profile + plans + first page of the creator's posts (differential).
    @discardableResult
    func refreshCreator(creatorID: String, accountID: String? = nil) async -> RemoteError? {
        guard canReachNetwork else { return .offline }
        guard let account = accountID ?? bestAccount(creatorID: creatorID), let row = store.account(id: account) else {
            return .invalidRequest("アカウントがありません")
        }
        if removingAccountIDs.contains(account) { return .cancelled }
        // No session to send: the creator.get below would be answered as a guest (isFollowed false) and stored.
        if Self.skipsForSessionState(row, reason: .onDemand) { return .unauthorized }
        let context = row.context
        let key = "creator|\(account)|\(creatorID)"
        return await coalescedOperation(key) { [weak self] in
            guard let self else { return .cancelled }
            return await RequestContext.$priority.withValue(max(.interactiveRead, RequestContext.priority)) {
                var firstError: RemoteError?
                do {
                    let creator = try await self.remote.dataSource(for: context).creator(id: creatorID, account: context)
                    self.store.upsertCreator(creator, account: context)
                } catch {
                    let mapped = self.handleFailure(error, accountID: account)
                    firstError = mapped
                }
                let plans = await self.sync(.plans, accountID: account, scope: creatorID, reason: .onDemand)
                let posts = await self.sync(.creatorPosts, accountID: account, scope: creatorID, reason: .onDemand)
                return firstError ?? plans.error ?? posts.error
            }
        }
    }

    /// Loads one older page of a creator's posts on explicit user request.
    @discardableResult
    func loadMoreCreatorPosts(creatorID: String, accountID: String? = nil) async -> RemoteError? {
        guard canReachNetwork else { return .offline }
        guard let account = accountID ?? bestAccount(creatorID: creatorID), let row = store.account(id: account) else {
            return .invalidRequest("アカウントがありません")
        }
        if removingAccountIDs.contains(account) { return .cancelled }
        if Self.skipsForSessionState(row, reason: .onDemand) { return .unauthorized }
        let context = row.context
        let key = "creatorPostsMore|\(account)|\(creatorID)"
        return await coalescedOperation(key) { [weak self] in
            guard let self else { return .cancelled }
            let state = self.store.syncState(accountID: account, resource: .creatorPosts, scope: creatorID)
            if state.cursor == Self.endOfListCursor { return nil }
            state.lastAttemptAt = clock()
            do {
                let page = try await RequestContext.$priority.withValue(max(.interactiveRead, RequestContext.priority)) {
                    try await self.remote.dataSource(for: context).creatorPosts(creatorID: creatorID, account: context, cursor: state.cursor)
                }
                self.store.upsertPostSummaries(page.items, account: context, source: .creator)
                state.cursor = page.nextCursor ?? Self.endOfListCursor
                if state.lastKnownItemID == nil { state.lastKnownItemID = page.items.first?.id }
                self.markSuccess(state: state, accountID: account, provesSession: false)
                return nil
            } catch {
                let mapped = self.handleFailure(error, accountID: account)
                self.markFailure(state: state, error: mapped)
                return mapped
            }
        }
    }

    /// Whether an older page of the creator's posts may exist (drives the "さらに読み込む" button).
    func hasMoreCreatorPosts(creatorID: String, accountID: String? = nil) -> Bool {
        guard let account = accountID ?? bestAccount(creatorID: creatorID) else { return false }
        let key = SyncState.key(accountID: account, resource: .creatorPosts, scope: creatorID)
        guard let state = store.first(#Predicate<SyncState> { $0.key == key }) else { return true }
        return state.cursor != Self.endOfListCursor
    }

    @discardableResult
    func refreshNewsletter(id: String, accountID: String? = nil, priority: RequestPriority = .interactiveRead) async -> RemoteError? {
        guard canReachNetwork else { return .offline }
        let enabled = Set(store.accounts().map(\.id))
        // A disabled account never sends requests (like `sync`), even when it is passed explicitly. A stored おたより is read
        // only as an enabled account that received it; the main account is the fallback for one without known receivers.
        let explicit = accountID.flatMap { enabled.contains($0) ? $0 : nil }
        let receivers = store.newsletter(id: id)?.accountIDs ?? []
        let candidate = explicit ?? (receivers.isEmpty ? store.mainAccount()?.id : receivers.first(where: { enabled.contains($0) }))
        guard let account = candidate, let row = store.account(id: account) else { return .invalidRequest("アカウントがありません") }
        if removingAccountIDs.contains(account) { return .cancelled }
        let context = row.context
        return await coalescedOperation("newsletter|\(account)|\(id)") { [weak self] in
            guard let self else { return .cancelled }
            do {
                let item = try await RequestContext.$priority.withValue(max(priority, RequestContext.priority)) {
                    try await self.remote.dataSource(for: context).newsletter(id: id, account: context)
                }
                self.store.upsertNewsletters([item], account: context)
                return nil
            } catch {
                return self.handleFailure(error, accountID: account)
            }
        }
    }

    /// Optimistic like toggle; reverted locally when FANBOX rejects it.
    func setLike(postID: String, liked: Bool) async -> RemoteError? {
        guard canReachNetwork else { return .offline }
        guard let post = store.post(id: postID) else { return .notFound }
        let enabled = Set(store.accounts().map(\.id))
        let accountID = post.detailAccountID.flatMap { enabled.contains($0) ? $0 : nil }
            ?? AccountSelector.bestAccount(postID: postID, store: store)
        guard let accountID, let row = store.account(id: accountID) else { return .invalidRequest("アカウントがありません") }
        let context = row.context
        let previous = (post.isLiked, post.likeCount)
        if post.isLiked != liked {
            post.isLiked = liked
            post.likeCount = max(0, post.likeCount + (liked ? 1 : -1))
            store.save()
        }
        do {
            try await RequestContext.$priority.withValue(.interactiveWrite) {
                try await self.remote.dataSource(for: context).setLike(postID: postID, liked: liked, account: context)
            }
            return nil
        } catch {
            let mapped = handleFailure(error, accountID: accountID)
            if let p = store.post(id: postID) {
                p.isLiked = previous.0
                p.likeCount = previous.1
                store.save()
            }
            return mapped
        }
    }

    /// Deletes a comment (own comment, or a comment on my creator post) and updates the local DB.
    @discardableResult
    func deleteComment(commentID: String, postID: String, accountID: String) async -> RemoteError? {
        guard canReachNetwork else { return .offline }
        guard let row = store.account(id: accountID) else { return .invalidRequest("アカウントがありません") }
        let context = row.context
        do {
            try await RequestContext.$priority.withValue(.interactiveWrite) {
                try await self.remote.dataSource(for: context).deleteComment(commentID: commentID, postID: postID, account: context)
            }
            store.deleteLocalComment(commentID: commentID)
            return nil
        } catch {
            return handleFailure(error, accountID: accountID)
        }
    }

    // MARK: - Priority / keys

    static func key(accountID: String, resource: SyncResource, scope: String) -> String {
        SyncState.key(accountID: accountID, resource: resource, scope: scope)
    }

    /// Whether `account` is skipped for `reason` because of its session state (FANBOX accounts only).
    /// Logged out and quarantined (`.error`) accounts have no credential at all: every request would go out as a guest
    /// (known to fail, or answered as a guest), so nothing runs for them until a login. Expired accounts still run explicit
    /// refreshes (the cookie may work again).
    static func skipsForSessionState(_ account: Account, reason: SyncReason) -> Bool {
        guard account.kind == .fanbox else { return false }
        switch account.sessionState {
        case .error, .loggedOut:
            return true
        case .expired:
            switch reason {
            case .appLaunch, .foregroundPolling, .backgroundRefresh, .notification: return true
            case .userRefresh, .onDemand, .afterWrite: return false
            }
        case .valid, .unknown:
            return false
        }
    }

    /// SPEC §29: user-initiated → interactiveRead, notification detection → notificationPrefetch, everything else backgroundSync.
    static func priority(for resource: SyncResource, reason: SyncReason) -> RequestPriority {
        var p: RequestPriority
        switch reason {
        case .userRefresh, .onDemand, .afterWrite: p = .interactiveRead
        case .notification: p = .notificationPrefetch
        case .appLaunch, .foregroundPolling, .backgroundRefresh: p = .backgroundSync
        }
        if resource == .notifications { p = max(p, .notificationPrefetch) }
        return p
    }

    /// Reasons that only need the newest page (background / polling / silent push).
    static func isLightweight(_ reason: SyncReason) -> Bool {
        reason == .backgroundRefresh || reason == .foregroundPolling || reason == .notification
    }

    static func requiresCreatorAccount(_ resource: SyncResource, scope: String) -> Bool {
        switch resource {
        case .creatorDashboard, .creatorComments, .fans: return true
        case .creatorPosts: return scope.isEmpty      // no scope = my own managed posts
        default: return false
        }
    }

    /// Cursor sentinel meaning "no older page exists".
    static let endOfListCursor = "<end>"

    // MARK: - Resource runners

    /// Returns the outcome, the event ids to announce and the event ids to prefetch without a banner.
    private func perform(_ resource: SyncResource, context: AccountContext, scope: String,
                         reason: SyncReason) async -> (SyncOutcome, [String], [String]) {
        let accountID = context.accountID
        let state = store.syncState(accountID: accountID, resource: resource, scope: scope)
        let isFirstSync = state.lastSuccessfulSync == nil
        // Low-frequency resources answer from the local DB while their last refresh is recent enough (no request).
        if isThrottled(resource, state: state, reason: reason) {
            return (.skipped(resource, accountID: accountID, scope: scope), [], [])
        }
        state.lastAttemptAt = clock()
        let ds = remote.dataSource(for: context)
        var deliver: [String] = []
        var prefetchOnly: [String] = []
        var partialFailure: RemoteError?
        do {
            var newIDs: [String] = []
            switch resource {
            case .session:
                let user = try await ds.currentUser(account: context)
                if context.kind == .fanbox, let known = store.account(id: accountID)?.pixivUserID, known != user.pixivUserID {
                    await onIdentityMismatch?(accountID, user.pixivUserID)
                    throw RemoteError.invalidRequest("このアカウントとは別のpixivユーザーのセッションでした")
                }
                applyCurrentUser(user, accountID: accountID)

            case .timeline, .supportingTimeline:
                newIDs = try await syncFeed(resource, ds: ds, context: context, state: state, isFirstSync: isFirstSync, reason: reason)

            case .creators:
                let creators = try await ds.followingCreators(account: context)
                store.applyFollowing(creators, account: context)

            case .supports:
                let listing = try await ds.supportingPlanListing(account: context)
                // A stopped support may leave plan.listSupporting while creator.listFollowing still reports
                // isSupported && isStopped (docs/API.md §8.1 / §18.10). Only when a support would vanish, read the
                // following list (best effort) so the change is recorded as 支援終了 rather than an unexplained anomaly.
                // After a payment web session (.afterWrite) the user may just have stopped a support that FANBOX still
                // lists until month end: the stop is only visible in the following list, so it is read then too.
                if listing.isComplete,
                   reason == .afterWrite || store.hasActiveSupports(absentFrom: listing.supports, accountID: accountID),
                   let following = try? await ds.followingCreators(account: context) {
                    store.applyFollowing(following, account: context)
                }
                let observed = Self.supportObservedSource(reason: reason, kind: context.kind)
                let (diff, history) = store.applySupportsDetailed(listing.supports, account: context, source: observed,
                                                                  isBaseline: isFirstSync, listingIsComplete: listing.isComplete)
                newIDs = diff.observedCreatorIDs
                let name = store.account(id: accountID)?.displayName ?? ""
                if !isFirstSync {
                    // A plan that disappears on the 1st–5th is a payment-attention signal (docs/API.md §18.8 B): announce it
                    // once as 決済要確認 (Critical) instead of a second 支援状態変化 banner for the same observation.
                    let earlyInMonth = LocalStore.dayOfMonthJST(clock()) <= 5
                    let changes = earlyInMonth ? history.filter { $0.kind != .disappeared } : history
                    if !changes.isEmpty {
                        deliver += store.recordSupportChangeEvents(changes, account: context, accountName: name)
                    }
                    if earlyInMonth, !diff.disappeared.isEmpty {
                        deliver += store.recordPaymentAttentionEvents(.disappearedEarlyInMonth, creatorIDs: diff.disappeared,
                                                                      account: context, accountName: name, now: clock())
                    }
                }
                // Paid records and the unpaid check are best effort and low frequency: their failure never fails supports.
                if isPaymentsRefreshDue(accountID: accountID, reason: reason) {
                    await syncPayments(ds: ds, context: context)
                }
                if isPaymentStatusCheckDue(accountID: accountID, reason: reason) {
                    deliver += await syncPaymentStatus(ds: ds, context: context, accountName: name)
                }
                if let problem = listing.problem {
                    // Recorded as a failure so it shows up in sync state / Research Mode; nothing was marked missing.
                    throw RemoteError.decoding(endpoint: "plan.listSupporting", detail: problem)
                }

            case .plans:
                guard !scope.isEmpty else { throw RemoteError.invalidRequest("creatorIDが必要です") }
                let plans = try await ds.creatorPlans(creatorID: scope, account: context)
                store.upsertPlans(plans, creatorID: scope)

            case .notifications:
                var created: [String] = []
                let probe = try await probeUnreadNotifications(ds: ds, context: context, state: state, reason: reason)
                if !probe.unchanged {
                    // Newest page first; older pages (nextUrl) only until one holds a bell this account already imported
                    // or predates the previous listing (docs/API.md §19.2), so a gap of more than one page is not lost.
                    // The first import reads one page (history is not crawled). The previous listing is the last bell.list
                    // read (the count state is written only after one); a sync the count probe skipped listed nothing.
                    let previousListing = store.syncState(accountID: accountID, resource: .notifications, scope: Self.unreadCountScope)
                        .lastSuccessfulSync ?? state.lastSuccessfulSync
                    let pageLimit = isFirstSync ? 1 : Self.maxNotificationPages
                    var cursor: String?
                    var rearmed: [String] = []
                    for pageIndex in 0..<pageLimit {
                        let batch = try await ds.notificationBatch(account: context, cursor: cursor)
                        let items = batch.page.items
                        let reachedKnown = store.hasImportedNotification(items, accountID: accountID)
                            || previousListing.map { last in
                                items.contains { $0.createdAt > .distantPast && $0.createdAt < last.addingTimeInterval(-Self.notificationOverlap) }
                            } ?? false
                        // Posts embedded in new-post notifications: the title / excerpt / cover are local before any tap.
                        if !batch.posts.isEmpty { store.upsertPostSummaries(batch.posts, account: context, source: .notification) }
                        let result = store.upsertNotificationsDetailed(items, account: context)
                        created += result.created
                        rearmed += result.rearmed
                        if pageIndex == 0 { state.lastKnownItemID = items.first?.remoteID ?? state.lastKnownItemID }
                        guard !reachedKnown, let next = batch.page.nextCursor, !items.isEmpty else { break }
                        cursor = next
                    }
                    // Another account's unrestricted copy re-armed a post event's prefetch: it goes through the pipeline
                    // again when it was announced (or due) before; a silently imported event stays silent. An unread one
                    // that was never announced (local notifications off, imported silently) is only prefetched.
                    for id in rearmed {
                        guard let event = store.notificationEvent(id: id) else { continue }
                        if event.deliveredLocally || event.deliveryPendingSince != nil {
                            deliver.append(id)
                        } else if !event.isRead {
                            prefetchOnly.append(id)
                        }
                    }
                    // The count is remembered only once the listing that goes with it succeeded (a failed listing is
                    // retried on the next tick instead of being hidden behind an "unchanged" count).
                    let countState = store.syncState(accountID: accountID, resource: .notifications, scope: Self.unreadCountScope)
                    countState.lastSuccessfulSync = clock()
                    if let count = probe.count { countState.lastKnownItemID = String(count) }
                }
                // おたより are part of notification detection; failures here don't fail notifications.
                if isNewsletterPollDue(accountID: accountID, reason: reason), let letters = try? await ds.newsletters(account: context) {
                    let newLetters = store.upsertNewsletters(letters, account: context)
                    created += store.ensureNewsletterEvents(newsletterIDs: newLetters, account: context)
                    markSubResourceSuccess(.newsletters, accountID: accountID)
                }
                newIDs = created
                deliver += deliverable(created, isFirstSync: isFirstSync)

            case .newsletters:
                let letters = try await ds.newsletters(account: context)
                let newLetters = store.upsertNewsletters(letters, account: context)
                let created = store.ensureNewsletterEvents(newsletterIDs: newLetters, account: context)
                newIDs = newLetters
                let notificationsKnown = store.syncState(accountID: accountID, resource: .notifications).lastSuccessfulSync != nil
                deliver += deliverable(created, isFirstSync: isFirstSync && !notificationsKnown)

            case .comments:
                guard !scope.isEmpty else { throw RemoteError.invalidRequest("postIDが必要です") }
                newIDs = try await syncComments(postID: scope, ds: ds, context: context, state: state)

            case .creatorDashboard:
                let dashboard = try await ds.creatorDashboard(account: context)
                store.upsertDashboard(dashboard, account: context)
                // What was read is stored; the metrics that could not be read keep their values and the failure shows.
                partialFailure = dashboard.partialError

            case .creatorPosts:
                if scope.isEmpty {
                    newIDs = try await syncManagedPosts(ds: ds, context: context, state: state, isFirstSync: isFirstSync, reason: reason)
                } else {
                    newIDs = try await syncCreatorPostsFirstPage(creatorID: scope, ds: ds, context: context, state: state)
                }

            case .creatorComments:
                newIDs = try await syncCreatorComments(ds: ds, context: context, state: state, isFirstSync: isFirstSync)

            case .fans:
                let newSupporters = try await syncFans(ds: ds, context: context, state: state)
                newIDs = newSupporters
                if !isFirstSync, !newSupporters.isEmpty {
                    let name = store.account(id: accountID)?.displayName ?? ""
                    deliver += store.recordNewSupporterEvents(userIDs: newSupporters, account: context, accountName: name, now: clock())
                }

            case .payments:
                let payments = try await ds.paidRecords(account: context)
                store.upsertPayments(payments, account: context)
            }
            markSuccess(state: state, accountID: accountID, provesSession: Self.provesSession(resource, scope: scope))
            if let partialFailure {
                // One dashboard source failed: recorded on this state and returned to Creator Mode only. It is not a
                // failed sync (no Home banner), and a refused source says nothing about the session the others used.
                state.error = partialFailure.userMessage
                store.save()
            }
            return (SyncOutcome(resource: resource, accountID: accountID, scope: scope, newItemIDs: newIDs, error: nil,
                                partialError: partialFailure), deliver, prefetchOnly)
        } catch {
            let mapped = handleFailure(error, accountID: accountID, operation: scope.isEmpty ? resource.rawValue : "\(resource.rawValue):\(scope)")
            markFailure(state: state, error: mapped)
            AppLog.sync.error("sync \(resource.rawValue, privacy: .public) failed: \(mapped.userMessage, privacy: .public)")
            return (SyncOutcome(resource: resource, accountID: accountID, scope: scope, newItemIDs: [], error: mapped), deliver, prefetchOnly)
        }
    }

    // MARK: - Frequency rules

    /// User-initiated reasons (and a notification that points at the resource) always refresh.
    static func isUserInitiated(_ reason: SyncReason) -> Bool {
        switch reason {
        case .userRefresh, .onDemand, .afterWrite, .notification: return true
        case .appLaunch, .foregroundPolling, .backgroundRefresh: return false
        }
    }

    /// Low Data / Extreme: automatic low-priority refreshes are skipped once the data exists locally.
    private var isConstrainedMode: Bool {
        let mode = network.policy.mode
        return mode == .lowData || mode == .extreme
    }

    /// Resources refreshed at low frequency. A throttled sync makes no request and leaves the state untouched.
    private func isThrottled(_ resource: SyncResource, state: SyncState, reason: SyncReason) -> Bool {
        guard let last = state.lastSuccessfulSync else { return false }
        let age = clock().timeIntervalSince(last)
        switch resource {
        case .payments:
            // The Support screen syncs supports (which refreshes payments when due) and then payments explicitly.
            return Self.isUserInitiated(reason) ? age < Self.userRefreshDedupeInterval : !isPaymentsRefreshDue(age: age)
        case .fans:
            // Automatic: about daily at most. Opening a screen (.onDemand) reuses a recent list; pull-to-refresh always reads.
            if reason == .onDemand { return age < Self.fansOnDemandInterval }
            return !Self.isUserInitiated(reason) && age < Self.fansAutomaticInterval
        default:
            return false
        }
    }

    private func isPaymentsRefreshDue(accountID: String, reason: SyncReason) -> Bool {
        guard let last = store.syncState(accountID: accountID, resource: .payments).lastSuccessfulSync else {
            return !(network.policy.mode == .extreme && !Self.isUserInitiated(reason))
        }
        let age = clock().timeIntervalSince(last)
        return Self.isUserInitiated(reason) ? age >= Self.userRefreshDedupeInterval : isPaymentsRefreshDue(age: age)
    }

    /// Automatic cadence for payment.listPaid: about daily, every few hours during the first week of the month
    /// (docs/API.md §19.2), never in Low Data / Extreme.
    private func isPaymentsRefreshDue(age: TimeInterval) -> Bool {
        guard !isConstrainedMode else { return false }
        let interval = LocalStore.dayOfMonthJST(clock()) <= 7 ? Self.paymentsEarlyMonthInterval : Self.paymentsAutomaticInterval
        return age >= interval
    }

    private func isPaymentStatusCheckDue(accountID: String, reason: SyncReason) -> Bool {
        let state = store.syncState(accountID: accountID, resource: .payments, scope: Self.paymentStatusScope)
        guard let last = state.lastAttemptAt else { return true }
        let age = clock().timeIntervalSince(last)
        if Self.isUserInitiated(reason) { return age >= Self.userRefreshDedupeInterval }
        let interval = LocalStore.dayOfMonthJST(clock()) <= 5 ? Self.paymentStatusEarlyMonthInterval : Self.paymentStatusInterval
        return age >= interval
    }

    private func isNewsletterPollDue(accountID: String, reason: SyncReason) -> Bool {
        guard reason == .foregroundPolling || reason == .backgroundRefresh else { return true }
        guard let last = store.syncState(accountID: accountID, resource: .newsletters).lastSuccessfulSync else { return true }
        return clock().timeIntervalSince(last) >= Self.newsletterPollInterval
    }

    /// Cheap gate for automatic polling (docs/API.md §10.2 / §19.2): bell.countUnread first; bell.list only when the
    /// count changed or `notificationFullRefreshInterval` passed. `unchanged == true` means the listing can be skipped.
    /// A probe that is unavailable or fails never blocks the listing.
    private func probeUnreadNotifications(ds: RemoteDataSource, context: AccountContext, state: SyncState,
                                          reason: SyncReason) async throws -> (unchanged: Bool, count: Int?) {
        guard reason == .foregroundPolling || reason == .backgroundRefresh, state.lastSuccessfulSync != nil else { return (false, nil) }
        let countState = store.syncState(accountID: context.accountID, resource: .notifications, scope: Self.unreadCountScope)
        let count: Int?
        do {
            count = try await ds.unreadNotificationCount(account: context)
        } catch let error as RemoteError where error == .unauthorized || error == .offline || error == .cancelled {
            throw error
        } catch {
            count = nil
        }
        guard let count else { return (false, nil) }
        countState.lastAttemptAt = clock()
        let previous = countState.lastKnownItemID.flatMap { Int($0) }
        guard previous == count, let lastFull = countState.lastSuccessfulSync else { return (false, count) }
        return (clock().timeIntervalSince(lastFull) < Self.notificationFullRefreshInterval, count)
    }

    /// Newest → oldest; STOP at the first page containing a post this account already knows (SPEC §3.7).
    /// First-ever sync and lightweight reasons read 1 page; otherwise at most `maxFeedPages`.
    /// A full sync that stops at its page limit before reaching a known post leaves a gap: its next cursor is kept in
    /// `state.cursor`, and the next full sync continues there after its own newest pages, within the same page cap, until
    /// it reaches a known post. A lightweight read that does not reach a known post leaves no mark at all (see below).
    /// Otherwise one read of the newest page would make the next full sync stop at page 1 and the posts below it would
    /// never be listed.
    private func syncFeed(_ resource: SyncResource, ds: RemoteDataSource, context: AccountContext, state: SyncState,
                          isFirstSync: Bool, reason: SyncReason) async throws -> [String] {
        let lightweight = Self.isLightweight(reason)
        let pageLimit = (isFirstSync || lightweight) ? 1 : Self.maxFeedPages
        let source: TimelineSource = resource == .timeline ? .home : .supporting
        let pendingGap = state.cursor
        var cursor: String?
        var resumingGap = false
        var readFromGap = false
        var inserted: [String] = []
        var newest: String?
        var firstPageIDs: [String] = []
        var gap: String?
        for pageIndex in 0..<pageLimit {
            if resumingGap { readFromGap = true }
            let page = resource == .timeline
                ? try await ds.homeTimeline(account: context, cursor: cursor)
                : try await ds.supportingTimeline(account: context, cursor: cursor)
            let ids = page.items.map(\.id)
            if pageIndex == 0 {
                newest = ids.first
                firstPageIDs = ids
            }
            let knownBefore = knownPostIDs(ids, accountID: context.accountID)
            let result = store.upsertPostSummaries(page.items, account: context, source: source)
            inserted += result.insertedIDs
            let reachedKnown = !knownBefore.isEmpty || (!resumingGap && (state.lastKnownItemID.map { ids.contains($0) } ?? false))
            let next = page.items.isEmpty ? nil : page.nextCursor
            gap = nil
            if reachedKnown {
                // The newest pages are covered; an older gap left by an earlier read is filled next (full syncs only).
                guard !resumingGap, !lightweight, !isFirstSync, let pendingGap else { break }
                resumingGap = true
                cursor = pendingGap
                continue
            }
            guard let next else { break }
            gap = next          // stays a gap unless a later page reaches a known post
            cursor = next
        }
        // A lightweight read (one page) that did not reach a known post: its posts are stored but not counted as seen, and
        // neither the newest id nor the gap cursor moves, so the next full sync reads through them down to the posts it
        // knows. A gap cursor per such read would replace the previous one (two background reads overnight, each finding
        // a full page of new posts, and the older gap would never be listed).
        if lightweight, !isFirstSync, gap != nil {
            let accountID = context.accountID
            let unseen = firstPageIDs
            for post in store.fetch(FetchDescriptor<Post>(predicate: #Predicate { unseen.contains($0.postID) })) {
                post.seenByAccountIDs.removeAll { $0 == accountID }
            }
            return inserted
        }
        if let newest { state.lastKnownItemID = newest }
        // The first import reads one page on purpose (history is not crawled): no gap to fill.
        if !isFirstSync {
            if let gap {
                state.cursor = gap                      // stopped at the page limit before a known post
            } else if resumingGap {
                if readFromGap { state.cursor = nil }   // filled; not reached yet (page limit) → kept for the next sync
            } else if !lightweight {
                state.cursor = nil
            }
        }
        return inserted
    }

    /// Post ids of `ids` that this account has already seen in a listing.
    private func knownPostIDs(_ ids: [String], accountID: String) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let posts = store.fetch(FetchDescriptor<Post>(predicate: #Predicate { ids.contains($0.postID) }))
        return Set(posts.filter { $0.seenByAccountIDs.contains(accountID) }.map(\.postID))
    }

    private func syncCreatorPostsFirstPage(creatorID: String, ds: RemoteDataSource, context: AccountContext,
                                           state: SyncState) async throws -> [String] {
        let page = try await ds.creatorPosts(creatorID: creatorID, account: context, cursor: nil)
        let result = store.upsertPostSummaries(page.items, account: context, source: .creator)
        // Keep an older-page cursor from earlier "load more" requests while the newest post of the previous visit is still
        // on the first page. When new posts pushed it off (the page boundaries shifted, docs/API.md §19.2), or "<end>" is
        // no longer true because a next page exists, "load more" continues right after this first page.
        let shifted = state.lastKnownItemID.map { newest in !page.items.contains { $0.id == newest } } ?? true
        if state.cursor == nil || shifted || (state.cursor == Self.endOfListCursor && page.nextCursor != nil) {
            state.cursor = page.nextCursor ?? Self.endOfListCursor
        }
        if let newest = page.items.first?.id { state.lastKnownItemID = newest }
        return result.insertedIDs
    }

    private func syncManagedPosts(ds: RemoteDataSource, context: AccountContext, state: SyncState, isFirstSync: Bool,
                                  reason: SyncReason) async throws -> [String] {
        let pageLimit = (isFirstSync || Self.isLightweight(reason)) ? 1 : Self.maxFeedPages
        var cursor: String?
        var inserted: [String] = []
        var listed: Set<String> = []
        var oldestListed: Date?
        var complete = false
        for pageIndex in 0..<pageLimit {
            let page = try await ds.managedPosts(account: context, cursor: cursor)
            let known = store.knownPostIDs(page.items.map(\.id))
            inserted += store.upsertManagedPosts(page.items, account: context).insertedIDs
            listed.formUnion(page.items.map(\.id))
            if let oldest = page.items.map(\.publishedAt).min() { oldestListed = min(oldestListed ?? oldest, oldest) }
            if pageIndex == 0, let newest = page.items.first?.id { state.lastKnownItemID = newest }
            if page.nextCursor == nil { complete = true }
            if !known.isEmpty { break }
            guard let next = page.nextCursor, !page.items.isEmpty else { break }
            cursor = next
        }
        // Every page from the first to the last was read: own posts missing from it were deleted on FANBOX.
        if complete, let creatorID = context.creatorID {
            store.markMissingManagedPostsRemoved(presentIDs: listed, oldestListed: oldestListed, creatorID: creatorID)
        }
        return inserted
    }

    private func syncComments(postID: String, ds: RemoteDataSource, context: AccountContext, state: SyncState) async throws -> [String] {
        var cursor: String?
        var inserted: [String] = []
        let cutoff = commentReadCutoff(postID: postID)
        // Without a local Post row (a post published on the web, a comment bell) ownership comes from the hint.
        let creatorID = postCreatorID(postID)
        let ownCreatorID = creatorID.flatMap { store.ownedCreatorAccountMap()[$0] != nil ? $0 : nil }
        for pageIndex in 0..<Self.maxCommentPages {
            let page = try await ds.comments(postID: postID, account: context, cursor: cursor)
            let before = inserted.count
            let flatCount = page.items.reduce(0) { $0 + $1.flattened.count }
            inserted += store.upsertCommentsReturningNew(page.items, postID: postID, account: context, readCutoff: cutoff,
                                                         ownPostCreatorID: ownCreatorID)
            if pageIndex == 0, let newest = page.items.first?.id { state.lastKnownItemID = newest }
            // Stop once a page contained anything already known.
            if inserted.count - before < flatCount { break }
            guard let next = page.nextCursor, !page.items.isEmpty else { break }
            cursor = next
        }
        return inserted
    }

    private func syncCreatorComments(ds: RemoteDataSource, context: AccountContext, state: SyncState,
                                     isFirstSync: Bool) async throws -> [String] {
        let pageLimit = isFirstSync ? 1 : Self.maxCommentPages
        // First import: every existing comment is history (read). Later: comments older than the previous successful
        // listing were simply not listed before (e.g. a post entered the first page) and are history too.
        let cutoff = state.lastSuccessfulSync ?? .distantFuture
        var cursor: String?
        var inserted: [String] = []
        for pageIndex in 0..<pageLimit {
            let page = try await ds.creatorComments(account: context, cursor: cursor)
            let before = inserted.count
            let flatCount = page.items.reduce(0) { $0 + $1.flattened.count }
            inserted += store.upsertCreatorComments(page.items, account: context, readCutoff: cutoff)
            if pageIndex == 0, let newest = page.items.first?.id { state.lastKnownItemID = newest }
            if inserted.count - before < flatCount { break }
            guard let next = page.nextCursor, !page.items.isEmpty else { break }
            cursor = next
        }
        return inserted
    }

    /// Own supporters list (bounded). Missing supporters are marked ended only after a complete listing that could be read
    /// entirely (an item dropped by decoding may be any of them).
    /// Returns the user ids newly observed as supporters.
    private func syncFans(ds: RemoteDataSource, context: AccountContext, state: SyncState) async throws -> [String] {
        var cursor: String?
        var seen: Set<String> = []
        var complete = false
        var problem: String?
        var newSupporters: [String] = []
        for _ in 0..<Self.maxFanPages {
            let listing = try await ds.fanListing(account: context, cursor: cursor)
            let page = listing.page
            problem = problem ?? listing.problem
            newSupporters += store.upsertFans(page.items, account: context)
            seen.formUnion(page.items.map(\.userID))
            guard let next = page.nextCursor, !page.items.isEmpty else { complete = true; break }
            cursor = next
        }
        if let problem {
            AppLog.sync.notice("fans: incomplete listing (\(problem, privacy: .public)); nobody is marked ended")
        } else if complete {
            store.markMissingFansEnded(presentUserIDs: seen, account: context, now: clock())
        }
        state.cursor = complete ? nil : cursor
        return newSupporters
    }

    private func syncPayments(ds: RemoteDataSource, context: AccountContext) async {
        let state = store.syncState(accountID: context.accountID, resource: .payments)
        state.lastAttemptAt = clock()
        do {
            let payments = try await ds.paidRecords(account: context)
            store.upsertPayments(payments, account: context)
            state.lastSuccessfulSync = clock()
            state.error = nil
            state.consecutiveFailures = 0
        } catch {
            let mapped = Self.map(error)
            if case .unsupported = mapped { state.error = nil } else { markFailure(state: state, error: mapped) }
        }
        store.save()
    }

    /// Unpaid-payment signals (docs/API.md §18.8 B): stored on the account and its supports, announced as 決済要確認 when
    /// the flag switches to unpaid or a creator is newly listed as unpaid. The first observation is a silent baseline.
    private func syncPaymentStatus(ds: RemoteDataSource, context: AccountContext, accountName: String) async -> [String] {
        let state = store.syncState(accountID: context.accountID, resource: .payments, scope: Self.paymentStatusScope)
        state.lastAttemptAt = clock()
        let status: RemotePaymentStatus?
        do {
            status = try await ds.paymentStatus(account: context)
        } catch {
            let mapped = Self.map(error)
            if case .unsupported = mapped { state.error = nil } else { markFailure(state: state, error: mapped) }
            return []
        }
        guard let status else { return [] }
        state.lastSuccessfulSync = clock()
        state.error = nil
        state.consecutiveFailures = 0
        let change = store.applyPaymentStatus(status, account: context, now: clock())
        guard !change.firstObservation else { return [] }
        var created: [String] = []
        if !change.newlyFlaggedCreatorIDs.isEmpty {
            created += store.recordPaymentAttentionEvents(.unpaidRecord, creatorIDs: change.newlyFlaggedCreatorIDs, account: context,
                                                          accountName: accountName, now: clock())
        } else if change.becameUnpaid {
            created += store.recordPaymentAttentionEvents(.unpaidFlag, creatorIDs: [], account: context, accountName: accountName, now: clock())
        }
        return created
    }

    private func applyCurrentUser(_ user: RemoteUser, accountID: String) {
        guard let account = store.account(id: accountID) else { return }
        // Never rebind an account to another pixiv user (SPEC §3.2).
        if let known = account.pixivUserID, known != user.pixivUserID { return }
        account.pixivUserID = user.pixivUserID
        account.fanboxUserID = user.fanboxUserID ?? account.fanboxUserID
        account.avatarURL = user.iconURL ?? account.avatarURL
        if let creatorID = user.creatorID { account.creatorID = creatorID }
        account.sessionState = .valid
        account.sessionCheckedAt = .now
        store.save()
    }

    // MARK: - Post detail with account fallback

    private func fetchPostDetail(postID: String, explicitAccountID: String?, operationKey: String) async -> RemoteError? {
        var ordered: [String]
        var candidateByID: [String: AccountCandidate] = [:]
        if let explicitAccountID {
            ordered = [explicitAccountID]
        } else {
            let candidates = AccountSelector.candidates(postID: postID, store: store).filter { $0.enabled && $0.hasSession }
            guard let best = AccountSelector.select(candidates) else { return .invalidRequest("アカウントがありません") }
            let others = candidates.filter { $0.accountID != best && $0.canView != false }.sorted(by: AccountSelector.isPreferred)
            ordered = [best] + others.map(\.accountID)
            for candidate in candidates { candidateByID[candidate.accountID] = candidate }
        }
        let interactive = RequestContext.priority >= .interactiveRead
        var lastError: RemoteError?
        var previousWasRestricted = false
        var attempted = false
        for (index, accountID) in ordered.enumerated() {
            // A turned-off account never sends requests (like `sync`), even when a screen still names it explicitly.
            guard let row = store.account(id: accountID), row.enabled, !removingAccountIDs.contains(accountID) else { continue }
            // A logged-out / identity-mismatched account has no credential (SPEC §3.2): post.info would go out as a guest and
            // its restricted answer would be stored as this account's viewing right. Not even when a screen names it.
            if !AccountSelector.hasSession(kind: row.kind, state: row.sessionState) {
                if explicitAccountID != nil { return .unauthorized }
                continue
            }
            if previousWasRestricted, let candidate = candidateByID[accountID], candidate.canView == nil {
                // docs/API.md §1.8: after a restricted answer, another post.info is only worth it for an account that may
                // be entitled — known viewable, or supporting the creator at the post's fee or above.
                let fee = store.post(id: postID)?.feeRequired ?? 0
                if fee > 0 && candidate.planFee < fee { continue }
            }
            let context = row.context
            postFetchAccounts[operationKey] = accountID
            defer { postFetchAccounts[operationKey] = nil }
            if !interactive, let until = postDetailBlockedUntil, until > clock() {
                // The detail endpoint was refused recently: automatic work makes no detail request. Metadata is fetched only
                // when nothing is stored yet (a notification normally brought the summary already).
                if store.post(id: postID) == nil { await refreshPostMetadata(postID: postID, context: context) }
                return .forbidden
            }
            attempted = true
            do {
                let detail = try await remote.dataSource(for: context).post(id: postID, account: context)
                // The account started being removed meanwhile: its answer is not stored (its rows are about to go).
                if removingAccountIDs.contains(accountID) { return .cancelled }
                store.upsertPostDetail(detail, account: context)
                postDetailBlockedUntil = nil
                if !detail.summary.isRestricted { return nil }
                lastError = nil     // restricted is a valid answer, not an error
                previousWasRestricted = true
            } catch {
                let mapped = handleFailure(error, accountID: accountID, operation: "post:\(postID)")
                // Cancelled (e.g. a background fetch the post screen took over): says nothing about this account's access.
                if mapped == .cancelled { return mapped }
                store.recordPostAccessError(postID: postID, accountID: accountID, message: mapped.userMessage)
                lastError = mapped
                if case .edgeBlocked = mapped {
                    // post.info blocked at the edge: refresh the summary through post.get (docs/API.md §6.2); the cached
                    // body stays. Other accounts are not tried (they would collect the same block), and automatic detail
                    // fetches pause for a while (repeated blocked calls risk the session, docs/API.md §1.7).
                    postDetailBlockedUntil = clock().addingTimeInterval(Self.postDetailBlockCooldown)
                    await refreshPostMetadata(postID: postID, context: context)
                    return mapped
                }
                switch mapped {
                case .unauthorized, .notFound:
                    // Session / visibility problems of this account: another account may still read the post.
                    break
                case .forbidden:
                    // FANBOX answers "not entitled" with a 200 + isRestricted; a 403 on the detail endpoint is most likely an
                    // edge block for native clients (docs/API.md §1.6 / §1.7). Every account would get the same answer and
                    // repeated blocked calls risk the session, so stop here and keep the summary current via post.get.
                    postDetailBlockedUntil = clock().addingTimeInterval(Self.postDetailBlockCooldown)
                    await refreshPostMetadata(postID: postID, context: context)
                    return mapped
                default:
                    return mapped
                }
            }
            if explicitAccountID != nil || index == ordered.count - 1 { break }
        }
        if !attempted { return .invalidRequest("利用できるアカウントがありません") }
        return lastError
    }

    /// post.get fallback (metadata only; the cached body is never touched). Best effort.
    private func refreshPostMetadata(postID: String, context: AccountContext) async {
        do {
            let summary = try await remote.dataSource(for: context).postMetadata(id: postID, account: context)
            store.upsertPostMetadata(summary, account: context)
        } catch {
            AppLog.sync.info("post metadata fallback unavailable: \(SyncEngine.map(error).userMessage, privacy: .public)")
        }
    }

    // MARK: - Account choice helpers

    /// postID → creatorID for posts that have no local row yet (comment bells carry the creator but not the post).
    @ObservationIgnored private var postCreatorHints: [String: String] = [:]

    /// Records the creator of a post that may not be stored locally (a comment notification on a post published on the
    /// web), so its comments are recognised as comments on my own post (Creator Mode 未読).
    func notePostCreator(postID: String, creatorID: String?) {
        guard let creatorID, !creatorID.isEmpty, store.post(id: postID) == nil else { return }
        postCreatorHints[postID] = creatorID
    }

    private func postCreatorID(_ postID: String) -> String? {
        store.post(id: postID)?.creatorID ?? postCreatorHints[postID]
    }

    /// Account for comment listings: the owner (creator account) if the post is mine, else one of `preferring` (e.g. the
    /// accounts that received a notification), else AccountSelector's choice. Shared by the post screen and the
    /// notification prefetch so both produce the same sync key (coalescing, SPEC §34).
    func commentAccount(postID: String, preferring: [String] = []) -> String? {
        let usable = automaticAccountIDs()
        if let post = store.post(id: postID), let owner = store.ownedCreatorAccountMap()[post.creatorID], usable.contains(owner) {
            return owner
        }
        if let hinted = preferring.first(where: { usable.contains($0) }) { return hinted }
        return AccountSelector.bestAccount(postID: postID, store: store) ?? store.mainAccount().flatMap { usable.contains($0.id) ? $0.id : nil }
    }

    /// Enabled accounts that may be chosen automatically: an account without a session (logged out / quarantined) would
    /// send a guest request whose answers must not be stored as its own (`AccountSelector.hasSession`).
    private func automaticAccountIDs() -> Set<String> {
        Set(store.accounts().filter { AccountSelector.hasSession(kind: $0.kind, state: $0.sessionState) }.map(\.id))
    }

    /// Read cutoff for comments on my own posts: comments at or before the owner's last creator-comment listing are
    /// history (imported as read); nil when the post is not mine.
    private func commentReadCutoff(postID: String) -> Date? {
        guard let creatorID = postCreatorID(postID), let owner = store.ownedCreatorAccountMap()[creatorID] else { return nil }
        let key = SyncState.key(accountID: owner, resource: .creatorComments)
        return store.first(#Predicate<SyncState> { $0.key == key })?.lastSuccessfulSync ?? .distantFuture
    }

    /// Account for creator pages: my own account if it owns the page, else the account with the highest active support,
    /// else a follower, else the main account. Accounts without a session (logged out / quarantined) are skipped.
    func bestAccount(creatorID: String) -> String? {
        let usable = automaticAccountIDs()
        if let owner = store.ownedCreatorAccountMap()[creatorID], usable.contains(owner) { return owner }
        let supports = store.supports(creatorID: creatorID).filter { $0.isActive && usable.contains($0.accountID) }
        if let best = supports.max(by: { $0.amount < $1.amount }) { return best.accountID }
        if let creator = store.creator(id: creatorID), let follower = creator.followedByAccountIDs.first(where: { usable.contains($0) }) {
            return follower
        }
        if let main = store.mainAccount(), usable.contains(main.id) { return main.id }
        return store.accounts().first { usable.contains($0.id) }?.id
    }

    // MARK: - Bookkeeping

    private func runForAllAccounts(reason: SyncReason, _ plan: (Account) -> [SyncResource]) async -> [SyncOutcome] {
        let jobs: [(String, [SyncResource])] = store.accounts().map { ($0.id, plan($0)) }
        guard !jobs.isEmpty else { return [] }
        return await withTaskGroup(of: [SyncOutcome].self) { group in
            // Accounts run concurrently; resources of one account run in order (notifications first).
            for (accountID, resources) in jobs {
                group.addTask { @MainActor [weak self] in
                    guard let self else { return [] }
                    var outcomes: [SyncOutcome] = []
                    for resource in resources {
                        // A more urgent caller that joined this batch raises the remaining requests (see `syncAll`).
                        let floor = max(RequestContext.priority, self.batchPriorityFloor ?? RequestContext.priority)
                        let outcome = await RequestContext.$priority.withValue(floor) {
                            await self.sync(resource, accountID: accountID, reason: reason)
                        }
                        outcomes.append(outcome)
                        if outcome.error == .unauthorized || outcome.error == .offline { break }
                    }
                    return outcomes
                }
            }
            var all: [SyncOutcome] = []
            for await chunk in group { all += chunk }
            return all
        }
    }

    private func finishBatch(_ outcomes: [SyncOutcome]) {
        let errors = outcomes.compactMap(\.error)
        lastError = errors.first
        if outcomes.contains(where: { $0.error == nil }) { lastSuccessAt = .now }
    }

    private func deliverable(_ created: [String], isFirstSync: Bool) -> [String] {
        // The very first sync of an account imports history silently (no flood of iOS notifications).
        guard !isFirstSync else { return [] }
        return created.filter { id in store.notificationEvent(id: id).map { !$0.isRead } ?? false }
    }

    /// Resources FANBOX serves without a login too (docs/API.md §5.4 / §8.2 / §9.1): their success says nothing about
    /// the session.
    static func provesSession(_ resource: SyncResource, scope: String) -> Bool {
        switch resource {
        case .plans, .comments, .creatorComments: return false   // the owner's comments are read from public post pages
        case .creatorPosts: return scope.isEmpty        // my own managed list needs the session; a creator page does not
        default: return true
        }
    }

    private func markSuccess(state: SyncState, accountID: String, provesSession: Bool = true) {
        let now = clock()
        state.lastSuccessfulSync = now
        state.error = nil
        state.consecutiveFailures = 0
        if let account = store.account(id: accountID) {
            account.lastSyncAt = now
            // A successful sync of an endpoint that needs the session proves it works. It never clears an identity
            // mismatch (`.error`) or a logout (`.loggedOut`): only a verified login / session check does.
            if provesSession, account.sessionState == .unknown || account.sessionState == .expired {
                account.sessionState = .valid
                account.sessionCheckedAt = now
            }
        }
        lastSuccessAt = now
        store.save()
    }

    private func markSubResourceSuccess(_ resource: SyncResource, accountID: String) {
        let state = store.syncState(accountID: accountID, resource: resource)
        state.lastAttemptAt = clock()
        state.lastSuccessfulSync = clock()
        state.error = nil
        state.consecutiveFailures = 0
    }

    private func markFailure(state: SyncState, error: RemoteError) {
        state.error = error.userMessage
        state.consecutiveFailures += 1
        store.save()
    }

    /// Maps any error to RemoteError, records it and expires the session on `.unauthorized`.
    @discardableResult
    private func handleFailure(_ error: Error, accountID: String, operation: String = "sync") -> RemoteError {
        let mapped = Self.map(error)
        if mapped != .cancelled {
            lastError = mapped
            onFailure?(operation, accountID, mapped)
        }
        // A logout or an identity mismatch is not an expiry: no re-login notice for an account the user logged out.
        if mapped == .unauthorized, let account = store.account(id: accountID),
           account.sessionState != .error, account.sessionState != .loggedOut {
            let wasExpired = account.sessionState == .expired
            account.sessionState = .expired
            account.sessionCheckedAt = .now
            store.save()
            // A turned-off account (its request was already running) is hidden everywhere, iOS notifications included.
            if !wasExpired && account.kind == .fanbox && account.enabled { onSessionExpired?(accountID) }
        }
        return mapped
    }

    static func map(_ error: Error) -> RemoteError {
        if let remote = error as? RemoteError { return remote }
        if error is CancellationError { return .cancelled }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: return .offline
            case .cancelled: return .cancelled
            case .userAuthenticationRequired: return .unauthorized
            default: return .network(code: url.code.rawValue, detail: url.code.rawValue.description)
            }
        }
        return .network(code: -1, detail: String(describing: type(of: error)))
    }

    private func beginActivity() {
        activeCount += 1
        if !isSyncing { isSyncing = true }
    }

    private func endActivity() {
        activeCount = max(0, activeCount - 1)
        if activeCount == 0 && isSyncing { isSyncing = false }
    }

    private func coalescedOperation(_ key: String, _ body: @escaping @MainActor () async -> RemoteError?) async -> RemoteError? {
        if let running = inFlightOps[key] { return await running.value }
        let task = Task { @MainActor [weak self] () -> RemoteError? in
            guard let self else { return .cancelled }
            self.beginActivity()
            let result = await body()
            self.inFlightOps[key] = nil
            self.endActivity()
            return result
        }
        inFlightOps[key] = task
        return await task.value
    }
}

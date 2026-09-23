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
    static let fansAutomaticInterval: TimeInterval = 6 * 60 * 60
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

    @discardableResult
    func sync(_ resource: SyncResource, accountID: String, scope: String = "", reason: SyncReason) async -> SyncOutcome {
        let key = Self.key(accountID: accountID, resource: resource, scope: scope)
        if let running = inFlight[key] { return await running.value }

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
                                     lastSuccess: store.existingSyncState(accountID: accountID, resource: resource, scope: scope)?.lastSuccessfulSync) {
            return .skipped(resource, accountID: accountID, scope: scope)
        }

        let context = account.context
        let priority = max(RequestContext.priority, Self.priority(for: resource, reason: reason))
        let task = Task { @MainActor [weak self] () -> SyncOutcome in
            guard let self else { return .skipped(resource, accountID: accountID, scope: scope) }
            self.beginActivity()
            let (outcome, deliver) = await RequestContext.$priority.withValue(priority) {
                await self.perform(resource, context: context, scope: scope, reason: reason)
            }
            self.inFlight[key] = nil
            self.endActivity()
            self.onSyncFinished?(outcome, reason)
            // Notification pipeline runs after the coalesced sync finished (no re-entrancy into this key).
            if !deliver.isEmpty, let callback = self.onNewNotificationEvents {
                await callback(deliver)
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
        let key = "post|\(accountID ?? "*")|\(postID)"
        if inFlightOps[key] == nil {
            // Another fetch of the same post is running with a different account choice (notification prefetch vs. the
            // post screen): wait for it instead of issuing a second GET, and only fetch again when it did not yield a body.
            let others = inFlightOps.filter { $0.key.hasPrefix("post|") && $0.key.hasSuffix("|\(postID)") }.map(\.value)
            if !others.isEmpty {
                var result: RemoteError?
                for other in others { result = await other.value }
                if result == nil, store.post(id: postID)?.hasCachedBody == true { return nil }
            }
        }
        return await coalescedOperation(key) { [weak self] in
            guard let self else { return .cancelled }
            return await RequestContext.$priority.withValue(max(priority, RequestContext.priority)) {
                await self.fetchPostDetail(postID: postID, explicitAccountID: accountID)
            }
        }
    }

    @discardableResult
    func refreshComments(postID: String, accountID: String? = nil, priority: RequestPriority = .interactiveRead) async -> RemoteError? {
        guard canReachNetwork else { return .offline }
        guard let account = accountID ?? commentAccount(postID: postID) else { return .invalidRequest("アカウントがありません") }
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
                self.markSuccess(state: state, accountID: account)
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
        let candidate = accountID ?? store.newsletter(id: id)?.accountIDs.first(where: { enabled.contains($0) }) ?? store.mainAccount()?.id
        guard let account = candidate, let row = store.account(id: account) else { return .invalidRequest("アカウントがありません") }
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
    static func skipsForSessionState(_ account: Account, reason: SyncReason) -> Bool {
        guard account.kind == .fanbox else { return false }
        switch account.sessionState {
        case .error:
            return true
        case .expired, .loggedOut:
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

    private func perform(_ resource: SyncResource, context: AccountContext, scope: String,
                         reason: SyncReason) async -> (SyncOutcome, [String]) {
        let accountID = context.accountID
        let state = store.syncState(accountID: accountID, resource: resource, scope: scope)
        let isFirstSync = state.lastSuccessfulSync == nil
        // Low-frequency resources answer from the local DB while their last refresh is recent enough (no request).
        if isThrottled(resource, state: state, reason: reason) {
            return (.skipped(resource, accountID: accountID, scope: scope), [])
        }
        state.lastAttemptAt = clock()
        let ds = remote.dataSource(for: context)
        var deliver: [String] = []
        do {
            var newIDs: [String] = []
            switch resource {
            case .session:
                let user = try await ds.currentUser(account: context)
                if context.kind == .fanbox, let known = store.account(id: accountID)?.pixivUserID, known != user.pixivUserID {
                    await onIdentityMismatch?(accountID, user.pixivUserID)
                    throw RemoteError.invalidRequest("このアカウントとは別の pixiv ユーザーのセッションでした")
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
                if listing.isComplete, store.hasActiveSupports(absentFrom: listing.supports, accountID: accountID),
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
                guard !scope.isEmpty else { throw RemoteError.invalidRequest("creatorID が必要です") }
                let plans = try await ds.creatorPlans(creatorID: scope, account: context)
                store.upsertPlans(plans, creatorID: scope)

            case .notifications:
                var created: [String] = []
                let probe = try await probeUnreadNotifications(ds: ds, context: context, state: state, reason: reason)
                if !probe.unchanged {
                    let batch = try await ds.notificationBatch(account: context, cursor: nil)
                    // Posts embedded in new-post notifications: the title / excerpt / cover are local before any tap.
                    if !batch.posts.isEmpty { store.upsertPostSummaries(batch.posts, account: context, source: .notification) }
                    created = store.upsertNotifications(batch.page.items, account: context)
                    state.lastKnownItemID = batch.page.items.first?.remoteID ?? state.lastKnownItemID
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
                guard !scope.isEmpty else { throw RemoteError.invalidRequest("postID が必要です") }
                newIDs = try await syncComments(postID: scope, ds: ds, context: context, state: state)

            case .creatorDashboard:
                let dashboard = try await ds.creatorDashboard(account: context)
                store.upsertDashboard(dashboard, account: context)

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
            markSuccess(state: state, accountID: accountID)
            return (SyncOutcome(resource: resource, accountID: accountID, scope: scope, newItemIDs: newIDs, error: nil), deliver)
        } catch {
            let mapped = handleFailure(error, accountID: accountID, operation: scope.isEmpty ? resource.rawValue : "\(resource.rawValue):\(scope)")
            markFailure(state: state, error: mapped)
            AppLog.sync.error("sync \(resource.rawValue, privacy: .public) failed: \(mapped.userMessage, privacy: .public)")
            return (SyncOutcome(resource: resource, accountID: accountID, scope: scope, newItemIDs: [], error: mapped), deliver)
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
    private func syncFeed(_ resource: SyncResource, ds: RemoteDataSource, context: AccountContext, state: SyncState,
                          isFirstSync: Bool, reason: SyncReason) async throws -> [String] {
        let pageLimit = (isFirstSync || Self.isLightweight(reason)) ? 1 : Self.maxFeedPages
        let source: TimelineSource = resource == .timeline ? .home : .supporting
        var cursor: String?
        var inserted: [String] = []
        var newest: String?
        for pageIndex in 0..<pageLimit {
            let page = resource == .timeline
                ? try await ds.homeTimeline(account: context, cursor: cursor)
                : try await ds.supportingTimeline(account: context, cursor: cursor)
            let ids = page.items.map(\.id)
            if pageIndex == 0 { newest = ids.first }
            let knownBefore = knownPostIDs(ids, accountID: context.accountID)
            let result = store.upsertPostSummaries(page.items, account: context, source: source)
            inserted += result.insertedIDs
            let reachedKnown = !knownBefore.isEmpty || (state.lastKnownItemID.map { ids.contains($0) } ?? false)
            if reachedKnown { break }
            guard let next = page.nextCursor, !page.items.isEmpty else { break }
            cursor = next
        }
        if let newest { state.lastKnownItemID = newest }
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
        // Keep an older-page cursor from earlier "load more" requests; only seed it when none exists yet.
        if state.cursor == nil { state.cursor = page.nextCursor ?? Self.endOfListCursor }
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
        for pageIndex in 0..<Self.maxCommentPages {
            let page = try await ds.comments(postID: postID, account: context, cursor: cursor)
            let before = inserted.count
            let flatCount = page.items.reduce(0) { $0 + $1.flattened.count }
            inserted += store.upsertCommentsReturningNew(page.items, postID: postID, account: context, readCutoff: cutoff)
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

    /// Own supporters list (bounded). Missing supporters are marked ended only after a complete listing.
    /// Returns the user ids newly observed as supporters.
    private func syncFans(ds: RemoteDataSource, context: AccountContext, state: SyncState) async throws -> [String] {
        var cursor: String?
        var seen: Set<String> = []
        var complete = false
        var newSupporters: [String] = []
        for _ in 0..<Self.maxFanPages {
            let page = try await ds.fans(account: context, cursor: cursor)
            newSupporters += store.upsertFans(page.items, account: context)
            seen.formUnion(page.items.map(\.userID))
            guard let next = page.nextCursor, !page.items.isEmpty else { complete = true; break }
            cursor = next
        }
        if complete { store.markMissingFansEnded(presentUserIDs: seen, account: context) }
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

    private func fetchPostDetail(postID: String, explicitAccountID: String?) async -> RemoteError? {
        var ordered: [String]
        var candidateByID: [String: AccountCandidate] = [:]
        if let explicitAccountID {
            ordered = [explicitAccountID]
        } else {
            let candidates = AccountSelector.candidates(postID: postID, store: store).filter(\.enabled)
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
            guard let row = store.account(id: accountID) else { continue }
            // An identity-mismatched account has no usable session (SPEC §3.2): never pick it automatically.
            if explicitAccountID == nil && row.kind == .fanbox && row.sessionState == .error { continue }
            if previousWasRestricted, let candidate = candidateByID[accountID], candidate.canView == nil {
                // docs/API.md §1.8: after a restricted answer, another post.info is only worth it for an account that may
                // be entitled — known viewable, or supporting the creator at the post's fee or above.
                let fee = store.post(id: postID)?.feeRequired ?? 0
                if fee > 0 && candidate.planFee < fee { continue }
            }
            let context = row.context
            if !interactive, let until = postDetailBlockedUntil, until > clock() {
                // The detail endpoint was refused recently: automatic work makes no detail request. Metadata is fetched only
                // when nothing is stored yet (a notification normally brought the summary already).
                if store.post(id: postID) == nil { await refreshPostMetadata(postID: postID, context: context) }
                return .forbidden
            }
            attempted = true
            do {
                let detail = try await remote.dataSource(for: context).post(id: postID, account: context)
                store.upsertPostDetail(detail, account: context)
                postDetailBlockedUntil = nil
                if !detail.summary.isRestricted { return nil }
                lastError = nil     // restricted is a valid answer, not an error
                previousWasRestricted = true
            } catch {
                let mapped = handleFailure(error, accountID: accountID, operation: "post:\(postID)")
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

    /// Account for comment listings: the owner (creator account) if the post is mine, else one of `preferring` (e.g. the
    /// accounts that received a notification), else AccountSelector's choice. Shared by the post screen and the
    /// notification prefetch so both produce the same sync key (coalescing, SPEC §34).
    func commentAccount(postID: String, preferring: [String] = []) -> String? {
        let enabled = Set(store.accounts().map(\.id))
        if let post = store.post(id: postID), let owner = store.ownedCreatorAccountMap()[post.creatorID], enabled.contains(owner) {
            return owner
        }
        if let hinted = preferring.first(where: { enabled.contains($0) }) { return hinted }
        return AccountSelector.bestAccount(postID: postID, store: store) ?? store.mainAccount()?.id
    }

    /// Read cutoff for comments on my own posts: comments at or before the owner's last creator-comment listing are
    /// history (imported as read); nil when the post is not mine.
    private func commentReadCutoff(postID: String) -> Date? {
        guard let post = store.post(id: postID), let owner = store.ownedCreatorAccountMap()[post.creatorID] else { return nil }
        let key = SyncState.key(accountID: owner, resource: .creatorComments)
        return store.first(#Predicate<SyncState> { $0.key == key })?.lastSuccessfulSync ?? .distantFuture
    }

    /// Account for creator pages: my own account if it owns the page, else the account with the highest active support,
    /// else a follower, else the main account.
    func bestAccount(creatorID: String) -> String? {
        let accounts = store.accounts()
        let enabled = Set(accounts.map(\.id))
        if let owner = store.ownedCreatorAccountMap()[creatorID], enabled.contains(owner) { return owner }
        let supports = store.supports(creatorID: creatorID).filter { $0.isActive && enabled.contains($0.accountID) }
        if let best = supports.max(by: { $0.amount < $1.amount }) { return best.accountID }
        if let creator = store.creator(id: creatorID), let follower = creator.followedByAccountIDs.first(where: { enabled.contains($0) }) {
            return follower
        }
        return store.mainAccount()?.id
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

    private func markSuccess(state: SyncState, accountID: String) {
        let now = clock()
        state.lastSuccessfulSync = now
        state.error = nil
        state.consecutiveFailures = 0
        if let account = store.account(id: accountID) {
            account.lastSyncAt = now
            // A successful sync proves the session works, but never clears an identity mismatch (`.error`): only a
            // verified re-login / session check does.
            if account.sessionState != .valid && account.sessionState != .error {
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
        if mapped == .unauthorized, let account = store.account(id: accountID), account.sessionState != .error {
            let wasExpired = account.sessionState == .expired
            account.sessionState = .expired
            account.sessionCheckedAt = .now
            store.save()
            if !wasExpired && account.kind == .fanbox { onSessionExpired?(accountID) }
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

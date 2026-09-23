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

    /// Hard cap for differential feed paging (SPEC §3.7: never crawl history).
    static let maxFeedPages = 3
    /// Own-data listings (fans) may page further, but still bounded.
    static let maxFanPages = 20
    static let maxCommentPages = 3

    @ObservationIgnored private var inFlight: [String: Task<SyncOutcome, Never>] = [:]
    @ObservationIgnored private var inFlightOps: [String: Task<RemoteError?, Never>] = [:]
    @ObservationIgnored private var syncAllTask: Task<Void, Never>?
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
        guard canReachNetwork else {
            // Offline: return immediately; local data stays exactly as it is.
            return .failed(resource, accountID: accountID, scope: scope, error: .offline)
        }
        if Self.requiresCreatorAccount(resource, scope: scope), account.creatorID == nil {
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
        if let running = syncAllTask { await running.value; return }
        guard canReachNetwork else {
            lastError = .offline
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcomes = await self.runForAllAccounts(reason: reason) { account in
                var plan: [SyncResource] = [.notifications, .supports, .timeline, .supportingTimeline, .creators]
                if account.creatorID != nil { plan += [.creatorDashboard, .creatorComments, .fans] }
                return plan
            }
            self.finishBatch(outcomes)
            self.syncAllTask = nil
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
        let outcomes = await runForAllAccounts(reason: reason) { _ in [.notifications, .supports, .timeline] }
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
            state.lastAttemptAt = .now
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
        state.lastAttemptAt = .now
        let ds = remote.dataSource(for: context)
        var deliver: [String] = []
        do {
            var newIDs: [String] = []
            switch resource {
            case .session:
                let user = try await ds.currentUser(account: context)
                applyCurrentUser(user, accountID: accountID)

            case .timeline, .supportingTimeline:
                newIDs = try await syncFeed(resource, ds: ds, context: context, state: state, isFirstSync: isFirstSync, reason: reason)

            case .creators:
                let creators = try await ds.followingCreators(account: context)
                store.applyFollowing(creators, account: context)

            case .supports:
                let supports = try await ds.supportingPlans(account: context)
                let observed: ObservedSource = context.kind == .demo ? .demo
                    : (reason == .backgroundRefresh ? .backgroundSync : (reason == .notification ? .notification : .sync))
                let (diff, history) = store.applySupportsDetailed(supports, account: context, source: observed)
                newIDs = diff.started + diff.changed + diff.restored + diff.disappeared
                if !isFirstSync, !history.isEmpty {
                    let name = store.account(id: accountID)?.displayName ?? ""
                    deliver += store.recordSupportChangeEvents(history, account: context, accountName: name)
                }
                // Paid records are best effort: their failure never marks the supports sync as failed.
                await syncPayments(ds: ds, context: context)

            case .plans:
                guard !scope.isEmpty else { throw RemoteError.invalidRequest("creatorID が必要です") }
                let plans = try await ds.creatorPlans(creatorID: scope, account: context)
                store.upsertPlans(plans, creatorID: scope)

            case .notifications:
                let page = try await ds.notifications(account: context, cursor: nil)
                var created = store.upsertNotifications(page.items, account: context)
                state.lastKnownItemID = page.items.first?.remoteID ?? state.lastKnownItemID
                // おたより are part of notification detection; failures here don't fail notifications.
                if let letters = try? await ds.newsletters(account: context) {
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
                try await syncFans(ds: ds, context: context, state: state)

            case .payments:
                let payments = try await ds.paidRecords(account: context)
                store.upsertPayments(payments, account: context)
            }
            markSuccess(state: state, accountID: accountID)
            return (SyncOutcome(resource: resource, accountID: accountID, scope: scope, newItemIDs: newIDs, error: nil), deliver)
        } catch {
            let mapped = handleFailure(error, accountID: accountID)
            markFailure(state: state, error: mapped)
            AppLog.sync.error("sync \(resource.rawValue, privacy: .public) failed: \(mapped.userMessage, privacy: .public)")
            return (SyncOutcome(resource: resource, accountID: accountID, scope: scope, newItemIDs: [], error: mapped), deliver)
        }
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
        for pageIndex in 0..<pageLimit {
            let page = try await ds.managedPosts(account: context, cursor: cursor)
            let known = store.knownPostIDs(page.items.map(\.id))
            inserted += store.upsertManagedPosts(page.items, account: context).insertedIDs
            if pageIndex == 0, let newest = page.items.first?.id { state.lastKnownItemID = newest }
            if !known.isEmpty { break }
            guard let next = page.nextCursor, !page.items.isEmpty else { break }
            cursor = next
        }
        return inserted
    }

    private func syncComments(postID: String, ds: RemoteDataSource, context: AccountContext, state: SyncState) async throws -> [String] {
        var cursor: String?
        var inserted: [String] = []
        for pageIndex in 0..<Self.maxCommentPages {
            let page = try await ds.comments(postID: postID, account: context, cursor: cursor)
            let before = inserted.count
            let flatCount = page.items.reduce(0) { $0 + $1.flattened.count }
            inserted += store.upsertCommentsReturningNew(page.items, postID: postID, account: context)
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
        var cursor: String?
        var inserted: [String] = []
        for pageIndex in 0..<pageLimit {
            let page = try await ds.creatorComments(account: context, cursor: cursor)
            let before = inserted.count
            let flatCount = page.items.reduce(0) { $0 + $1.flattened.count }
            inserted += store.upsertCreatorComments(page.items, account: context)
            if pageIndex == 0, let newest = page.items.first?.id { state.lastKnownItemID = newest }
            if inserted.count - before < flatCount { break }
            guard let next = page.nextCursor, !page.items.isEmpty else { break }
            cursor = next
        }
        return inserted
    }

    /// Own supporters list (bounded). Missing supporters are marked ended only after a complete listing.
    private func syncFans(ds: RemoteDataSource, context: AccountContext, state: SyncState) async throws {
        var cursor: String?
        var seen: Set<String> = []
        var complete = false
        for _ in 0..<Self.maxFanPages {
            let page = try await ds.fans(account: context, cursor: cursor)
            store.upsertFans(page.items, account: context)
            seen.formUnion(page.items.map(\.userID))
            guard let next = page.nextCursor, !page.items.isEmpty else { complete = true; break }
            cursor = next
        }
        if complete { store.markMissingFansEnded(presentUserIDs: seen, account: context) }
        state.cursor = complete ? nil : cursor
    }

    private func syncPayments(ds: RemoteDataSource, context: AccountContext) async {
        let state = store.syncState(accountID: context.accountID, resource: .payments)
        state.lastAttemptAt = .now
        do {
            let payments = try await ds.paidRecords(account: context)
            store.upsertPayments(payments, account: context)
            state.lastSuccessfulSync = .now
            state.error = nil
            state.consecutiveFailures = 0
        } catch {
            let mapped = Self.map(error)
            if case .unsupported = mapped { state.error = nil } else { markFailure(state: state, error: mapped) }
        }
        store.save()
    }

    private func applyCurrentUser(_ user: RemoteUser, accountID: String) {
        guard let account = store.account(id: accountID) else { return }
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
        if let explicitAccountID {
            ordered = [explicitAccountID]
        } else {
            let candidates = AccountSelector.candidates(postID: postID, store: store).filter(\.enabled)
            guard let best = AccountSelector.select(candidates) else { return .invalidRequest("アカウントがありません") }
            let others = candidates.filter { $0.accountID != best && $0.canView != false }.sorted(by: AccountSelector.isPreferred)
            ordered = [best] + others.map(\.accountID)
        }
        var lastError: RemoteError?
        for (index, accountID) in ordered.enumerated() {
            guard let row = store.account(id: accountID) else { continue }
            let context = row.context
            do {
                let detail = try await remote.dataSource(for: context).post(id: postID, account: context)
                store.upsertPostDetail(detail, account: context)
                if !detail.summary.isRestricted { return nil }
                lastError = nil     // restricted is a valid answer, not an error
            } catch {
                let mapped = handleFailure(error, accountID: accountID)
                store.recordPostAccessError(postID: postID, accountID: accountID, message: mapped.userMessage)
                lastError = mapped
                // Only session / permission problems make another account worth trying; network errors would repeat.
                let tryNext: Bool
                switch mapped {
                case .unauthorized, .forbidden, .notFound: tryNext = true
                default: tryNext = false
                }
                if !tryNext { return mapped }
            }
            if explicitAccountID != nil || index == ordered.count - 1 { break }
        }
        return lastError
    }

    // MARK: - Account choice helpers

    /// Account for comment listings: the owner (creator account) if the post is mine, else AccountSelector's choice.
    private func commentAccount(postID: String) -> String? {
        if let post = store.post(id: postID), let owner = store.ownedCreatorAccountMap()[post.creatorID],
           store.account(id: owner)?.enabled == true {
            return owner
        }
        return AccountSelector.bestAccount(postID: postID, store: store) ?? store.mainAccount()?.id
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
                        let outcome = await self.sync(resource, accountID: accountID, reason: reason)
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
        let now = Date.now
        state.lastSuccessfulSync = now
        state.error = nil
        state.consecutiveFailures = 0
        if let account = store.account(id: accountID) {
            account.lastSyncAt = now
            if account.sessionState != .valid {
                account.sessionState = .valid
                account.sessionCheckedAt = now
            }
        }
        lastSuccessAt = now
        store.save()
    }

    private func markSubResourceSuccess(_ resource: SyncResource, accountID: String) {
        let state = store.syncState(accountID: accountID, resource: resource)
        state.lastAttemptAt = .now
        state.lastSuccessfulSync = .now
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
    private func handleFailure(_ error: Error, accountID: String) -> RemoteError {
        let mapped = Self.map(error)
        if mapped != .cancelled { lastError = mapped }
        if mapped == .unauthorized, let account = store.account(id: accountID) {
            account.sessionState = .expired
            account.sessionCheckedAt = .now
            store.save()
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

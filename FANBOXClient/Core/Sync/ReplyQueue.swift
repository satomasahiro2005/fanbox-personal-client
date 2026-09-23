import Foundation
import Observation
import SwiftData

/// Offline-capable comment / reply queue (SPEC §22):
/// draft → queued (persisted locally) → sending → sent | failed | needsConfirmation.
/// - Sending uses `RequestPriority.interactiveWrite` (beats all media).
/// - Short disconnections are retried automatically, but never blindly: post.addComment has no idempotency key, so
///   before any re-send the thread is re-read and an own comment with the same text is taken as the earlier send
///   (docs/API.md §9.2). When that check is impossible the item waits for the user (`needsConfirmation`).
/// - Items older than `settings.staleReplyThreshold` go to `needsConfirmation` unless `autoSendStaleReplies`.
/// - Items that need the user are reported through `onAttentionNeeded` (local notification for notification replies)
///   and counted in `attentionCount` (app-level banner / 送信キュー screen).
@MainActor
@Observable
final class ReplyQueue {
    /// Items not yet sent that the user expects to go out: queued + sending + needsConfirmation + failed.
    private(set) var pendingCount = 0
    /// Items needing a user decision (needsConfirmation + failed).
    private(set) var attentionCount = 0
    private(set) var isFlushing = false

    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let remote: RemoteDataSourceProvider
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let network: NetworkModeController
    /// Called with the item id when an item moves to `.failed` / `.needsConfirmation` (wired to NotificationService).
    @ObservationIgnored var onAttentionNeeded: ((String) async -> Void)?

    /// Automatic attempts for transient failures before an item needs the user.
    static let maxAttempts = 5
    /// Backoff for automatic retries: base * 2^(attempt-1), capped.
    static let retryBaseDelay: TimeInterval = 2
    static let retryMaxDelay: TimeInterval = 60
    static let interruptedSendMessage = "送信中に中断されました。送信済みか確認してください"
    static let unconfirmedSendMessage = "送信結果を確認できませんでした。送信済みか確認してください"
    /// Comment pages read to look for an earlier send before re-sending.
    static let verificationPages = 3
    /// Tolerance for clock differences when matching an earlier send by its FANBOX timestamp.
    static let verificationClockSkew: TimeInterval = 10 * 60

    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var nextAttemptAt: [String: Date] = [:]
    @ObservationIgnored private var retryTimer: Task<Void, Never>?

    init(store: LocalStore, remote: RemoteDataSourceProvider, settings: AppSettings, network: NetworkModeController) {
        self.store = store
        self.remote = remote
        self.settings = settings
        self.network = network
        recoverInterruptedSends()
        refreshCounts()
    }

    // MARK: - Queue operations

    /// Queues a comment / reply and tries to send immediately. Returns the OutgoingComment id.
    @discardableResult
    func submit(postID: String, body: String, parentCommentID: String? = nil, rootCommentID: String? = nil, accountID: String,
                origin: ReplyOrigin = .inApp) -> String {
        let item = OutgoingComment(accountID: accountID, postID: postID, parentCommentID: parentCommentID, rootCommentID: rootCommentID,
                                   body: body.trimmingCharacters(in: .whitespacesAndNewlines), state: .queued, origin: origin)
        item.queuedAt = .now
        store.context.insert(item)
        store.save()        // persisted before any network attempt (works fully offline)
        refreshCounts()
        Task { [weak self] in await self?.flush() }
        return item.id
    }

    /// Saves an unsent draft (state .draft) without sending. Returns the id.
    @discardableResult
    func saveDraft(postID: String, body: String, parentCommentID: String? = nil, rootCommentID: String? = nil,
                   accountID: String) -> String {
        let item = OutgoingComment(accountID: accountID, postID: postID, parentCommentID: parentCommentID, rootCommentID: rootCommentID,
                                   body: body, state: .draft, origin: .inApp)
        store.context.insert(item)
        store.save()
        return item.id
    }

    /// Updates the text of a draft.
    func updateDraft(id: String, body: String) {
        guard let item = item(id: id), item.state == .draft else { return }
        item.body = body
        store.save()
    }

    /// Moves a draft into the queue and tries to send it.
    func submitDraft(id: String) async {
        guard let item = item(id: id), item.state == .draft else { return }
        item.body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        item.state = .queued
        item.queuedAt = .now
        store.save()
        refreshCounts()
        await flush()
    }

    /// Sends every queued item that is allowed to go now. Concurrent calls share one run.
    func flush() async {
        if let running = flushTask {
            rerunRequested = true
            await running.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isFlushing = true
            repeat {
                self.rerunRequested = false
                await self.flushOnce()
            } while self.rerunRequested
            self.isFlushing = false
            self.flushTask = nil
        }
        flushTask = task
        await task.value
    }

    /// Explicit user retry. An earlier attempt is still looked up first, so a retry never duplicates a comment that did
    /// reach FANBOX; if the lookup is impossible the user's decision wins and the reply is sent.
    func retry(id: String) async {
        guard let item = item(id: id) else { return }
        switch item.state {
        case .failed, .queued, .needsConfirmation:
            item.state = .queued
            item.attemptCount = 0
            item.queuedAt = .now            // explicit user action restarts the staleness clock
            nextAttemptAt[id] = nil
            store.save()
            refreshCounts()
            guard canSend else { return }
            await send(item, userConfirmed: true)
        default:
            return
        }
    }

    /// User confirmed a `needsConfirmation` item.
    func confirmAndSend(id: String) async {
        guard let item = item(id: id), item.state == .needsConfirmation else { return }
        item.state = .queued
        item.queuedAt = .now
        nextAttemptAt[id] = nil
        store.save()
        refreshCounts()
        guard canSend else { return }
        await send(item, userConfirmed: true)
    }

    /// Deletes a draft / queued / failed / needsConfirmation item. Sending or sent items are kept.
    func cancel(id: String) {
        guard let item = item(id: id) else { return }
        switch item.state {
        case .draft, .queued, .failed, .needsConfirmation:
            nextAttemptAt[id] = nil
            store.context.delete(item)
            store.save()
            refreshCounts()
        case .sending, .sent:
            return
        }
    }

    /// Connectivity came back.
    func handleConnectivityRestored() {
        nextAttemptAt.removeAll()
        Task { [weak self] in await self?.flush() }
    }

    // MARK: - Queries

    func item(id: String) -> OutgoingComment? {
        store.first(#Predicate<OutgoingComment> { $0.id == id })
    }

    /// Unsent items (all states except sent) for a post, oldest first.
    func unsentItems(postID: String) -> [OutgoingComment] {
        let sent = ReplyState.sent.rawValue
        return store.fetch(FetchDescriptor<OutgoingComment>(
            predicate: #Predicate { $0.postID == postID && $0.stateRaw != sent },
            sortBy: [SortDescriptor(\.createdAt)]))
    }

    /// Items that need a user decision (needsConfirmation + failed), oldest first.
    func attentionItems() -> [OutgoingComment] { items(in: [.needsConfirmation, .failed]) }

    func items(in states: Set<ReplyState>) -> [OutgoingComment] {
        let raws = states.map(\.rawValue)
        return store.fetch(FetchDescriptor<OutgoingComment>(predicate: #Predicate { raws.contains($0.stateRaw) },
                                                           sortBy: [SortDescriptor(\.createdAt)]))
    }

    // MARK: - Sending

    private var canSend: Bool { MediaPolicy.allowsText(policy: network.policy) }

    private func flushOnce() async {
        guard canSend else { return }       // offline: everything stays queued locally
        let queued = ReplyState.queued.rawValue
        let items = store.fetch(FetchDescriptor<OutgoingComment>(predicate: #Predicate { $0.stateRaw == queued }))
            .sorted { ($0.queuedAt ?? $0.createdAt) < ($1.queuedAt ?? $1.createdAt) }
        let now = Date.now
        for item in items {
            guard item.state == .queued else { continue }        // cancelled / confirmed meanwhile
            if let next = nextAttemptAt[item.id], next > now { continue }
            let age = now.timeIntervalSince(item.queuedAt ?? item.createdAt)
            if age > settings.staleReplyThreshold && !settings.autoSendStaleReplies {
                // Long-waiting replies are not sent silently (SPEC §22 default).
                item.state = .needsConfirmation
                store.save()
                refreshCounts()
                await notifyAttention(item)
                continue
            }
            await send(item)
            guard canSend else { break }
        }
        refreshCounts()
    }

    private enum EarlierSend {
        /// The earlier attempt did reach FANBOX.
        case found(RemoteComment)
        /// The thread was read far enough: no earlier copy exists, sending is safe.
        case notFound
        /// Could not tell (lookup failed or the thread was not reached).
        case inconclusive(RemoteError?)
    }

    private func send(_ item: OutgoingComment, userConfirmed: Bool = false) async {
        guard let account = store.account(id: item.accountID) else {
            item.state = .failed
            item.lastError = "アカウントが見つかりません"
            store.save()
            refreshCounts()
            await notifyAttention(item)
            return
        }
        let context = account.context
        resolveRootIfNeeded(item)
        let postID = item.postID, body = item.body, parent = item.parentCommentID, root = item.rootCommentID
        guard !body.isEmpty else {
            item.state = .failed
            item.lastError = "本文が空です"
            store.save()
            refreshCounts()
            await notifyAttention(item)
            return
        }
        let dataSource = remote.dataSource(for: context)

        // Duplicate guard (docs/API.md §9.2): a previous attempt may have reached FANBOX although its response was lost.
        if item.lastAttemptAt != nil {
            item.state = .sending
            store.save()
            refreshCounts()
            switch await findEarlierSend(item, parent: parent, root: root, context: context, dataSource: dataSource) {
            case .found(let comment):
                markSent(item, comment: comment, context: context, dataSource: dataSource)
                store.save()
                refreshCounts()
                return
            case .notFound:
                break
            case .inconclusive(let error):
                if error == .offline {
                    item.state = .queued        // checked again once connectivity is back
                    store.save()
                    refreshCounts()
                    return
                }
                if !userConfirmed {
                    item.state = .needsConfirmation
                    item.lastError = Self.unconfirmedSendMessage
                    nextAttemptAt[item.id] = nil
                    store.save()
                    refreshCounts()
                    await notifyAttention(item)
                    return
                }
            }
        }

        item.state = .sending
        item.attemptCount += 1
        item.lastAttemptAt = .now
        store.save()
        refreshCounts()

        do {
            let comment = try await RequestContext.$priority.withValue(.interactiveWrite) {
                try await dataSource.addComment(postID: postID, body: body, parentCommentID: parent, rootCommentID: root, account: context)
            }
            markSent(item, comment: comment, context: context, dataSource: dataSource)
        } catch {
            let mapped = SyncEngine.map(error)
            item.lastError = mapped.userMessage
            if mapped == .unauthorized {
                account.sessionState = .expired
                account.sessionCheckedAt = .now
            }
            if mapped == .offline {
                // Lost connectivity: not the reply's fault; keep it queued without consuming attempts. The request may
                // still have reached FANBOX, so the next attempt looks for it first.
                item.state = .queued
                item.attemptCount = max(0, item.attemptCount - 1)
            } else if mapped.isTransient && item.attemptCount < Self.maxAttempts {
                item.state = .queued
                scheduleRetry(for: item)
            } else if Self.mayHaveReachedServer(mapped) {
                // Out of automatic attempts after errors that do not prove the comment was rejected.
                item.state = .needsConfirmation
                item.lastError = "\(Self.unconfirmedSendMessage)（\(mapped.userMessage)）"
                nextAttemptAt[item.id] = nil
            } else {
                item.state = .failed
                nextAttemptAt[item.id] = nil
            }
            AppLog.sync.error("reply send failed: \(mapped.userMessage, privacy: .public)")
        }
        store.save()
        refreshCounts()
        if item.state == .failed || item.state == .needsConfirmation { await notifyAttention(item) }
    }

    /// Errors after which the comment may exist on FANBOX (timeouts, lost connections, gateway / server errors).
    /// 4xx answers (including 429) mean the request was refused.
    static func mayHaveReachedServer(_ error: RemoteError) -> Bool {
        switch error {
        case .offline, .network, .cancelled: return true
        case .server(let status): return status >= 500
        default: return false
        }
    }

    private func markSent(_ item: OutgoingComment, comment: RemoteComment, context: AccountContext, dataSource: RemoteDataSource) {
        item.state = .sent
        item.sentAt = .now
        item.lastError = nil
        nextAttemptAt[item.id] = nil
        if LocalStore.isProvisionalCommentID(comment.id) {
            // Sent, but FANBOX did not tell us the id: keep the queue row visible (送信済) and reconcile with the real
            // comment from a thread refresh instead of storing a fake Comment row (no double display, no invalid delete).
            item.sentCommentID = nil
            let postID = item.postID
            Task { [weak self] in await self?.refreshThread(postID: postID, context: context, dataSource: dataSource) }
            return
        }
        item.sentCommentID = comment.id
        var local = comment
        if local.postID.isEmpty { local.postID = item.postID }
        if local.parentCommentID == nil { local.parentCommentID = item.parentCommentID }
        if local.rootCommentID == nil { local.rootCommentID = item.rootCommentID }
        store.upsertOwnComment(local, account: context)
    }

    /// Re-reads the first comment page so a provisional send is matched to its real comment (see `LocalStore`).
    private func refreshThread(postID: String, context: AccountContext, dataSource: RemoteDataSource) async {
        guard canSend else { return }
        do {
            let page = try await RequestContext.$priority.withValue(.interactiveRead) {
                try await dataSource.comments(postID: postID, account: context, cursor: nil)
            }
            store.upsertCommentsReturningNew(page.items, postID: postID, account: context)
        } catch {
            AppLog.sync.info("thread refresh after send failed: \(SyncEngine.map(error).userMessage, privacy: .public)")
        }
    }

    /// Looks for an own comment with the same text and parent created since the item was written.
    private func findEarlierSend(_ item: OutgoingComment, parent: String?, root: String?, context: AccountContext,
                                 dataSource: RemoteDataSource) async -> EarlierSend {
        let postID = item.postID
        let notBefore = item.createdAt.addingTimeInterval(-Self.verificationClockSkew)
        let sent = ReplyState.sent.rawValue
        let itemID = item.id
        let claimed = Set(store.fetch(FetchDescriptor<OutgoingComment>(
            predicate: #Predicate { $0.postID == postID && $0.stateRaw == sent && $0.id != itemID })).compactMap(\.sentCommentID))
        var cursor: String?
        do {
            for _ in 0..<Self.verificationPages {
                let page = try await RequestContext.$priority.withValue(.interactiveWrite) {
                    try await dataSource.comments(postID: postID, account: context, cursor: cursor)
                }
                let flat = Self.flattenFillingParents(page.items)
                if let match = Self.findPostedComment(in: flat.filter { !claimed.contains($0.id) }, body: item.body,
                                                      parentCommentID: parent, notBefore: notBefore, ownUserID: context.pixivUserID) {
                    return .found(match)
                }
                // Covered: the whole list was read, the target thread was read, or (root comments, newest-first
                // listing) the page already reaches roots older than the item.
                guard let next = page.nextCursor, !page.items.isEmpty else { return .notFound }
                if let thread = root ?? parent {
                    if flat.contains(where: { $0.id == thread || $0.id == parent }) { return .notFound }
                } else if page.items.contains(where: { $0.createdAt < notBefore }) {
                    return .notFound
                }
                cursor = next
            }
            return .inconclusive(nil)
        } catch {
            return .inconclusive(SyncEngine.map(error))
        }
    }

    /// Own comment with the same (trimmed) text and parent, created at or after `notBefore`; newest wins.
    static func findPostedComment(in comments: [RemoteComment], body: String, parentCommentID: String?, notBefore: Date,
                                  ownUserID: String?) -> RemoteComment? {
        let normalized = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return comments
            .filter { $0.isOwn || (ownUserID.map { !$0.isEmpty } == true && $0.authorUserID == ownUserID) }
            .filter { $0.body.trimmingCharacters(in: .whitespacesAndNewlines) == normalized }
            .filter { parentCommentID == nil ? $0.parentCommentID == nil : $0.parentCommentID == parentCommentID }
            .filter { $0.createdAt >= notBefore }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Depth-first flattening that fills parent / root ids implied by nesting.
    static func flattenFillingParents(_ comments: [RemoteComment]) -> [RemoteComment] {
        var flat: [RemoteComment] = []
        func walk(_ c: RemoteComment, parent: String?, root: String?) {
            var copy = c
            if copy.parentCommentID == nil { copy.parentCommentID = parent }
            if copy.rootCommentID == nil { copy.rootCommentID = root }
            copy.replies = []
            flat.append(copy)
            for r in c.replies { walk(r, parent: c.id, root: copy.rootCommentID ?? c.id) }
        }
        for c in comments { walk(c, parent: nil, root: nil) }
        return flat
    }

    /// FANBOX needs the thread root as well as the parent (docs/API.md §9.2); fill it from the local thread when known.
    private func resolveRootIfNeeded(_ item: OutgoingComment) {
        guard let parent = item.parentCommentID, item.rootCommentID == nil,
              let row = store.first(#Predicate<Comment> { $0.commentID == parent }) else { return }
        item.rootCommentID = row.rootCommentID ?? row.commentID
    }

    private func notifyAttention(_ item: OutgoingComment) async {
        guard let hook = onAttentionNeeded else { return }
        await hook(item.id)
    }

    private func scheduleRetry(for item: OutgoingComment) {
        let exponent = Double(max(0, item.attemptCount - 1))
        let delay = min(Self.retryMaxDelay, Self.retryBaseDelay * pow(2, exponent))
        nextAttemptAt[item.id] = Date(timeIntervalSinceNow: delay)
        retryTimer?.cancel()
        let wait = nextAttemptAt.values.min().map { max(0.1, $0.timeIntervalSinceNow) } ?? delay
        retryTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            await self?.flush()
        }
    }

    /// An app kill during `.sending` leaves the outcome unknown: ask the user instead of risking a duplicate post.
    private func recoverInterruptedSends() {
        let sending = ReplyState.sending.rawValue
        let stuck = store.fetch(FetchDescriptor<OutgoingComment>(predicate: #Predicate { $0.stateRaw == sending }))
        guard !stuck.isEmpty else { return }
        for item in stuck {
            item.state = .needsConfirmation
            item.lastError = Self.interruptedSendMessage
        }
        store.save()
    }

    private func refreshCounts() {
        let states: [String] = [ReplyState.queued, .sending, .needsConfirmation, .failed].map(\.rawValue)
        let rows = store.fetch(FetchDescriptor<OutgoingComment>(predicate: #Predicate { states.contains($0.stateRaw) }))
        let pending = rows.count
        let attention = rows.filter { $0.state == .needsConfirmation || $0.state == .failed }.count
        if pendingCount != pending { pendingCount = pending }
        if attentionCount != attention { attentionCount = attention }
    }
}

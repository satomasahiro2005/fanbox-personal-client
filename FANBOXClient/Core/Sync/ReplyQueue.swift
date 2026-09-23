import Foundation
import Observation
import SwiftData

/// Offline-capable comment / reply queue (SPEC §22):
/// draft → queued (persisted locally) → sending → sent | failed | needsConfirmation.
/// - Sending uses `RequestPriority.interactiveWrite` (beats all media).
/// - Short disconnections are retried automatically.
/// - Items older than `settings.staleReplyThreshold` go to `needsConfirmation` unless `autoSendStaleReplies`.
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

    /// Automatic attempts for transient failures before an item becomes `.failed`.
    static let maxAttempts = 5
    /// Backoff for automatic retries: base * 2^(attempt-1), capped.
    static let retryBaseDelay: TimeInterval = 2
    static let retryMaxDelay: TimeInterval = 60
    static let interruptedSendMessage = "送信中に中断されました。送信済みか確認してください"

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
            await send(item)
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
        await send(item)
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
                continue
            }
            await send(item)
            guard canSend else { break }
        }
        refreshCounts()
    }

    private func send(_ item: OutgoingComment) async {
        guard let account = store.account(id: item.accountID) else {
            item.state = .failed
            item.lastError = "アカウントが見つかりません"
            store.save()
            refreshCounts()
            return
        }
        let context = account.context
        let postID = item.postID, body = item.body, parent = item.parentCommentID, root = item.rootCommentID
        guard !body.isEmpty else {
            item.state = .failed
            item.lastError = "本文が空です"
            store.save()
            refreshCounts()
            return
        }
        item.state = .sending
        item.attemptCount += 1
        item.lastAttemptAt = .now
        store.save()
        refreshCounts()

        let dataSource = remote.dataSource(for: context)
        do {
            let comment = try await RequestContext.$priority.withValue(.interactiveWrite) {
                try await dataSource.addComment(postID: postID, body: body, parentCommentID: parent, rootCommentID: root, account: context)
            }
            item.state = .sent
            item.sentAt = .now
            item.sentCommentID = comment.id
            item.lastError = nil
            nextAttemptAt[item.id] = nil
            var local = comment
            if local.postID.isEmpty { local.postID = postID }
            if local.parentCommentID == nil { local.parentCommentID = parent }
            if local.rootCommentID == nil { local.rootCommentID = root }
            store.upsertOwnComment(local, account: context)
        } catch {
            let mapped = SyncEngine.map(error)
            item.lastError = mapped.userMessage
            if mapped == .unauthorized {
                account.sessionState = .expired
                account.sessionCheckedAt = .now
            }
            if mapped == .offline {
                // Lost connectivity: not the reply's fault; keep it queued without consuming attempts.
                item.state = .queued
                item.attemptCount = max(0, item.attemptCount - 1)
            } else if mapped.isTransient && item.attemptCount < Self.maxAttempts {
                item.state = .queued
                scheduleRetry(for: item)
            } else {
                item.state = .failed
                nextAttemptAt[item.id] = nil
            }
            AppLog.sync.error("reply send failed: \(mapped.userMessage, privacy: .public)")
        }
        store.save()
        refreshCounts()
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

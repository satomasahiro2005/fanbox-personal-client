import Foundation
import SwiftData
import UserNotifications
import XCTest
@testable import FANBOXClient

/// Scripted `RemoteDataSource` for sync tests. All state is guarded by a lock (remote calls run off the main actor).
final class SyncMockRemote: RemoteDataSource, @unchecked Sendable {
    struct Script {
        /// accountID → cursor ("" = first page) → page
        var homePages: [String: [String: RemotePage<RemotePostSummary>]] = [:]
        var supportingPages: [String: [String: RemotePage<RemotePostSummary>]] = [:]
        /// creatorID → cursor → page
        var creatorPostPages: [String: [String: RemotePage<RemotePostSummary>]] = [:]
        /// accountID → postID → detail
        var details: [String: [String: RemotePostDetail]] = [:]
        /// accountID → error thrown by every call of that account
        var accountErrors: [String: RemoteError] = [:]
        var following: [String: [RemoteCreator]] = [:]
        var supports: [String: [RemoteSupport]] = [:]
        var payments: [String: [RemotePayment]] = [:]
        var notifications: [String: [RemoteNotification]] = [:]
        /// accountID → cursor ("" = first page) → bell.list page; used instead of `notifications` when set.
        var notificationPages: [String: [String: RemotePage<RemoteNotification>]] = [:]
        var newsletters: [String: [RemoteNewsletter]] = [:]
        /// postID → comments
        var comments: [String: [RemoteComment]] = [:]
        /// Consumed in order by addComment; when empty, addComment echoes a successful comment.
        var addCommentResults: [RemoteError?] = []
        /// When true, a failing addComment still stores the comment (the POST reached FANBOX, the response was lost).
        var addCommentReachesServerOnError = false
        /// Errors thrown by comments(postID:) (consumed in order; empty = success).
        var commentErrors: [RemoteError] = []
        var homeDelayNanoseconds: UInt64 = 0
        var addCommentDelayNanoseconds: UInt64 = 0
        var commentsDelayNanoseconds: UInt64 = 0
        var postDelayNanoseconds: UInt64 = 0
        /// accountID → postID → error thrown by post(id:)
        var postErrors: [String: [String: RemoteError]] = [:]
        /// postID → metadata returned by postMetadata(id:)
        var postMetadata: [String: RemotePostSummary] = [:]
        /// accountID → unread bell count (nil = probe unavailable)
        var unreadCounts: [String: Int] = [:]
        /// accountID → payment status (nil = unsupported)
        var paymentStatuses: [String: RemotePaymentStatus] = [:]
        /// accountID → completeness problem of the supporting-plan listing
        var supportProblems: [String: String] = [:]
        /// accountID → posts embedded in notifications
        var notificationPosts: [String: [RemotePostSummary]] = [:]
        /// accountID → fans
        var fans: [String: [RemoteFan]] = [:]
        /// accountID → completeness problem of the fan listing
        var fanProblems: [String: String] = [:]
    }

    private let lock = NSLock()
    private var script = Script()
    private var log: [String] = []
    private var priorityLog: [(String, RequestPriority)] = []
    private var sentCounter = 0

    /// Request priority seen by the first call whose log entry starts with `prefix`.
    func priority(of prefix: String) -> RequestPriority? {
        lock.lock(); defer { lock.unlock() }
        return priorityLog.first { $0.0.hasPrefix(prefix) }?.1
    }

    /// Priorities of every call whose log entry starts with `prefix`, in order.
    func priorities(of prefix: String) -> [RequestPriority] {
        lock.lock(); defer { lock.unlock() }
        return priorityLog.filter { $0.0.hasPrefix(prefix) }.map(\.1)
    }

    func update(_ change: (inout Script) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&script)
    }

    func count(_ prefix: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return log.filter { $0.hasPrefix(prefix) }.count
    }

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    private func record(_ entry: String, account: AccountContext) throws -> Script {
        let priority = RequestContext.priority
        lock.lock(); defer { lock.unlock() }
        log.append(entry)
        priorityLog.append((entry, priority))
        if let error = script.accountErrors[account.accountID] { throw error }
        return script
    }

    // MARK: RemoteDataSource

    func currentUser(account: AccountContext) async throws -> RemoteUser {
        _ = try record("currentUser|\(account.accountID)", account: account)
        return RemoteUser(pixivUserID: account.pixivUserID ?? "", fanboxUserID: nil, name: "user", iconURL: nil, creatorID: account.creatorID)
    }

    func homeTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        let s = try record("home|\(account.accountID)|\(cursor ?? "")", account: account)
        if s.homeDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: s.homeDelayNanoseconds) }
        return s.homePages[account.accountID]?[cursor ?? ""] ?? RemotePage(items: [])
    }

    func supportingTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        let s = try record("supporting|\(account.accountID)|\(cursor ?? "")", account: account)
        return s.supportingPages[account.accountID]?[cursor ?? ""] ?? RemotePage(items: [])
    }

    func creatorPosts(creatorID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        let s = try record("creatorPosts|\(creatorID)|\(cursor ?? "")", account: account)
        return s.creatorPostPages[creatorID]?[cursor ?? ""] ?? RemotePage(items: [])
    }

    func post(id: String, account: AccountContext) async throws -> RemotePostDetail {
        let s = try record("post|\(account.accountID)|\(id)", account: account)
        if s.postDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: s.postDelayNanoseconds) }
        if let error = s.postErrors[account.accountID]?[id] { throw error }
        guard let detail = s.details[account.accountID]?[id] else { throw RemoteError.notFound }
        return detail
    }

    func postMetadata(id: String, account: AccountContext) async throws -> RemotePostSummary {
        let s = try record("postMetadata|\(account.accountID)|\(id)", account: account)
        guard let summary = s.postMetadata[id] else { throw RemoteError.unsupported(operation: "postMetadata") }
        return summary
    }

    func creator(id: String, account: AccountContext) async throws -> RemoteCreator {
        _ = try record("creator|\(id)", account: account)
        return RemoteCreator(creatorID: id, name: "Creator \(id)")
    }

    func followingCreators(account: AccountContext) async throws -> [RemoteCreator] {
        try record("following|\(account.accountID)", account: account).following[account.accountID] ?? []
    }

    func supportingPlans(account: AccountContext) async throws -> [RemoteSupport] {
        try record("supports|\(account.accountID)", account: account).supports[account.accountID] ?? []
    }

    func supportingPlanListing(account: AccountContext) async throws -> RemoteSupportListing {
        let s = try record("supports|\(account.accountID)", account: account)
        return RemoteSupportListing(supports: s.supports[account.accountID] ?? [], problem: s.supportProblems[account.accountID])
    }

    func paymentStatus(account: AccountContext) async throws -> RemotePaymentStatus? {
        try record("paymentStatus|\(account.accountID)", account: account).paymentStatuses[account.accountID]
    }

    func unreadNotificationCount(account: AccountContext) async throws -> Int? {
        try record("unreadCount|\(account.accountID)", account: account).unreadCounts[account.accountID]
    }

    func creatorPlans(creatorID: String, account: AccountContext) async throws -> [RemotePlan] {
        _ = try record("plans|\(creatorID)", account: account)
        return []
    }

    func setLike(postID: String, liked: Bool, account: AccountContext) async throws {
        _ = try record("like|\(postID)", account: account)
    }

    func comments(postID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> {
        let s = try record("comments|\(account.accountID)|\(postID)", account: account)
        if s.commentsDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: s.commentsDelayNanoseconds) }
        let error: RemoteError? = {
            lock.lock(); defer { lock.unlock() }
            return script.commentErrors.isEmpty ? nil : script.commentErrors.removeFirst()
        }()
        if let error { throw error }
        return RemotePage(items: s.comments[postID] ?? [])
    }

    func addComment(postID: String, body: String, parentCommentID: String?, rootCommentID: String?,
                    account: AccountContext) async throws -> RemoteComment {
        let priority = RequestContext.priority
        let (error, n, delay): (RemoteError?, Int, UInt64) = {
            lock.lock(); defer { lock.unlock() }
            log.append("addComment|\(account.accountID)|\(postID)")
            priorityLog.append(("addComment|\(account.accountID)|\(postID)", priority))
            sentCounter += 1
            let next = script.addCommentResults.isEmpty ? nil : script.addCommentResults.removeFirst()
            return (next, sentCounter, script.addCommentDelayNanoseconds)
        }()
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let comment = RemoteComment(id: "sent-\(n)", postID: postID, parentCommentID: parentCommentID, rootCommentID: rootCommentID,
                                    authorUserID: account.pixivUserID ?? "", authorName: "me", body: body, createdAt: .now, isOwn: true)
        // A successful POST (or one that reached FANBOX before its response was lost) is visible in the thread.
        lock.withLock {
            if error == nil || script.addCommentReachesServerOnError { script.comments[postID, default: []].append(comment) }
        }
        if let error { throw error }
        return comment
    }

    func deleteComment(commentID: String, postID: String, account: AccountContext) async throws {
        _ = try record("deleteComment|\(commentID)", account: account)
    }

    func notifications(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteNotification> {
        RemotePage(items: try record("notifications|\(account.accountID)", account: account).notifications[account.accountID] ?? [])
    }

    func notificationBatch(account: AccountContext, cursor: String?) async throws -> RemoteNotificationBatch {
        let s = try record("notifications|\(account.accountID)", account: account)
        if let pages = s.notificationPages[account.accountID] {
            return RemoteNotificationBatch(page: pages[cursor ?? ""] ?? RemotePage(items: []), posts: [])
        }
        return RemoteNotificationBatch(page: RemotePage(items: s.notifications[account.accountID] ?? []),
                                       posts: s.notificationPosts[account.accountID] ?? [])
    }

    func newsletters(account: AccountContext) async throws -> [RemoteNewsletter] {
        try record("newsletters|\(account.accountID)", account: account).newsletters[account.accountID] ?? []
    }

    func newsletter(id: String, account: AccountContext) async throws -> RemoteNewsletter {
        let s = try record("newsletter|\(id)", account: account)
        guard let n = s.newsletters[account.accountID]?.first(where: { $0.id == id }) else { throw RemoteError.notFound }
        return n
    }

    func paidRecords(account: AccountContext) async throws -> [RemotePayment] {
        try record("payments|\(account.accountID)", account: account).payments[account.accountID] ?? []
    }

    func managedPosts(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        _ = try record("managed|\(account.accountID)", account: account)
        return RemotePage(items: [])
    }

    func editablePost(id: String, account: AccountContext) async throws -> RemoteEditablePost { throw RemoteError.notFound }
    func createPost(_ draft: RemotePostDraft, account: AccountContext) async throws -> String { throw RemoteError.unsupported(operation: "createPost") }
    func updatePost(id: String, _ draft: RemotePostDraft, account: AccountContext) async throws {}
    func uploadImage(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        throw RemoteError.unsupported(operation: "uploadImage")
    }
    func uploadFile(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        throw RemoteError.unsupported(operation: "uploadFile")
    }

    func fans(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteFan> {
        let s = try record("fans|\(account.accountID)", account: account)
        return RemotePage(items: s.fans[account.accountID] ?? [])
    }

    func fanListing(account: AccountContext, cursor: String?) async throws -> RemoteFanListing {
        let s = try record("fans|\(account.accountID)", account: account)
        return RemoteFanListing(page: RemotePage(items: s.fans[account.accountID] ?? []), problem: s.fanProblems[account.accountID])
    }

    func creatorDashboard(account: AccountContext) async throws -> RemoteCreatorDashboard {
        _ = try record("dashboard|\(account.accountID)", account: account)
        return RemoteCreatorDashboard(month: "2026-09", supporterCount: 12, earnings: nil, postCount: 3, commentCount: nil)
    }

    func creatorComments(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> {
        _ = try record("creatorComments|\(account.accountID)", account: account)
        return RemotePage(items: [])
    }
}

struct SyncMockProvider: RemoteDataSourceProvider {
    let mock: SyncMockRemote
    func dataSource(for account: AccountContext) -> RemoteDataSource { mock }
}

/// Captures local notification requests instead of posting them.
@MainActor
final class SyncRecordingPoster: LocalNotificationPosting {
    var requests: [UNNotificationRequest] = []
    var badge: Int?

    func post(_ request: UNNotificationRequest) async throws { requests.append(request) }
    func setBadge(_ count: Int) async { badge = count }
}

/// In-memory store + real services wired to `SyncMockRemote`.
@MainActor
final class SyncHarness {
    let container: ModelContainer
    let store: LocalStore
    let settings: AppSettings
    let policy: NetworkPolicyStore
    let network: NetworkModeController
    let mock = SyncMockRemote()
    let engine: SyncEngine
    let replies: ReplyQueue
    let router = AppRouter()
    /// Per-harness UserDefaults suites (settings, Creator Mode's selected account), removed with the harness.
    private let settingsSuite = "sync-tests-\(UUID().uuidString)"
    private let creatorModeSuite = "sync-creator-mode-\(UUID().uuidString)"
    lazy var notifications: NotificationService = {
        let service = NotificationService(store: store, engine: engine, replies: replies, router: router, settings: settings)
        service.poster = poster
        service.creatorModeDefaults = UserDefaults(suiteName: creatorModeSuite)!
        return service
    }()
    lazy var coordinator: SyncCoordinator = {
        let coordinator = SyncCoordinator(engine: engine, settings: settings, network: network, replies: replies)
        coordinator.notifications = notifications
        return coordinator
    }()
    let poster = SyncRecordingPoster()

    init() throws {
        container = try PersistenceController.makeContainer(inMemory: true)
        store = LocalStore(container: container)
        settings = AppSettings(defaults: UserDefaults(suiteName: settingsSuite)!)
        policy = NetworkPolicyStore()
        network = NetworkModeController(settings: settings, policyStore: policy)
        let provider = SyncMockProvider(mock: mock)
        engine = SyncEngine(store: store, remote: provider, settings: settings, network: network)
        replies = ReplyQueue(store: store, remote: provider, settings: settings, network: network)
        // Same wiring as AppEnvironment.wire().
        replies.onAttentionNeeded = { [weak self] itemID in
            await self?.notifications.handleReplyAttention(itemID: itemID)
        }
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: settingsSuite)
        UserDefaults().removePersistentDomain(forName: creatorModeSuite)
    }

    @discardableResult
    func addAccount(_ name: String, pixivUserID: String, creatorID: String? = nil, isMain: Bool = false) -> Account {
        let account = Account(kind: .fanbox, displayName: name, pixivUserID: pixivUserID, creatorID: creatorID, isMain: isMain,
                              sortOrder: store.accounts(includeDisabled: true).count, sessionState: .valid)
        store.context.insert(account)
        store.save()
        return account
    }

    func setOffline(_ offline: Bool) {
        settings.networkModePreference = offline ? .offline : .normal
        network.recompute()
    }

    // MARK: Engine clock (frequency rules / day-of-month rules)

    private var clockBase: Date?
    private var clockOffset: TimeInterval = 0

    /// Pins the engine clock to `date` (sync-state timestamps and frequency rules use it).
    func setClock(_ date: Date) {
        clockBase = date
        clockOffset = 0
        installClock()
    }

    /// Moves the engine clock forward (pinned or real time).
    func advanceClock(by seconds: TimeInterval) {
        clockOffset += seconds
        installClock()
    }

    private func installClock() {
        let base = clockBase, offset = clockOffset
        engine.clock = { (base ?? Date.now).addingTimeInterval(offset) }
    }
}

enum SyncFixtures {
    static let base = Date(timeIntervalSince1970: 1_780_000_000)

    /// Noon (JST) of `day` in the current month.
    static func dayOfCurrentMonthJST(_ day: Int, now: Date = .now) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var c = calendar.dateComponents([.year, .month], from: now)
        c.day = day
        c.hour = 12
        return calendar.date(from: c)!
    }

    /// The 15th of the current month (JST): outside the 1st–5th payment window.
    static var midMonthJST: Date { dayOfCurrentMonthJST(15) }

    static func summary(_ id: String, creator: String = "c1", title: String? = nil, restricted: Bool = false, fee: Int = 0,
                        minutesAgo: Double = 0) -> RemotePostSummary {
        RemotePostSummary(id: id, creatorID: creator, creatorName: "Creator \(creator)", title: title ?? "Post \(id)",
                          excerpt: "excerpt \(id)", type: .article, feeRequired: fee,
                          publishedAt: base.addingTimeInterval(-minutesAgo * 60), isRestricted: restricted)
    }

    static func page(_ ids: [String], next: String? = nil, creator: String = "c1") -> RemotePage<RemotePostSummary> {
        RemotePage(items: ids.map { summary($0, creator: creator) }, nextCursor: next)
    }

    static func detail(_ id: String, creator: String = "c1", restricted: Bool = false, text: String = "本文",
                       withImage: Bool = true) -> RemotePostDetail {
        var blocks: [RemoteBlock] = []
        if !restricted {
            blocks.append(RemoteBlock(kind: .paragraph, text: text))
            if withImage {
                blocks.append(RemoteBlock(kind: .image, mediaID: "img-\(id)", thumbnailURL: "https://example.invalid/t.jpg",
                                          displayURL: "https://example.invalid/d.jpg", originalURL: "https://example.invalid/o.jpg",
                                          width: 800, height: 600))
            }
        }
        return RemotePostDetail(summary: summary(id, creator: creator, restricted: restricted), blocks: blocks,
                                plainText: restricted ? "" : text, prevPostID: nil, nextPostID: nil)
    }

    static func support(_ creator: String, plan: String, fee: Int) -> RemoteSupport {
        RemoteSupport(planID: plan, creatorID: creator, creatorName: "Creator \(creator)", creatorIconURL: nil, pixivUserID: nil,
                      planTitle: "Plan \(plan)", fee: fee, paymentMethod: nil, planDescription: nil, coverImageURL: nil)
    }

    static func notification(_ remoteID: String, type: NotificationEventType, postID: String? = nil, commentID: String? = nil,
                             newsletterID: String? = nil, creatorID: String? = "c1", unread: Bool? = true) -> RemoteNotification {
        RemoteNotification(remoteID: remoteID, type: type, rawType: type.rawValue, createdAt: .now, creatorID: creatorID,
                           creatorName: creatorID.map { "Creator \($0)" }, postID: postID, postTitle: nil, commentID: commentID,
                           newsletterID: newsletterID, actorName: "fan", actorIconURL: nil, title: "title \(remoteID)",
                           message: "message \(remoteID)", isUnread: unread)
    }
}

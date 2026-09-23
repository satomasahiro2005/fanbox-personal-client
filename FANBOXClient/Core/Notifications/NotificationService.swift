import Foundation
import SwiftData
import SwiftUI
import UserNotifications

/// Posts local notifications. Abstracted so tests can capture requests without touching the system center.
@MainActor
protocol LocalNotificationPosting: AnyObject {
    func post(_ request: UNNotificationRequest) async throws
    func setBadge(_ count: Int) async
}

@MainActor
final class SystemNotificationPoster: LocalNotificationPosting {
    func post(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    func setBadge(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}

/// Where tapping a notification event leads (pure; see `NotificationService.destination(for:)`).
enum NotificationDestination: Equatable {
    /// Reset the Home stack and push the route (instant local render).
    case home(AppRoute)
    /// Switch to the Support tab, optionally pushing a route.
    case support(AppRoute?)
    /// Switch to the Creator tab and push a route.
    case creatorMode(AppRoute)
    /// Present the notification inbox.
    case inbox
}

/// Notification pipeline (SPEC §24–§28):
/// FANBOX event → detection (sync) → text prefetch (priority table) → Local DB → iOS notification → tap → immediate local render.
/// Also handles the inline "返信" text action so replies can be queued straight from a notification.
@MainActor
final class NotificationService: NSObject {
    static let commentCategoryID = "FANBOX_COMMENT"
    static let postCategoryID = "FANBOX_POST"
    static let genericCategoryID = "FANBOX_GENERIC"
    static let replyActionID = "FANBOX_REPLY"
    static let markReadActionID = "FANBOX_MARK_READ"
    static let eventIDKey = "eventID"

    /// Events older than this are imported silently (no banner), e.g. after a long time offline.
    static let deliveryWindow: TimeInterval = 3 * 24 * 60 * 60
    static let bodyPreviewLength = 180

    let store: LocalStore
    let engine: SyncEngine
    let replies: ReplyQueue
    let router: AppRouter
    let settings: AppSettings
    /// Replaceable for tests.
    var poster: LocalNotificationPosting = SystemNotificationPoster()

    private var configured = false

    init(store: LocalStore, engine: SyncEngine, replies: ReplyQueue, router: AppRouter, settings: AppSettings) {
        self.store = store
        self.engine = engine
        self.replies = replies
        self.router = router
        self.settings = settings
        super.init()
        // The delegate must be installed before launch finishes so a tap that cold-launches the app is delivered.
        if !Self.isRunningTests {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// Sets the UNUserNotificationCenter delegate and registers categories / actions.
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        guard !configured else { return }
        configured = true
        center.setNotificationCategories(Self.categories())
        let arguments = ProcessInfo.processInfo.arguments
        if settings.localNotificationsEnabled, !Self.isRunningTests, !arguments.contains("-uiTesting") {
            Task { [weak self] in
                let status = await center.notificationSettings().authorizationStatus
                if status == .notDetermined { await self?.requestAuthorization() }
            }
        }
    }

    static func categories() -> Set<UNNotificationCategory> {
        let reply = UNTextInputNotificationAction(identifier: replyActionID, title: "返信", options: [],
                                                  textInputButtonTitle: "送信", textInputPlaceholder: "返信を入力")
        let markRead = UNNotificationAction(identifier: markReadActionID, title: "既読にする", options: [])
        return [
            UNNotificationCategory(identifier: commentCategoryID, actions: [reply, markRead], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: postCategoryID, actions: [markRead], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: genericCategoryID, actions: [markRead], intentIdentifiers: [], options: []),
        ]
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            AppLog.notifications.error("authorization failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Pipeline

    /// Prefetches text for new events (highest priority first), then posts local notifications.
    func process(newEventIDs: [String]) async {
        let events = Array(Set(newEventIDs)).compactMap { store.notificationEvent(id: $0) }
            .sorted { a, b in
                if a.priority != b.priority { return a.priority > b.priority }
                return a.timestamp > b.timestamp
            }
        let ids = events.map(\.id)
        for id in ids {
            // Priority 0 / 1 text first, then the iOS notification — its body is readable without opening the app.
            await prefetch(eventID: id)
            await deliver(eventID: id)
        }
        await updateBadge()
    }

    /// Prefetch for one event according to its type (SPEC §24.2 / §25).
    func prefetch(eventID: String) async {
        guard let event = store.notificationEvent(id: eventID) else { return }
        switch event.prefetchState {
        case .textReady, .complete, .notNeeded, .inProgress: return
        case .pending, .failed: break
        }
        event.prefetchState = .inProgress
        store.save()

        let postID = event.postID, newsletterID = event.newsletterID, type = event.type
        let accountIDs = event.accountIDs
        let result: PrefetchState = await RequestContext.$priority.withValue(.notificationPrefetch) {
            switch type.prefetchTarget {
            case .commentThread:
                guard let postID else { return .notNeeded }
                let account = self.preferredAccount(for: event)
                let commentError = await self.engine.refreshComments(postID: postID, accountID: account, priority: .notificationPrefetch)
                if self.store.post(id: postID)?.hasCachedBody != true {
                    await self.engine.refreshPost(postID: postID, priority: .notificationPrefetch)
                }
                return commentError == nil ? .textReady : .failed
            case .postText:
                guard let postID else { return .notNeeded }
                let error = await self.engine.refreshPost(postID: postID, priority: .notificationPrefetch)
                return error == nil && self.store.post(id: postID) != nil ? .textReady : .failed
            case .newsletterBody:
                guard let newsletterID else { return .notNeeded }
                let error = await self.engine.refreshNewsletter(id: newsletterID, accountID: accountIDs.first, priority: .notificationPrefetch)
                return error == nil ? .textReady : .failed
            case .supportMetadata:
                var failed = false
                for accountID in accountIDs {
                    let outcome = await self.engine.sync(.supports, accountID: accountID, reason: .notification)
                    if outcome.error != nil { failed = true }
                }
                return failed ? .failed : .textReady
            case .metadata, .notificationMetadata:
                return .notNeeded
            }
        }
        if let e = store.notificationEvent(id: eventID) {
            e.prefetchState = result
            store.save()
        }
    }

    /// Posts the local iOS notification for an event (once), built from the local DB.
    func deliver(eventID: String) async {
        guard settings.localNotificationsEnabled, let event = store.notificationEvent(id: eventID) else { return }
        guard !event.deliveredLocally, !event.isRead else { return }
        guard event.timestamp > Date(timeIntervalSinceNow: -Self.deliveryWindow) else { return }
        let request = makeRequest(for: event)
        do {
            try await poster.post(request)
            event.deliveredLocally = true
            store.save()
        } catch {
            AppLog.notifications.error("local notification failed: \(String(describing: error), privacy: .public)")
        }
    }

    func makeRequest(for event: NotificationEvent) -> UNNotificationRequest {
        let text = Self.content(for: event, store: store)
        let content = UNMutableNotificationContent()
        content.title = text.title
        if !text.subtitle.isEmpty { content.subtitle = text.subtitle }
        content.body = text.body
        content.sound = .default
        content.userInfo = [Self.eventIDKey: event.id]
        content.threadIdentifier = event.creatorID ?? event.type.rawValue
        content.categoryIdentifier = Self.categoryID(for: event.type)
        content.interruptionLevel = event.priority == .critical ? .timeSensitive : .active
        content.relevanceScore = Double(event.priority.rawValue) / 3
        return UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
    }

    static func categoryID(for type: NotificationEventType) -> String {
        switch type {
        case .comment, .commentReply: return commentCategoryID
        case .newPost: return postCategoryID
        default: return genericCategoryID
        }
    }

    /// Notification text from the local DB (comment body / post title are already prefetched).
    static func content(for event: NotificationEvent, store: LocalStore) -> (title: String, subtitle: String, body: String) {
        let post = event.postID.flatMap { store.post(id: $0) }
        let creatorName = event.creatorID.flatMap { store.creator(id: $0)?.name } ?? post?.creatorName
        func preview(_ s: String) -> String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > bodyPreviewLength ? String(trimmed.prefix(bodyPreviewLength)) + "…" : trimmed
        }
        let fallbackBody = event.message.isEmpty ? event.title : event.message

        switch event.type {
        case .comment, .commentReply:
            let commentID = event.commentID
            let comment = commentID.flatMap { id in store.first(#Predicate<Comment> { $0.commentID == id }) }
            let author = comment?.authorName ?? event.actorName ?? "誰か"
            let title = event.type == .comment ? "\(author) がコメントしました" : "\(author) が返信しました"
            let body = comment.map { preview($0.body) } ?? preview(fallbackBody)
            return (title, post?.title ?? "", body)
        case .newPost:
            let title = "\(creatorName ?? event.actorName ?? "クリエイター") が投稿しました"
            guard let post else { return (title, "", preview(fallbackBody)) }
            let lead = post.bodyText.isEmpty ? post.excerpt : post.bodyText
            let body = lead.isEmpty ? post.title : "\(post.title)\n\(preview(lead))"
            return (title, "", body)
        case .newsletter:
            let letter = event.newsletterID.flatMap { store.newsletter(id: $0) }
            let title = "\(letter?.creatorName ?? creatorName ?? "クリエイター") からおたより"
            let body = letter.map { $0.body.isEmpty ? ($0.title ?? fallbackBody) : preview($0.body) } ?? preview(fallbackBody)
            return (title, letter?.title ?? "", body)
        case .supportChanged, .paymentAttention, .newSupporter, .other:
            let title = event.title.isEmpty ? event.type.displayName : event.title
            let body = event.message.isEmpty ? event.type.displayName : preview(event.message)
            return (title, "", body)
        }
    }

    // MARK: - Open / actions

    /// Opens the local screen for an event (used by taps and the in-app inbox). Never waits for the network.
    func open(eventID: String) {
        guard let event = store.notificationEvent(id: eventID) else {
            router.isNotificationInboxPresented = true
            return
        }
        markRead(event)
        apply(Self.destination(for: event))
    }

    /// Route mapping for an event (pure).
    static func destination(for event: NotificationEvent) -> NotificationDestination {
        switch event.type {
        case .comment, .commentReply:
            guard let postID = event.postID else { return .inbox }
            return .home(.comments(postID: postID, focusCommentID: event.commentID))
        case .newPost:
            guard let postID = event.postID else { return .inbox }
            return .home(.post(postID: postID))
        case .newsletter:
            guard let id = event.newsletterID else { return .inbox }
            return .home(.newsletter(newsletterID: id))
        case .supportChanged, .paymentAttention:
            return .support(event.creatorID.map { .supportCreator(creatorID: $0) })
        case .newSupporter:
            return .creatorMode(.fans)
        case .other:
            return .inbox
        }
    }

    func apply(_ destination: NotificationDestination) {
        switch destination {
        case .home(let route):
            router.openFromNotification(route)
        case .support(let route):
            dismissSheets()
            router.setPath(NavigationPath(), for: .support)
            if let route { router.open(route, in: .support) } else { router.selectedTab = .support }
        case .creatorMode(let route):
            dismissSheets()
            router.setPath(NavigationPath(), for: .creatorMode)
            router.open(route, in: .creatorMode)
        case .inbox:
            router.isSettingsPresented = false
            router.isNotificationInboxPresented = true
        }
    }

    /// Inline reply from the notification: queued locally first (works offline), sent with interactiveWrite priority.
    @discardableResult
    func handleReply(eventID: String, text: String) async -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let event = store.notificationEvent(id: eventID), let postID = event.postID else { return nil }
        guard let accountID = preferredAccount(for: event) else { return nil }
        let commentID = event.commentID
        let comment = commentID.flatMap { id in store.first(#Predicate<Comment> { $0.commentID == id }) }
        let id = replies.submit(postID: postID, body: body, parentCommentID: commentID,
                                rootCommentID: comment?.rootCommentID ?? commentID, accountID: accountID, origin: .notificationAction)
        markRead(event)
        await replies.flush()
        await updateBadge()
        return id
    }

    func markRead(eventID: String) {
        guard let event = store.notificationEvent(id: eventID) else { return }
        markRead(event)
        Task { await updateBadge() }
    }

    /// Account to act as for an event: the creator account that owns the post, else one that received the event, else main.
    func preferredAccount(for event: NotificationEvent) -> String? {
        let enabled = Set(store.accounts().map(\.id))
        let owned = store.ownedCreatorAccountMap()
        let creatorID = event.postID.flatMap { store.post(id: $0)?.creatorID } ?? event.creatorID
        if let creatorID, let owner = owned[creatorID], enabled.contains(owner) { return owner }
        if let received = event.accountIDs.first(where: { enabled.contains($0) }) { return received }
        return store.mainAccount()?.id
    }

    // MARK: - Private

    private func markRead(_ event: NotificationEvent) {
        if !event.isRead { event.isRead = true }
        if let commentID = event.commentID, let c = store.first(#Predicate<Comment> { $0.commentID == commentID }), !c.isRead {
            c.isRead = true
        }
        store.save()
    }

    private func dismissSheets() {
        router.isSettingsPresented = false
        router.isNotificationInboxPresented = false
    }

    private func updateBadge() async {
        let unread = (try? store.context.fetchCount(FetchDescriptor<NotificationEvent>(predicate: #Predicate { !$0.isRead }))) ?? 0
        await poster.setBadge(unread)
    }

    fileprivate func handleResponse(action: String, eventID: String?, text: String?) async {
        guard let eventID else { return }
        switch action {
        case Self.replyActionID:
            await handleReply(eventID: eventID, text: text ?? "")
        case Self.markReadActionID:
            markRead(eventID: eventID)
        case UNNotificationDismissActionIdentifier:
            break
        default:
            open(eventID: eventID)
        }
    }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let eventID = response.notification.request.content.userInfo["eventID"] as? String
        let text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            await self.handleResponse(action: action, eventID: eventID, text: text)
            completionHandler()
        }
    }
}

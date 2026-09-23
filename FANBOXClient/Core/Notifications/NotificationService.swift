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
    /// userInfo key of reply-queue notices (value: OutgoingComment id).
    static let replyItemIDKey = "replyItemID"

    /// Events older than this are imported silently (no banner), e.g. after a long time offline.
    static let deliveryWindow: TimeInterval = 3 * 24 * 60 * 60
    static let bodyPreviewLength = 180
    /// Failed text prefetches of events newer than this are retried when the app becomes active (SPEC §3.3 / §25).
    static let prefetchRetryWindow: TimeInterval = 48 * 60 * 60
    static let prefetchRetryLimit = 20
    /// Comment authors whose avatars are prefetched with a comment thread (Priority 2).
    static let threadAvatarPrefetchLimit = 5

    let store: LocalStore
    let engine: SyncEngine
    let replies: ReplyQueue
    let router: AppRouter
    let settings: AppSettings
    /// Repository façade (SPEC §43) used for post text prefetch.
    let repository: FanboxRepository
    /// Replaceable for tests.
    var poster: LocalNotificationPosting = SystemNotificationPoster()
    /// Priority 2 prefetch (avatars / thumbnails) after text is ready. Wired to `MediaService` by `AppEnvironment`;
    /// `MediaPolicy` still decides whether anything is downloaded (Low Data / Extreme / Wi-Fi only).
    var mediaPrefetcher: ((MediaRequest) -> Void)?
    /// `.timeSensitive` requires the Time Sensitive Notifications entitlement. Without it iOS reports the setting as
    /// unsupported and Critical events are delivered as `.active` (documented fallback). Refreshed in `configure()`.
    var timeSensitiveAvailable = false

    private var configured = false
    /// Reply-queue notices already posted in this process ("<itemID>|<state>").
    private var postedReplyNotices: Set<String> = []

    init(store: LocalStore, engine: SyncEngine, replies: ReplyQueue, router: AppRouter, settings: AppSettings) {
        self.store = store
        self.engine = engine
        self.replies = replies
        self.router = router
        self.settings = settings
        self.repository = DefaultFanboxRepository(store: store, engine: engine)
        super.init()
        // A prefetch interrupted by an app kill stays `.inProgress`; make it retryable.
        store.resetInterruptedPrefetches()
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
        guard !Self.isRunningTests else { return }
        Task { [weak self] in
            if self?.settings.localNotificationsEnabled == true, !arguments.contains("-uiTesting") {
                let status = await center.notificationSettings().authorizationStatus
                if status == .notDetermined { await self?.requestAuthorization() }
            }
            await self?.refreshDeliveryCapabilities()
            await self?.updateBadge()
        }
    }

    /// Reads whether time-sensitive delivery is available (entitlement present and allowed by the user).
    func refreshDeliveryCapabilities() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        timeSensitiveAvailable = settings.timeSensitiveSetting == .enabled
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
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshDeliveryCapabilities()
            return granted
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
                // Same account choice as the post screen → the same sync key → one request (SPEC §34).
                let account = self.engine.commentAccount(postID: postID, preferring: accountIDs)
                let commentError = await self.engine.refreshComments(postID: postID, accountID: account, priority: .notificationPrefetch)
                if commentError == nil { self.resolveComment(eventID: eventID) }
                if self.store.post(id: postID)?.hasCachedBody != true {
                    _ = try? await self.repository.post(id: postID, account: nil, priority: .notificationPrefetch)
                }
                return commentError == nil ? .textReady : .failed
            case .postText:
                guard let postID else { return .notNeeded }
                do {
                    let post = try await self.repository.post(id: postID, account: nil, priority: .notificationPrefetch)
                    // Text is ready when the body is cached, or when no account may view it (title / excerpt is all there is).
                    return post.hasCachedBody || post.accessAccountIDs.isEmpty ? .textReady : .failed
                } catch {
                    return .failed
                }
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
            case .metadata:
                // 新規支援: refresh the fan list of the creator accounts so the Fans screen opened from it is current.
                let creators = accountIDs.filter { self.store.account(id: $0)?.creatorID != nil }
                guard !creators.isEmpty else { return .notNeeded }
                var failed = false
                for accountID in creators {
                    let outcome = await self.engine.sync(.fans, accountID: accountID, reason: .notification)
                    if outcome.error != nil { failed = true }
                }
                return failed ? .failed : .textReady
            case .notificationMetadata:
                return .notNeeded
            }
        }
        if let e = store.notificationEvent(id: eventID) {
            e.prefetchState = result
            store.save()
        }
        if result == .textReady { prefetchSmallMedia(eventID: eventID) }
    }

    /// Retries text prefetches that failed recently (called when the app becomes active). Sequential, newest first.
    func retryFailedPrefetches(now: Date = .now) async {
        guard engine.canReachNetwork else { return }
        let ids = store.failedPrefetchEventIDs(since: now.addingTimeInterval(-Self.prefetchRetryWindow), limit: Self.prefetchRetryLimit)
        for id in ids {
            guard engine.canReachNetwork else { return }
            await prefetch(eventID: id)
        }
    }

    /// Resolves `commentID` of a comment event from the locally stored thread (FANBOX bells carry no comment id).
    /// Returns the resolved id (existing or new).
    @discardableResult
    func resolveComment(eventID: String) -> String? {
        guard let event = store.notificationEvent(id: eventID), event.type == .comment || event.type == .commentReply,
              let postID = event.postID else { return nil }
        if let known = event.commentID { return known }
        let comments = store.comments(postID: postID)
        let candidates = comments.map {
            NotificationCommentResolver.Candidate(id: $0.commentID, parentID: $0.parentCommentID, authorName: $0.authorName, body: $0.body,
                                                  createdAt: $0.createdAt, isOwn: $0.isOwn)
        }
        guard let resolved = NotificationCommentResolver.resolve(
            type: event.type, message: event.message, actorName: event.actorName, timestamp: event.timestamp,
            bellIDs: NotificationCommentResolver.bellIDs(fromRemoteIDs: event.remoteIDs), postTitle: store.post(id: postID)?.title,
            candidates: candidates) else { return nil }
        event.commentID = resolved
        // An unread notification means the comment is unread too (Creator Mode 未読), even if it was imported as history.
        if !event.isRead, let comment = comments.first(where: { $0.commentID == resolved }), comment.isOnOwnPost, !comment.isOwn {
            comment.isRead = false
        }
        store.save()
        return resolved
    }

    /// Priority 2 (SPEC §25): actor avatar, post cover / creator icon and the latest thread avatars, after the text.
    private func prefetchSmallMedia(eventID: String) {
        guard let prefetch = mediaPrefetcher, let event = store.notificationEvent(id: eventID) else { return }
        let account = event.accountIDs.first
        var seen = Set<String>()
        var requests: [MediaRequest] = []
        func add(_ url: String?, postID: String? = nil, creatorID: String? = nil) {
            guard let url, !url.isEmpty, seen.insert(url).inserted else { return }
            requests.append(MediaRequest(url: url, variant: .thumbnail, kind: .image, trigger: .prefetch, priority: .mediaPrefetch,
                                         postID: postID, creatorID: creatorID, accountID: account))
        }
        add(event.actorIconURL, creatorID: event.creatorID)
        if let postID = event.postID, let post = store.post(id: postID) {
            add(post.coverImageURL, postID: postID, creatorID: post.creatorID)
            add(post.creatorIconURL, creatorID: post.creatorID)
            if event.type == .comment || event.type == .commentReply {
                let recent = store.comments(postID: postID).sorted { $0.createdAt > $1.createdAt }
                for comment in recent.prefix(20) where requests.count < Self.threadAvatarPrefetchLimit + 3 {
                    add(comment.authorIconURL, postID: postID)
                }
            }
        }
        if let newsletterID = event.newsletterID, let letter = store.newsletter(id: newsletterID) {
            add(letter.creatorIconURL, creatorID: letter.creatorID)
        }
        for request in requests { prefetch(request) }
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
        // Critical events break through Focus only when the time-sensitive entitlement is available (else `.active`).
        content.interruptionLevel = event.priority == .critical && timeSensitiveAvailable ? .timeSensitive : .active
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
        Task { await updateBadge() }
    }

    /// Opens the thread of a reply-queue item (tap on a "返信を送信できませんでした" notice).
    func openReplyItem(id: String) {
        guard let item = replies.item(id: id) else {
            router.isNotificationInboxPresented = true
            return
        }
        router.openFromNotification(.comments(postID: item.postID, focusCommentID: item.parentCommentID))
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
    /// A reply to a comment is always threaded under that comment. When the comment cannot be identified (FANBOX bells
    /// have no comment id and the thread could not be read), the text is kept as a draft on the thread instead of being
    /// posted as a public top-level comment, and a notice asks the user to pick the target in the app.
    @discardableResult
    func handleReply(eventID: String, text: String) async -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let event = store.notificationEvent(id: eventID), let postID = event.postID else { return nil }
        guard let accountID = preferredAccount(for: event) else { return nil }
        markRead(event)
        let isCommentEvent = event.type == .comment || event.type == .commentReply

        var target = replyTarget(for: event)
        if isCommentEvent, target == nil, engine.canReachNetwork {
            let account = engine.commentAccount(postID: postID, preferring: event.accountIDs)
            await engine.refreshComments(postID: postID, accountID: account, priority: .interactiveRead)
            resolveComment(eventID: eventID)
            target = replyTarget(for: event)
        }
        if isCommentEvent, target == nil {
            let draftID = replies.saveDraft(postID: postID, body: body, accountID: accountID)
            await postReplyNotice(itemID: draftID, title: "返信先を特定できませんでした",
                                  body: "返信を下書きとして保存しました。タップしてスレッドで返信先を選んでください。", tag: "unresolved")
            await updateBadge()
            return draftID
        }
        let id = replies.submit(postID: postID, body: body, parentCommentID: target?.parent, rootCommentID: target?.root,
                                accountID: accountID, origin: .notificationAction)
        await replies.flush()
        await updateBadge()
        return id
    }

    /// Parent / root for a reply to the event's comment. The root is left nil when the thread is not local; the reply queue
    /// fills it from the local thread before sending (the data source falls back to the parent).
    private func replyTarget(for event: NotificationEvent) -> (parent: String, root: String?)? {
        guard let commentID = event.commentID else { return nil }
        let comment = store.first(#Predicate<Comment> { $0.commentID == commentID })
        return (commentID, comment.map { $0.rootCommentID ?? $0.commentID })
    }

    /// Reply-queue item needs the user (`ReplyQueue.onAttentionNeeded`). Replies written from a notification were never
    /// seen in the thread, so the user is told with a local notification that opens the thread.
    func handleReplyAttention(itemID: String) async {
        guard let item = replies.item(id: itemID), item.origin == .notificationAction else { return }
        let title: String
        switch item.state {
        case .failed: title = "返信を送信できませんでした"
        case .needsConfirmation: title = "返信の送信確認が必要です"
        default: return
        }
        var body = Self.preview(item.body)
        if let error = item.lastError, !error.isEmpty { body += "\n" + error }
        await postReplyNotice(itemID: itemID, title: title, body: body, tag: item.state.rawValue)
    }

    private func postReplyNotice(itemID: String, title: String, body: String, tag: String) async {
        guard settings.localNotificationsEnabled, postedReplyNotices.insert("\(itemID)|\(tag)").inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [Self.replyItemIDKey: itemID]
        content.threadIdentifier = "replyQueue"
        content.interruptionLevel = .active
        do {
            try await poster.post(UNNotificationRequest(identifier: "reply|\(itemID)|\(tag)", content: content, trigger: nil))
        } catch {
            AppLog.notifications.error("reply notice failed: \(String(describing: error), privacy: .public)")
        }
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

    /// App icon badge = unread inbox events. Called after every local read-state change (inbox, taps, actions).
    func updateBadge() async {
        await poster.setBadge(store.unreadNotificationEventCount())
    }

    // MARK: - Private

    private func markRead(_ event: NotificationEvent) {
        if !event.isRead { event.isRead = true }
        if let commentID = event.commentID, let c = store.first(#Predicate<Comment> { $0.commentID == commentID }), !c.isRead {
            c.isRead = true
        }
        // Keep the おたより read state in step with its event (both segments of the inbox).
        if let newsletterID = event.newsletterID, let letter = store.newsletter(id: newsletterID), !letter.isRead {
            letter.isRead = true
        }
        store.save()
    }

    static func preview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > bodyPreviewLength ? String(trimmed.prefix(bodyPreviewLength)) + "…" : trimmed
    }

    private func dismissSheets() {
        router.isSettingsPresented = false
        router.isNotificationInboxPresented = false
    }

    fileprivate func handleResponse(action: String, eventID: String?, replyItemID: String?, text: String?) async {
        if let replyItemID {
            if action != UNNotificationDismissActionIdentifier { openReplyItem(id: replyItemID) }
            return
        }
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
        let userInfo = response.notification.request.content.userInfo
        let eventID = userInfo["eventID"] as? String
        let replyItemID = userInfo["replyItemID"] as? String
        let text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            await self.handleResponse(action: action, eventID: eventID, replyItemID: replyItemID, text: text)
            completionHandler()
        }
    }
}

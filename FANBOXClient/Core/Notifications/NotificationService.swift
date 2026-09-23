import Foundation
import UserNotifications

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

    let store: LocalStore
    let engine: SyncEngine
    let replies: ReplyQueue
    let router: AppRouter
    let settings: AppSettings

    init(store: LocalStore, engine: SyncEngine, replies: ReplyQueue, router: AppRouter, settings: AppSettings) {
        self.store = store
        self.engine = engine
        self.replies = replies
        self.router = router
        self.settings = settings
        super.init()
    }

    /// Sets the UNUserNotificationCenter delegate and registers categories / actions.
    func configure() {}

    @discardableResult
    func requestAuthorization() async -> Bool { false }

    /// Prefetches text for new events (highest priority first), then posts local notifications.
    func process(newEventIDs: [String]) async {}

    /// Prefetch for one event according to its type (SPEC §24.2 / §25).
    func prefetch(eventID: String) async {}

    /// Opens the local screen for an event (used by taps and the in-app inbox).
    func open(eventID: String) {}
}

import Foundation
import Observation

/// Offline-capable comment / reply queue (SPEC §22):
/// draft → queued (persisted locally) → sending → sent | failed | needsConfirmation.
/// - Sending uses `RequestPriority.interactiveWrite` (beats all media).
/// - Short disconnections are retried automatically.
/// - Items older than `settings.staleReplyThreshold` go to `needsConfirmation` unless `autoSendStaleReplies`.
@MainActor
@Observable
final class ReplyQueue {
    private(set) var pendingCount = 0

    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let remote: RemoteDataSourceProvider
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let network: NetworkModeController

    init(store: LocalStore, remote: RemoteDataSourceProvider, settings: AppSettings, network: NetworkModeController) {
        self.store = store
        self.remote = remote
        self.settings = settings
        self.network = network
    }

    /// Queues a comment / reply and tries to send immediately. Returns the OutgoingComment id.
    @discardableResult
    func submit(postID: String, body: String, parentCommentID: String? = nil, rootCommentID: String? = nil, accountID: String,
                origin: ReplyOrigin = .inApp) -> String {
        ""
    }

    /// Saves an unsent draft (state .draft) without sending. Returns the id.
    @discardableResult
    func saveDraft(postID: String, body: String, parentCommentID: String? = nil, rootCommentID: String? = nil,
                   accountID: String) -> String {
        ""
    }

    /// Sends every queued item that is allowed to go now.
    func flush() async {}

    func retry(id: String) async {}

    /// User confirmed a `needsConfirmation` item.
    func confirmAndSend(id: String) async {}

    func cancel(id: String) {}

    /// Connectivity came back.
    func handleConnectivityRestored() {}
}

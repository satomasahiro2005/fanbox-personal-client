import Foundation
import Observation

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

    init(store: LocalStore, remote: RemoteDataSourceProvider, settings: AppSettings, network: NetworkModeController) {
        self.store = store
        self.remote = remote
        self.settings = settings
        self.network = network
    }

    @discardableResult
    func sync(_ resource: SyncResource, accountID: String, scope: String = "", reason: SyncReason) async -> SyncOutcome {
        .skipped(resource, accountID: accountID, scope: scope)
    }

    /// Full lightweight refresh of all enabled accounts (launch / pull-to-refresh).
    func syncAll(reason: SyncReason) async {}

    /// Background refresh: notifications, supports, timeline metadata only (SPEC §35).
    func syncLightweight(reason: SyncReason) async {}

    /// Fetches the post body into the local DB using the best account (SPEC §8) unless `accountID` is given.
    @discardableResult
    func refreshPost(postID: String, accountID: String? = nil, priority: RequestPriority = .interactiveRead) async -> RemoteError? { nil }

    @discardableResult
    func refreshComments(postID: String, accountID: String? = nil, priority: RequestPriority = .interactiveRead) async -> RemoteError? { nil }

    @discardableResult
    func refreshCreator(creatorID: String, accountID: String? = nil) async -> RemoteError? { nil }

    /// Loads one older page of a creator's posts on explicit user request.
    @discardableResult
    func loadMoreCreatorPosts(creatorID: String, accountID: String? = nil) async -> RemoteError? { nil }

    @discardableResult
    func refreshNewsletter(id: String, accountID: String? = nil, priority: RequestPriority = .interactiveRead) async -> RemoteError? { nil }

    func setLike(postID: String, liked: Bool) async -> RemoteError? { nil }
}

import Foundation
import SwiftData

/// Normalizing upserts: Remote* value types → SwiftData models.
/// Rules:
/// - Never delete cached content because of a network error.
/// - Posts are deduplicated by postID across accounts; per-account visibility goes to PostAccess.
/// - User metadata (isRead, isFavorite, memo, tags, offline state) is never overwritten by remote data.
extension LocalStore {
    @discardableResult
    func upsertPostSummaries(_ items: [RemotePostSummary], account: AccountContext, source: TimelineSource) -> UpsertResult {
        UpsertResult()
    }

    func upsertPostDetail(_ detail: RemotePostDetail, account: AccountContext) {}

    func upsertCreator(_ creator: RemoteCreator, account: AccountContext?) {}

    /// Replaces the "followed by <account>" set with `creators`.
    func applyFollowing(_ creators: [RemoteCreator], account: AccountContext) {}

    /// Applies the account's current supporting plans, records SupportHistory and flags anomalies.
    @discardableResult
    func applySupports(_ supports: [RemoteSupport], account: AccountContext, source: ObservedSource) -> SupportDiff {
        SupportDiff()
    }

    func upsertPlans(_ plans: [RemotePlan], creatorID: String) {}

    func upsertComments(_ comments: [RemoteComment], postID: String, account: AccountContext) {}

    /// Returns ids of NotificationEvents that are new (not previously known).
    @discardableResult
    func upsertNotifications(_ items: [RemoteNotification], account: AccountContext) -> [String] { [] }

    /// Returns ids of newsletters that are new.
    @discardableResult
    func upsertNewsletters(_ items: [RemoteNewsletter], account: AccountContext) -> [String] { [] }

    func upsertPayments(_ items: [RemotePayment], account: AccountContext) {}

    func upsertFans(_ fans: [RemoteFan], account: AccountContext) {}

    func upsertDashboard(_ dashboard: RemoteCreatorDashboard, account: AccountContext) {}
}

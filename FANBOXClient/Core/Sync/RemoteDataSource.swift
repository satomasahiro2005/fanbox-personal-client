import Foundation

/// Remote side of the Repository layer (SPEC §43). Implemented by `FanboxRemoteDataSource` (FANBOX API via `FanboxAdapter`)
/// and by `DemoRemoteDataSource` (offline fixtures). SwiftUI never calls this directly; it goes through use cases / sync.
///
/// `cursor` values are opaque strings produced by the implementation. Lists are ordered newest -> oldest.
protocol RemoteDataSource: Sendable {
    // MARK: Session
    func currentUser(account: AccountContext) async throws -> RemoteUser

    // MARK: Reader
    func homeTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary>
    func supportingTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary>
    func creatorPosts(creatorID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary>
    func post(id: String, account: AccountContext) async throws -> RemotePostDetail
    func creator(id: String, account: AccountContext) async throws -> RemoteCreator
    func followingCreators(account: AccountContext) async throws -> [RemoteCreator]
    func supportingPlans(account: AccountContext) async throws -> [RemoteSupport]
    func creatorPlans(creatorID: String, account: AccountContext) async throws -> [RemotePlan]
    func setLike(postID: String, liked: Bool, account: AccountContext) async throws

    // MARK: Comments
    func comments(postID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment>
    func addComment(postID: String, body: String, parentCommentID: String?, rootCommentID: String?,
                    account: AccountContext) async throws -> RemoteComment
    func deleteComment(commentID: String, postID: String, account: AccountContext) async throws

    // MARK: Notifications / おたより / payments
    func notifications(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteNotification>
    func newsletters(account: AccountContext) async throws -> [RemoteNewsletter]
    func newsletter(id: String, account: AccountContext) async throws -> RemoteNewsletter
    func paidRecords(account: AccountContext) async throws -> [RemotePayment]

    // MARK: Creator Mode (account must own a creator page)
    func managedPosts(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary>
    func editablePost(id: String, account: AccountContext) async throws -> RemoteEditablePost
    func createPost(_ draft: RemotePostDraft, account: AccountContext) async throws -> String
    func updatePost(id: String, _ draft: RemotePostDraft, account: AccountContext) async throws
    func uploadImage(fileURL: URL, account: AccountContext,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult
    func uploadFile(fileURL: URL, account: AccountContext,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult
    func fans(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteFan>
    func creatorDashboard(account: AccountContext) async throws -> RemoteCreatorDashboard
    /// Comments on posts of the account's own creator page (newest first).
    func creatorComments(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment>

    // MARK: Optional signals (default implementations below; see the extension)
    func unreadNotificationCount(account: AccountContext) async throws -> Int?
    func paymentStatus(account: AccountContext) async throws -> RemotePaymentStatus?
    func supportingPlanListing(account: AccountContext) async throws -> RemoteSupportListing
    func notificationBatch(account: AccountContext, cursor: String?) async throws -> RemoteNotificationBatch
    func postMetadata(id: String, account: AccountContext) async throws -> RemotePostSummary
}

/// Chooses the remote implementation per account kind.
protocol RemoteDataSourceProvider: Sendable {
    func dataSource(for account: AccountContext) -> RemoteDataSource
}

// MARK: - Optional sync signals (default implementations keep every conformer compiling)

/// A supporting-plan listing together with a completeness verdict. `problem` is non-nil when the response could not be
/// read completely (unknown shape, `null` list, undecodable or id-less items). An incomplete listing must never be used to
/// mark supports as disappeared: a decoding artifact is not an observed fact (SPEC §15).
struct RemoteSupportListing: Sendable, Equatable {
    var supports: [RemoteSupport]
    var problem: String?

    init(supports: [RemoteSupport], problem: String? = nil) {
        self.supports = supports
        self.problem = problem
    }

    var isComplete: Bool { problem == nil }
}

/// Observed payment signals of one account (docs/API.md §2.14 `hasUnpaidPayments`, §12.2 `payment.listUnpaid`).
/// Observed values only: they never prove that a payment failed (SPEC §15).
struct RemotePaymentStatus: Sendable, Equatable {
    /// Page metadata flag; nil when it could not be read.
    var hasUnpaidPayments: Bool?
    /// Outstanding payment records; nil when the list was not fetched or could not be read.
    var unpaidRecords: [RemotePayment]?

    init(hasUnpaidPayments: Bool?, unpaidRecords: [RemotePayment]? = nil) {
        self.hasUnpaidPayments = hasUnpaidPayments
        self.unpaidRecords = unpaidRecords
    }

    /// true / false when at least one signal was read; nil when nothing is known.
    var indicatesUnpaid: Bool? {
        if let records = unpaidRecords, !records.isEmpty { return true }
        if let flag = hasUnpaidPayments { return flag }
        if unpaidRecords != nil { return false }
        return nil
    }
}

/// One notification page plus the post summaries embedded in its items (bell `post`, docs/API.md §2.11), so a new-post
/// notification can render title / excerpt / cover locally even when the detail endpoint is unavailable.
struct RemoteNotificationBatch: Sendable {
    var page: RemotePage<RemoteNotification>
    var posts: [RemotePostSummary]

    init(page: RemotePage<RemoteNotification>, posts: [RemotePostSummary] = []) {
        self.page = page
        self.posts = posts
    }
}

extension RemoteDataSource {
    /// Cheap "anything new?" probe (bell.countUnread). nil = not available; callers then list notifications directly.
    func unreadNotificationCount(account: AccountContext) async throws -> Int? { nil }

    /// Payment-attention signals. nil = not available for this source.
    func paymentStatus(account: AccountContext) async throws -> RemotePaymentStatus? { nil }

    /// Supporting plans with a completeness verdict. Default: the plain listing, assumed complete.
    func supportingPlanListing(account: AccountContext) async throws -> RemoteSupportListing {
        RemoteSupportListing(supports: try await supportingPlans(account: account))
    }

    /// Notifications plus embedded post summaries. Default: the plain page without posts.
    func notificationBatch(account: AccountContext, cursor: String?) async throws -> RemoteNotificationBatch {
        RemoteNotificationBatch(page: try await notifications(account: account, cursor: cursor))
    }

    /// Post metadata without the body (fallback when the detail endpoint is blocked). Default: unsupported.
    func postMetadata(id: String, account: AccountContext) async throws -> RemotePostSummary {
        throw RemoteError.unsupported(operation: "postMetadata")
    }
}

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
}

/// Chooses the remote implementation per account kind.
protocol RemoteDataSourceProvider: Sendable {
    func dataSource(for account: AccountContext) -> RemoteDataSource
}

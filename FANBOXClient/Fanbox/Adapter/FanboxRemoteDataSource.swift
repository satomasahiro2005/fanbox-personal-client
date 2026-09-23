import Foundation

/// `RemoteDataSource` backed by the FANBOX API. Maps DTO → Remote* (SPEC §43: API changes are absorbed here and in DTO).
struct FanboxRemoteDataSource: RemoteDataSource {
    let api: FanboxAPIClient

    init(api: FanboxAPIClient) {
        self.api = api
    }

    func currentUser(account: AccountContext) async throws -> RemoteUser { throw RemoteError.unsupported(operation: "currentUser") }
    func homeTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { RemotePage(items: []) }
    func supportingTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { RemotePage(items: []) }
    func creatorPosts(creatorID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        RemotePage(items: [])
    }
    func post(id: String, account: AccountContext) async throws -> RemotePostDetail { throw RemoteError.notFound }
    func creator(id: String, account: AccountContext) async throws -> RemoteCreator { throw RemoteError.notFound }
    func followingCreators(account: AccountContext) async throws -> [RemoteCreator] { [] }
    func supportingPlans(account: AccountContext) async throws -> [RemoteSupport] { [] }
    func creatorPlans(creatorID: String, account: AccountContext) async throws -> [RemotePlan] { [] }
    func setLike(postID: String, liked: Bool, account: AccountContext) async throws {}
    func comments(postID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> { RemotePage(items: []) }
    func addComment(postID: String, body: String, parentCommentID: String?, rootCommentID: String?,
                    account: AccountContext) async throws -> RemoteComment {
        throw RemoteError.unsupported(operation: "addComment")
    }
    func deleteComment(commentID: String, postID: String, account: AccountContext) async throws {}
    func notifications(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteNotification> { RemotePage(items: []) }
    func newsletters(account: AccountContext) async throws -> [RemoteNewsletter] { [] }
    func newsletter(id: String, account: AccountContext) async throws -> RemoteNewsletter { throw RemoteError.notFound }
    func paidRecords(account: AccountContext) async throws -> [RemotePayment] { [] }
    func managedPosts(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { RemotePage(items: []) }
    func editablePost(id: String, account: AccountContext) async throws -> RemoteEditablePost { throw RemoteError.notFound }
    func createPost(_ draft: RemotePostDraft, account: AccountContext) async throws -> String { throw RemoteError.unsupported(operation: "createPost") }
    func updatePost(id: String, _ draft: RemotePostDraft, account: AccountContext) async throws {
        throw RemoteError.unsupported(operation: "updatePost")
    }
    func uploadImage(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        throw RemoteError.unsupported(operation: "uploadImage")
    }
    func uploadFile(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        throw RemoteError.unsupported(operation: "uploadFile")
    }
    func fans(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteFan> { RemotePage(items: []) }
    func creatorDashboard(account: AccountContext) async throws -> RemoteCreatorDashboard {
        RemoteCreatorDashboard(month: SupportAnalyzer.monthKey(.now))
    }
    func creatorComments(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> { RemotePage(items: []) }
}

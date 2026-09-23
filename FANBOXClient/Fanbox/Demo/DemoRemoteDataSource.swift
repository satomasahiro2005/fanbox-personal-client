import Foundation

/// Offline, deterministic fixture data for `AccountKind.demo` accounts (previews, tests, simulator UI checks).
/// Never touches the network. Content is synthetic and clearly labeled as demo.
struct DemoRemoteDataSource: RemoteDataSource {
    init() {}

    func currentUser(account: AccountContext) async throws -> RemoteUser {
        RemoteUser(pixivUserID: account.pixivUserID ?? "demo", fanboxUserID: nil, name: "Demo", iconURL: nil, creatorID: account.creatorID)
    }
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
        RemoteComment(id: UUID().uuidString, postID: postID, parentCommentID: parentCommentID, rootCommentID: rootCommentID,
                      authorUserID: account.pixivUserID ?? "demo", authorName: "Demo", body: body, createdAt: .now, isOwn: true)
    }
    func deleteComment(commentID: String, postID: String, account: AccountContext) async throws {}
    func notifications(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteNotification> { RemotePage(items: []) }
    func newsletters(account: AccountContext) async throws -> [RemoteNewsletter] { [] }
    func newsletter(id: String, account: AccountContext) async throws -> RemoteNewsletter { throw RemoteError.notFound }
    func paidRecords(account: AccountContext) async throws -> [RemotePayment] { [] }
    func managedPosts(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { RemotePage(items: []) }
    func editablePost(id: String, account: AccountContext) async throws -> RemoteEditablePost { throw RemoteError.notFound }
    func createPost(_ draft: RemotePostDraft, account: AccountContext) async throws -> String { UUID().uuidString }
    func updatePost(id: String, _ draft: RemotePostDraft, account: AccountContext) async throws {}
    func uploadImage(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        progress(1)
        return RemoteUploadResult(mediaID: UUID().uuidString, url: nil)
    }
    func uploadFile(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        progress(1)
        return RemoteUploadResult(mediaID: UUID().uuidString, url: nil)
    }
    func fans(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteFan> { RemotePage(items: []) }
    func creatorDashboard(account: AccountContext) async throws -> RemoteCreatorDashboard {
        RemoteCreatorDashboard(month: SupportAnalyzer.monthKey(.now))
    }
    func creatorComments(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> { RemotePage(items: []) }
}

/// Picks the demo or FANBOX data source per account kind.
struct DefaultRemoteDataSourceProvider: RemoteDataSourceProvider {
    let fanbox: FanboxRemoteDataSource
    let demo: DemoRemoteDataSource

    func dataSource(for account: AccountContext) -> RemoteDataSource {
        switch account.kind {
        case .fanbox: return fanbox
        case .demo: return demo
        }
    }
}

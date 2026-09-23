import Foundation
@testable import FANBOXClient

/// Remote fake for AccountService tests: only `currentUser` is meaningful; everything else is unsupported.
final class AuthMockRemote: RemoteDataSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _userResult: Result<RemoteUser, RemoteError>
    private var _currentUserCalls = 0

    init(user: Result<RemoteUser, RemoteError>) {
        _userResult = user
    }

    var userResult: Result<RemoteUser, RemoteError> {
        get { lock.withLock { _userResult } }
        set { lock.withLock { _userResult = newValue } }
    }

    var currentUserCalls: Int { lock.withLock { _currentUserCalls } }

    func currentUser(account: AccountContext) async throws -> RemoteUser {
        let result = lock.withLock { () -> Result<RemoteUser, RemoteError> in
            _currentUserCalls += 1
            return _userResult
        }
        return try result.get()
    }

    private func unsupported(_ name: String = #function) -> RemoteError { .unsupported(operation: name) }

    func homeTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { throw unsupported() }
    func supportingTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { throw unsupported() }
    func creatorPosts(creatorID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        throw unsupported()
    }
    func post(id: String, account: AccountContext) async throws -> RemotePostDetail { throw unsupported() }
    func creator(id: String, account: AccountContext) async throws -> RemoteCreator { throw unsupported() }
    func followingCreators(account: AccountContext) async throws -> [RemoteCreator] { throw unsupported() }
    func supportingPlans(account: AccountContext) async throws -> [RemoteSupport] { throw unsupported() }
    func creatorPlans(creatorID: String, account: AccountContext) async throws -> [RemotePlan] { throw unsupported() }
    func setLike(postID: String, liked: Bool, account: AccountContext) async throws { throw unsupported() }
    func comments(postID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> { throw unsupported() }
    func addComment(postID: String, body: String, parentCommentID: String?, rootCommentID: String?,
                    account: AccountContext) async throws -> RemoteComment { throw unsupported() }
    func deleteComment(commentID: String, postID: String, account: AccountContext) async throws { throw unsupported() }
    func notifications(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteNotification> { throw unsupported() }
    func newsletters(account: AccountContext) async throws -> [RemoteNewsletter] { throw unsupported() }
    func newsletter(id: String, account: AccountContext) async throws -> RemoteNewsletter { throw unsupported() }
    func paidRecords(account: AccountContext) async throws -> [RemotePayment] { throw unsupported() }
    func managedPosts(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { throw unsupported() }
    func editablePost(id: String, account: AccountContext) async throws -> RemoteEditablePost { throw unsupported() }
    func createPost(_ draft: RemotePostDraft, account: AccountContext) async throws -> String { throw unsupported() }
    func updatePost(id: String, _ draft: RemotePostDraft, account: AccountContext) async throws { throw unsupported() }
    func uploadImage(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        throw unsupported()
    }
    func uploadFile(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        throw unsupported()
    }
    func fans(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteFan> { throw unsupported() }
    func creatorDashboard(account: AccountContext) async throws -> RemoteCreatorDashboard { throw unsupported() }
    func creatorComments(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> { throw unsupported() }
}

/// Real FANBOX accounts use the mock; demo accounts keep the fixture data source.
struct AuthMockProvider: RemoteDataSourceProvider {
    let mock: AuthMockRemote
    let demo = DemoRemoteDataSource()

    func dataSource(for account: AccountContext) -> RemoteDataSource {
        account.kind == .demo ? demo : mock
    }
}

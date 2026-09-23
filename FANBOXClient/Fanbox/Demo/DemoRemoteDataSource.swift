import Foundation

/// Offline, deterministic fixture data for `AccountKind.demo` accounts (previews, tests, simulator UI checks).
/// Never touches the network. Content is synthetic and clearly labeled as demo.
///
/// Every call:
/// 1. throws `RemoteError.offline` when the network policy is Offline / has no path (so offline UX can be exercised),
/// 2. waits a deterministic per-call latency (~120–350 ms × `world.latencyScale`),
/// 3. forwards to the shared `DemoWorld` actor, which keeps session state (comments, likes, posts, uploads).
struct DemoRemoteDataSource: RemoteDataSource {
    /// When given, the demo source honors Offline mode (throws `.offline`) so offline UX can be exercised.
    let policy: NetworkPolicyStore?
    let world: DemoWorld

    init(policy: NetworkPolicyStore? = nil) {
        self.init(policy: policy, world: .shared)
    }

    /// Uses a specific world (tests: `DemoWorld(now: fixedDate, latencyScale: 0)`).
    init(policy: NetworkPolicyStore?, world: DemoWorld) {
        self.policy = policy
        self.world = world
    }

    // MARK: Session

    func currentUser(account: AccountContext) async throws -> RemoteUser {
        try await gate(.currentUser)
        return await world.currentUser(account: account)
    }

    // MARK: Reader

    func homeTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        try await gate(.timeline)
        return try await world.homeTimeline(account: account, cursor: cursor)
    }

    func supportingTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        try await gate(.timeline)
        return try await world.supportingTimeline(account: account, cursor: cursor)
    }

    func creatorPosts(creatorID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        try await gate(.creatorPosts)
        return try await world.creatorPosts(creatorID: creatorID, account: account, cursor: cursor)
    }

    func post(id: String, account: AccountContext) async throws -> RemotePostDetail {
        try await gate(.postDetail)
        return try await world.post(id: id, account: account)
    }

    func creator(id: String, account: AccountContext) async throws -> RemoteCreator {
        try await gate(.creator)
        return try await world.creator(id: id, account: account)
    }

    func followingCreators(account: AccountContext) async throws -> [RemoteCreator] {
        try await gate(.following)
        return await world.followingCreators(account: account)
    }

    func supportingPlans(account: AccountContext) async throws -> [RemoteSupport] {
        try await gate(.supports)
        return await world.supportingPlans(account: account)
    }

    func creatorPlans(creatorID: String, account: AccountContext) async throws -> [RemotePlan] {
        try await gate(.plans)
        return try await world.creatorPlans(creatorID: creatorID, account: account)
    }

    func setLike(postID: String, liked: Bool, account: AccountContext) async throws {
        try await gate(.like)
        try await world.setLike(postID: postID, liked: liked, account: account)
    }

    // MARK: Comments

    func comments(postID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> {
        try await gate(.comments)
        return try await world.comments(postID: postID, account: account, cursor: cursor)
    }

    func addComment(postID: String, body: String, parentCommentID: String?, rootCommentID: String?,
                    account: AccountContext) async throws -> RemoteComment {
        try await gate(.addComment)
        return try await world.addComment(postID: postID, body: body, parentCommentID: parentCommentID, rootCommentID: rootCommentID,
                                          account: account)
    }

    func deleteComment(commentID: String, postID: String, account: AccountContext) async throws {
        try await gate(.deleteComment)
        try await world.deleteComment(commentID: commentID, postID: postID, account: account)
    }

    // MARK: Notifications / おたより / payments

    func notifications(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteNotification> {
        try await gate(.notifications)
        return try await world.notifications(account: account, cursor: cursor)
    }

    func newsletters(account: AccountContext) async throws -> [RemoteNewsletter] {
        try await gate(.newsletters)
        return await world.newsletters(account: account)
    }

    func newsletter(id: String, account: AccountContext) async throws -> RemoteNewsletter {
        try await gate(.newsletter)
        return try await world.newsletter(id: id, account: account)
    }

    func paidRecords(account: AccountContext) async throws -> [RemotePayment] {
        try await gate(.payments)
        return await world.paidRecords(account: account)
    }

    // MARK: Creator Mode

    /// Every block natively, with FANBOX's create-first flow: uploads and link cards are stored into the post.
    var draftCapabilities: DraftCapabilities { .demo }

    func managedPosts(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        try await gate(.managedPosts)
        return try await world.managedPosts(account: account, cursor: cursor)
    }

    func editablePost(id: String, account: AccountContext) async throws -> RemoteEditablePost {
        try await gate(.editablePost)
        return try await world.editablePost(id: id, account: account)
    }

    func createPost(_ draft: RemotePostDraft, account: AccountContext) async throws -> String {
        try await gate(.writePost)
        return try await world.createPost(draft, account: account)
    }

    func updatePost(id: String, _ draft: RemotePostDraft, account: AccountContext) async throws {
        try await gate(.writePost)
        try await world.updatePost(id: id, draft, account: account)
    }

    func uploadImage(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        try await upload(fileURL: fileURL, kind: .image, postID: nil, account: account, progress: progress)
    }

    func uploadFile(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        try await upload(fileURL: fileURL, kind: .file, postID: nil, account: account, progress: progress)
    }

    func createEmptyPost(account: AccountContext) async throws -> String {
        try await gate(.writePost)
        return try await world.createEmptyPost(account: account)
    }

    func uploadImage(fileURL: URL, postID: String, account: AccountContext,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        try await upload(fileURL: fileURL, kind: .image, postID: postID, account: account, progress: progress)
    }

    func uploadFile(fileURL: URL, postID: String, account: AccountContext,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        try await upload(fileURL: fileURL, kind: .file, postID: postID, account: account, progress: progress)
    }

    func addURLEmbed(url: String, postID: String, account: AccountContext) async throws -> RemoteUploadResult {
        try await gate(.writePost)
        return try await world.addURLEmbed(url: url, postID: postID, account: account)
    }

    func fans(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteFan> {
        try await gate(.fans)
        return try await world.fans(account: account, cursor: cursor)
    }

    func creatorDashboard(account: AccountContext) async throws -> RemoteCreatorDashboard {
        try await gate(.dashboard)
        return try await world.creatorDashboard(account: account)
    }

    func creatorComments(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> {
        try await gate(.creatorComments)
        return try await world.creatorComments(account: account, cursor: cursor)
    }

    // MARK: - Simulation

    /// Simulated upload: ~1 s in 0.1 progress steps. Names containing "fail" always fail (at 40 %) so the Upload Queue's
    /// failed-job retry can be exercised; names containing "flaky" fail on the first attempt only. With a `postID` the
    /// post must be one of the self creator's (uploads are stored into it, as on FANBOX).
    private func upload(fileURL: URL, kind: UploadKind, postID: String?, account: AccountContext,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        try ensureOnline()
        guard await world.profile(for: account) == .creator else { throw RemoteError.forbidden }
        if let postID { try await world.requireOwnPost(postID, account: account) }
        let shouldFail = await world.registerUploadAttempt(fileName: fileURL.lastPathComponent)
        for step in 1...10 {
            try await pause(milliseconds: DemoCall.uploadStep.latencyMilliseconds)
            try ensureOnline()
            if shouldFail && step == 4 {
                throw RemoteError.invalidRequest("Demo: アップロードに失敗しました（\(fileURL.lastPathComponent)）")
            }
            progress(Double(step) / 10)
        }
        return await world.completeUpload(fileURL: fileURL, kind: kind, postID: postID)
    }

    private func gate(_ call: DemoCall) async throws {
        try ensureOnline()
        try await pause(milliseconds: call.latencyMilliseconds)
        try ensureOnline()
    }

    private func ensureOnline() throws {
        if let snapshot = policy?.current, snapshot.mode == .offline || !snapshot.pathSatisfied {
            throw RemoteError.offline
        }
    }

    private func pause(milliseconds: Int) async throws {
        let scaled = Double(milliseconds) * world.latencyScale
        do {
            if scaled > 0 {
                try await Task.sleep(nanoseconds: UInt64(scaled * 1_000_000))
            } else {
                try Task.checkCancellation()
            }
        } catch {
            throw RemoteError.cancelled
        }
    }
}

/// Call classes with a fixed simulated latency (deterministic, ~120–350 ms).
enum DemoCall: String, CaseIterable, Sendable {
    case currentUser, timeline, creatorPosts, postDetail, creator, following, supports, plans, like
    case comments, addComment, deleteComment, notifications, newsletters, newsletter, payments
    case managedPosts, editablePost, writePost, fans, dashboard, creatorComments, uploadStep

    var latencyMilliseconds: Int {
        switch self {
        case .currentUser: return 150
        case .timeline: return 280
        case .creatorPosts: return 240
        case .postDetail: return 200
        case .creator: return 160
        case .following: return 220
        case .supports: return 230
        case .plans: return 140
        case .like: return 120
        case .comments: return 180
        case .addComment: return 300
        case .deleteComment: return 210
        case .notifications: return 190
        case .newsletters: return 210
        case .newsletter: return 150
        case .payments: return 250
        case .managedPosts: return 270
        case .editablePost: return 220
        case .writePost: return 350
        case .fans: return 260
        case .dashboard: return 240
        case .creatorComments: return 230
        case .uploadStep: return 100
        }
    }
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

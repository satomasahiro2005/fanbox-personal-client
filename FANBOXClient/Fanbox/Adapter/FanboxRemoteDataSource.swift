import Foundation

/// Logged-in user plus the flags the page metadata carries (e.g. `hasUnpaidPayments` for paymentAttention, docs/API.md §18.8).
struct FanboxSessionSummary: Sendable, Hashable {
    var user: RemoteUser
    var isCreator: Bool
    var isSupporter: Bool?
    /// Observed flag only; never claim that a payment failed (SPEC §15).
    var hasUnpaidPayments: Bool?
    var planCount: Int?
}

/// `RemoteDataSource` backed by the FANBOX API. Maps DTO → Remote* (SPEC §43: API changes are absorbed here and in DTO).
///
/// - Request priority comes from the caller's task-local `RequestContext.priority` (read by `FanboxAPIClient`).
/// - Cursors are opaque `FanboxCursor` strings.
/// - Operations FANBOX does not offer through any documented endpoint throw `RemoteError.unsupported(operation:)`
///   so the UI can fall back to the account-aware WebView (SPEC §21 / §40). See docs/API.md for confidence levels.
struct FanboxRemoteDataSource: RemoteDataSource {
    let api: FanboxAPIClient
    let pageCache: FanboxPageURLCache
    /// Native creation / update of text-only article posts (post.create + post.update, docs/API.md §14.3–14.4).
    /// Turn off to force every post write through the web editor.
    let nativePostWritesEnabled: Bool

    static let timelinePageSize = 10
    static let commentPageSize = 20
    /// Creator comments: at most this many posts (with comments) are inspected per page.
    static let creatorCommentPostsPerPage = 10

    init(api: FanboxAPIClient) {
        self.init(api: api, pageCache: FanboxPageURLCache(), nativePostWritesEnabled: true)
    }

    init(api: FanboxAPIClient, pageCache: FanboxPageURLCache, nativePostWritesEnabled: Bool) {
        self.api = api
        self.pageCache = pageCache
        self.nativePostWritesEnabled = nativePostWritesEnabled
    }

    // MARK: - Session

    /// From the www.fanbox.cc page metadata (no JSON endpoint returns the current user). Also refreshes the account's
    /// CSRF token when `FanboxAPIClient.credentials` is wired.
    func currentUser(account: AccountContext) async throws -> RemoteUser {
        let metadata = try await api.fetchMetadata(accountID: account.accountID)
        return try FanboxAdapter.user(metadata)
    }

    // MARK: - Reader

    func homeTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        try await nextURLTimeline(first: .listHome(limit: Self.timelinePageSize), path: "/post.listHome", account: account, cursor: cursor)
    }

    func supportingTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        try await nextURLTimeline(first: .listSupporting(limit: Self.timelinePageSize), path: "/post.listSupporting", account: account, cursor: cursor)
    }

    private func nextURLTimeline(first: FanboxEndpoint, path: String, account: AccountContext,
                                 cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        var endpoint = first
        if let cursor {
            guard case .nextURL(let url)? = FanboxCursor(encoded: cursor),
                  let next = FanboxEndpoint.followURL(url, key: first.key, expectedPath: path) else {
                throw RemoteError.invalidRequest("カーソルが不正です")
            }
            endpoint = next
        }
        let body = try await api.send(endpoint, as: FanboxPostListBody.self, accountID: account.accountID)
        return RemotePage(items: FanboxAdapter.postSummaries(body.items), nextCursor: body.nextUrl.map { FanboxCursor.nextURL($0).encoded })
    }

    /// paginateCreator → pageUrls[i] → post.listCreator. The first page always refetches the page list.
    func creatorPosts(creatorID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        let index: Int
        var pageURL: String?
        if let cursor {
            guard case .creatorPage(let i, let url)? = FanboxCursor(encoded: cursor) else { throw RemoteError.invalidRequest("カーソルが不正です") }
            index = i
            pageURL = url
        } else {
            index = 0
        }
        let cacheKey = account.accountID + "|" + creatorID
        var urls = index == 0 ? nil : await pageCache.urls(for: cacheKey)
        if urls == nil || index == 0 {
            let pages = try await api.send(.paginateCreator(creatorID: creatorID), as: FanboxPaginateCreatorBody.self, accountID: account.accountID)
            urls = pages.pageUrls
            await pageCache.store(pages.pageUrls, for: cacheKey)
        }
        let allURLs = urls ?? []
        if index == 0 { pageURL = allURLs.first }
        guard let pageURL else { return RemotePage(items: []) }
        guard let endpoint = FanboxEndpoint.followURL(pageURL, key: "post.listCreator", expectedPath: "/post.listCreator") else {
            throw RemoteError.decoding(endpoint: "post.paginateCreator", detail: "想定外のページ URL")
        }
        let body = try await api.send(endpoint, as: FanboxCreatorPostListBody.self, accountID: account.accountID)
        let items = FanboxAdapter.postSummaries(body.items, fallbackCreatorID: creatorID)
        let nextIndex = index + 1
        let next = allURLs.indices.contains(nextIndex) ? FanboxCursor.creatorPage(index: nextIndex, url: allURLs[nextIndex]).encoded : nil
        return RemotePage(items: items, nextCursor: next)
    }

    func post(id: String, account: AccountContext) async throws -> RemotePostDetail {
        let body = try await api.send(.postInfo(postID: id), as: FanboxPostInfoBody.self, accountID: account.accountID)
        guard let detail = FanboxAdapter.postDetail(body.post) else {
            throw RemoteError.decoding(endpoint: "post.info", detail: "id がありません")
        }
        return detail
    }

    func creator(id: String, account: AccountContext) async throws -> RemoteCreator {
        let body = try await api.send(.creatorGet(creatorID: id), as: FanboxCreatorBody.self, accountID: account.accountID)
        guard let creator = FanboxAdapter.creator(body.creator) else { throw RemoteError.notFound }
        return creator
    }

    func followingCreators(account: AccountContext) async throws -> [RemoteCreator] {
        let body = try await api.send(.listFollowing(), as: FanboxCreatorListBody.self, accountID: account.accountID)
        return body.items.compactMap(FanboxAdapter.creator)
    }

    func supportingPlans(account: AccountContext) async throws -> [RemoteSupport] {
        let body = try await api.send(.planListSupporting(), as: FanboxPlanListBody.self, accountID: account.accountID)
        return body.items.compactMap(FanboxAdapter.support)
    }

    func creatorPlans(creatorID: String, account: AccountContext) async throws -> [RemotePlan] {
        let body = try await api.send(.planListCreator(creatorID: creatorID), as: FanboxPlanListBody.self, accountID: account.accountID)
        return FanboxAdapter.plans(body.items, fallbackCreatorID: creatorID)
    }

    /// Like only: FANBOX has no unlike endpoint (docs/API.md §6.3), so `liked == false` is unsupported.
    func setLike(postID: String, liked: Bool, account: AccountContext) async throws {
        guard liked else { throw RemoteError.unsupported(operation: "post.unlike") }
        try await api.perform(.likePost(postID: postID), accountID: account.accountID)
    }

    // MARK: - Comments

    func comments(postID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> {
        var offset = 0
        if let cursor {
            guard case .offset(let o)? = FanboxCursor(encoded: cursor) else { throw RemoteError.invalidRequest("カーソルが不正です") }
            offset = o
        }
        let body = try await api.send(.getComments(postID: postID, offset: offset, limit: Self.commentPageSize), as: FanboxCommentListBody.self,
                                      accountID: account.accountID)
        let comments = FanboxAdapter.comments(body.items, postID: postID)
        var next: String?
        if let nextURL = body.nextUrl {
            let nextOffset = FanboxCursor.queryValue("offset", in: nextURL).flatMap(Int.init) ?? offset + max(body.items.count, 1)
            if nextOffset > offset { next = FanboxCursor.offset(nextOffset).encoded }
        }
        return RemotePage(items: comments, nextCursor: next)
    }

    /// post.addComment returns no documented body. After a successful POST this never throws for the lookup:
    /// it re-reads the first comment page and returns the matching own comment; if that fails, a provisional comment whose
    /// id starts with "pending:" is returned (the caller should refresh comments; the send itself succeeded).
    func addComment(postID: String, body: String, parentCommentID: String?, rootCommentID: String?,
                    account: AccountContext) async throws -> RemoteComment {
        let started = Date()
        let parent = parentCommentID ?? rootCommentID
        let root = rootCommentID ?? parentCommentID
        let response = try await api.perform(.addComment(postID: postID, body: body, rootCommentID: root, parentCommentID: parent),
                                             accountID: account.accountID)
        // Tolerant: use a returned comment if FANBOX ever includes one.
        if let json = response, let dto = Self.commentDTO(from: json), var comment = FanboxAdapter.comment(dto, postID: postID) {
            comment.isOwn = true
            return comment
        }
        if let page = try? await comments(postID: postID, account: account, cursor: nil),
           let found = FanboxAdapter.findPostedComment(in: page.items, body: body, parentCommentID: parent, notBefore: started) {
            return found
        }
        return RemoteComment(id: "pending:" + UUID().uuidString, postID: postID, parentCommentID: parent, rootCommentID: root,
                             authorUserID: account.pixivUserID ?? "", authorName: "", body: body, createdAt: started, isOwn: true)
    }

    func deleteComment(commentID: String, postID: String, account: AccountContext) async throws {
        try await api.perform(.deleteComment(commentID: commentID), accountID: account.accountID)
    }

    // MARK: - Notifications / おたより / payments

    /// bell.list with `skipConvertUnreadNotification=1`: listing never marks notifications read on FANBOX.
    func notifications(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteNotification> {
        var page = 1
        if let cursor {
            guard case .page(let p)? = FanboxCursor(encoded: cursor) else { throw RemoteError.invalidRequest("カーソルが不正です") }
            page = p
        }
        let body = try await api.send(.bellList(page: page), as: FanboxBellListBody.self, accountID: account.accountID)
        let items = body.items.compactMap(FanboxAdapter.notification)
        var next: String?
        if let nextURL = body.nextUrl {
            let nextPage = FanboxCursor.queryValue("page", in: nextURL).flatMap(Int.init) ?? page + 1
            if nextPage > page { next = FanboxCursor.page(nextPage).encoded }
        }
        return RemotePage(items: items, nextCursor: next)
    }

    func newsletters(account: AccountContext) async throws -> [RemoteNewsletter] {
        let body = try await api.send(.newsletterList(), as: FanboxNewsletterListBody.self, accountID: account.accountID)
        return body.items.compactMap(FanboxAdapter.newsletter).sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }

    /// No single-newsletter endpoint exists; the list is fetched and filtered.
    func newsletter(id: String, account: AccountContext) async throws -> RemoteNewsletter {
        guard let item = try await newsletters(account: account).first(where: { $0.id == id }) else { throw RemoteError.notFound }
        return item
    }

    func paidRecords(account: AccountContext) async throws -> [RemotePayment] {
        let body = try await api.send(.paymentListPaid(), as: FanboxPaymentListBody.self, accountID: account.accountID)
        return FanboxAdapter.payments(body.items)
    }

    // MARK: - Creator Mode

    /// post.listManaged returns the whole list at once (no paging); a non-nil cursor yields an empty page.
    func managedPosts(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        guard cursor == nil else { return RemotePage(items: []) }
        let creatorID = try requireCreator(account)
        let body = try await api.send(.listManaged(), as: FanboxManagedPostListBody.self, accountID: account.accountID)
        // Best effort: name / icon of the own creator page for the summaries.
        let me = try? await creator(id: creatorID, account: account)
        return RemotePage(items: FanboxAdapter.managedPostSummaries(body.items, creatorID: creatorID, creatorName: me?.name, creatorIconURL: me?.iconURL))
    }

    func editablePost(id: String, account: AccountContext) async throws -> RemoteEditablePost {
        let body = try await api.send(.getEditable(postID: id), as: FanboxEditablePostBody.self, accountID: account.accountID)
        guard let post = FanboxAdapter.editablePost(body.post) else { throw RemoteError.notFound }
        return post
    }

    /// post.create (empty article draft) + post.update (title / text / fee / status). Drafts that need uploads or new
    /// embeds throw `.unsupported` BEFORE anything is created on FANBOX.
    func createPost(_ draft: RemotePostDraft, account: AccountContext) async throws -> String {
        guard nativePostWritesEnabled else { throw RemoteError.unsupported(operation: "createPost") }
        _ = try requireCreator(account)
        try FanboxPostUpdateForm.validateForCreate(draft)
        guard let token = try await api.csrfToken(accountID: account.accountID) else { throw RemoteError.unauthorized }
        let created = try await api.send(.postCreate(type: "article"), as: FanboxPostCreateBody.self, accountID: account.accountID)
        guard let postID = created.postId else { throw RemoteError.decoding(endpoint: "post.create", detail: "postId がありません") }
        do {
            try await sendUpdate(postID: postID, draft: draft, token: token, existing: FanboxPostUpdateForm.ExistingMedia(), account: account)
        } catch {
            // The empty draft exists on FANBOX; never delete it automatically (the update may have been applied).
            AppLog.creator.error("post.update after post.create failed")
            throw RemoteError.invalidRequest("FANBOX に空の下書き (ID: \(postID)) を作成しましたが、本文の保存に失敗しました。Web で確認してください")
        }
        return postID
    }

    /// Re-reads the editable post (ownership + existing media) and saves the draft with post.update.
    func updatePost(id: String, _ draft: RemotePostDraft, account: AccountContext) async throws {
        guard nativePostWritesEnabled else { throw RemoteError.unsupported(operation: "updatePost") }
        _ = try requireCreator(account)
        let editable = try await api.send(.getEditable(postID: id), as: FanboxEditablePostBody.self, accountID: account.accountID)
        let existing = FanboxPostUpdateForm.ExistingMedia(editable: editable.post)
        _ = try FanboxPostUpdateForm.blocksJSON(draft.blocks, existing: existing)
        guard let token = try await api.csrfToken(accountID: account.accountID) else { throw RemoteError.unauthorized }
        try await sendUpdate(postID: id, draft: draft, token: token, existing: existing, account: account)
    }

    private func sendUpdate(postID: String, draft: RemotePostDraft, token: String, existing: FanboxPostUpdateForm.ExistingMedia,
                            account: AccountContext) async throws {
        let form = try FanboxPostUpdateForm.make(postID: postID, draft: draft, csrfToken: token, existing: existing)
        let response = try await api.sendMultipart(.postUpdate(), form: form, accountID: account.accountID)
        if let json = try? JSONValue.parse(response.data), let code = json["error"]?.stringValue, json["body"] == nil {
            throw FanboxResponseHandling.mapErrorCode(code, statusCode: response.statusCode)
        }
    }

    /// The upload endpoint is unknown (docs/API.md §15): uploads run in the web editor.
    func uploadImage(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        throw RemoteError.unsupported(operation: "uploadImage")
    }

    func uploadFile(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        throw RemoteError.unsupported(operation: "uploadFile")
    }

    /// relationship.listFans?status=supporter (whole list, no paging) + plan titles from plan.listCreator.
    func fans(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteFan> {
        guard cursor == nil else { return RemotePage(items: []) }
        let creatorID = try requireCreator(account)
        let body = try await api.send(.listFans(status: "supporter"), as: FanboxFanListBody.self, accountID: account.accountID)
        var plansByID: [String: RemotePlan] = [:]
        if let plans = try? await creatorPlans(creatorID: creatorID, account: account) {
            for plan in plans { plansByID[plan.planID] = plan }
        }
        let fans = body.items.compactMap { FanboxAdapter.fan($0, plans: plansByID) }
            .sorted { ($0.supportStartedAt ?? .distantPast, $0.userID) > ($1.supportStartedAt ?? .distantPast, $1.userID) }
        return RemotePage(items: fans)
    }

    /// Only values FANBOX provides (SPEC §17): supporters (relationship.listFilterOptions), support received this month
    /// (legacy/manage/pledge/monthly) and posts published this month (post.listManaged). `commentCount` has no reliable
    /// source and stays nil. A failing source leaves its metric nil; if every source fails the first error is thrown.
    func creatorDashboard(account: AccountContext) async throws -> RemoteCreatorDashboard {
        _ = try requireCreator(account)
        let month = FanboxDateParser.monthKey(.now)
        var dashboard = RemoteCreatorDashboard(month: month)
        var firstError: Error?
        var succeeded = 0

        do {
            let options = try await api.send(.listFanFilterOptions(), as: FanboxFanFilterOptionListBody.self, accountID: account.accountID)
            dashboard.supporterCount = FanboxAdapter.supporterCount(options.items)
            succeeded += 1
        } catch {
            firstError = firstError ?? error
        }
        do {
            let pledges = try await api.send(.pledgeMonthly(month: month), as: FanboxPledgeMonthlyBody.self, accountID: account.accountID)
            dashboard.earnings = FanboxAdapter.earnings(pledges, month: month)
            succeeded += 1
        } catch {
            firstError = firstError ?? error
        }
        do {
            let posts = try await api.send(.listManaged(), as: FanboxManagedPostListBody.self, accountID: account.accountID)
            dashboard.postCount = FanboxAdapter.publishedPostCount(posts.items, month: month)
            succeeded += 1
        } catch {
            firstError = firstError ?? error
        }
        if succeeded == 0, let firstError { throw FanboxAPIClient.normalize(firstError) }
        return dashboard
    }

    /// Comments on the own creator page: the creator's post pages (paginateCreator / listCreator) → post.getComments for
    /// posts with `commentCount > 0` (first comment page each). Newest root comments first.
    func creatorComments(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> {
        let creatorID = try requireCreator(account)
        var postCursor: String?
        if let cursor {
            guard case .creatorPage? = FanboxCursor(encoded: cursor) else { throw RemoteError.invalidRequest("カーソルが不正です") }
            postCursor = cursor
        }
        let posts = try await creatorPosts(creatorID: creatorID, account: account, cursor: postCursor)
        var all: [RemoteComment] = []
        for post in posts.items.filter({ $0.commentCount > 0 }).prefix(Self.creatorCommentPostsPerPage) {
            try Task.checkCancellation()
            do {
                let page = try await comments(postID: post.id, account: account, cursor: nil)
                all += page.items
            } catch let error as RemoteError where error == .unauthorized || error == .cancelled {
                throw error
            } catch {
                // One inaccessible post must not hide the other posts' comments.
                continue
            }
        }
        all.sort { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
        return RemotePage(items: all, nextCursor: posts.nextCursor)
    }

    // MARK: - Extra reads (not part of RemoteDataSource; available to other modules via FanboxRemoteDataSource)

    /// The viewer's support details for one creator (plan, support start, transactions) — legacy/support/creator.
    func supportDetail(creatorID: String, account: AccountContext) async throws -> FanboxSupportCreatorBody {
        try await api.send(.supportCreator(creatorID: creatorID), as: FanboxSupportCreatorBody.self, accountID: account.accountID)
    }

    /// Outstanding payments (payment.listUnpaid, medium confidence).
    func unpaidRecords(account: AccountContext) async throws -> [RemotePayment] {
        let body = try await api.send(.paymentListUnpaid(), as: FanboxPaymentListBody.self, accountID: account.accountID)
        return FanboxAdapter.payments(body.items)
    }

    /// Unread bell count (cheap session probe, docs/API.md §4.2).
    func unreadNotificationCount(account: AccountContext) async throws -> Int? {
        try await api.send(.bellCountUnread(), as: FanboxCountBody.self, accountID: account.accountID).count
    }

    /// Post metadata without content (post.get, medium confidence). Useful when post.info is blocked for the native
    /// transport: the summary still updates while the body stays as cached.
    func postMetadata(id: String, account: AccountContext) async throws -> RemotePostSummary {
        let body = try await api.send(.postGet(postID: id), as: FanboxPostInfoBody.self, accountID: account.accountID)
        guard let detail = FanboxAdapter.postDetail(body.post) else { throw RemoteError.notFound }
        var summary = detail.summary
        // post.get never carries the content, so "no body" does not mean restricted here.
        summary.isRestricted = body.post.isRestricted ?? false
        return summary
    }

    /// Posts with a tag (post.listTagged, medium confidence). User-initiated only; never used by background sync.
    func taggedPosts(tag: String, creatorID: String?, account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> {
        var endpoint = FanboxEndpoint.listTagged(tag: tag, creatorID: creatorID, page: 0)
        if let cursor {
            guard case .nextURL(let url)? = FanboxCursor(encoded: cursor),
                  let next = FanboxEndpoint.followURL(url, key: endpoint.key, expectedPath: "/post.listTagged") else {
                throw RemoteError.invalidRequest("カーソルが不正です")
            }
            endpoint = next
        }
        let body = try await api.send(endpoint, as: FanboxPostListBody.self, accountID: account.accountID)
        return RemotePage(items: FanboxAdapter.postSummaries(body.items, fallbackCreatorID: creatorID),
                          nextCursor: body.nextUrl.map { FanboxCursor.nextURL($0).encoded })
    }

    /// Creator search (creator.search, 0-based pages).
    func searchCreators(query: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteCreator> {
        var page = 0
        if let cursor {
            guard case .page(let p)? = FanboxCursor(encoded: cursor) else { throw RemoteError.invalidRequest("カーソルが不正です") }
            page = p
        }
        let body = try await api.send(.creatorSearch(query: query, page: page), as: FanboxCreatorSearchBody.self, accountID: account.accountID)
        let next = body.nextPage.flatMap { $0 > page ? FanboxCursor.page($0).encoded : nil }
        return RemotePage(items: body.creators.compactMap(FanboxAdapter.creator), nextCursor: next)
    }

    /// Session summary from the page metadata (never includes the CSRF token).
    func sessionSummary(account: AccountContext) async throws -> FanboxSessionSummary {
        let metadata = try await api.fetchMetadata(accountID: account.accountID)
        let user = try FanboxAdapter.user(metadata)
        return FanboxSessionSummary(user: user, isCreator: metadata.user?.isCreator ?? (user.creatorID != nil),
                                    isSupporter: metadata.user?.isSupporter, hasUnpaidPayments: metadata.user?.hasUnpaidPayments,
                                    planCount: metadata.user?.planCount)
    }

    /// Follow / unfollow by the creator's pixiv user id (not the creatorId handle).
    func setFollow(creatorUserID: String, follow: Bool, account: AccountContext) async throws {
        let endpoint: FanboxEndpoint = follow ? .followCreate(creatorUserID: creatorUserID) : .followDelete(creatorUserID: creatorUserID)
        try await api.perform(endpoint, accountID: account.accountID)
    }

    // MARK: - Helpers

    /// A comment object in a write response (`body` itself or `body.comment`), if any.
    static func commentDTO(from json: JSONValue) -> FanboxCommentDTO? {
        let candidate = json["comment"] ?? json
        guard candidate.objectValue != nil, let data = try? candidate.encoded(),
              let dto = try? JSONDecoder().decode(FanboxCommentDTO.self, from: data), dto.id != nil else { return nil }
        return dto
    }

    private func requireCreator(_ account: AccountContext) throws -> String {
        guard let creatorID = account.creatorID, !creatorID.isEmpty else {
            throw RemoteError.invalidRequest("このアカウントにはクリエイターページがありません")
        }
        return creatorID
    }
}

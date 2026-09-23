import Foundation
import ImageIO

/// A post as stored in the demo world (reader fixtures, self-creator managed posts and posts created at runtime).
struct DemoStoredPost: Sendable, Hashable {
    var id: String
    var creatorID: String
    var type: PostType
    var title: String
    var feeRequired: Int
    var planID: String?
    var status: RemotePostStatus
    var tags: [String]
    var hasAdultContent: Bool
    var blocks: [RemoteBlock]
    var coverImageURL: String?
    var publishedAt: Date?
    var updatedAt: Date
    var baseLikeCount: Int

    var sortDate: Date { publishedAt ?? updatedAt }
    var isPublished: Bool { status == .published }
}

struct DemoStoredComment: Sendable, Hashable {
    var id: String
    var postID: String
    var parentID: String?
    var rootID: String?
    var author: DemoAuthor
    var body: String
    var createdAt: Date
    var likeCount: Int
}

/// Stateful, deterministic, offline fixture world shared by every `DemoRemoteDataSource` of the process.
///
/// - Deterministic: for a given `anchor` date the same calls return the same values. The only changes come from
///   explicit mutations (comments, likes, created / updated posts, uploads) and the documented support anomaly.
/// - Profiles: `demo-creator-self` ⇒ `.creator`; other accounts get `.viewerA` / `.viewerB` by FNV-1a parity of their
///   pixivUserID. When a second viewer account hashes to an already assigned profile while the other one is still free,
///   it gets the free one, so two viewer accounts always differ.
/// - Support anomaly (SPEC §15): for `.viewerB`, one support is returned by the first `supportingPlans` call of an
///   account only; later calls omit it (tracked per account id).
actor DemoWorld {
    static let shared = DemoWorld()

    /// "Now" of the fixture world. All fixture dates are relative to it.
    nonisolated let anchor: Date
    /// Multiplier for simulated latency (0 = no delay; tests).
    nonisolated let latencyScale: Double
    nonisolated let calendar: Calendar

    private var posts: [String: DemoStoredPost] = [:]
    private var commentStore: [String: DemoStoredComment] = [:]
    /// identity key → liked post ids.
    private var likes: [String: Set<String>] = [:]
    /// account id → number of `supportingPlans` calls.
    private var supportingPlansCalls: [String: Int] = [:]
    /// identity key → assigned viewer profile.
    private var viewerAssignments: [String: DemoProfile] = [:]
    /// First identity key seen per profile (used to show fixture comments of a profile under its real demo account id).
    private var profileIdentity: [DemoProfile: String] = [:]
    /// mediaID → block template (fixture media + uploads) so edited posts keep working image / file URLs.
    private var mediaIndex: [String: RemoteBlock] = [:]
    /// file name → number of upload attempts.
    private var uploadAttempts: [String: Int] = [:]
    private var dynamicNotifications: [DynamicNotification] = []
    private var sequence = 0

    private struct DynamicNotification: Sendable {
        var audience: Set<DemoProfile>
        var fixture: DemoNotificationFixture
        var date: Date
    }

    /// Per-request resolved view of the requesting account.
    struct Viewer: Sendable {
        var account: AccountContext
        var profile: DemoProfile
        var key: String
        var supports: [DemoSupportFixture]
        var following: Set<String>

        func planFee(creatorID: String) -> Int { supports.first { $0.creatorID == creatorID }?.fee ?? 0 }
        func isSupporting(_ creatorID: String) -> Bool { supports.contains { $0.creatorID == creatorID } }
        var ownsSelfCreator: Bool { profile == .creator }
    }

    init(now: Date = Date(), latencyScale: Double = 1, calendar: Calendar = .current) {
        anchor = now
        self.latencyScale = max(0, latencyScale)
        self.calendar = calendar
        for fixture in DemoFixtures.readerPosts + DemoFixtures.managedPosts {
            let post = DemoWorld.makePost(fixture, anchor: now, calendar: calendar)
            posts[post.id] = post
            for block in post.blocks { if let id = block.mediaID { mediaIndex[id] = block } }
        }
        let fixtureByID = Dictionary(uniqueKeysWithValues: DemoFixtures.comments.map { ($0.id, $0) })
        for fixture in DemoFixtures.comments {
            var root: String? = nil
            var cursor = fixture.parentID
            while let current = cursor {
                root = current
                cursor = fixtureByID[current]?.parentID
            }
            commentStore[fixture.id] = DemoStoredComment(
                id: fixture.id, postID: fixture.postID, parentID: fixture.parentID, rootID: root, author: fixture.author,
                body: fixture.body, createdAt: fixture.time.resolve(anchor: now, calendar: calendar), likeCount: fixture.likes)
        }
    }

    // MARK: - Profiles

    func profile(for account: AccountContext) -> DemoProfile {
        let key = DemoProfileRules.identityKey(account)
        let resolved: DemoProfile
        if DemoProfileRules.isSelfCreator(account) {
            resolved = .creator
        } else if let assigned = viewerAssignments[key] {
            resolved = assigned
        } else {
            let preferred = DemoProfileRules.preferredViewerProfile(for: key)
            let other: DemoProfile = preferred == .viewerA ? .viewerB : .viewerA
            let taken = Set(viewerAssignments.values)
            resolved = (taken.contains(preferred) && !taken.contains(other)) ? other : preferred
            viewerAssignments[key] = resolved
        }
        if profileIdentity[resolved] == nil { profileIdentity[resolved] = key }
        return resolved
    }

    func viewer(_ account: AccountContext) -> Viewer {
        let profile = profile(for: account)
        let fixture = DemoFixtures.profile(profile)
        let calls = supportingPlansCalls[account.accountID] ?? 0
        let supports = fixture.supports.filter { support in
            !(support.creatorID == fixture.disappearingSupportCreatorID && calls >= 2)
        }
        // Following does not change when a support disappears.
        let following = Set(fixture.supports.map(\.creatorID) + fixture.followOnly)
        return Viewer(account: account, profile: profile, key: DemoProfileRules.identityKey(account), supports: supports,
                      following: following)
    }

    // MARK: - Session

    func currentUser(account: AccountContext) -> RemoteUser {
        let v = viewer(account)
        let fixture = DemoFixtures.profile(v.profile)
        return RemoteUser(pixivUserID: v.key, fanboxUserID: "demo-fu-\(DemoHash.hex(v.key, length: 10))", name: fixture.userName,
                          iconURL: fixture.iconURL, creatorID: v.ownsSelfCreator ? DemoFixtures.selfCreatorID : nil)
    }

    // MARK: - Reader

    func homeTimeline(account: AccountContext, cursor: String?) throws -> RemotePage<RemotePostSummary> {
        let v = viewer(account)
        let list = publishedPosts { v.following.contains($0.creatorID) || v.isSupporting($0.creatorID) }
        return try summaryPage(list, viewer: v, cursor: cursor)
    }

    func supportingTimeline(account: AccountContext, cursor: String?) throws -> RemotePage<RemotePostSummary> {
        let v = viewer(account)
        return try summaryPage(publishedPosts { v.isSupporting($0.creatorID) }, viewer: v, cursor: cursor)
    }

    func creatorPosts(creatorID: String, account: AccountContext, cursor: String?) throws -> RemotePage<RemotePostSummary> {
        guard DemoFixtures.creatorsByID[creatorID] != nil else { throw RemoteError.notFound }
        let v = viewer(account)
        return try summaryPage(publishedPosts { $0.creatorID == creatorID }, viewer: v, cursor: cursor)
    }

    func post(id: String, account: AccountContext) throws -> RemotePostDetail {
        let v = viewer(account)
        guard let post = posts[id], isVisible(post, to: v) else { throw RemoteError.notFound }
        let summary = makeSummary(post, viewer: v)
        let blocks = summary.isRestricted ? [] : post.blocks
        let plain = blocks.filter { $0.kind == .paragraph || $0.kind == .header }.map(\.text).joined(separator: "\n")
        var prev: String?
        var next: String?
        if post.isPublished {
            let siblings = publishedPosts { $0.creatorID == post.creatorID }   // newest first
            if let index = siblings.firstIndex(where: { $0.id == post.id }) {
                if index + 1 < siblings.count { prev = siblings[index + 1].id }
                if index > 0 { next = siblings[index - 1].id }
            }
        }
        return RemotePostDetail(summary: summary, blocks: blocks, plainText: plain, prevPostID: prev, nextPostID: next)
    }

    func creator(id: String, account: AccountContext) throws -> RemoteCreator {
        guard let fixture = DemoFixtures.creatorsByID[id] else { throw RemoteError.notFound }
        return makeCreator(fixture, viewer: viewer(account))
    }

    func followingCreators(account: AccountContext) -> [RemoteCreator] {
        let v = viewer(account)
        return DemoFixtures.creators.filter { v.following.contains($0.id) }.map { makeCreator($0, viewer: v) }
    }

    func supportingPlans(account: AccountContext) -> [RemoteSupport] {
        supportingPlansCalls[account.accountID, default: 0] += 1
        let v = viewer(account)
        return v.supports.compactMap { support in
            guard let creator = DemoFixtures.creatorsByID[support.creatorID], let plan = creator.plan(fee: support.fee) else { return nil }
            let planID = creator.planID(fee: support.fee)
            return RemoteSupport(planID: planID, creatorID: creator.id, creatorName: creator.name, creatorIconURL: creator.iconURL,
                                 pixivUserID: creator.pixivUserID, planTitle: plan.title, fee: plan.fee,
                                 paymentMethod: support.paymentMethod, planDescription: plan.description,
                                 coverImageURL: DemoWorld.planCoverURL(planID))
        }
    }

    func creatorPlans(creatorID: String, account: AccountContext) throws -> [RemotePlan] {
        guard let creator = DemoFixtures.creatorsByID[creatorID] else { throw RemoteError.notFound }
        _ = viewer(account)
        return creator.plans.map { plan in
            let planID = creator.planID(fee: plan.fee)
            return RemotePlan(planID: planID, creatorID: creator.id, title: plan.title, fee: plan.fee, description: plan.description,
                              coverImageURL: DemoWorld.planCoverURL(planID), hasAdultContent: false)
        }
    }

    func setLike(postID: String, liked: Bool, account: AccountContext) throws {
        let v = viewer(account)
        guard let post = posts[postID], isVisible(post, to: v) else { throw RemoteError.notFound }
        if liked { likes[v.key, default: []].insert(postID) } else { likes[v.key]?.remove(postID) }
    }

    // MARK: - Comments

    func comments(postID: String, account: AccountContext, cursor: String?) throws -> RemotePage<RemoteComment> {
        let v = viewer(account)
        guard let post = posts[postID], isVisible(post, to: v) else { throw RemoteError.notFound }
        let all = commentStore.values.filter { $0.postID == postID }
        let roots = DemoWorld.sortedNewestFirst(all.filter { $0.parentID == nil }, key: { ($0.createdAt, $0.id) })
        let page = try DemoPaging.page(roots, cursor: cursor, size: DemoFixtures.commentPageSize, key: { ($0.createdAt, $0.id) })
        let items = page.items.map { root -> RemoteComment in
            let replies = all.filter { $0.rootID == root.id }
                .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
                .map { makeComment($0, post: post, viewer: v) }
            var remote = makeComment(root, post: post, viewer: v)
            remote.replies = replies
            return remote
        }
        return RemotePage(items: items, nextCursor: page.nextCursor)
    }

    func addComment(postID: String, body: String, parentCommentID: String?, rootCommentID: String?,
                    account: AccountContext) throws -> RemoteComment {
        let v = viewer(account)
        guard let post = posts[postID], isVisible(post, to: v) else { throw RemoteError.notFound }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteError.invalidRequest("コメントを入力してください")
        }
        var parent: DemoStoredComment?
        if let parentCommentID {
            guard let found = commentStore[parentCommentID], found.postID == postID else { throw RemoteError.notFound }
            parent = found
        }
        sequence += 1
        let profile = DemoFixtures.profile(v.profile)
        let stored = DemoStoredComment(
            id: "demo-c-new-\(sequence)", postID: postID, parentID: parent?.id,
            rootID: parent.map { rootCommentID ?? $0.rootID ?? $0.id }, author: .user(id: v.key, name: profile.userName, iconURL: profile.iconURL),
            body: body, createdAt: mutationDate(), likeCount: 0)
        commentStore[stored.id] = stored
        notifyForNewComment(stored, post: post, parent: parent, writer: v)
        return makeComment(stored, post: post, viewer: v)
    }

    func deleteComment(commentID: String, postID: String, account: AccountContext) throws {
        let v = viewer(account)
        guard let comment = commentStore[commentID], comment.postID == postID, let post = posts[postID] else {
            throw RemoteError.notFound
        }
        let ownsPost = v.ownsSelfCreator && post.creatorID == DemoFixtures.selfCreatorID
        guard ownsPost || resolveAuthor(comment.author, post: post, viewer: v).isOwn else { throw RemoteError.forbidden }
        // Remove the comment and everything that replies to it (directly or transitively).
        var removed: Set<String> = [commentID]
        var changed = true
        while changed {
            changed = false
            for c in commentStore.values where !removed.contains(c.id) {
                if let parent = c.parentID, removed.contains(parent) { removed.insert(c.id); changed = true }
            }
        }
        for id in removed { commentStore[id] = nil }
    }

    // MARK: - Notifications / おたより / payments

    func notifications(account: AccountContext, cursor: String?) throws -> RemotePage<RemoteNotification> {
        let v = viewer(account)
        var items = (DemoFixtures.notifications[v.profile] ?? []).map {
            makeNotification($0, date: $0.time.resolve(anchor: anchor, calendar: calendar), viewer: v)
        }
        items += dynamicNotifications.filter { $0.audience.contains(v.profile) }.map { makeNotification($0.fixture, date: $0.date, viewer: v) }
        let sorted = DemoWorld.sortedNewestFirst(items, key: { ($0.createdAt, $0.remoteID) })
        return try DemoPaging.page(sorted, cursor: cursor, size: DemoFixtures.notificationPageSize, key: { ($0.createdAt, $0.remoteID) })
    }

    func newsletters(account: AccountContext) -> [RemoteNewsletter] {
        let v = viewer(account)
        let items = (DemoFixtures.newsletters[v.profile] ?? []).map(makeNewsletter)
        return DemoWorld.sortedNewestFirst(items, key: { ($0.createdAt, $0.id) })
    }

    func newsletter(id: String, account: AccountContext) throws -> RemoteNewsletter {
        let v = viewer(account)
        guard let fixture = DemoFixtures.newsletters[v.profile]?.first(where: { $0.id == id }) else { throw RemoteError.notFound }
        return makeNewsletter(fixture)
    }

    func paidRecords(account: AccountContext) -> [RemotePayment] {
        let v = viewer(account)
        let items = (DemoFixtures.payments[v.profile] ?? []).map { p in
            RemotePayment(id: p.id, creatorID: p.creatorID, creatorName: DemoFixtures.creatorsByID[p.creatorID]?.name, amount: p.amount,
                          paidAt: p.time.resolve(anchor: anchor, calendar: calendar), paymentMethod: p.paymentMethod)
        }
        return DemoWorld.sortedNewestFirst(items, key: { ($0.paidAt, $0.id) })
    }

    // MARK: - Creator Mode

    func managedPosts(account: AccountContext, cursor: String?) throws -> RemotePage<RemotePostSummary> {
        let v = try creatorViewer(account)
        let list = DemoWorld.sortedNewestFirst(posts.values.filter { $0.creatorID == DemoFixtures.selfCreatorID },
                                               key: { ($0.sortDate, $0.id) })
        var page = try summaryPage(list, viewer: v, cursor: cursor)
        // Managed listings carry the post status (drafts must not look published).
        page.items = page.items.map { item in
            var item = item
            item.remoteStatus = posts[item.id]?.status
            return item
        }
        return page
    }

    func editablePost(id: String, account: AccountContext) throws -> RemoteEditablePost {
        _ = try creatorViewer(account)
        guard let post = posts[id], post.creatorID == DemoFixtures.selfCreatorID else { throw RemoteError.notFound }
        return RemoteEditablePost(id: post.id, title: post.title, feeRequired: post.feeRequired, planID: post.planID, status: post.status,
                                  blocks: post.blocks, tags: post.tags, hasAdultContent: post.hasAdultContent,
                                  publishedAt: post.publishedAt, updatedAt: post.updatedAt, postType: post.type)
    }

    func createPost(_ draft: RemotePostDraft, account: AccountContext) throws -> String {
        _ = try creatorViewer(account)
        try validate(draft)
        sequence += 1
        let id = "demo-post-new-\(sequence)"
        let now = mutationDate()
        let blocks = draft.blocks.map(makeBlock)
        posts[id] = DemoStoredPost(
            id: id, creatorID: DemoFixtures.selfCreatorID, type: DemoWorld.inferType(blocks), title: draft.title,
            feeRequired: draft.feeRequired, planID: draft.planID, status: draft.publish ? .published : .draft, tags: draft.tags,
            hasAdultContent: draft.hasAdultContent, blocks: blocks, coverImageURL: DemoWorld.cover(for: blocks, postID: id, type: .article),
            publishedAt: draft.publish ? now : nil, updatedAt: now, baseLikeCount: 0)
        return id
    }

    func updatePost(id: String, _ draft: RemotePostDraft, account: AccountContext) throws {
        _ = try creatorViewer(account)
        guard var post = posts[id], post.creatorID == DemoFixtures.selfCreatorID else { throw RemoteError.notFound }
        try validate(draft)
        let now = mutationDate()
        let blocks = draft.blocks.map(makeBlock)
        post.title = draft.title
        post.feeRequired = draft.feeRequired
        post.planID = draft.planID
        post.tags = draft.tags
        post.hasAdultContent = draft.hasAdultContent
        post.blocks = blocks
        post.type = DemoWorld.inferType(blocks)
        post.coverImageURL = DemoWorld.cover(for: blocks, postID: id, type: post.type)
        post.updatedAt = now
        if draft.publish {
            if post.status != .published { post.publishedAt = now }
            post.status = .published
        } else {
            post.status = .draft
            post.publishedAt = nil
        }
        posts[id] = post
    }

    /// Records an upload attempt and tells whether it must fail.
    /// Names containing "fail" always fail; names containing "flaky" fail on the first attempt only.
    func registerUploadAttempt(fileName: String) -> Bool {
        let lower = fileName.lowercased()
        uploadAttempts[lower, default: 0] += 1
        if lower.contains("fail") { return true }
        if lower.contains("flaky") { return uploadAttempts[lower] == 1 }
        return false
    }

    func completeUpload(fileURL: URL, kind: UploadKind) -> RemoteUploadResult {
        sequence += 1
        let name = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.lowercased()
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        switch kind {
        case .image:
            let mediaID = "demo-upload-img-\(sequence)"
            let (w, h) = DemoWorld.imageSize(of: fileURL) ?? (1200, 900)
            let set = DemoMedia.imageSet(seed: "upload-\(sequence)", width: w, height: h)
            mediaIndex[mediaID] = RemoteBlock(kind: .image, mediaID: mediaID, thumbnailURL: set.thumbnail, displayURL: set.display,
                                              originalURL: set.original, width: w, height: h)
            return RemoteUploadResult(mediaID: mediaID, url: set.display)
        case .file:
            let mediaID = "demo-upload-file-\(sequence)"
            let url = DemoMedia.fileURL(name: ext.isEmpty ? name : "\(name).\(ext)", size: size)
            mediaIndex[mediaID] = RemoteBlock(kind: DemoWorld.fileBlockKind(ext: ext), mediaID: mediaID, fileName: name,
                                              fileExtension: ext.isEmpty ? nil : ext, fileSize: size, url: url)
            return RemoteUploadResult(mediaID: mediaID, url: url)
        }
    }

    func fans(account: AccountContext, cursor: String?) throws -> RemotePage<RemoteFan> {
        _ = try creatorViewer(account)
        let creator = DemoFixtures.creatorsByID[DemoFixtures.selfCreatorID]!
        let fans = DemoFixtures.fans.map { fan -> RemoteFan in
            let started = fan.startedMinutesAgo.map { anchor.addingTimeInterval(-Double($0) * 60) }
            let months = fan.months ?? fan.startedMinutesAgo.map { max(1, $0 / (30 * 1440) + 1) }
            let plan = fan.fee.flatMap { creator.plan(fee: $0) }
            return RemoteFan(userID: fan.userID, name: fan.name, iconURL: fan.iconURL, planID: fan.fee.map { creator.planID(fee: $0) },
                             planTitle: plan?.title, fee: fan.fee, supportStartedAt: started, supportMonths: months, state: fan.state)
        }
        return try DemoPaging.offsetPage(fans, cursor: cursor, size: DemoFixtures.fanPageSize)
    }

    func creatorDashboard(account: AccountContext) throws -> RemoteCreatorDashboard {
        _ = try creatorViewer(account)
        let supporting = DemoFixtures.fans.filter { $0.state == .supporting }
        let monthStart = DemoTime.startOfMonth(anchor, calendar: calendar)
        let postCount = posts.values.filter {
            $0.creatorID == DemoFixtures.selfCreatorID && $0.isPublished && ($0.publishedAt ?? .distantPast) >= monthStart
        }.count
        // Keyed like FANBOX: the JST month (CreatorMonth), whatever the device time zone.
        return RemoteCreatorDashboard(month: CreatorMonth.key(anchor), supporterCount: supporting.count,
                                      earnings: supporting.compactMap(\.fee).reduce(0, +), postCount: postCount, commentCount: nil)
    }

    /// All comments on posts of the self creator page, flattened (each with parent/root ids, no nested replies), newest first.
    func creatorComments(account: AccountContext, cursor: String?) throws -> RemotePage<RemoteComment> {
        let v = try creatorViewer(account)
        let own = commentStore.values.filter { posts[$0.postID]?.creatorID == DemoFixtures.selfCreatorID }
        let sorted = DemoWorld.sortedNewestFirst(own, key: { ($0.createdAt, $0.id) })
        let page = try DemoPaging.page(sorted, cursor: cursor, size: DemoFixtures.commentPageSize, key: { ($0.createdAt, $0.id) })
        return RemotePage(items: page.items.compactMap { c in posts[c.postID].map { makeComment(c, post: $0, viewer: v) } },
                          nextCursor: page.nextCursor)
    }

    // MARK: - Simulation hooks (debug menus / tests)

    /// Publishes a new post for a reader-side creator and emits a new-post notification to every profile following it.
    @discardableResult
    func simulateIncomingPost(creatorID: String = "demo-aoi", title: String? = nil, feeRequired: Int = 0) -> String {
        sequence += 1
        let id = "demo-post-live-\(sequence)"
        let now = mutationDate()
        let creator = DemoFixtures.creatorsByID[creatorID] ?? DemoFixtures.creators[0]
        let postTitle = title ?? "Demo 新着投稿 #\(sequence)"
        let blocks = DemoWorld.expand([.paragraph("（デモ用に生成された新着投稿です）"), .images(count: 1, width: 1600, height: 1200)], postID: id)
        posts[id] = DemoStoredPost(id: id, creatorID: creator.id, type: .image, title: postTitle, feeRequired: feeRequired, planID: nil,
                                   status: .published, tags: ["Demo"], hasAdultContent: false, blocks: blocks,
                                   coverImageURL: DemoWorld.cover(for: blocks, postID: id, type: .image), publishedAt: now,
                                   updatedAt: now, baseLikeCount: 0)
        let audience = Set(DemoProfile.allCases.filter { p in
            let f = DemoFixtures.profile(p)
            return f.supports.contains { $0.creatorID == creator.id } || f.followOnly.contains(creator.id)
        })
        dynamicNotifications.append(DynamicNotification(audience: audience, fixture: DemoNotificationFixture(
            key: "newpost-\(id)", type: .newPost, rawType: "post_published", time: .minutesAgo(0), creatorID: creator.id, postID: id,
            commentID: nil, newsletterID: nil, actorName: creator.name, actorIconURL: creator.iconURL,
            title: "\(creator.name) が新しい投稿を公開しました", message: postTitle, unread: true), date: now))
        return id
    }

    /// Adds a fan comment on a self-creator post and emits a `.comment` notification to the creator profile.
    @discardableResult
    func simulateIncomingComment(postID: String = "demo-post-901", body: String? = nil) -> String? {
        guard let post = posts[postID], post.creatorID == DemoFixtures.selfCreatorID else { return nil }
        sequence += 1
        let fanIndex = sequence % DemoFixtures.fans.count
        let fan = DemoFixtures.fans[fanIndex]
        let comment = DemoStoredComment(id: "demo-c-live-\(sequence)", postID: postID, parentID: nil, rootID: nil, author: .fan(fanIndex),
                                        body: body ?? "（デモ）新しいコメントです #\(sequence)", createdAt: mutationDate(), likeCount: 0)
        commentStore[comment.id] = comment
        dynamicNotifications.append(DynamicNotification(audience: [.creator], fixture: DemoNotificationFixture(
            key: "comment-\(comment.id)", type: .comment, rawType: "post_comment", time: .minutesAgo(0),
            creatorID: DemoFixtures.selfCreatorID, postID: postID, commentID: comment.id, newsletterID: nil, actorName: fan.name,
            actorIconURL: fan.iconURL, title: "\(fan.name) さんが「\(post.title)」にコメントしました", message: comment.body, unread: true),
            date: comment.createdAt))
        return comment.id
    }

    /// Number of `supportingPlans` calls observed for a local account id (tests / diagnostics).
    func supportingPlansCallCount(accountID: String) -> Int { supportingPlansCalls[accountID] ?? 0 }

    // MARK: - Builders

    private func creatorViewer(_ account: AccountContext) throws -> Viewer {
        let v = viewer(account)
        guard v.ownsSelfCreator else { throw RemoteError.forbidden }
        return v
    }

    private func validate(_ draft: RemotePostDraft) throws {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteError.invalidRequest("タイトルを入力してください")
        }
        guard draft.feeRequired >= 0 else { throw RemoteError.invalidRequest("支援額が不正です") }
    }

    /// Strictly increasing timestamps for runtime mutations (always newer than every fixture).
    private func mutationDate() -> Date {
        max(Date(), anchor).addingTimeInterval(Double(sequence) * 0.001)
    }

    private func publishedPosts(_ include: (DemoStoredPost) -> Bool) -> [DemoStoredPost] {
        DemoWorld.sortedNewestFirst(posts.values.filter { $0.isPublished && include($0) }, key: { ($0.sortDate, $0.id) })
    }

    private func isVisible(_ post: DemoStoredPost, to viewer: Viewer) -> Bool {
        post.isPublished || (viewer.ownsSelfCreator && post.creatorID == DemoFixtures.selfCreatorID)
    }

    private func summaryPage(_ list: [DemoStoredPost], viewer: Viewer, cursor: String?) throws -> RemotePage<RemotePostSummary> {
        let page = try DemoPaging.page(list, cursor: cursor, size: DemoFixtures.timelinePageSize, key: { ($0.sortDate, $0.id) })
        return RemotePage(items: page.items.map { makeSummary($0, viewer: viewer) }, nextCursor: page.nextCursor)
    }

    private func makeSummary(_ post: DemoStoredPost, viewer: Viewer) -> RemotePostSummary {
        let creator = DemoFixtures.creatorsByID[post.creatorID]
        let owner = viewer.ownsSelfCreator && post.creatorID == DemoFixtures.selfCreatorID
        let restricted = !owner && post.feeRequired > viewer.planFee(creatorID: post.creatorID)
        let likedBy = likes.values.filter { $0.contains(post.id) }.count
        let commentCount = commentStore.values.filter { $0.postID == post.id }.count
        return RemotePostSummary(
            id: post.id, creatorID: post.creatorID, creatorName: creator?.name ?? post.creatorID, creatorIconURL: creator?.iconURL,
            pixivUserID: creatorPixivUserID(post.creatorID), title: post.title, excerpt: DemoWorld.excerpt(post.blocks), type: post.type,
            feeRequired: post.feeRequired, coverImageURL: post.coverImageURL, publishedAt: post.sortDate, updatedAt: post.updatedAt,
            tags: post.tags, likeCount: post.baseLikeCount + likedBy, commentCount: commentCount,
            isLiked: likes[viewer.key]?.contains(post.id) ?? false, isRestricted: restricted, hasAdultContent: post.hasAdultContent)
    }

    private func makeCreator(_ fixture: DemoCreatorFixture, viewer: Viewer) -> RemoteCreator {
        let isSelf = fixture.id == DemoFixtures.selfCreatorID
        return RemoteCreator(creatorID: fixture.id, pixivUserID: creatorPixivUserID(fixture.id), name: fixture.name,
                             iconURL: fixture.iconURL, coverImageURL: fixture.coverURL, profileText: fixture.profileText,
                             profileLinks: fixture.links, hasAdultContent: false,
                             isFollowed: isSelf ? false : viewer.following.contains(fixture.id),
                             isSupported: isSelf ? false : viewer.isSupporting(fixture.id))
    }

    /// The self creator's pixiv user id is the id of the demo account that owns it (when known).
    private func creatorPixivUserID(_ creatorID: String) -> String? {
        if creatorID == DemoFixtures.selfCreatorID, let key = profileIdentity[.creator] { return key }
        return DemoFixtures.creatorsByID[creatorID]?.pixivUserID
    }

    private func identity(of profile: DemoProfile, viewer: Viewer) -> String {
        if viewer.profile == profile { return viewer.key }
        return profileIdentity[profile] ?? "demo-user-\(profile.tag)"
    }

    private func resolveAuthor(_ author: DemoAuthor, post: DemoStoredPost, viewer: Viewer)
        -> (id: String, name: String, icon: String?, isOwn: Bool) {
        switch author {
        case .fan(let index):
            let fan = DemoFixtures.fans[index % DemoFixtures.fans.count]
            return (fan.userID, fan.name, fan.iconURL, false)
        case .postCreator:
            let creator = DemoFixtures.creatorsByID[post.creatorID]
            if post.creatorID == DemoFixtures.selfCreatorID {
                return (identity(of: .creator, viewer: viewer), creator?.name ?? "", creator?.iconURL, viewer.ownsSelfCreator)
            }
            return (creator?.pixivUserID ?? post.creatorID, creator?.name ?? "", creator?.iconURL, false)
        case .profile(let profile):
            let fixture = DemoFixtures.profile(profile)
            return (identity(of: profile, viewer: viewer), fixture.userName, fixture.iconURL, viewer.profile == profile)
        case .user(let id, let name, let icon):
            return (id, name, icon, id == viewer.key)
        }
    }

    private func makeComment(_ comment: DemoStoredComment, post: DemoStoredPost, viewer: Viewer) -> RemoteComment {
        let author = resolveAuthor(comment.author, post: post, viewer: viewer)
        return RemoteComment(id: comment.id, postID: comment.postID, parentCommentID: comment.parentID, rootCommentID: comment.rootID,
                             authorUserID: author.id, authorName: author.name, authorIconURL: author.icon, body: comment.body,
                             createdAt: comment.createdAt, likeCount: comment.likeCount, isLiked: false, isOwn: author.isOwn)
    }

    private func makeNotification(_ fixture: DemoNotificationFixture, date: Date, viewer: Viewer) -> RemoteNotification {
        RemoteNotification(
            remoteID: "demo-ntf-\(DemoHash.hex(viewer.key, length: 6))-\(fixture.key)", type: fixture.type, rawType: fixture.rawType,
            createdAt: date, creatorID: fixture.creatorID, creatorName: fixture.creatorID.flatMap { DemoFixtures.creatorsByID[$0]?.name },
            postID: fixture.postID, postTitle: fixture.postID.flatMap { posts[$0]?.title }, commentID: fixture.commentID,
            newsletterID: fixture.newsletterID, actorName: fixture.actorName, actorIconURL: fixture.actorIconURL, title: fixture.title,
            message: fixture.message, isUnread: fixture.unread)
    }

    private func makeNewsletter(_ fixture: DemoNewsletterFixture) -> RemoteNewsletter {
        let creator = DemoFixtures.creatorsByID[fixture.creatorID]
        return RemoteNewsletter(id: fixture.id, creatorID: fixture.creatorID, creatorName: creator?.name ?? fixture.creatorID,
                                creatorIconURL: creator?.iconURL, title: fixture.title, body: fixture.body,
                                createdAt: fixture.time.resolve(anchor: anchor, calendar: calendar), isRead: fixture.isRead)
    }

    /// Emits notifications a real service would send when a demo account comments.
    private func notifyForNewComment(_ comment: DemoStoredComment, post: DemoStoredPost, parent: DemoStoredComment?, writer: Viewer) {
        let writerName = DemoFixtures.profile(writer.profile).userName
        let writerIcon = DemoFixtures.profile(writer.profile).iconURL
        if post.creatorID == DemoFixtures.selfCreatorID && !writer.ownsSelfCreator {
            dynamicNotifications.append(DynamicNotification(audience: [.creator], fixture: DemoNotificationFixture(
                key: "comment-\(comment.id)", type: .comment, rawType: "post_comment", time: .minutesAgo(0),
                creatorID: post.creatorID, postID: post.id, commentID: comment.id, newsletterID: nil, actorName: writerName,
                actorIconURL: writerIcon, title: "\(writerName) さんが「\(post.title)」にコメントしました", message: comment.body,
                unread: true), date: comment.createdAt))
        }
        if let parent {
            var recipient: DemoProfile?
            switch parent.author {
            case .profile(let p): recipient = p
            case .user(let id, _, _): recipient = viewerAssignments[id] ?? (profileIdentity[.creator] == id ? .creator : nil)
            case .postCreator: recipient = post.creatorID == DemoFixtures.selfCreatorID ? .creator : nil
            case .fan: recipient = nil
            }
            if let recipient, recipient != writer.profile {
                dynamicNotifications.append(DynamicNotification(audience: [recipient], fixture: DemoNotificationFixture(
                    key: "reply-\(comment.id)", type: .commentReply, rawType: "comment_reply", time: .minutesAgo(0),
                    creatorID: post.creatorID, postID: post.id, commentID: comment.id, newsletterID: nil, actorName: writerName,
                    actorIconURL: writerIcon, title: "\(writerName) さんがあなたのコメントに返信しました", message: comment.body,
                    unread: true), date: comment.createdAt))
            }
        }
    }

    private func makeBlock(_ draft: RemoteDraftBlock) -> RemoteBlock {
        switch draft.kind {
        case .text:
            return RemoteBlock(kind: .paragraph, text: draft.text, styles: draft.styles)
        case .header:
            return RemoteBlock(kind: .header, text: draft.text, styles: draft.styles)
        case .image:
            if let id = draft.mediaID, let known = mediaIndex[id] { return known }
            let seed = draft.mediaID ?? "image-\(sequence)"
            let set = DemoMedia.imageSet(seed: seed, width: 1200, height: 900)
            return RemoteBlock(kind: .image, mediaID: draft.mediaID, thumbnailURL: set.thumbnail, displayURL: set.display,
                               originalURL: set.original, width: set.width, height: set.height)
        case .file:
            if let id = draft.mediaID, let known = mediaIndex[id] { return known }
            let name = draft.text.isEmpty ? (draft.mediaID ?? "file") : draft.text
            return RemoteBlock(kind: .file, mediaID: draft.mediaID, fileName: name, url: DemoMedia.fileURL(name: name, size: 0))
        case .url:
            return RemoteBlock(kind: .url, url: draft.url, title: draft.text.isEmpty ? draft.url : draft.text)
        case .embed:
            return RemoteBlock(kind: .embed, text: draft.text, url: draft.url, embedProvider: draft.embedProvider,
                               embedContentID: draft.embedContentID)
        }
    }

    // MARK: - Static helpers

    static func makePost(_ fixture: DemoPostFixture, anchor: Date, calendar: Calendar) -> DemoStoredPost {
        let date = fixture.time.resolve(anchor: anchor, calendar: calendar)
        let blocks = expand(fixture.body, postID: fixture.id)
        var planID: String?
        if fixture.fee > 0, let creator = DemoFixtures.creatorsByID[fixture.creatorID],
           let plan = creator.plans.first(where: { $0.fee >= fixture.fee }) {
            planID = creator.planID(fee: plan.fee)
        }
        return DemoStoredPost(
            id: fixture.id, creatorID: fixture.creatorID, type: fixture.type, title: fixture.title, feeRequired: fixture.fee,
            planID: planID, status: fixture.status, tags: fixture.tags, hasAdultContent: false, blocks: blocks,
            coverImageURL: cover(for: blocks, postID: fixture.id, type: fixture.type),
            publishedAt: fixture.status == .published ? date : nil, updatedAt: date, baseLikeCount: fixture.likes)
    }

    static func expand(_ specs: [DemoBlockSpec], postID: String) -> [RemoteBlock] {
        var blocks: [RemoteBlock] = []
        var imageIndex = 0
        var fileIndex = 0
        for spec in specs {
            switch spec {
            case .paragraph(let text):
                blocks.append(RemoteBlock(kind: .paragraph, text: text))
            case .styled(let text, let bold, let large):
                var styles: [RemoteTextStyle] = []
                for part in bold {
                    if let r = text.range(of: part) {
                        let ns = NSRange(r, in: text)
                        styles.append(RemoteTextStyle(type: "bold", offset: ns.location, length: ns.length, size: nil))
                    }
                }
                for part in large {
                    if let r = text.range(of: part) {
                        let ns = NSRange(r, in: text)
                        styles.append(RemoteTextStyle(type: "fontSize", offset: ns.location, length: ns.length, size: 24))
                    }
                }
                blocks.append(RemoteBlock(kind: .paragraph, text: text, styles: styles))
            case .header(let text):
                blocks.append(RemoteBlock(kind: .header, text: text))
            case .images(let count, let width, let height):
                for _ in 0..<max(0, count) {
                    imageIndex += 1
                    let seed = "\(postID)-\(imageIndex)"
                    let set = DemoMedia.imageSet(seed: seed, width: width, height: height)
                    blocks.append(RemoteBlock(kind: .image, mediaID: "demo-img-\(seed)", thumbnailURL: set.thumbnail,
                                              displayURL: set.display, originalURL: set.original, width: width, height: height))
                }
            case .file(let name, let ext, let size):
                fileIndex += 1
                blocks.append(RemoteBlock(kind: .file, mediaID: "demo-file-\(postID)-\(fileIndex)", fileName: name, fileExtension: ext,
                                          fileSize: size, url: DemoMedia.fileURL(name: "\(name).\(ext)", size: size)))
            case .audio(let name, let size):
                fileIndex += 1
                blocks.append(RemoteBlock(kind: .audio, mediaID: "demo-file-\(postID)-\(fileIndex)", fileName: name, fileExtension: "mp3",
                                          fileSize: size, url: DemoMedia.fileURL(name: "\(name).mp3", size: size)))
            case .videoFile(let name, let size):
                fileIndex += 1
                blocks.append(RemoteBlock(kind: .video, mediaID: "demo-file-\(postID)-\(fileIndex)", fileName: name, fileExtension: "mp4",
                                          fileSize: size, url: DemoMedia.fileURL(name: "\(name).mp4", size: size)))
            case .externalVideo(let provider, let id):
                blocks.append(RemoteBlock(kind: .video, thumbnailURL: DemoMedia.imageURL(seed: "video-\(id)", width: 480, height: 270, variant: .thumbnail),
                                          url: "https://example.com/demo/video/\(provider)/\(id)", embedProvider: provider,
                                          embedContentID: id, title: "Demo 動画（\(provider)）"))
            case .link(let url, let title, let subtitle):
                blocks.append(RemoteBlock(kind: .url, thumbnailURL: DemoMedia.imageURL(seed: "link-\(url)", width: 480, height: 252, variant: .thumbnail),
                                          url: url, title: title, subtitle: subtitle))
            case .embed(let provider, let id):
                blocks.append(RemoteBlock(kind: .embed, url: "https://example.com/demo/embed/\(provider)/\(id)", embedProvider: provider,
                                          embedContentID: id, title: "Demo 埋め込み（\(provider)）"))
            }
        }
        return blocks
    }

    static func cover(for blocks: [RemoteBlock], postID: String, type: PostType) -> String? {
        if let image = blocks.first(where: { $0.kind == .image }) { return image.thumbnailURL }
        switch type {
        case .article, .video, .file:
            return DemoMedia.imageURL(seed: "cover-\(postID)", width: 640, height: 360, variant: .thumbnail)
        default:
            return nil
        }
    }

    static func excerpt(_ blocks: [RemoteBlock], limit: Int = 60) -> String {
        guard let text = blocks.first(where: { $0.kind == .paragraph && !$0.text.isEmpty })?.text else { return "" }
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    static func inferType(_ blocks: [RemoteBlock]) -> PostType {
        let kinds = Set(blocks.map(\.kind))
        let media = kinds.subtracting([.paragraph])
        if media.isEmpty { return .text }
        if media == [.image] { return .image }
        if media.isSubset(of: [.file, .audio, .video]) && !blocks.contains(where: { $0.embedProvider != nil }) { return .file }
        return .article
    }

    static func fileBlockKind(ext: String) -> PostBlockKind {
        switch ext {
        case "mp3", "m4a", "wav", "aac", "flac", "ogg": return .audio
        case "mp4", "mov", "m4v", "webm": return .video
        default: return .file
        }
    }

    static func planCoverURL(_ planID: String) -> String {
        DemoMedia.imageURL(seed: "plan-\(planID)", width: 1200, height: 630, variant: .display)
    }

    static func imageSize(of url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// Newest first by (millisecond timestamp, id), matching `DemoPaging` keyset cursors.
    static func sortedNewestFirst<T>(_ items: [T], key: (T) -> (Date, String)) -> [T] {
        items.sorted { lhs, rhs in
            let l = key(lhs), r = key(rhs)
            let lm = DemoPaging.millis(l.0), rm = DemoPaging.millis(r.0)
            return lm != rm ? lm > rm : l.1 > r.1
        }
    }
}

/// Opaque cursors for demo listings.
enum DemoPaging {
    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func encode(date: Date, id: String) -> String {
        Data("k1|\(millis(date))|\(id)".utf8).base64EncodedString()
    }

    static func decode(_ cursor: String) -> (Int64, String)? {
        guard let data = Data(base64Encoded: cursor), let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "k1", let ms = Int64(parts[1]) else { return nil }
        return (ms, String(parts[2]))
    }

    /// Keyset page over items sorted by `DemoWorld.sortedNewestFirst`: items strictly older than the cursor.
    static func page<T>(_ items: [T], cursor: String?, size: Int, key: (T) -> (Date, String)) throws -> RemotePage<T> {
        var start = 0
        if let cursor {
            guard let (ms, id) = decode(cursor) else { throw RemoteError.invalidRequest("Demo: 不正なカーソルです") }
            start = items.firstIndex { item in
                let k = key(item)
                let m = millis(k.0)
                return m < ms || (m == ms && k.1 < id)
            } ?? items.count
        }
        let end = min(items.count, start + max(1, size))
        let slice = Array(items[start..<end])
        let next = end < items.count ? slice.last.map { encode(date: key($0).0, id: key($0).1) } : nil
        return RemotePage(items: slice, nextCursor: next)
    }

    static func offsetPage<T>(_ items: [T], cursor: String?, size: Int) throws -> RemotePage<T> {
        var start = 0
        if let cursor {
            guard let data = Data(base64Encoded: cursor), let text = String(data: data, encoding: .utf8), text.hasPrefix("o1|"),
                  let offset = Int(text.dropFirst(3)), offset >= 0 else {
                throw RemoteError.invalidRequest("Demo: 不正なカーソルです")
            }
            start = min(offset, items.count)
        }
        let end = min(items.count, start + max(1, size))
        let next = end < items.count ? Data("o1|\(end)".utf8).base64EncodedString() : nil
        return RemotePage(items: Array(items[start..<end]), nextCursor: next)
    }
}

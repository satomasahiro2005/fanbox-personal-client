import XCTest
import UIKit
@testable import FANBOXClient

/// Collects values from `@Sendable` callbacks (upload progress).
private final class DemoTestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}

final class DemoDataSourceTests: XCTestCase {
    /// Fixed anchor: 2026-09-24 12:00 in the current calendar.
    private let anchor: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 24; components.hour = 12
        return Calendar.current.date(from: components)!
    }()

    private func makeSource(policy: NetworkPolicyStore? = nil, latencyScale: Double = 0) -> (DemoRemoteDataSource, DemoWorld) {
        let world = DemoWorld(now: anchor, latencyScale: latencyScale)
        return (DemoRemoteDataSource(policy: policy, world: world), world)
    }

    /// First pixiv user id (deterministic search) whose FNV-1a preference is `profile`.
    private func userID(preferring profile: DemoProfile, skip: Int = 0) -> String {
        var found = 0
        for i in 0..<10_000 {
            let id = String(format: "demo-%06d", i)
            if DemoProfileRules.preferredViewerProfile(for: id) == profile {
                if found == skip { return id }
                found += 1
            }
        }
        fatalError("no id found")
    }

    private func account(_ pixivUserID: String, creatorID: String? = nil) -> AccountContext {
        AccountContext(accountID: "local-\(pixivUserID)", kind: .demo, pixivUserID: pixivUserID, fanboxUserID: nil, creatorID: creatorID)
    }

    private var viewerA: AccountContext { account(userID(preferring: .viewerA)) }
    private var viewerB: AccountContext { account(userID(preferring: .viewerB)) }
    private var creator: AccountContext { account("demo-cr0001", creatorID: DemoFixtures.selfCreatorID) }

    private func assertRemoteError<T>(_ expected: RemoteError, file: StaticString = #filePath, line: UInt = #line,
                                      _ body: () async throws -> T) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as RemoteError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private func allPages<T>(_ fetch: (String?) async throws -> RemotePage<T>) async throws -> (items: [T], pages: Int) {
        var items: [T] = []
        var cursor: String? = nil
        var pages = 0
        repeat {
            let page = try await fetch(cursor)
            items += page.items
            cursor = page.nextCursor
            pages += 1
            XCTAssertLessThan(pages, 50, "paging must terminate")
        } while cursor != nil && pages < 50
        return (items, pages)
    }

    // MARK: - Profiles / determinism

    func testFNV1aAndProfileDeterminism() async throws {
        XCTAssertEqual(DemoHash.fnv1a64(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(DemoHash.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(DemoHash.fnv1a64("foobar"), 0x8594_4171_f739_67e8)

        let id = "demo-3f9a1c"
        let preferred = DemoProfileRules.preferredViewerProfile(for: id)
        for _ in 0..<5 { XCTAssertEqual(DemoProfileRules.preferredViewerProfile(for: id), preferred) }

        // Same account ⇒ same profile in independent worlds.
        let w1 = DemoWorld(now: anchor, latencyScale: 0)
        let w2 = DemoWorld(now: anchor, latencyScale: 0)
        let p1 = await w1.profile(for: account(id))
        let p2 = await w2.profile(for: account(id))
        XCTAssertEqual(p1, p2)
        XCTAssertEqual(p1, preferred)

        // Two viewer accounts always get different fixture profiles, even when both hash to the same profile.
        let first = account(userID(preferring: .viewerA, skip: 0))
        let second = account(userID(preferring: .viewerA, skip: 1))
        let world = DemoWorld(now: anchor, latencyScale: 0)
        let pa = await world.profile(for: first)
        let pb = await world.profile(for: second)
        XCTAssertNotEqual(pa, pb)
        let pa2 = await world.profile(for: first)
        XCTAssertEqual(pa, pa2, "assignment is stable within a session")
        let pc = await world.profile(for: creator)
        XCTAssertEqual(pc, .creator)

        // currentUser is consistent with the profile.
        let (source, _) = makeSource()
        let userA = try await source.currentUser(account: viewerA)
        let userB = try await source.currentUser(account: viewerB)
        let userC = try await source.currentUser(account: creator)
        XCTAssertEqual(userA.name, DemoFixtures.profile(.viewerA).userName)
        XCTAssertEqual(userB.name, DemoFixtures.profile(.viewerB).userName)
        XCTAssertNotEqual(userA.name, userB.name)
        XCTAssertEqual(userA.pixivUserID, viewerA.pixivUserID)
        XCTAssertNil(userA.creatorID)
        XCTAssertEqual(userC.creatorID, DemoFixtures.selfCreatorID)
    }

    func testSameInputsProduceSameOutputs() async throws {
        let (s1, _) = makeSource()
        let (s2, _) = makeSource()
        let a = viewerA
        let home1 = try await s1.homeTimeline(account: a, cursor: nil)
        let home2 = try await s2.homeTimeline(account: a, cursor: nil)
        XCTAssertEqual(home1.items, home2.items)
        XCTAssertEqual(home1.nextCursor, home2.nextCursor)
        let post1 = try await s1.post(id: "demo-post-104", account: a)
        let post2 = try await s2.post(id: "demo-post-104", account: a)
        XCTAssertEqual(post1, post2)
        let n1 = try await s1.notifications(account: a, cursor: nil)
        let n2 = try await s2.notifications(account: a, cursor: nil)
        XCTAssertEqual(n1.items, n2.items)
        let c1 = try await s1.comments(postID: "demo-post-101", account: a, cursor: nil)
        let c2 = try await s2.comments(postID: "demo-post-101", account: a, cursor: nil)
        XCTAssertEqual(c1.items, c2.items)
        // Repeated call on the same world is stable too.
        let home1again = try await s1.homeTimeline(account: a, cursor: nil)
        XCTAssertEqual(home1.items, home1again.items)
    }

    // MARK: - Paging

    func testPagingCursorsTerminate() async throws {
        let (source, _) = makeSource()
        let a = viewerA
        let home = try await allPages { try await source.homeTimeline(account: a, cursor: $0) }
        XCTAssertGreaterThan(home.pages, 1)
        XCTAssertEqual(Set(home.items.map(\.id)).count, home.items.count, "no duplicates across pages")
        XCTAssertEqual(home.items.map(\.publishedAt), home.items.map(\.publishedAt).sorted(by: >), "newest first")
        XCTAssertTrue(home.items.allSatisfy { $0.title.hasPrefix("Demo") })

        let supporting = try await allPages { try await source.supportingTimeline(account: a, cursor: $0) }
        let supportedIDs = Set(DemoFixtures.profile(.viewerA).supports.map(\.creatorID))
        XCTAssertFalse(supporting.items.isEmpty)
        XCTAssertTrue(supporting.items.allSatisfy { supportedIDs.contains($0.creatorID) })

        let aoi = try await allPages { try await source.creatorPosts(creatorID: "demo-aoi", account: a, cursor: $0) }
        XCTAssertEqual(aoi.items.count, DemoFixtures.readerPosts.filter { $0.creatorID == "demo-aoi" }.count)

        let notifications = try await allPages { try await source.notifications(account: a, cursor: $0) }
        XCTAssertGreaterThan(notifications.pages, 1)
        XCTAssertEqual(Set(notifications.items.map(\.remoteID)).count, notifications.items.count)

        let fans = try await allPages { try await source.fans(account: self.creator, cursor: $0) }
        XCTAssertEqual(fans.items.count, 15)
        XCTAssertEqual(fans.pages, 2)

        await assertRemoteError(.invalidRequest("Demo: 不正なカーソルです")) {
            try await source.homeTimeline(account: a, cursor: "garbage")
        }
    }

    // MARK: - Access differences

    func testRestrictedVersusViewableDiffersBetweenProfiles() async throws {
        let (source, _) = makeSource()
        let a = viewerA, b = viewerB

        // Both viewers support the same creator at different plans (integrated Creator view).
        let supportsA = try await source.supportingPlans(account: a)
        let supportsB = try await source.supportingPlans(account: b)
        XCTAssertEqual(supportsA.first { $0.creatorID == "demo-aoi" }?.fee, 500)
        XCTAssertEqual(supportsB.first { $0.creatorID == "demo-aoi" }?.fee, 1000)
        XCTAssertTrue(Set(supportsA.compactMap(\.paymentMethod) + supportsB.compactMap(\.paymentMethod)).isSuperset(of: ["card", "paypal"]))

        // ¥1,000 post of Demo 絵描きアオイ: A (¥500) restricted, B (¥1,000) viewable.
        let detailA = try await source.post(id: "demo-post-106", account: a)
        let detailB = try await source.post(id: "demo-post-106", account: b)
        XCTAssertTrue(detailA.summary.isRestricted)
        XCTAssertTrue(detailA.blocks.isEmpty)
        XCTAssertFalse(detailB.summary.isRestricted)
        XCTAssertEqual(detailB.blocks.filter { $0.kind == .image }.count, 6)

        // ¥1,000 post of Demo 作曲家ミント: A supports at ¥1,000, B at ¥500.
        let mintA = try await source.post(id: "demo-post-102", account: a)
        let mintB = try await source.post(id: "demo-post-102", account: b)
        XCTAssertFalse(mintA.summary.isRestricted)
        XCTAssertTrue(mintA.blocks.contains { $0.kind == .audio })
        XCTAssertTrue(mintB.summary.isRestricted)
        let mintCheapB = try await source.post(id: "demo-post-125", account: b)
        XCTAssertFalse(mintCheapB.summary.isRestricted, "B's ¥500 plan covers the ¥500 post")

        // Free posts are viewable by everyone.
        let free = try await source.post(id: "demo-post-107", account: a)
        XCTAssertFalse(free.summary.isRestricted)
        XCTAssertTrue(free.blocks.contains { $0.kind == .video && $0.embedProvider == "youtube" })

        // Every post type appears in the fixtures.
        let types = Set(DemoFixtures.readerPosts.map(\.type))
        XCTAssertTrue(types.isSuperset(of: [.text, .image, .file, .article, .video]))

        // Follow-only and unrelated creators exist.
        let followingA = try await source.followingCreators(account: a)
        XCTAssertTrue(followingA.contains { $0.isFollowed == true && $0.isSupported == false })
        let hisui = try await source.creator(id: "demo-hisui", account: a)
        XCTAssertEqual(hisui.isFollowed, false)
        XCTAssertEqual(hisui.isSupported, false)
    }

    // MARK: - Notifications

    func testSharedNewPostNotificationForBothViewerAccounts() async throws {
        let (source, _) = makeSource()
        let a = viewerA, b = viewerB
        let listA = try await allPages { try await source.notifications(account: a, cursor: $0) }.items
        let listB = try await allPages { try await source.notifications(account: b, cursor: $0) }.items
        let listC = try await allPages { try await source.notifications(account: self.creator, cursor: $0) }.items
        let sharedA = try XCTUnwrap(listA.first { $0.type == .newPost && $0.postID == "demo-post-101" })
        let sharedB = try XCTUnwrap(listB.first { $0.type == .newPost && $0.postID == "demo-post-101" })
        XCTAssertNotEqual(sharedA.remoteID, sharedB.remoteID, "per-account remote ids")
        XCTAssertEqual(sharedA.createdAt, sharedB.createdAt)
        XCTAssertEqual(sharedA.creatorID, sharedB.creatorID)
        let keyA = NotificationEvent.dedupeKey(type: sharedA.type, creatorID: sharedA.creatorID, postID: sharedA.postID,
                                               commentID: sharedA.commentID, newsletterID: sharedA.newsletterID, fallbackRemoteID: sharedA.remoteID)
        let keyB = NotificationEvent.dedupeKey(type: sharedB.type, creatorID: sharedB.creatorID, postID: sharedB.postID,
                                               commentID: sharedB.commentID, newsletterID: sharedB.newsletterID, fallbackRemoteID: sharedB.remoteID)
        XCTAssertEqual(keyA, keyB)

        // Every event type is covered and references are consistent.
        let all = listA + listB + listC
        XCTAssertEqual(Set(all.map(\.type)), Set(NotificationEventType.allCases))
        for n in all {
            switch n.type {
            case .comment, .commentReply:
                XCTAssertNotNil(n.commentID); XCTAssertNotNil(n.postID)
            case .newPost:
                XCTAssertNotNil(n.postID)
            case .newsletter:
                XCTAssertNotNil(n.newsletterID)
            case .supportChanged, .paymentAttention, .newSupporter:
                XCTAssertNotNil(n.creatorID)
            case .other:
                break
            }
        }
        // Newsletter notifications resolve through newsletter(id:).
        for n in listA where n.type == .newsletter {
            let letter = try await source.newsletter(id: n.newsletterID!, account: a)
            XCTAssertFalse(letter.body.isEmpty)
        }
        // Reply notifications point at an existing comment in the thread.
        let reply = try XCTUnwrap(listA.first { $0.type == .commentReply })
        let thread = try await source.comments(postID: reply.postID!, account: a, cursor: nil)
        XCTAssertTrue(thread.items.flatMap(\.flattened).contains { $0.id == reply.commentID })
    }

    // MARK: - Comments

    func testAddCommentVisibleOnNextFetchAndDelete() async throws {
        let (source, _) = makeSource()
        let a = viewerA, b = viewerB
        let before = try await source.comments(postID: "demo-post-110", account: a, cursor: nil)
        XCTAssertTrue(before.items.flatMap(\.flattened).contains { $0.isOwn == false })

        let added = try await source.addComment(postID: "demo-post-110", body: "デモのテストコメント", parentCommentID: nil,
                                                rootCommentID: nil, account: a)
        XCTAssertTrue(added.isOwn)
        let reply = try await source.addComment(postID: "demo-post-110", body: "返信です", parentCommentID: added.id,
                                                rootCommentID: added.id, account: b)
        XCTAssertEqual(reply.rootCommentID, added.id)

        let afterA = try await source.comments(postID: "demo-post-110", account: a, cursor: nil)
        let mine = try XCTUnwrap(afterA.items.first { $0.id == added.id })
        XCTAssertTrue(mine.isOwn)
        XCTAssertEqual(mine.replies.map(\.id), [reply.id])
        XCTAssertEqual(afterA.items.first?.id, added.id, "newest root first")

        let afterB = try await source.comments(postID: "demo-post-110", account: b, cursor: nil)
        XCTAssertEqual(afterB.items.first { $0.id == added.id }?.isOwn, false)

        // B got nothing, A gets a reply notification for B's reply.
        let notificationsA = try await allPages { try await source.notifications(account: a, cursor: $0) }.items
        XCTAssertTrue(notificationsA.contains { $0.type == .commentReply && $0.commentID == reply.id })

        // Fixture "you" comments are own for the matching profile only.
        let thread101 = try await source.comments(postID: "demo-post-101", account: a, cursor: nil)
        XCTAssertTrue(thread101.items.contains { $0.isOwn && $0.authorUserID == a.pixivUserID })

        // Deleting someone else's comment is forbidden; deleting own removes it (and its replies).
        await assertRemoteError(.forbidden) { try await source.deleteComment(commentID: added.id, postID: "demo-post-110", account: b) }
        try await source.deleteComment(commentID: added.id, postID: "demo-post-110", account: a)
        let afterDelete = try await source.comments(postID: "demo-post-110", account: a, cursor: nil)
        XCTAssertFalse(afterDelete.items.flatMap(\.flattened).contains { $0.id == added.id || $0.id == reply.id })

        await assertRemoteError(.invalidRequest("コメントを入力してください")) {
            try await source.addComment(postID: "demo-post-110", body: "  ", parentCommentID: nil, rootCommentID: nil, account: a)
        }
    }

    // MARK: - Offline

    func testOfflinePolicyThrowsOffline() async throws {
        let policy = NetworkPolicyStore()
        let (source, _) = makeSource(policy: policy)
        let a = viewerA
        _ = try await source.currentUser(account: a)

        policy.update { $0.mode = .offline }
        await assertRemoteError(.offline) { try await source.currentUser(account: a) }
        await assertRemoteError(.offline) { try await source.homeTimeline(account: a, cursor: nil) }
        await assertRemoteError(.offline) {
            try await source.addComment(postID: "demo-post-101", body: "x", parentCommentID: nil, rootCommentID: nil, account: a)
        }
        await assertRemoteError(.offline) {
            try await source.uploadImage(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"), account: self.creator, progress: { _ in })
        }

        policy.update { $0.mode = .normal; $0.pathSatisfied = false }
        await assertRemoteError(.offline) { try await source.notifications(account: a, cursor: nil) }

        policy.update { $0.pathSatisfied = true }
        let page = try await source.notifications(account: a, cursor: nil)
        XCTAssertFalse(page.items.isEmpty)
    }

    func testSimulatedLatencyIsApplied() async throws {
        let (source, _) = makeSource(latencyScale: 1)
        let start = Date()
        _ = try await source.currentUser(account: viewerA)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.12)
    }

    // MARK: - Creator side

    func testUploadFailsForFailNamesAndSucceedsOtherwise() async throws {
        let (source, _) = makeSource()
        let progress = DemoTestRecorder()
        let ok = try await source.uploadImage(fileURL: URL(fileURLWithPath: "/tmp/demo-ok.jpg"), account: creator) { progress.append($0) }
        XCTAssertFalse(ok.mediaID.isEmpty)
        XCTAssertEqual(progress.values.count, 10)
        XCTAssertEqual(progress.values.last ?? 0, 1, accuracy: 0.0001)

        let failing = DemoTestRecorder()
        do {
            _ = try await source.uploadFile(fileURL: URL(fileURLWithPath: "/tmp/will-fail.zip"), account: creator) { failing.append($0) }
            XCTFail("expected failure")
        } catch let error as RemoteError {
            guard case .invalidRequest = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertLessThan(failing.values.last ?? 0, 1)

        // Retrying a "fail" file fails again; a "flaky" file succeeds on retry.
        await assertRemoteError(.invalidRequest("Demo: アップロードに失敗しました（will-fail.zip）")) {
            try await source.uploadFile(fileURL: URL(fileURLWithPath: "/tmp/will-fail.zip"), account: self.creator) { _ in }
        }
        let flakyURL = URL(fileURLWithPath: "/tmp/flaky.png")
        do {
            _ = try await source.uploadImage(fileURL: flakyURL, account: creator) { _ in }
            XCTFail("first flaky attempt should fail")
        } catch {}
        let retried = try await source.uploadImage(fileURL: flakyURL, account: creator) { _ in }
        XCTAssertTrue(retried.mediaID.hasPrefix("demo-upload-img-"))

        await assertRemoteError(.forbidden) {
            try await source.uploadImage(fileURL: URL(fileURLWithPath: "/tmp/x.jpg"), account: self.viewerA) { _ in }
        }
    }

    func testCreatorModeData() async throws {
        let (source, _) = makeSource()
        let c = creator
        let managed = try await allPages { try await source.managedPosts(account: c, cursor: $0) }.items
        XCTAssertEqual(managed.count, 6)
        var statuses: [RemotePostStatus] = []
        for summary in managed {
            let editable = try await source.editablePost(id: summary.id, account: c)
            statuses.append(editable.status)
            XCTAssertFalse(summary.isRestricted, "owner sees own posts")
        }
        XCTAssertEqual(statuses.filter { $0 == .draft }.count, 2)
        XCTAssertEqual(statuses.filter { $0 == .published }.count, 4)
        let illustration = try await source.editablePost(id: "demo-post-901", account: c)
        XCTAssertTrue(illustration.blocks.contains { $0.kind == .image && $0.mediaID != nil })

        // Upload + create + update persist in the world.
        let upload = try await source.uploadImage(fileURL: URL(fileURLWithPath: "/tmp/new.jpg"), account: c) { _ in }
        let draft = RemotePostDraft(title: "Demo テスト投稿", feeRequired: 500, planID: "demo-creator-self-plan-500", tags: ["Demo"],
                                    hasAdultContent: false, blocks: [
                                        RemoteDraftBlock(kind: .text, text: "本文", mediaID: nil, url: nil, embedProvider: nil, embedContentID: nil),
                                        RemoteDraftBlock(kind: .image, text: "", mediaID: upload.mediaID, url: nil, embedProvider: nil, embedContentID: nil),
                                    ], publish: false)
        let newID = try await source.createPost(draft, account: c)
        let created = try await source.editablePost(id: newID, account: c)
        XCTAssertEqual(created.status, .draft)
        XCTAssertEqual(created.blocks.first { $0.kind == .image }?.displayURL, upload.url)
        var published = draft
        published.title = "Demo テスト投稿（公開）"
        published.publish = true
        try await source.updatePost(id: newID, published, account: c)
        let updated = try await source.editablePost(id: newID, account: c)
        XCTAssertEqual(updated.title, "Demo テスト投稿（公開）")
        XCTAssertEqual(updated.status, .published)
        let managedAfter = try await source.managedPosts(account: c, cursor: nil)
        XCTAssertEqual(managedAfter.items.first?.id, newID)
        let publicView = try await source.creatorPosts(creatorID: DemoFixtures.selfCreatorID, account: viewerA, cursor: nil)
        XCTAssertTrue(publicView.items.contains { $0.id == newID && $0.isRestricted })

        // Dashboard: actual supporter / earnings / post counts, comment count unavailable.
        let dashboard = try await source.creatorDashboard(account: c)
        XCTAssertEqual(dashboard.supporterCount, 11)
        XCTAssertEqual(dashboard.earnings, DemoFixtures.fans.filter { $0.state == .supporting }.compactMap(\.fee).reduce(0, +))
        XCTAssertNotNil(dashboard.postCount)
        XCTAssertNil(dashboard.commentCount)
        XCTAssertEqual(dashboard.month, CreatorMonth.key(anchor), "JST month, like FANBOX")

        // Fans: states and plans.
        let fans = try await allPages { try await source.fans(account: c, cursor: $0) }.items
        XCTAssertEqual(Set(fans.map(\.state)), [.supporting, .following, .ended])
        XCTAssertTrue(fans.filter { $0.state == .supporting }.allSatisfy { $0.planID != nil && $0.supportStartedAt != nil })

        // Creator comments: only on own posts, newest first, own replies flagged.
        let comments = try await allPages { try await source.creatorComments(account: c, cursor: $0) }.items
        XCTAssertFalse(comments.isEmpty)
        XCTAssertEqual(comments.map(\.createdAt), comments.map(\.createdAt).sorted(by: >))
        XCTAssertTrue(comments.contains { $0.isOwn })
        let ownPostIDs = Set(managed.map(\.id))
        XCTAssertTrue(comments.allSatisfy { ownPostIDs.contains($0.postID) })

        // Viewer accounts cannot use Creator Mode.
        await assertRemoteError(.forbidden) { try await source.managedPosts(account: self.viewerA, cursor: nil) }
        await assertRemoteError(.forbidden) { try await source.creatorDashboard(account: self.viewerB) }
    }

    // MARK: - Supports / payments

    func testSupportAnomalySecondCallLacksSupport() async throws {
        let (source, world) = makeSource()
        let b = viewerB, a = viewerA
        let missing = try XCTUnwrap(DemoFixtures.profile(.viewerB).disappearingSupportCreatorID)
        XCTAssertEqual(missing, "demo-mint")
        let before = try await source.post(id: "demo-post-125", account: b)
        XCTAssertFalse(before.summary.isRestricted, "B's ¥500 ミント plan covers the post before the support disappears")
        let first = try await source.supportingPlans(account: b)
        let second = try await source.supportingPlans(account: b)
        let third = try await source.supportingPlans(account: b)
        XCTAssertTrue(first.contains { $0.creatorID == missing })
        XCTAssertFalse(second.contains { $0.creatorID == missing })
        XCTAssertEqual(second, third)
        XCTAssertEqual(first.count, second.count + 1)
        let calls = await world.supportingPlansCallCount(accountID: b.accountID)
        XCTAssertEqual(calls, 3)
        // After the disappearance, paid posts of that creator become restricted for B.
        let mintPostB = try await source.post(id: "demo-post-125", account: b)
        XCTAssertTrue(mintPostB.summary.isRestricted)

        // Viewer A is stable and keeps supporting the same creator.
        let a1 = try await source.supportingPlans(account: a)
        let a2 = try await source.supportingPlans(account: a)
        XCTAssertEqual(a1, a2)
        XCTAssertTrue(a2.contains { $0.creatorID == missing })
        let mintPostA = try await source.post(id: "demo-post-125", account: a)
        XCTAssertFalse(mintPostA.summary.isRestricted)
    }

    /// The demo accounts are one person's accounts: FANBOX allows one plan per account per creator, so the viewer
    /// accounts support mostly the same creators, and the per-account state changes sit on creators the other account
    /// keeps supporting.
    func testViewerAccountsSupportMostlyTheSameCreators() throws {
        let a = DemoFixtures.profile(.viewerA), b = DemoFixtures.profile(.viewerB)
        let feesA = Dictionary(uniqueKeysWithValues: a.supports.map { ($0.creatorID, $0.fee) })
        let feesB = Dictionary(uniqueKeysWithValues: b.supports.map { ($0.creatorID, $0.fee) })
        let shared = Set(feesA.keys).intersection(feesB.keys)
        let all = Set(feesA.keys).union(feesB.keys)
        XCTAssertGreaterThan(shared.count * 2, all.count, "most supported creators are supported by both viewer accounts")
        for creatorID in shared {
            XCTAssertEqual(a.supports.filter { $0.creatorID == creatorID }.count, 1, "\(creatorID): one support per account")
            XCTAssertEqual(b.supports.filter { $0.creatorID == creatorID }.count, 1, "\(creatorID): one support per account")
        }
        XCTAssertTrue(DemoFixtures.profile(.creator).supports.contains { $0.creatorID == "demo-aoi" })
        XCTAssertTrue(shared.contains("demo-aoi"), "one creator is supported by all three demo accounts")

        // A stops a support that B keeps.
        let stopping = a.supports.filter(\.stopping)
        XCTAssertFalse(stopping.isEmpty)
        for support in stopping {
            let other = try XCTUnwrap(b.supports.first { $0.creatorID == support.creatorID })
            XCTAssertFalse(other.stopping)
        }
        // B loses a support that A keeps.
        let disappearing = try XCTUnwrap(b.disappearingSupportCreatorID)
        XCTAssertNotNil(feesA[disappearing])
        // The fixture support-state events of one account are on creators the other account also supports.
        for (profile, other) in [(DemoProfile.viewerA, feesB), (.viewerB, feesA)] {
            let events = (DemoFixtures.notifications[profile] ?? []).filter { $0.type == .paymentAttention || $0.type == .supportChanged }
            XCTAssertTrue(events.contains { event in event.creatorID.map { other[$0] != nil } ?? false }, "\(profile)")
        }
    }

    func testThisMonthActualDiffersFromRecurring() async throws {
        let (source, _) = makeSource()
        let a = viewerA
        let supports = try await source.supportingPlans(account: a)
        let recurring = supports.map(\.fee).reduce(0, +)
        let payments = try await source.paidRecords(account: a)
        let month = SupportAnalyzer.monthKey(anchor)
        let thisMonth = payments.filter { SupportAnalyzer.monthKey($0.paidAt) == month }
        let previousKey = SupportAnalyzer.monthKey(Calendar.current.date(byAdding: .month, value: -1, to: anchor)!)
        let lastMonth = payments.filter { SupportAnalyzer.monthKey($0.paidAt) == previousKey }
        XCTAssertFalse(thisMonth.isEmpty)
        XCTAssertFalse(lastMonth.isEmpty)
        XCTAssertTrue(thisMonth.allSatisfy { $0.paidAt <= anchor })
        XCTAssertNotEqual(thisMonth.map(\.amount).reduce(0, +), recurring)
        XCTAssertEqual(recurring, 5600)
        XCTAssertEqual(thisMonth.map(\.amount).reduce(0, +), 6100)
    }

    // MARK: - Media

    func testDemoMediaURLsParseAndRender() throws {
        let set = DemoMedia.imageSet(seed: "demo-post-101-1", width: 2400, height: 3200)
        XCTAssertEqual(DemoMedia.parse(set.thumbnail), .image(seed: "demo-post-101-1", width: 270, height: 360, variant: .thumbnail))
        XCTAssertEqual(DemoMedia.parse(set.original), .image(seed: "demo-post-101-1", width: 2400, height: 3200, variant: .original))
        let image = try XCTUnwrap(DemoMedia.renderImage(url: set.display))
        XCTAssertEqual(image.size.height * image.scale, 1200, accuracy: 1)
        XCTAssertNotNil(DemoMedia.placeholderData(for: set.thumbnail))
        let zip = try XCTUnwrap(DemoMedia.placeholderData(for: DemoMedia.fileURL(name: "a.zip", size: 1000)))
        XCTAssertEqual(Array(zip.prefix(4)), [0x50, 0x4B, 0x05, 0x06])
        XCTAssertEqual(DemoMedia.parse(DemoMedia.fileURL(name: "楽譜.pdf", size: 42)), .file(name: "楽譜.pdf", size: 42))
        XCTAssertNil(DemoMedia.placeholderData(for: "https://example.com/a.png"))
    }
}

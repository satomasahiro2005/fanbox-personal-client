import SwiftData
import XCTest
@testable import FANBOXClient

@MainActor
final class SyncUpsertTests: XCTestCase {
    func testPostsDedupedAcrossAccountsWithPostAccess() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        h.store.applySupports([SyncFixtures.support("c1", plan: "p500", fee: 500)], account: a.context, source: .sync)

        h.store.upsertPostSummaries([SyncFixtures.summary("p1")], account: a.context, source: .home)
        h.store.upsertPostSummaries([SyncFixtures.summary("p1", restricted: true, fee: 1000)], account: b.context, source: .supporting)

        let posts = h.store.fetch(FetchDescriptor<Post>())
        XCTAssertEqual(posts.count, 1, "same postID from two accounts must be one Post")
        let post = try XCTUnwrap(h.store.post(id: "p1"))
        let accesses = h.store.postAccesses(postID: "p1")
        XCTAssertEqual(accesses.count, 2)
        XCTAssertEqual(accesses.first { $0.accountID == a.id }?.canView, true)
        XCTAssertEqual(accesses.first { $0.accountID == a.id }?.accountPlanFee, 500)
        XCTAssertEqual(accesses.first { $0.accountID == b.id }?.canView, false)
        XCTAssertNil(accesses.first { $0.accountID == b.id }?.accountPlanFee)
        XCTAssertEqual(post.accessAccountIDs, [a.id])
        XCTAssertEqual(Set(post.seenByAccountIDs), [a.id, b.id])
        XCTAssertTrue(post.isFromSupportedCreator)
        XCTAssertTrue(post.isFromFollowedCreator)
        XCTAssertFalse(post.isOwnPost)
        let creator = try XCTUnwrap(h.store.creator(id: "c1"))
        XCTAssertTrue(creator.hasKnownPosts)
        XCTAssertEqual(creator.latestPostAt, SyncFixtures.base)

        // B later gains access → recomputed from PostAccess.
        h.store.upsertPostSummaries([SyncFixtures.summary("p1")], account: b.context, source: .supporting)
        XCTAssertEqual(Set(post.accessAccountIDs), [a.id, b.id])
    }

    func testOwnPostsAreFlagged() throws {
        let h = try SyncHarness()
        let me = h.addAccount("Me", pixivUserID: "pMe", creatorID: "mine")
        let other = h.addAccount("Other", pixivUserID: "pO")
        h.store.upsertPostSummaries([SyncFixtures.summary("own1", creator: "mine")], account: other.context, source: .home)
        XCTAssertEqual(h.store.post(id: "own1")?.isOwnPost, true)
        XCTAssertEqual(h.store.creator(id: "mine")?.ownedByAccountID, me.id)

        h.store.upsertManagedPosts([SyncFixtures.summary("own2", creator: "mine", restricted: true)], account: me.context)
        XCTAssertEqual(h.store.post(id: "own2")?.isOwnPost, true)
        XCTAssertEqual(h.store.post(id: "own2")?.accessAccountIDs, [me.id], "the owner can always view")
    }

    func testRestrictedDetailDoesNotWipeCachedBody() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA")
        let b = h.addAccount("B", pixivUserID: "pB")

        h.store.upsertPostDetail(SyncFixtures.detail("p1", text: "支援者向け本文"), account: a.context)
        let post = try XCTUnwrap(h.store.post(id: "p1"))
        XCTAssertEqual(post.bodyText, "支援者向け本文")
        XCTAssertEqual(post.orderedBlocks.count, 2)
        XCTAssertEqual(post.orderedBlocks.map(\.key), ["p1#0", "p1#1"])
        XCTAssertEqual(post.detailAccountID, a.id)
        XCTAssertNotNil(post.bodyFetchedAt)
        let media = h.store.fetch(FetchDescriptor<Media>())
        XCTAssertEqual(media.map(\.id), ["img-p1"])
        XCTAssertEqual(media.first?.kind, .image)
        XCTAssertEqual(media.first?.originalURL, "https://example.invalid/o.jpg")

        // Another account only gets a restricted detail: body stays, only PostAccess changes.
        h.store.upsertPostDetail(SyncFixtures.detail("p1", restricted: true), account: b.context)
        XCTAssertEqual(post.bodyText, "支援者向け本文")
        XCTAssertEqual(post.orderedBlocks.count, 2)
        XCTAssertEqual(post.detailAccountID, a.id)
        let accesses = h.store.postAccesses(postID: "p1")
        XCTAssertEqual(accesses.first { $0.accountID == b.id }?.canView, false)
        XCTAssertEqual(accesses.first { $0.accountID == a.id }?.bodyCached, true)
        XCTAssertEqual(post.accessAccountIDs, [a.id])

        // Same account, restricted now (e.g. support ended): still never wiped.
        h.store.upsertPostDetail(SyncFixtures.detail("p1", restricted: true), account: a.context)
        XCTAssertEqual(post.bodyText, "支援者向け本文")
        XCTAssertEqual(post.orderedBlocks.count, 2)

        // A fresh, viewable detail replaces the blocks.
        h.store.upsertPostDetail(SyncFixtures.detail("p1", text: "改訂", withImage: false), account: a.context)
        XCTAssertEqual(post.bodyText, "改訂")
        XCTAssertEqual(post.orderedBlocks.map(\.text), ["改訂"])
        XCTAssertEqual(h.store.fetch(FetchDescriptor<PostBlock>()).count, 1)
    }

    func testUserMetadataPreservedOnReupsert() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA")
        h.store.upsertPostSummaries([SyncFixtures.summary("p1")], account: a.context, source: .home)
        let post = try XCTUnwrap(h.store.post(id: "p1"))
        let readAt = Date(timeIntervalSince1970: 1_700_000_000)
        post.isRead = true
        post.readAt = readAt
        post.isFavorite = true
        post.isReadLater = true
        post.memo = "あとで見返す"
        post.offlineState = .saved
        h.store.context.insert(PostTag(postID: "p1", tagName: "#Music"))
        let creator = try XCTUnwrap(h.store.creator(id: "c1"))
        creator.isFavorite = true
        creator.memo = "好き"
        h.store.save()

        var changed = SyncFixtures.summary("p1", title: "新しいタイトル")
        changed.likeCount = 42
        h.store.upsertPostSummaries([changed], account: a.context, source: .supporting)
        h.store.upsertPostDetail(SyncFixtures.detail("p1"), account: a.context)
        h.store.upsertCreator(RemoteCreator(creatorID: "c1", name: "Renamed"), account: a.context)

        XCTAssertEqual(post.title, "Post p1", "detail re-upsert carries the fixture title")
        XCTAssertTrue(post.isRead)
        XCTAssertEqual(post.readAt, readAt)
        XCTAssertTrue(post.isFavorite)
        XCTAssertTrue(post.isReadLater)
        XCTAssertEqual(post.memo, "あとで見返す")
        XCTAssertEqual(post.offlineState, .saved)
        XCTAssertEqual(h.store.fetch(FetchDescriptor<PostTag>()).map(\.tagName), ["music"])
        XCTAssertTrue(creator.isFavorite)
        XCTAssertEqual(creator.memo, "好き")
        XCTAssertEqual(creator.name, "Renamed")

        h.store.upsertPostSummaries([changed], account: a.context, source: .home)
        XCTAssertEqual(post.title, "新しいタイトル")
        XCTAssertEqual(post.likeCount, 42)
        XCTAssertTrue(post.isRead)
    }

    func testSupportsDiffRecordsHistoryMissingAndRestored() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA")
        let ctx = a.context

        var diff = h.store.applySupports([SyncFixtures.support("c1", plan: "p500", fee: 500)], account: ctx, source: .sync)
        XCTAssertEqual(diff.started, ["c1"])
        let support = try XCTUnwrap(h.store.supports(accountID: a.id).first)
        XCTAssertEqual(support.status, .active)
        XCTAssertEqual(support.amount, 500)
        XCTAssertEqual(h.store.creator(id: "c1")?.isSupported, true)
        XCTAssertEqual(h.store.creator(id: "c1")?.supportedByAccountIDs, [a.id])
        XCTAssertEqual(h.store.plans(creatorID: "c1").map(\.planID), ["p500"])
        let assignment = try XCTUnwrap(h.store.fetch(FetchDescriptor<SupportPaymentAssignment>()).first)
        XCTAssertEqual(assignment.verificationState, .unknown, "payment state is never asserted")

        diff = h.store.applySupports([SyncFixtures.support("c1", plan: "p1000", fee: 1000)], account: ctx, source: .sync)
        XCTAssertEqual(diff.changed, ["c1"])
        XCTAssertEqual(support.amount, 1000)

        diff = h.store.applySupports([], account: ctx, source: .backgroundSync)
        XCTAssertEqual(diff.disappeared, ["c1"])
        XCTAssertEqual(support.status, .missing)
        XCTAssertTrue(support.needsAttention)
        XCTAssertNotNil(support.missingSince)
        XCTAssertEqual(support.attentionReason, LocalStore.supportMissingReason)
        XCTAssertFalse(support.attentionReason?.contains("決済失敗") ?? true)
        XCTAssertEqual(h.store.creator(id: "c1")?.isSupported, false)
        XCTAssertEqual(h.store.supports(accountID: a.id).count, 1, "missing supports are kept, not deleted")

        // Still missing on the next sync: no duplicate history.
        diff = h.store.applySupports([], account: ctx, source: .sync)
        XCTAssertTrue(diff.isEmpty)

        diff = h.store.applySupports([SyncFixtures.support("c1", plan: "p1000", fee: 1000)], account: ctx, source: .sync)
        XCTAssertEqual(diff.restored, ["c1"])
        XCTAssertEqual(support.status, .active)
        XCTAssertFalse(support.needsAttention)
        XCTAssertNil(support.attentionReason)
        XCTAssertNil(support.missingSince)
        XCTAssertEqual(h.store.creator(id: "c1")?.isSupported, true)

        let history = h.store.fetch(FetchDescriptor<SupportHistory>(sortBy: [SortDescriptor(\.timestamp)]))
        XCTAssertEqual(history.map(\.kind), [.started, .planChanged, .disappeared, .restored])
        let change = try XCTUnwrap(history.first { $0.kind == .planChanged })
        XCTAssertEqual(change.oldAmount, 500)
        XCTAssertEqual(change.newAmount, 1000)
        XCTAssertEqual(history.first { $0.kind == .disappeared }?.observedSource, .backgroundSync)
        XCTAssertEqual(h.store.fetch(FetchDescriptor<SupportPaymentAssignment>()).count, 1)
    }

    func testNotificationDedupeAcrossAccounts() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA")
        let b = h.addAccount("B", pixivUserID: "pB")

        let first = h.store.upsertNotifications([SyncFixtures.notification("r1", type: .newPost, postID: "p9")], account: a.context)
        XCTAssertEqual(first, ["newPost|p9"])
        let second = h.store.upsertNotifications([SyncFixtures.notification("r77", type: .newPost, postID: "p9"),
                                                  SyncFixtures.notification("r78", type: .comment, postID: "p9", commentID: "cm1")],
                                                 account: b.context)
        XCTAssertEqual(second, ["comment|cm1"], "only the comment is new; the post event is a duplicate")
        let events = h.store.fetch(FetchDescriptor<NotificationEvent>())
        XCTAssertEqual(events.count, 2)
        let post = try XCTUnwrap(h.store.notificationEvent(id: "newPost|p9"))
        XCTAssertEqual(Set(post.accountIDs), [a.id, b.id])
        XCTAssertEqual(Set(post.remoteIDs), ["\(a.id):r1", "\(b.id):r77"])
        XCTAssertEqual(post.prefetchState, .pending)

        // Re-delivering the same data reports nothing new and keeps the local read state.
        post.isRead = true
        let again = h.store.upsertNotifications([SyncFixtures.notification("r1", type: .newPost, postID: "p9")], account: a.context)
        XCTAssertTrue(again.isEmpty)
        XCTAssertTrue(post.isRead)
        XCTAssertEqual(post.remoteIDs.count, 2)
    }

    func testCommentsFlattenOwnershipAndUnreadOnOwnPost() throws {
        let h = try SyncHarness()
        let me = h.addAccount("Me", pixivUserID: "pMe", creatorID: "mine")
        h.store.upsertManagedPosts([SyncFixtures.summary("own1", creator: "mine")], account: me.context)

        let reply = RemoteComment(id: "r2", postID: "own1", authorUserID: "pMe", authorName: "Me", body: "ありがとう", createdAt: .now)
        let root = RemoteComment(id: "r1", postID: "own1", authorUserID: "fan1", authorName: "Fan", body: "最高です",
                                 createdAt: .now.addingTimeInterval(-60), replies: [reply])
        h.store.upsertComments([root], postID: "own1", account: me.context)

        let comments = h.store.comments(postID: "own1")
        XCTAssertEqual(comments.count, 2)
        let r1 = try XCTUnwrap(comments.first { $0.commentID == "r1" })
        let r2 = try XCTUnwrap(comments.first { $0.commentID == "r2" })
        XCTAssertEqual(r2.parentCommentID, "r1")
        XCTAssertEqual(r2.rootCommentID, "r1")
        XCTAssertTrue(r2.isOwn)
        XCTAssertTrue(r2.isRead)
        XCTAssertFalse(r1.isOwn)
        XCTAssertTrue(r1.isOnOwnPost)
        XCTAssertFalse(r1.isRead, "new comments on my posts start unread")
        XCTAssertEqual(r1.creatorID, "mine")

        r1.isRead = true
        h.store.upsertComments([root], postID: "own1", account: me.context)
        XCTAssertTrue(r1.isRead, "existing read state is kept")

        h.store.deleteLocalComment(commentID: "r2")
        XCTAssertEqual(h.store.comments(postID: "own1").map(\.commentID), ["r1"])
    }

    func testDashboardMetricSources() throws {
        let h = try SyncHarness()
        let me = h.addAccount("Me", pixivUserID: "pMe", creatorID: "mine")
        h.store.upsertDashboard(RemoteCreatorDashboard(month: "2026-09", supporterCount: 10, earnings: nil, postCount: 2, commentCount: nil),
                                account: me.context)
        let snap = try XCTUnwrap(h.store.fetch(FetchDescriptor<CreatorDashboardSnapshot>()).first)
        XCTAssertEqual(snap.supporterCountSource, .actual)
        XCTAssertEqual(snap.earningsSource, .unavailable)
        XCTAssertNil(snap.earnings)
        XCTAssertEqual(snap.postCountSource, .actual)
    }
}

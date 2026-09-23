import SwiftData
import UserNotifications
import XCTest
@testable import FANBOXClient

@MainActor
final class SyncNotificationTests: XCTestCase {
    private func event(_ type: NotificationEventType, postID: String? = "p1", commentID: String? = "cm1", newsletterID: String? = "nl1",
                       creatorID: String? = "c1") -> NotificationEvent {
        NotificationEvent(id: "\(type.rawValue)|x", type: type, accountIDs: ["a"], title: "t", message: "m", timestamp: .now,
                          creatorID: creatorID, postID: postID, commentID: commentID, newsletterID: newsletterID)
    }

    func testRouteMapping() {
        XCTAssertEqual(NotificationService.destination(for: event(.comment)), .home(.comments(postID: "p1", focusCommentID: "cm1")))
        XCTAssertEqual(NotificationService.destination(for: event(.commentReply)), .home(.comments(postID: "p1", focusCommentID: "cm1")))
        XCTAssertEqual(NotificationService.destination(for: event(.newPost)), .home(.post(postID: "p1")))
        XCTAssertEqual(NotificationService.destination(for: event(.newsletter)), .home(.newsletter(newsletterID: "nl1")))
        XCTAssertEqual(NotificationService.destination(for: event(.supportChanged)), .support(.supportCreator(creatorID: "c1")))
        XCTAssertEqual(NotificationService.destination(for: event(.paymentAttention, creatorID: nil)), .support(nil))
        XCTAssertEqual(NotificationService.destination(for: event(.newSupporter)), .creatorMode(.fans))
        XCTAssertEqual(NotificationService.destination(for: event(.other)), .inbox)
        XCTAssertEqual(NotificationService.destination(for: event(.comment, postID: nil)), .inbox)
    }

    func testOpenRoutesImmediatelyAndMarksRead() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let ids = h.store.upsertNotifications([SyncFixtures.notification("r1", type: .comment, postID: "p1", commentID: "cm1"),
                                              SyncFixtures.notification("r2", type: .supportChanged, creatorID: "c7"),
                                              SyncFixtures.notification("r3", type: .newSupporter, creatorID: nil),
                                              SyncFixtures.notification("r4", type: .other, creatorID: nil)],
                                             account: a.context)
        XCTAssertEqual(ids.count, 4)
        let service = h.notifications

        h.router.isNotificationInboxPresented = true
        service.open(eventID: "comment|cm1")
        XCTAssertEqual(h.router.selectedTab, .home)
        XCTAssertEqual(h.router.homePath.count, 1)
        XCTAssertFalse(h.router.isNotificationInboxPresented)
        XCTAssertEqual(h.store.notificationEvent(id: "comment|cm1")?.isRead, true)

        service.open(eventID: ids[1])
        XCTAssertEqual(h.router.selectedTab, .support)
        XCTAssertEqual(h.router.supportPath.count, 1)

        service.open(eventID: ids[2])
        XCTAssertEqual(h.router.selectedTab, .creatorMode)
        XCTAssertEqual(h.router.creatorModePath.count, 1)

        service.open(eventID: ids[3])
        XCTAssertTrue(h.router.isNotificationInboxPresented)
        XCTAssertTrue(h.mock.calls.isEmpty, "opening never waits for the network")
    }

    func testProcessPrefetchesThreadThenPostsReadableNotification() async throws {
        let h = try SyncHarness()
        let me = h.addAccount("Creator", pixivUserID: "pMe", creatorID: "mine", isMain: true)
        h.store.upsertManagedPosts([SyncFixtures.summary("own1", creator: "mine")], account: me.context)
        h.mock.update {
            $0.comments["own1"] = [RemoteComment(id: "cm9", postID: "own1", authorUserID: "fan", authorName: "ファンA",
                                                 body: "新作とても良かったです！", createdAt: .now)]
            $0.details[me.id] = ["own1": SyncFixtures.detail("own1", creator: "mine")]
        }
        let ids = h.store.upsertNotifications([SyncFixtures.notification("r9", type: .comment, postID: "own1", commentID: "cm9",
                                                                         creatorID: "mine")], account: me.context)
        // Time-sensitive delivery needs the entitlement; simulate an entitled build (fallback: FixSyncNotifyNotificationTests).
        h.notifications.timeSensitiveAvailable = true
        await h.notifications.process(newEventIDs: ids)

        let event = try XCTUnwrap(h.store.notificationEvent(id: "comment|cm9"))
        XCTAssertEqual(event.prefetchState, .textReady)
        XCTAssertTrue(event.deliveredLocally)
        XCTAssertEqual(h.mock.count("comments|\(me.id)|own1"), 1, "the owning creator account fetches the thread")
        XCTAssertEqual(h.store.post(id: "own1")?.hasCachedBody, true, "post body prefetched too")
        let request = try XCTUnwrap(h.poster.requests.first)
        XCTAssertEqual(request.identifier, "comment|cm9")
        XCTAssertTrue(request.content.body.contains("新作とても良かったです！"), "body readable without opening the app")
        XCTAssertTrue(request.content.title.contains("ファンA"))
        XCTAssertEqual(request.content.userInfo[NotificationService.eventIDKey] as? String, "comment|cm9")
        XCTAssertEqual(request.content.categoryIdentifier, NotificationService.commentCategoryID)
        XCTAssertEqual(request.content.threadIdentifier, "mine")
        XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(h.poster.badge, 1)

        // Delivered once only.
        await h.notifications.process(newEventIDs: ids)
        XCTAssertEqual(h.poster.requests.count, 1)
    }

    func testProcessOrdersCriticalFirstAndHonorsSetting() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let ids = h.store.upsertNotifications([SyncFixtures.notification("r1", type: .newSupporter, creatorID: nil),
                                              SyncFixtures.notification("r2", type: .comment, postID: "p1", commentID: "cm1")],
                                             account: a.context)
        await h.notifications.process(newEventIDs: ids)
        XCTAssertEqual(h.poster.requests.map(\.identifier).first, "comment|cm1")

        h.settings.localNotificationsEnabled = false
        let more = h.store.upsertNotifications([SyncFixtures.notification("r3", type: .newPost, postID: "p5")], account: a.context)
        await h.notifications.process(newEventIDs: more)
        XCTAssertEqual(h.poster.requests.count, 2, "no local notification while disabled")
    }

    func testInlineReplyQueuesAsOwningCreatorAccountAndSends() async throws {
        let h = try SyncHarness()
        let reader = h.addAccount("Reader", pixivUserID: "pR", isMain: true)
        let me = h.addAccount("Creator", pixivUserID: "pMe", creatorID: "mine")
        h.store.upsertManagedPosts([SyncFixtures.summary("own1", creator: "mine")], account: me.context)
        h.store.upsertComments([RemoteComment(id: "cm9", postID: "own1", rootCommentID: "cm1", authorUserID: "fan", authorName: "Fan",
                                              body: "質問です", createdAt: .now)], postID: "own1", account: me.context)
        let ids = h.store.upsertNotifications([SyncFixtures.notification("r9", type: .commentReply, postID: "own1", commentID: "cm9",
                                                                         creatorID: "mine")], account: reader.context)

        let replyID = await h.notifications.handleReply(eventID: ids[0], text: "  回答します  ")
        let item = try XCTUnwrap(replyID.flatMap { h.replies.item(id: $0) })
        XCTAssertEqual(item.accountID, me.id, "prefers the creator account that owns the post")
        XCTAssertEqual(item.parentCommentID, "cm9")
        XCTAssertEqual(item.rootCommentID, "cm1")
        XCTAssertEqual(item.origin, .notificationAction)
        XCTAssertEqual(item.body, "回答します")
        XCTAssertEqual(item.state, .sent)
        XCTAssertEqual(h.mock.count("addComment|\(me.id)|own1"), 1)
        XCTAssertEqual(h.store.notificationEvent(id: ids[0])?.isRead, true)
    }

    func testInlineReplyOfflineIsKeptQueued() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let ids = h.store.upsertNotifications([SyncFixtures.notification("r1", type: .comment, postID: "p1", commentID: "cm1")],
                                             account: a.context)
        h.setOffline(true)
        let replyID = await h.notifications.handleReply(eventID: ids[0], text: "電波が悪いけど返信")
        XCTAssertEqual(replyID.flatMap { h.replies.item(id: $0) }?.state, .queued)
        XCTAssertEqual(h.mock.count("addComment"), 0)
    }

    func testCategoriesExposeInlineReply() throws {
        let categories = NotificationService.categories()
        let comment = try XCTUnwrap(categories.first { $0.identifier == NotificationService.commentCategoryID })
        let reply = try XCTUnwrap(comment.actions.first { $0.identifier == NotificationService.replyActionID } as? UNTextInputNotificationAction)
        XCTAssertEqual(reply.title, "返信")
        XCTAssertEqual(reply.textInputButtonTitle, "送信")
        XCTAssertEqual(reply.textInputPlaceholder, "返信を入力")
        XCTAssertTrue(comment.actions.contains { $0.identifier == NotificationService.markReadActionID })
        XCTAssertEqual(categories.count, 3)
    }
}

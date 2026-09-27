import SwiftData
import UserNotifications
import XCTest
@testable import FANBOXClient

/// Notification pipeline: comment resolution for threaded replies, delivery level, badge / read state, prefetch retry,
/// Priority 2 media, cross-account dedupe, inbox retention.
@MainActor
final class FixSyncNotifyNotificationTests: XCTestCase {
    private typealias Candidate = NotificationCommentResolver.Candidate
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// FANBOX-style comment bell: no comment id, the comment text in `message`.
    private func fanboxCommentBell(_ remoteID: String, type: NotificationEventType = .comment, postID: String, body: String,
                                   actor: String = "Fan", at date: Date = .now, unread: Bool = true) -> RemoteNotification {
        RemoteNotification(remoteID: remoteID, type: type, rawType: "post_comment", createdAt: date, creatorID: "mine", creatorName: "Me",
                           postID: postID, postTitle: "作品", commentID: nil, newsletterID: nil, actorName: actor, actorIconURL: nil,
                           title: "\(actor)さんがコメントしました", message: body, isUnread: unread)
    }

    // MARK: Resolver (pure)

    func testResolverMatchesTextAuthorAndTime() {
        let candidates = [
            Candidate(id: "c1", parentID: nil, authorName: "Fan", body: "素敵です", createdAt: t0, isOwn: false),
            Candidate(id: "c2", parentID: nil, authorName: "Other", body: "素敵です", createdAt: t0, isOwn: false),
            Candidate(id: "c3", parentID: "c1", authorName: "Fan", body: "返信です", createdAt: t0.addingTimeInterval(30), isOwn: false),
            Candidate(id: "mine", parentID: "c1", authorName: "Me", body: "ありがとう", createdAt: t0, isOwn: true),
        ]
        XCTAssertEqual(NotificationCommentResolver.resolve(type: .comment, message: " 素敵です ", actorName: "Fan", timestamp: t0, bellIDs: [],
                                                           postTitle: "作品", candidates: candidates), "c1")
        XCTAssertEqual(NotificationCommentResolver.resolve(type: .commentReply, message: "返信です", actorName: "Fan", timestamp: t0, bellIDs: [],
                                                           postTitle: "作品", candidates: candidates), "c3")
        // A reply event never resolves to a root comment.
        XCTAssertNil(NotificationCommentResolver.resolve(type: .commentReply, message: "素敵です", actorName: "Fan", timestamp: t0, bellIDs: [],
                                                         postTitle: "作品", candidates: candidates))
        // Too far in time.
        XCTAssertNil(NotificationCommentResolver.resolve(type: .comment, message: "素敵です", actorName: "Fan",
                                                         timestamp: t0.addingTimeInterval(3600), bellIDs: [], postTitle: nil, candidates: candidates))
        // Own comments are never the target.
        XCTAssertNil(NotificationCommentResolver.resolve(type: .comment, message: "ありがとう", actorName: nil, timestamp: t0, bellIDs: [],
                                                         postTitle: nil, candidates: candidates))
        // Without the text, only a unique author + time match is trusted.
        XCTAssertNil(NotificationCommentResolver.resolve(type: .comment, message: "作品", actorName: "Fan", timestamp: t0, bellIDs: [],
                                                         postTitle: "作品", candidates: candidates))
        XCTAssertEqual(NotificationCommentResolver.resolve(type: .comment, message: "", actorName: "Other", timestamp: t0, bellIDs: [],
                                                           postTitle: nil, candidates: candidates), "c2")
        // A bell id equal to a comment id is used when it also fits.
        XCTAssertEqual(NotificationCommentResolver.resolve(type: .comment, message: "", actorName: "Fan", timestamp: t0, bellIDs: ["c3"],
                                                           postTitle: nil, candidates: candidates), "c3")
        XCTAssertEqual(NotificationCommentResolver.bellIDs(fromRemoteIDs: ["acc-1:991", "acc-2:bell:post_comment:1:2"]), ["991"])
    }

    /// A creator thanking several fans with the same text: the reply to someone else is never the target, and two equal
    /// candidates are ambiguous even though the text is known.
    func testResolverNeverPicksAReplyAddressedToSomeoneElse() {
        let toOther = Candidate(id: "r-y", parentID: "cy", authorName: "X", body: "ありがとうございます！", createdAt: t0, isOwn: false,
                                parentAuthorUserID: "fanY")
        let toMe = Candidate(id: "r-a", parentID: "ca", authorName: "X", body: "ありがとうございます！", createdAt: t0.addingTimeInterval(5),
                             isOwn: false, parentAuthorUserID: "pA")
        func resolve(_ candidates: [Candidate], receivers: Set<String>?) -> String? {
            NotificationCommentResolver.resolve(type: .commentReply, message: "ありがとうございます！", actorName: "X", timestamp: t0,
                                                bellIDs: [], postTitle: nil, candidates: candidates, replyParentAuthors: receivers)
        }
        XCTAssertNil(resolve([toOther], receivers: ["pA"]), "my comment's reply is not local yet: nothing to answer")
        XCTAssertEqual(resolve([toOther, toMe], receivers: ["pA"]), "r-a")
        XCTAssertNil(resolve([toOther, toMe], receivers: nil), "two equal replies are ambiguous")
    }

    // MARK: Threaded reply from the notification (§45 通知から即コメント返信)

    func testPrefetchResolvesTheCommentSoTheReplyIsThreaded() async throws {
        let h = try SyncHarness()
        let me = h.addAccount("Creator", pixivUserID: "pMe", creatorID: "mine", isMain: true)
        h.store.upsertManagedPosts([SyncFixtures.summary("own1", creator: "mine")], account: me.context)
        let now = Date.now
        h.mock.update {
            $0.comments["own1"] = [RemoteComment(id: "c1", postID: "own1", authorUserID: "fan", authorName: "Fan", body: "質問があります",
                                                 createdAt: now.addingTimeInterval(-600),
                                                 replies: [RemoteComment(id: "c2", postID: "own1", parentCommentID: "c1", rootCommentID: "c1",
                                                                         authorUserID: "fan", authorName: "Fan", body: "追記です", createdAt: now)])]
        }
        let ids = h.store.upsertNotifications([fanboxCommentBell("b77", type: .commentReply, postID: "own1", body: "追記です", at: now)],
                                              account: me.context)
        await h.notifications.process(newEventIDs: ids)
        let event = try XCTUnwrap(h.store.notificationEvent(id: ids[0]))
        XCTAssertEqual(event.commentID, "c2")
        XCTAssertEqual(NotificationService.destination(for: event), .home(.comments(postID: "own1", focusCommentID: "c2")))
        XCTAssertEqual(h.store.comments(postID: "own1").first { $0.commentID == "c2" }?.isRead, false, "notified comment stays unread")

        let replyID = await h.notifications.handleReply(eventID: ids[0], text: "回答します")
        let item = try XCTUnwrap(replyID.flatMap { h.replies.item(id: $0) })
        XCTAssertEqual(item.parentCommentID, "c2")
        XCTAssertEqual(item.rootCommentID, "c1")
        XCTAssertEqual(item.state, .sent)
    }

    /// A comment bell on my post that is not stored locally (published on the web): the new comment still counts as a
    /// comment on my post (Creator Mode 未読), and a later listing that cannot tell never hides it again.
    func testCommentBellOnAnOwnPostWithoutALocalRowStaysInCreatorMode() async throws {
        let h = try SyncHarness()
        let me = h.addAccount("Creator", pixivUserID: "pMe", creatorID: "mine", isMain: true)
        let now = Date.now
        h.mock.update {
            $0.comments["web1"] = [RemoteComment(id: "c1", postID: "web1", authorUserID: "fan", authorName: "Fan", body: "新作楽しみです",
                                                 createdAt: now)]
        }
        let ids = h.store.upsertNotifications([fanboxCommentBell("b1", postID: "web1", body: "新作楽しみです", at: now)], account: me.context)
        XCTAssertNil(h.store.post(id: "web1"))
        await h.notifications.prefetch(eventID: ids[0])
        let comment = try XCTUnwrap(h.store.comments(postID: "web1").first)
        XCTAssertTrue(comment.isOnOwnPost)
        XCTAssertFalse(comment.isRead, "a new comment on my post is unread")

        h.store.upsertComments([RemoteComment(id: "c1", postID: "web1", authorUserID: "fan", authorName: "Fan", body: "新作楽しみです",
                                              createdAt: now)], postID: "web1", account: me.context)
        XCTAssertTrue(comment.isOnOwnPost, "never downgraded by a listing without the post")
    }

    func testReplyResolvesTheCommentOnDemandWhenThePrefetchHadNotRun() async throws {
        let h = try SyncHarness()
        let me = h.addAccount("Creator", pixivUserID: "pMe", creatorID: "mine", isMain: true)
        h.store.upsertManagedPosts([SyncFixtures.summary("own1", creator: "mine")], account: me.context)
        let now = Date.now
        h.mock.update {
            $0.comments["own1"] = [RemoteComment(id: "c9", postID: "own1", authorUserID: "fan", authorName: "Fan", body: "はじめまして",
                                                 createdAt: now)]
        }
        let ids = h.store.upsertNotifications([fanboxCommentBell("b1", postID: "own1", body: "はじめまして", at: now)], account: me.context)
        let replyID = await h.notifications.handleReply(eventID: ids[0], text: "ようこそ")
        XCTAssertEqual(h.mock.count("comments|\(me.id)|own1") >= 1, true)
        let item = try XCTUnwrap(replyID.flatMap { h.replies.item(id: $0) })
        XCTAssertEqual(item.parentCommentID, "c9")
        XCTAssertEqual(item.rootCommentID, "c9")
        XCTAssertEqual(item.state, .sent)
    }

    func testUnresolvableReplyIsKeptAsADraftInsteadOfAPublicRootComment() async throws {
        let h = try SyncHarness()
        let me = h.addAccount("Creator", pixivUserID: "pMe", creatorID: "mine", isMain: true)
        let ids = h.store.upsertNotifications([fanboxCommentBell("b1", postID: "own1", body: "見つからないコメント")], account: me.context)
        h.setOffline(true)
        let replyID = await h.notifications.handleReply(eventID: ids[0], text: "返信文")
        let item = try XCTUnwrap(replyID.flatMap { h.replies.item(id: $0) })
        XCTAssertEqual(item.state, .draft, "never sent as a top-level comment")
        XCTAssertEqual(item.body, "返信文")
        XCTAssertEqual(h.mock.count("addComment"), 0)
        let notice = try XCTUnwrap(h.poster.requests.first)
        XCTAssertEqual(notice.content.title, "返信先を特定できませんでした")
        XCTAssertEqual(notice.content.userInfo[NotificationService.replyItemIDKey] as? String, replyID)
        XCTAssertEqual(h.store.notificationEvent(id: ids[0])?.isRead, true)

        // Online but the comment is not in the thread: still a draft.
        h.setOffline(false)
        let second = await h.notifications.handleReply(eventID: ids[0], text: "もう一度")
        XCTAssertEqual(second.flatMap { h.replies.item(id: $0) }?.state, .draft)
        XCTAssertEqual(h.mock.count("addComment"), 0)
    }

    /// Every account that received the event was removed: nothing is sent, and a notice carries the text (it is not
    /// dropped silently) and opens the thread.
    func testReplyWithoutAnyReceivingAccountLeftPostsANotice() async throws {
        let h = try SyncHarness()
        let fan = h.addAccount("Fan", pixivUserID: "pF", isMain: true)
        let ids = h.store.upsertNotifications([fanboxCommentBell("b1", type: .commentReply, postID: "p1", body: "こんにちは")],
                                              account: fan.context)
        let event = try XCTUnwrap(h.store.notificationEvent(id: ids[0]))
        event.accountIDs = []       // what removing the receiving account leaves
        h.store.save()
        let replyID = await h.notifications.handleReply(eventID: ids[0], text: "消えないで")
        XCTAssertNil(replyID)
        XCTAssertEqual(h.mock.count("addComment"), 0)
        let notice = try XCTUnwrap(h.poster.requests.first)
        XCTAssertEqual(notice.content.title, "返信を送信しませんでした")
        XCTAssertTrue(notice.content.body.contains("消えないで"))
        XCTAssertEqual(notice.content.userInfo[NotificationService.eventIDKey] as? String, ids[0])
    }

    /// The reply text is on disk before the thread is re-read (iOS may suspend or end the app during that request).
    func testNotificationReplyIsSavedBeforeTheThreadIsRead() async throws {
        let h = try SyncHarness()
        let me = h.addAccount("Creator", pixivUserID: "pMe", creatorID: "mine", isMain: true)
        h.store.upsertManagedPosts([SyncFixtures.summary("own1", creator: "mine")], account: me.context)
        let now = Date.now
        h.mock.update {
            $0.comments["own1"] = [RemoteComment(id: "c9", postID: "own1", authorUserID: "fan", authorName: "Fan", body: "はじめまして",
                                                 createdAt: now)]
            $0.commentsDelayNanoseconds = 200_000_000
        }
        let ids = h.store.upsertNotifications([fanboxCommentBell("b1", postID: "own1", body: "はじめまして", at: now)], account: me.context)
        let reply = Task { await h.notifications.handleReply(eventID: ids[0], text: "ようこそ") }
        var spins = 0
        while h.mock.count("comments|") == 0 && spins < 100_000 { spins += 1; await Task.yield() }
        XCTAssertEqual(h.store.fetch(FetchDescriptor<OutgoingComment>()).map(\.body), ["ようこそ"], "saved while the thread is being read")

        let replyID = await reply.value
        let item = try XCTUnwrap(replyID.flatMap { h.replies.item(id: $0) })
        XCTAssertEqual(item.parentCommentID, "c9")
        XCTAssertEqual(item.origin, .notificationAction)
        XCTAssertEqual(item.state, .sent)
        XCTAssertEqual(h.store.fetch(FetchDescriptor<OutgoingComment>()).count, 1, "the saved text is the one sent")
    }

    /// A notification of an account that was disabled afterwards is never answered as another account.
    func testReplyToADisabledAccountsNotificationIsNotSentAsAnotherAccount() async throws {
        let h = try SyncHarness()
        let main = h.addAccount("Main", pixivUserID: "pMain", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        let now = Date.now
        h.mock.update {
            $0.comments["p1"] = [RemoteComment(id: "c1", postID: "p1", authorUserID: "x", authorName: "X", body: "ありがとう", createdAt: now)]
        }
        let ids = h.store.upsertNotifications([fanboxCommentBell("b1", type: .commentReply, postID: "p1", body: "ありがとう", actor: "X",
                                                                 at: now)], account: b.context)
        b.enabled = false
        h.store.save()
        XCTAssertNil(h.notifications.preferredAccount(for: try XCTUnwrap(h.store.notificationEvent(id: ids[0]))))

        let replyID = await h.notifications.handleReply(eventID: ids[0], text: "どういたしまして")
        XCTAssertEqual(h.mock.count("addComment"), 0)
        let item = try XCTUnwrap(replyID.flatMap { h.replies.item(id: $0) })
        XCTAssertEqual(item.state, .draft)
        XCTAssertEqual(item.accountID, b.id, "kept for the receiving account, never \(main.id)")
    }

    // MARK: Banners of an interrupted run

    func testProcessMarksEveryBannerDueBeforeThePrefetch() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update {
            $0.details[a.id] = ["p1": SyncFixtures.detail("p1"), "p2": SyncFixtures.detail("p2")]
            $0.postDelayNanoseconds = 200_000_000
        }
        let ids = h.store.upsertNotifications([SyncFixtures.notification("r1", type: .newPost, postID: "p1"),
                                              SyncFixtures.notification("r2", type: .newPost, postID: "p2")], account: a.context)
        let run = Task { await h.notifications.process(newEventIDs: ids) }
        var spins = 0
        while h.mock.count("post|") == 0 && spins < 100_000 { spins += 1; await Task.yield() }
        XCTAssertTrue(ids.allSatisfy { h.store.notificationEvent(id: $0)?.deliveryPendingSince != nil },
                      "due before the first (slow) prefetch starts")
        await run.value
        XCTAssertEqual(h.poster.requests.count, 2)
        XCTAssertTrue(ids.allSatisfy { h.store.notificationEvent(id: $0)?.deliveryPendingSince == nil })
    }

    /// Banners the loop never reached (iOS suspended / ended the app) are posted by the next launch / activation.
    func testDueBannersOfAnInterruptedRunAreDeliveredLater() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let ids = h.store.upsertNotifications([SyncFixtures.notification("r1", type: .newPost, postID: "p1"),
                                              SyncFixtures.notification("r2", type: .comment, postID: "p2")], account: a.context)
        let silent = h.store.upsertNotifications([SyncFixtures.notification("r3", type: .newPost, postID: "p3")], account: a.context)
        for id in ids { h.store.notificationEvent(id: id)?.deliveryPendingSince = .now }     // marked, then the app was ended
        h.store.save()

        await h.notifications.redeliverPending()
        XCTAssertEqual(Set(h.poster.requests.map(\.identifier)), Set(ids))
        XCTAssertTrue(ids.allSatisfy { h.store.notificationEvent(id: $0)?.deliveredLocally == true })
        XCTAssertEqual(h.store.notificationEvent(id: silent[0])?.deliveredLocally, false, "an event imported silently stays silent")
        await h.notifications.redeliverPending()
        XCTAssertEqual(h.poster.requests.count, 2, "posted once")
    }

    /// Activation while `process` is still running: an event being prefetched is left to the loop (its banner carries the
    /// text), and one whose banner is being posted is not posted a second time.
    func testRedeliveryDuringARunningProcessPostsEachBannerOnce() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let slow = SlowRecordingPoster()
        h.notifications.poster = slow
        let ids = h.store.upsertNotifications([SyncFixtures.notification("r1", type: .newPost, postID: "p1"),
                                              SyncFixtures.notification("r2", type: .newPost, postID: "p2")], account: a.context)
        for id in ids { h.store.notificationEvent(id: id)?.deliveryPendingSince = .now }
        h.store.notificationEvent(id: ids[1])?.prefetchState = .inProgress       // the loop is still prefetching it
        h.store.save()

        async let first: Void = h.notifications.deliver(eventID: ids[0])
        async let redelivery: Void = h.notifications.redeliverPending()
        _ = await (first, redelivery)
        XCTAssertEqual(slow.requests.map(\.identifier), [ids[0]])
        XCTAssertEqual(h.store.notificationEvent(id: ids[1])?.deliveredLocally, false, "left to the running loop")
    }

    /// No banner for an account that was turned off while its sync was still running.
    func testNoBannerForADisabledAccount() async throws {
        let h = try SyncHarness()
        _ = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        let ids = h.store.upsertNotifications([SyncFixtures.notification("r1", type: .newPost, postID: "p1")], account: b.context)
        b.enabled = false
        h.store.save()
        await h.notifications.deliver(eventID: ids[0])
        XCTAssertTrue(h.poster.requests.isEmpty)
    }

    // MARK: Delivery level (SPEC §24.2)

    func testCriticalEventsUseTimeSensitiveOnlyWhenAvailable() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let ids = h.store.upsertNotifications([SyncFixtures.notification("r1", type: .comment, postID: "p1", commentID: "cm1")],
                                              account: a.context)
        let event = try XCTUnwrap(h.store.notificationEvent(id: ids[0]))
        h.notifications.timeSensitiveAvailable = false
        XCTAssertEqual(h.notifications.makeRequest(for: event).content.interruptionLevel, .active, "documented fallback without the entitlement")
        h.notifications.timeSensitiveAvailable = true
        XCTAssertEqual(h.notifications.makeRequest(for: event).content.interruptionLevel, .timeSensitive)
        let post = h.store.upsertNotifications([SyncFixtures.notification("r2", type: .newPost, postID: "p2")], account: a.context)
        XCTAssertEqual(h.notifications.makeRequest(for: try XCTUnwrap(h.store.notificationEvent(id: post[0]))).content.interruptionLevel, .active)
    }

    // MARK: Badge and read state (SPEC §27)

    func testBadgeFollowsLocalReadActions() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let ids = h.store.upsertNotifications([SyncFixtures.notification("r1", type: .newPost, postID: "p1"),
                                              SyncFixtures.notification("r2", type: .newPost, postID: "p2")], account: a.context)
        await h.notifications.updateBadge()
        XCTAssertEqual(h.poster.badge, 2)

        h.notifications.open(eventID: ids[0])
        var spins = 0
        while h.poster.badge != 1 && spins < 10_000 { spins += 1; await Task.yield() }
        XCTAssertEqual(h.poster.badge, 1, "opening from the inbox updates the badge")

        let second = try XCTUnwrap(h.store.notificationEvent(id: ids[1]))
        NotificationReadActions.setEventRead(second, read: true, store: h.store)
        await h.notifications.updateBadge()
        XCTAssertEqual(h.poster.badge, 0)
        XCTAssertEqual(h.store.unreadNotificationEventCount(), 0)
    }

    func testNewsletterAndEventShareOneReadState() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let letters = [RemoteNewsletter(id: "nl1", creatorID: "c1", creatorName: "C1", creatorIconURL: nil, title: nil, body: "本文",
                                        createdAt: .now, isRead: false),
                       RemoteNewsletter(id: "nl2", creatorID: "c1", creatorName: "C1", creatorIconURL: nil, title: nil, body: "本文2",
                                        createdAt: .now, isRead: false)]
        let newIDs = h.store.upsertNewsletters(letters, account: a.context)
        let events = h.store.ensureNewsletterEvents(newsletterIDs: newIDs, account: a.context)
        let event = try XCTUnwrap(h.store.notificationEvent(id: events[0]))
        let letter = try XCTUnwrap(h.store.newsletter(id: event.newsletterID ?? ""))

        NotificationReadActions.setEventRead(event, read: true, store: h.store)
        XCTAssertTrue(letter.isRead, "reading the event reads the おたより")
        NotificationReadActions.setNewsletterRead(newsletterID: letter.newsletterID, read: false, store: h.store)
        XCTAssertFalse(event.isRead, "marking the おたより unread brings its event back")

        let all = h.store.fetch(FetchDescriptor<Newsletter>())
        XCTAssertEqual(NotificationReadActions.markAllRead(all, filter: NotificationInboxFilter(), store: h.store), 2)
        XCTAssertTrue(h.store.fetch(FetchDescriptor<NotificationEvent>()).allSatisfy(\.isRead), "newsletter 'すべて既読' reads their events")

        NotificationReadActions.setNewsletterRead(newsletterID: letter.newsletterID, read: false, store: h.store)
        h.notifications.open(eventID: event.id)
        XCTAssertTrue(letter.isRead, "opening the event reads the おたより")
    }

    // MARK: Prefetch retry (SPEC §3.3 / §25)

    func testFailedAndInterruptedPrefetchesAreRetried() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let ids = h.store.upsertNotifications([SyncFixtures.notification("r1", type: .newPost, postID: "p1"),
                                              SyncFixtures.notification("r2", type: .newPost, postID: "p2")], account: a.context)
        let first = try XCTUnwrap(h.store.notificationEvent(id: ids[0]))
        let second = try XCTUnwrap(h.store.notificationEvent(id: ids[1]))
        second.prefetchState = .inProgress        // app killed mid-prefetch
        h.store.save()

        // The detail is not available yet: the prefetch fails.
        await h.notifications.prefetch(eventID: first.id)
        XCTAssertEqual(first.prefetchState, .failed)
        XCTAssertEqual(second.prefetchState, .failed, "a stuck prefetch is made retryable at launch")

        h.mock.update { $0.details[a.id] = ["p1": SyncFixtures.detail("p1"), "p2": SyncFixtures.detail("p2")] }
        await h.notifications.retryFailedPrefetches()
        XCTAssertEqual(first.prefetchState, .textReady)
        XCTAssertEqual(second.prefetchState, .textReady)
        XCTAssertEqual(h.store.post(id: "p1")?.hasCachedBody, true)
    }

    /// A failed おたより prefetch retried after its only receiver was turned off sends nothing: not as that account, and not
    /// as the main account, which never received it.
    func testNewsletterPrefetchRetryOfADisabledReceiverSendsNothing() async throws {
        let h = try SyncHarness()
        let main = h.addAccount("Main", pixivUserID: "pMain", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        let letter = RemoteNewsletter(id: "nl1", creatorID: "c1", creatorName: "C1", creatorIconURL: nil, title: nil, body: "本文",
                                      createdAt: .now, isRead: false)
        let newIDs = h.store.upsertNewsletters([letter], account: b.context)
        let events = h.store.ensureNewsletterEvents(newsletterIDs: newIDs, account: b.context)
        let event = try XCTUnwrap(h.store.notificationEvent(id: events[0]))
        event.prefetchState = .failed
        b.enabled = false
        h.store.save()
        h.mock.update {
            $0.newsletters[b.id] = [letter]
            $0.newsletters[main.id] = [letter]
        }

        await h.notifications.retryFailedPrefetches()
        let explicit = await h.engine.refreshNewsletter(id: "nl1", accountID: b.id)
        XCTAssertNotNil(explicit)
        XCTAssertEqual(h.mock.count("newsletter|"), 0)
    }

    func testNewSupporterPrefetchRefreshesTheFanList() async throws {
        let h = try SyncHarness()
        let me = h.addAccount("Creator", pixivUserID: "pMe", creatorID: "mine", isMain: true)
        let reader = h.addAccount("Reader", pixivUserID: "pR")
        let ids = h.store.upsertNotifications([SyncFixtures.notification("r1", type: .newSupporter, creatorID: "mine")], account: me.context)
        await h.notifications.prefetch(eventID: ids[0])
        XCTAssertEqual(h.mock.count("fans|\(me.id)"), 1)
        XCTAssertEqual(h.store.notificationEvent(id: ids[0])?.prefetchState, .textReady)

        let other = h.store.upsertNotifications([SyncFixtures.notification("r2", type: .newSupporter, creatorID: nil)], account: reader.context)
        await h.notifications.prefetch(eventID: other[0])
        XCTAssertEqual(h.store.notificationEvent(id: other[0])?.prefetchState, .notNeeded)
    }

    // MARK: Priority 2 media (SPEC §25)

    func testSmallMediaIsPrefetchedAfterTheText() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        var requests: [MediaRequest] = []
        h.notifications.mediaPrefetcher = { requests.append($0) }
        var summary = SyncFixtures.summary("p1")
        summary.coverImageURL = "https://example.invalid/cover.jpg"
        summary.creatorIconURL = "https://example.invalid/creator.jpg"
        h.store.upsertPostSummaries([summary], account: a.context, source: .home)
        h.mock.update { $0.details[a.id] = ["p1": SyncFixtures.detail("p1")] }
        var bell = SyncFixtures.notification("r1", type: .newPost, postID: "p1")
        bell.actorIconURL = "https://example.invalid/actor.jpg"
        let ids = h.store.upsertNotifications([bell], account: a.context)
        await h.notifications.prefetch(eventID: ids[0])
        XCTAssertEqual(Set(requests.map(\.url)), ["https://example.invalid/actor.jpg", "https://example.invalid/cover.jpg",
                                                  "https://example.invalid/creator.jpg"])
        XCTAssertTrue(requests.allSatisfy { $0.variant == .thumbnail && $0.trigger == .prefetch && $0.priority == .mediaPrefetch })

        // Nothing is requested before the text is ready.
        requests.removeAll()
        let failing = h.store.upsertNotifications([SyncFixtures.notification("r2", type: .newPost, postID: "p404")], account: a.context)
        await h.notifications.prefetch(eventID: failing[0])
        XCTAssertTrue(requests.isEmpty)
    }

    /// Commenters' avatars are not images of the post (they would be listed and pinned with it), and a disabled
    /// account's session never fetches the media.
    func testCommentAvatarsAreNotImagesOfThePostAndSkipADisabledAccount() async throws {
        let h = try SyncHarness()
        let b = h.addAccount("B", pixivUserID: "pB")
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        var requests: [MediaRequest] = []
        h.notifications.mediaPrefetcher = { requests.append($0) }
        var summary = SyncFixtures.summary("p1", creator: "mine")
        summary.coverImageURL = "https://example.invalid/cover.jpg"
        h.store.upsertPostSummaries([summary], account: a.context, source: .home)
        let now = Date.now
        h.mock.update {
            $0.comments["p1"] = [RemoteComment(id: "c1", postID: "p1", authorUserID: "u1", authorName: "Fan",
                                               authorIconURL: "https://example.invalid/fan.jpg", body: "素敵です", createdAt: now)]
        }
        let ids = h.store.upsertNotifications([fanboxCommentBell("b1", postID: "p1", body: "素敵です", at: now)], account: b.context)
        _ = h.store.upsertNotifications([fanboxCommentBell("a1", postID: "p1", body: "素敵です", at: now)], account: a.context)
        b.enabled = false
        h.store.save()
        XCTAssertEqual(h.store.notificationEvent(id: ids[0])?.accountIDs.first, b.id, "the turned-off account received it first")

        await h.notifications.prefetch(eventID: ids[0])
        let avatar = try XCTUnwrap(requests.first { $0.url == "https://example.invalid/fan.jpg" })
        XCTAssertNil(avatar.postID)
        XCTAssertEqual(requests.first { $0.url == "https://example.invalid/cover.jpg" }?.postID, "p1")
        XCTAssertTrue(requests.allSatisfy { $0.accountID == a.id })
    }

    // MARK: Cross-account dedupe of FANBOX comment bells (SPEC §27)

    func testSameCommentBellFromTwoAccountsIsOneEvent() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA")
        let b = h.addAccount("B", pixivUserID: "pB")
        let at = Date.now
        let fromA = h.store.upsertNotifications([fanboxCommentBell("111", postID: "p1", body: "同じコメント", at: at)], account: a.context)
        let fromB = h.store.upsertNotifications([fanboxCommentBell("222", postID: "p1", body: "同じコメント", at: at.addingTimeInterval(20))],
                                                account: b.context)
        XCTAssertEqual(fromA.count, 1)
        XCTAssertTrue(fromB.isEmpty, "the second account's bell is the same event")
        let event = try XCTUnwrap(h.store.notificationEvent(id: fromA[0]))
        XCTAssertEqual(Set(event.accountIDs), [a.id, b.id])
        XCTAssertEqual(Set(event.remoteIDs), ["\(a.id):111", "\(b.id):222"])

        // Listing B again does not create a copy; a different comment is a new event.
        XCTAssertTrue(h.store.upsertNotifications([fanboxCommentBell("222", postID: "p1", body: "同じコメント", at: at)], account: b.context).isEmpty)
        XCTAssertEqual(h.store.upsertNotifications([fanboxCommentBell("223", postID: "p1", body: "別のコメント", at: at)], account: b.context).count, 1)
        XCTAssertEqual(h.store.fetch(FetchDescriptor<NotificationEvent>()).count, 2)
    }

    /// A creator thanking two of my accounts with the same short text wrote two replies: two events, one per account.
    func testIdenticalRepliesToTwoAccountsStayTwoEvents() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA")
        let b = h.addAccount("B", pixivUserID: "pB")
        let at = Date.now
        let fromA = h.store.upsertNotifications([fanboxCommentBell("111", type: .commentReply, postID: "p1", body: "ありがとうございます！",
                                                                   actor: "X", at: at)], account: a.context)
        let fromB = h.store.upsertNotifications([fanboxCommentBell("222", type: .commentReply, postID: "p1", body: "ありがとうございます！",
                                                                   actor: "X", at: at.addingTimeInterval(40))], account: b.context)
        XCTAssertEqual(fromA.count, 1)
        XCTAssertEqual(fromB.count, 1, "B gets its own event (and its own banner)")
        XCTAssertEqual(h.store.notificationEvent(id: fromA[0])?.accountIDs, [a.id])
        XCTAssertEqual(h.store.notificationEvent(id: fromB[0])?.accountIDs, [b.id])
    }

    // MARK: Inbox retention (SPEC §27 scalability)

    func testReadEventsArePrunedAndNotReimported() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA")
        let old = Date(timeIntervalSinceNow: -LocalStore.notificationRetention - 86_400)
        var oldBell = SyncFixtures.notification("r-old", type: .newPost, postID: "p-old", unread: false)
        oldBell.createdAt = old
        var oldUnread = SyncFixtures.notification("r-old2", type: .newPost, postID: "p-old2", unread: true)
        oldUnread.createdAt = old
        let recent = SyncFixtures.notification("r-new", type: .newPost, postID: "p-new", unread: false)

        // Items older than the retention window are not imported at all…
        XCTAssertEqual(h.store.upsertNotifications([oldBell, oldUnread, recent], account: a.context), ["newPost|p-new"])

        // …and old read events already stored are pruned, unread ones kept.
        let stale = NotificationEvent(id: "newPost|legacy", type: .newPost, accountIDs: [a.id], title: "", message: "", timestamp: old,
                                      postID: "legacy", detectedAt: old)
        stale.isRead = true
        let staleUnread = NotificationEvent(id: "newPost|legacy2", type: .newPost, accountIDs: [a.id], title: "", message: "", timestamp: old,
                                            postID: "legacy2", detectedAt: old)
        h.store.context.insert(stale)
        h.store.context.insert(staleUnread)
        h.store.save()
        let pruned = h.store.maintenancePruneNotificationEvents(before: Date(timeIntervalSinceNow: -LocalStore.notificationRetention))
        XCTAssertEqual(pruned, 1)
        XCTAssertNil(h.store.notificationEvent(id: "newPost|legacy"))
        XCTAssertNotNil(h.store.notificationEvent(id: "newPost|legacy2"))
        XCTAssertNotNil(h.store.notificationEvent(id: "newPost|p-new"))
    }
}

/// Posts after a short delay, like the system center, so overlapping deliveries can be observed.
@MainActor
private final class SlowRecordingPoster: LocalNotificationPosting {
    var requests: [UNNotificationRequest] = []

    func post(_ request: UNNotificationRequest) async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
        requests.append(request)
    }

    func setBadge(_ count: Int) async {}
}

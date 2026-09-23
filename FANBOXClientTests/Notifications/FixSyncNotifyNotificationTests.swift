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

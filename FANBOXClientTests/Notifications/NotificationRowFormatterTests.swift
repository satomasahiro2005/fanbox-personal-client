import XCTest
import SwiftData
@testable import FANBOXClient

@MainActor
final class NotificationRowFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 (UTC)

    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func input(_ type: NotificationEventType, actor: String? = nil, creator: String? = nil, title: String = "",
                       message: String = "", ago: TimeInterval = 60, prefetch: PrefetchState = .pending) -> NotificationRowInput {
        NotificationRowInput(type: type, actorName: actor, creatorName: creator, title: title, message: message,
                             timestamp: now.addingTimeInterval(-ago), prefetchState: prefetch, isRead: false, accountIDs: ["A"])
    }

    // MARK: Headline (SPEC §27 examples)

    func testSpecExampleHeadlines() {
        XCTAssertEqual(NotificationRowFormatter.headline(for: input(.comment, actor: "user123")), "user123がコメントしました")
        XCTAssertEqual(NotificationRowFormatter.headline(for: input(.newPost, creator: "Creator A")), "Creator Aが投稿しました")
        XCTAssertEqual(NotificationRowFormatter.headline(for: input(.newsletter, creator: "Creator B")), "Creator Bからおたより")
    }

    func testHeadlinePerTypeAndFallbacks() {
        XCTAssertEqual(NotificationRowFormatter.headline(for: input(.commentReply, actor: "u")), "uが返信しました")
        XCTAssertEqual(NotificationRowFormatter.headline(for: input(.newSupporter, actor: "fan")), "fanが支援を開始しました")
        // newPost falls back to the actor when the creator is not known locally.
        XCTAssertEqual(NotificationRowFormatter.headline(for: input(.newPost, actor: "Actor")), "Actorが投稿しました")
        // Types without an actor sentence use the FANBOX title.
        XCTAssertEqual(NotificationRowFormatter.headline(for: input(.paymentAttention, actor: "x", title: "お支払いを確認してください")),
                       "お支払いを確認してください")
        // Nothing known → generic wording.
        XCTAssertEqual(NotificationRowFormatter.headline(for: input(.comment, actor: "  ")), "新しいコメントがあります")
        XCTAssertEqual(NotificationRowFormatter.headline(for: input(.supportChanged)), "支援状態が変わりました")
        XCTAssertEqual(NotificationRowFormatter.headline(for: input(.other, title: "メンテナンスのお知らせ")), "メンテナンスのお知らせ")
    }

    func testDetailsAreDeduplicatedAndCollapsed() {
        let text = NotificationRowFormatter.format(input(.comment, actor: "user123", title: "投稿タイトル", message: "すごい！\n\n最高です"),
                                                   now: now, calendar: tokyo)
        XCTAssertEqual(text.headline, "user123がコメントしました")
        XCTAssertEqual(text.details, ["投稿タイトル", "すごい！ 最高です"])

        // Title already used as the headline is not repeated.
        let other = NotificationRowFormatter.format(input(.other, title: "お知らせ", message: "お知らせ"), now: now, calendar: tokyo)
        XCTAssertEqual(other.headline, "お知らせ")
        XCTAssertEqual(other.details, [])
    }

    // MARK: Relative time

    func testRelativeTime() {
        func rel(_ ago: TimeInterval) -> String {
            NotificationRowFormatter.relativeTime(now.addingTimeInterval(-ago), now: now, calendar: tokyo)
        }
        XCTAssertEqual(rel(5), "たった今")
        XCTAssertEqual(rel(60), "1分前")
        XCTAssertEqual(rel(12 * 60), "12分前")
        XCTAssertEqual(rel(3 * 3600), "3時間前")
        XCTAssertEqual(rel(2 * 86400), "2日前")
        // 10 days before 2026-09-21 23:13 JST → 9月11日
        XCTAssertEqual(rel(10 * 86400), "9月11日")
        XCTAssertEqual(rel(400 * 86400), "2025年8月17日")
        // Future timestamps (clock skew) never show negative values.
        XCTAssertEqual(rel(-30), "たった今")
    }

    // MARK: Prefetch indicator

    func testPrefetchBadge() {
        XCTAssertEqual(NotificationRowFormatter.prefetchBadge(for: .textReady, type: .newPost)?.text, "本文取得済")
        XCTAssertEqual(NotificationRowFormatter.prefetchBadge(for: .complete, type: .newsletter)?.text, "本文取得済")
        XCTAssertEqual(NotificationRowFormatter.prefetchBadge(for: .textReady, type: .comment)?.text, "コメント取得済")
        XCTAssertEqual(NotificationRowFormatter.prefetchBadge(for: .textReady, type: .comment)?.tone, .ready)
        XCTAssertEqual(NotificationRowFormatter.prefetchBadge(for: .inProgress, type: .newPost)?.tone, .working)
        XCTAssertEqual(NotificationRowFormatter.prefetchBadge(for: .failed, type: .newPost)?.tone, .problem)
        XCTAssertNil(NotificationRowFormatter.prefetchBadge(for: .pending, type: .newPost))
        XCTAssertNil(NotificationRowFormatter.prefetchBadge(for: .notNeeded, type: .other))
    }

    // MARK: Filter

    func testTypeChipsCoverAllTypes() {
        let chips = NotificationInboxFilter.typeChips
        XCTAssertEqual(chips.first?.title, "すべて")
        XCTAssertNil(chips.first?.type)
        XCTAssertEqual(chips.dropFirst().map(\.title), NotificationEventType.allCases.map(\.displayName))
        XCTAssertEqual(Set(chips.map(\.id)).count, chips.count, "chip ids are unique")
    }

    func testFilterByTypeAccountAndUnread() {
        var filter = NotificationInboxFilter()
        XCTAssertFalse(filter.isActive)
        XCTAssertTrue(filter.matches(type: .comment, accountIDs: ["A"], isRead: true))

        filter.type = .comment
        XCTAssertTrue(filter.matches(type: .comment, accountIDs: ["A"], isRead: false))
        XCTAssertFalse(filter.matches(type: .commentReply, accountIDs: ["A"], isRead: false))

        filter.accountID = "B"
        XCTAssertFalse(filter.matches(type: .comment, accountIDs: ["A"], isRead: false))
        XCTAssertTrue(filter.matches(type: .comment, accountIDs: ["A", "B"], isRead: false), "deduped events match any receiving account")

        filter.unreadOnly = true
        XCTAssertFalse(filter.matches(type: .comment, accountIDs: ["B"], isRead: true))
        XCTAssertTrue(filter.isActive)
    }

    /// A type chip chosen in the 通知 segment never empties the おたより segment (which shows no type chips).
    func testTypeChipDoesNotApplyToNewsletters() {
        var filter = NotificationInboxFilter()
        filter.type = .comment
        filter.accountID = "A"
        let newsletters = filter.forNewsletters
        XCTAssertNil(newsletters.type)
        XCTAssertEqual(newsletters.accountID, "A", "the account and unread filters still apply")
        XCTAssertTrue(newsletters.matches(type: .newsletter, accountIDs: ["A"], isRead: false))
        XCTAssertFalse(filter.matches(type: .newsletter, accountIDs: ["A"], isRead: false))
    }

    /// Items show only when one of their receiving accounts is enabled: a disabled account's items and items left without
    /// any account (after a removal) are hidden, and "すべて既読" does not touch them.
    func testEnabledAccountsRestriction() throws {
        let enabledOnly = NotificationInboxFilter(enabledAccountIDs: ["A"])
        XCTAssertFalse(enabledOnly.isActive, "not a user filter")
        XCTAssertTrue(enabledOnly.matches(type: .newPost, accountIDs: ["A"], isRead: false))
        XCTAssertTrue(enabledOnly.matches(type: .newPost, accountIDs: ["B", "A"], isRead: false), "shared with an enabled account")
        XCTAssertFalse(enabledOnly.matches(type: .newPost, accountIDs: ["B"], isRead: false))
        XCTAssertFalse(enabledOnly.matches(type: .newPost, accountIDs: [], isRead: false))
        XCTAssertTrue(NotificationInboxFilter().matches(type: .newPost, accountIDs: [], isRead: false), "nil = no restriction")

        var byB = enabledOnly
        byB.accountID = "B"
        XCTAssertFalse(byB.matches(type: .newPost, accountIDs: ["B"], isRead: false))

        let store = LocalStore(container: try PersistenceController.makeContainer(inMemory: true))
        let ofA = NotificationEvent(id: "e1", type: .newPost, accountIDs: ["A"], title: "", message: "", timestamp: now)
        let ofB = NotificationEvent(id: "e2", type: .newPost, accountIDs: ["B"], title: "", message: "", timestamp: now)
        [ofA, ofB].forEach(store.context.insert)
        store.save()
        XCTAssertEqual(NotificationReadActions.markAllRead([ofA, ofB], filter: enabledOnly, store: store), 1)
        XCTAssertTrue(ofA.isRead)
        XCTAssertFalse(ofB.isRead, "a disabled account's event stays as it was")
    }

    // MARK: SwiftData integration

    func testRowInputFromEventAndMarkAllRead() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = LocalStore(container: container)
        let e1 = NotificationEvent(id: "comment|c1", type: .comment, accountIDs: ["creatorAcc"], title: "投稿", message: "こんにちは",
                                   timestamp: now.addingTimeInterval(-60), commentID: "c1")
        e1.actorName = "user123"
        e1.prefetchState = .textReady
        let e2 = NotificationEvent(id: "newPost|p1", type: .newPost, accountIDs: ["A", "C"], title: "新作", message: "",
                                   timestamp: now.addingTimeInterval(-180), creatorID: "cA", postID: "p1")
        let e3 = NotificationEvent(id: "newsletter|n1", type: .newsletter, accountIDs: ["B"], title: "", message: "",
                                   timestamp: now.addingTimeInterval(-720), creatorID: "cB", newsletterID: "n1")
        [e1, e2, e3].forEach(store.context.insert)
        store.save()

        let row1 = NotificationRowFormatter.format(NotificationRowInput(event: e1, creatorName: nil), now: now, calendar: tokyo)
        XCTAssertEqual(row1.headline, "user123がコメントしました")
        XCTAssertEqual(row1.relativeTime, "1分前")
        XCTAssertEqual(row1.badge?.text, "コメント取得済")

        let row2 = NotificationRowFormatter.format(NotificationRowInput(event: e2, creatorName: "Creator A"), now: now, calendar: tokyo)
        XCTAssertEqual(row2.headline, "Creator Aが投稿しました")
        XCTAssertEqual(row2.relativeTime, "3分前")

        let all = store.fetch(FetchDescriptorFactory.notificationsNewestFirst())
        XCTAssertEqual(all.map(\.id), ["comment|c1", "newPost|p1", "newsletter|n1"])

        var filter = NotificationInboxFilter()
        filter.type = .newPost
        XCTAssertEqual(NotificationReadActions.markAllRead(all, filter: filter, store: store), 1)
        XCTAssertTrue(e2.isRead)
        XCTAssertFalse(e1.isRead)
        XCTAssertEqual(NotificationReadActions.markAllRead(all, filter: NotificationInboxFilter(), store: store), 2)
        XCTAssertTrue(all.allSatisfy(\.isRead))
    }

    func testMarkNewsletterReadAlsoReadsItsEvent() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = LocalStore(container: container)
        let newsletter = Newsletter(newsletterID: "n1", creatorID: "cB", creatorName: "Creator B", body: "本文", createdAt: now,
                                    accountIDs: ["B"])
        let event = NotificationEvent(id: "newsletter|n1", type: .newsletter, accountIDs: ["B"], title: "", message: "",
                                      timestamp: now, creatorID: "cB", newsletterID: "n1")
        let unrelated = NotificationEvent(id: "newsletter|n2", type: .newsletter, accountIDs: ["B"], title: "", message: "",
                                          timestamp: now, creatorID: "cB", newsletterID: "n2")
        store.context.insert(newsletter)
        store.context.insert(event)
        store.context.insert(unrelated)
        store.save()

        XCTAssertTrue(NotificationReadActions.markNewsletterRead(newsletterID: "n1", store: store))
        XCTAssertTrue(newsletter.isRead)
        XCTAssertTrue(event.isRead)
        XCTAssertFalse(unrelated.isRead)
        XCTAssertFalse(NotificationReadActions.markNewsletterRead(newsletterID: "n1", store: store), "idempotent")
    }
}

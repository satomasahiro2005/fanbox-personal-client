import XCTest
import SwiftData
@testable import FANBOXClient

@MainActor
final class HomeFeedFilterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func entries() -> [HomeFeedEntry] {
        [
            HomeFeedEntry(postID: "p1", publishedAt: t0, isFromSupportedCreator: true, isRead: false, accessAccountIDs: ["A"],
                          seenByAccountIDs: ["A"]),
            HomeFeedEntry(postID: "p2", publishedAt: t0.addingTimeInterval(10), isFromFollowedCreator: true, isRead: true,
                          isFavorite: true, seenByAccountIDs: ["B"]),
            HomeFeedEntry(postID: "p3", publishedAt: t0.addingTimeInterval(20), isFromSupportedCreator: true,
                          isFromFollowedCreator: true, isRead: true, accessAccountIDs: ["A", "B"], seenByAccountIDs: ["A", "B"]),
            HomeFeedEntry(postID: "p4", publishedAt: t0.addingTimeInterval(30), isRead: false, isFavorite: true),
        ]
    }

    private func ids(_ filter: HomeFeedFilter) -> [String] { filter.apply(entries()).map(\.postID) }

    func testChipFilters() {
        XCTAssertEqual(ids(HomeFeedFilter(kind: .all)), ["p1", "p2", "p3", "p4"])
        XCTAssertEqual(ids(HomeFeedFilter(kind: .supporting)), ["p1", "p3"])
        XCTAssertEqual(ids(HomeFeedFilter(kind: .following)), ["p2", "p3"])
        XCTAssertEqual(ids(HomeFeedFilter(kind: .unread)), ["p1", "p4"])
        XCTAssertEqual(ids(HomeFeedFilter(kind: .favorite)), ["p2", "p4"])
    }

    func testAccountFilterUsesSeenOrAccess() {
        XCTAssertEqual(ids(HomeFeedFilter(kind: .all, accountID: "A")), ["p1", "p3"])
        XCTAssertEqual(ids(HomeFeedFilter(kind: .all, accountID: "B")), ["p2", "p3"])
        XCTAssertEqual(ids(HomeFeedFilter(kind: .supporting, accountID: "B")), ["p3"])
        XCTAssertEqual(ids(HomeFeedFilter(kind: .all, accountID: "Z")), [])
    }

    func testAccessOnlyAccountMatches() {
        let e = HomeFeedEntry(postID: "x", accessAccountIDs: ["C"], seenByAccountIDs: [])
        XCTAssertTrue(HomeFeedFilter(kind: .all, accountID: "C").matches(e))
    }

    func testDedupesByPostIDKeepingFirst() {
        var list = entries()
        var dup = list[0]
        dup.isRead = true
        list.append(dup)
        let result = HomeFeedFilter(kind: .all).apply(list)
        XCTAssertEqual(result.map(\.postID), ["p1", "p2", "p3", "p4"])
        XCTAssertFalse(result[0].isRead, "first occurrence wins")
        // A duplicate that only the second copy matches is still included once.
        XCTAssertEqual(HomeFeedFilter(kind: .all).apply([dup, list[0]]).count, 1)
    }

    func testNewestFirstSortIsStable() {
        let sorted = HomeFeedFilter.newestFirst(entries() + [HomeFeedEntry(postID: "p0", publishedAt: t0.addingTimeInterval(30))])
        XCTAssertEqual(sorted.map(\.postID), ["p4", "p0", "p3", "p2", "p1"])
    }

    func testKindMetadata() {
        XCTAssertEqual(HomeFeedFilterKind.allCases.map(\.title), ["すべて", "支援中", "フォロー中", "未読", "お気に入り"])
        XCTAssertEqual(HomeFeedFilterKind.unread.accessibilityID, "homeFilter.unread")
    }

    /// The SQLite pre-filter (descriptor) and the in-memory filter agree on real SwiftData posts.
    func testDescriptorWithSwiftDataPosts() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = LocalStore(container: container)
        for (i, e) in entries().enumerated() {
            let p = Post(postID: e.postID, creatorID: "c", creatorName: "C", title: "T\(i)", publishedAt: e.publishedAt)
            p.isFromSupportedCreator = e.isFromSupportedCreator
            p.isFromFollowedCreator = e.isFromFollowedCreator
            p.isRead = e.isRead
            p.isFavorite = e.isFavorite
            p.accessAccountIDs = e.accessAccountIDs
            p.seenByAccountIDs = e.seenByAccountIDs
            store.context.insert(p)
        }
        store.save()

        for kind in HomeFeedFilterKind.allCases {
            let filter = HomeFeedFilter(kind: kind, accountID: "A")
            let fetched = filter.apply(store.fetch(filter.descriptor(limit: nil)))
            let expected = HomeFeedFilter.newestFirst(filter.apply(entries())).map(\.postID)
            XCTAssertEqual(fetched.map(\.postID), expected, "kind \(kind)")
        }
        let limited = store.fetch(HomeFeedFilter(kind: .all).descriptor(limit: 2))
        XCTAssertEqual(limited.map(\.postID), ["p4", "p3"], "newest first with limit")
    }

    func testUserActionsWriteLocalMetadata() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = LocalStore(container: container)
        let p = Post(postID: "m1", creatorID: "c", creatorName: "C", title: "T", publishedAt: t0)
        store.context.insert(p)
        HomePostUserActions.setRead(p, true, store: store)
        XCTAssertTrue(p.isRead)
        XCTAssertNotNil(p.readAt)
        HomePostUserActions.setRead(p, false, store: store)
        XCTAssertFalse(p.isRead)
        XCTAssertNil(p.readAt)
        HomePostUserActions.toggleFavorite(p, store: store)
        HomePostUserActions.toggleReadLater(p, store: store)
        XCTAssertTrue(p.isFavorite)
        XCTAssertTrue(p.isReadLater)
    }

    func testDateText() {
        let now = t0
        XCTAssertEqual(HomeDateText.format(now.addingTimeInterval(0.4), now: now), "たった今", "tiny future skew")
        XCTAssertEqual(HomeDateText.format(now.addingTimeInterval(-30), now: now), "たった今")
        XCTAssertEqual(HomeDateText.format(now.addingTimeInterval(-30 * 24 * 3600), now: now),
                       Formatters.shortDate(now.addingTimeInterval(-30 * 24 * 3600)))
        XCTAssertNotEqual(HomeDateText.format(now.addingTimeInterval(-3600), now: now), "たった今")
    }

    func testPlanLabel() {
        XCTAssertEqual(HomePlanLabel.text(feeRequired: 0), "全体公開")
        XCTAssertEqual(HomePlanLabel.text(feeRequired: 500), "¥500〜")
        let plans: [(fee: Int, title: String)] = [(300, "S"), (500, "M"), (1000, "L")]
        XCTAssertEqual(HomePlanLabel.planTitle(feeRequired: 400, plans: plans), "M")
        XCTAssertEqual(HomePlanLabel.planTitle(feeRequired: 500, plans: plans), "M")
        XCTAssertNil(HomePlanLabel.planTitle(feeRequired: 5000, plans: plans))
        XCTAssertNil(HomePlanLabel.planTitle(feeRequired: 0, plans: plans))
    }
}

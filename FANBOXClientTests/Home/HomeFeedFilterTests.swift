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

    /// p4 has neither timeline flag (only seen via a creator page / link): not part of すべて / 未読, but a favorite
    /// still shows under お気に入り. (Updated: すべて / 未読 used to list every locally known post.)
    func testChipFilters() {
        XCTAssertEqual(ids(HomeFeedFilter(kind: .all)), ["p1", "p2", "p3"])
        XCTAssertEqual(ids(HomeFeedFilter(kind: .supporting)), ["p1", "p3"])
        XCTAssertEqual(ids(HomeFeedFilter(kind: .following)), ["p2", "p3"])
        XCTAssertEqual(ids(HomeFeedFilter(kind: .unread)), ["p1"])
        XCTAssertEqual(ids(HomeFeedFilter(kind: .favorite)), ["p2", "p4"])
    }

    func testAccountFilterUsesSeenOrAccess() {
        XCTAssertEqual(ids(HomeFeedFilter(kind: .all, accountID: "A")), ["p1", "p3"])
        XCTAssertEqual(ids(HomeFeedFilter(kind: .all, accountID: "B")), ["p2", "p3"])
        XCTAssertEqual(ids(HomeFeedFilter(kind: .supporting, accountID: "B")), ["p3"])
        XCTAssertEqual(ids(HomeFeedFilter(kind: .all, accountID: "Z")), [])
    }

    func testAccessOnlyAccountMatches() {
        let e = HomeFeedEntry(postID: "x", isFromFollowedCreator: true, accessAccountIDs: ["C"], seenByAccountIDs: [])
        XCTAssertTrue(HomeFeedFilter(kind: .all, accountID: "C").matches(e))
    }

    func testDedupesByPostIDKeepingFirst() {
        var list = entries()
        var dup = list[0]
        dup.isRead = true
        list.append(dup)
        let result = HomeFeedFilter(kind: .all).apply(list)
        XCTAssertEqual(result.map(\.postID), ["p1", "p2", "p3"])
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
        // p4 (no timeline flag) is not part of すべて; updated from ["p4", "p3"].
        let limited = store.fetch(HomeFeedFilter(kind: .all).descriptor(limit: 2))
        XCTAssertEqual(limited.map(\.postID), ["p3", "p2"], "newest first with limit")
    }

    /// The timeline flags count enabled accounts only: posts of a creator supported / followed by a disabled account alone
    /// leave すべて / 支援中 / フォロー中 / 未読 and the Library 未読 list, and come back when the account is enabled again.
    func testDisabledAccountsCreatorsLeaveTheTimeline() throws {
        let store = LocalStore(container: try PersistenceController.makeContainer(inMemory: true))
        let a = Account(id: "A", kind: .demo, displayName: "A", isMain: true, sortOrder: 0)
        let b = Account(id: "B", kind: .demo, displayName: "B", sortOrder: 1)
        [a, b].forEach(store.context.insert)
        store.save()
        store.applySupports([SyncFixtures.support("shared", plan: "p1", fee: 500)], account: a.context, source: .sync, isBaseline: true)
        store.applySupports([SyncFixtures.support("shared", plan: "p2", fee: 1000), SyncFixtures.support("onlyB", plan: "p3", fee: 300)],
                            account: b.context, source: .sync, isBaseline: true)
        store.applyFollowing([RemoteCreator(creatorID: "followedByB", name: "Followed by B")], account: b.context)
        store.upsertPostSummaries([SyncFixtures.summary("s1", creator: "shared"), SyncFixtures.summary("b1", creator: "onlyB", minutesAgo: 1),
                                   SyncFixtures.summary("f1", creator: "followedByB", minutesAgo: 2)], account: b.context, source: .creator)

        func ids(_ kind: HomeFeedFilterKind) -> Set<String> {
            let filter = HomeFeedFilter(kind: kind)
            return Set(filter.apply(store.fetch(filter.descriptor(limit: nil))).map(\.postID))
        }
        XCTAssertEqual(ids(.all), ["s1", "b1", "f1"])

        b.enabled = false
        store.refreshRelationFlags()
        XCTAssertEqual(ids(.all), ["s1"], "the creator A also supports stays")
        XCTAssertEqual(ids(.supporting), ["s1"])
        XCTAssertEqual(ids(.following), [])
        XCTAssertEqual(ids(.unread), ["s1"])
        XCTAssertEqual(Set(store.fetch(LibraryListKind.unread.descriptor(limit: nil)).map(\.postID)), ["s1"])

        b.enabled = true
        store.refreshRelationFlags()
        XCTAssertEqual(ids(.all), ["s1", "b1", "f1"])
        XCTAssertEqual(ids(.following), ["f1"])
    }

    /// Earlier builds stored flags that counted disabled accounts, and a sync of another account recomputes only that
    /// account's creators. The launch pass re-derives them, so a creator supported only by an account disabled before the
    /// update leaves the timeline.
    func testLaunchRederivesFlagsStoredWithADisabledAccount() throws {
        let env = AppEnvironment.preview(seedDemo: false)
        let store = env.store
        let a = Account(id: "A", kind: .demo, displayName: "A", isMain: true, sortOrder: 0)
        let b = Account(id: "B", kind: .demo, displayName: "B", sortOrder: 1)
        [a, b].forEach(store.context.insert)
        store.save()
        store.applySupports([SyncFixtures.support("onlyB", plan: "p3", fee: 300)], account: b.context, source: .sync, isBaseline: true)
        store.upsertPostSummaries([SyncFixtures.summary("b1", creator: "onlyB")], account: b.context, source: .creator)
        // What the earlier build's setEnabled did: flip the flag without re-deriving anything.
        b.enabled = false
        store.save()
        store.applySupports([SyncFixtures.support("shared", plan: "p1", fee: 500)], account: a.context, source: .sync, isBaseline: true)
        store.applyFollowing([], account: a.context)
        XCTAssertEqual(store.creator(id: "onlyB")?.isSupported, true, "A's sync leaves B's creators alone")

        env.refreshStoredFlagsAtLaunch()
        XCTAssertEqual(store.creator(id: "onlyB")?.isSupported, false)
        XCTAssertEqual(store.creator(id: "shared")?.isSupported, true)
        let all = HomeFeedFilter(kind: .all)
        XCTAssertFalse(all.apply(store.fetch(all.descriptor(limit: nil))).contains { $0.postID == "b1" })
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

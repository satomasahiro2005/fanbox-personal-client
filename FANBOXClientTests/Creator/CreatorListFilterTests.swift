import XCTest
import SwiftData
@testable import FANBOXClient

@MainActor
final class CreatorListFilterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func facts(_ id: String, name: String? = nil, supported: Bool = false, followed: Bool = false, posts: Bool = false,
                       favorite: Bool = false, own: Bool = false, latest: Date? = nil, total: Int = 0, memo: String = "") -> CreatorFilterFacts {
        CreatorFilterFacts(creatorID: id, name: name ?? id, memo: memo, profileText: "", isSupported: supported, isFollowed: followed,
                           hasPosts: posts, isFavorite: favorite, isOwnCreator: own, latestPostAt: latest, monthlySupportTotal: total)
    }

    private var sample: [CreatorFilterFacts] {
        [
            facts("a", supported: true, posts: true, latest: t0),
            facts("b", followed: true),
            facts("c", supported: true, followed: true, favorite: true),
            facts("d", posts: true, own: true),
            facts("e"),
        ]
    }

    func testChipTitlesMatchSpec() {
        XCTAssertEqual(CreatorListFilter.allCases.map(\.title),
                       ["すべて", "支援中", "フォロー中", "投稿あり", "お気に入り", "自分のCreator Account"])
    }

    func testEachFilter() {
        func ids(_ f: CreatorListFilter) -> Set<String> {
            Set(CreatorListFilter.apply(sample, filter: f, query: "").map(\.creatorID))
        }
        XCTAssertEqual(ids(.all), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(ids(.supporting), ["a", "c"])
        XCTAssertEqual(ids(.following), ["b", "c"])
        XCTAssertEqual(ids(.hasPosts), ["a", "d"])
        XCTAssertEqual(ids(.favorite), ["c"])
        XCTAssertEqual(ids(.ownCreatorAccount), ["d"])
    }

    func testCounts() {
        let counts = CreatorListFilter.counts(sample)
        XCTAssertEqual(counts[.all], 5)
        XCTAssertEqual(counts[.supporting], 2)
        XCTAssertEqual(counts[.following], 2)
        XCTAssertEqual(counts[.hasPosts], 2)
        XCTAssertEqual(counts[.favorite], 1)
        XCTAssertEqual(counts[.ownCreatorAccount], 1)
    }

    func testSearchMatchesNameIDMemoAndIsInsensitive() {
        let items = [
            facts("hanako", name: "花子 Studio", memo: "#music 参考"),
            facts("taro", name: "Taro"),
        ]
        XCTAssertEqual(CreatorListFilter.apply(items, filter: .all, query: "studio").map(\.creatorID), ["hanako"])
        // Full-width query matches half-width text.
        XCTAssertEqual(CreatorListFilter.apply(items, filter: .all, query: "ＴＡＲＯ").map(\.creatorID), ["taro"])
        // Memo is searchable (SPEC §33).
        XCTAssertEqual(CreatorListFilter.apply(items, filter: .all, query: "#music").map(\.creatorID), ["hanako"])
        // "@id" searches the creator id.
        XCTAssertEqual(CreatorListFilter.apply(items, filter: .all, query: "@taro").map(\.creatorID), ["taro"])
        // All tokens must match.
        XCTAssertEqual(CreatorListFilter.apply(items, filter: .all, query: "花子 参考").map(\.creatorID), ["hanako"])
        XCTAssertTrue(CreatorListFilter.apply(items, filter: .all, query: "花子 taro").isEmpty)
        // Blank query = everything.
        XCTAssertEqual(CreatorListFilter.apply(items, filter: .all, query: "   ").count, 2)
    }

    func testSearchCombinesWithFilter() {
        XCTAssertEqual(CreatorListFilter.apply(sample, filter: .supporting, query: "c").map(\.creatorID), ["c"])
        XCTAssertTrue(CreatorListFilter.apply(sample, filter: .favorite, query: "a").isEmpty)
    }

    func testRecommendedSortFavoritesThenNewestThenName() {
        let items = [
            facts("z", name: "Zeta", latest: nil),
            facts("y", name: "Yota", latest: t0),
            facts("x", name: "Xi", latest: t0.addingTimeInterval(100)),
            facts("w", name: "Omega", favorite: true, latest: nil),
            facts("v", name: "Alpha", latest: nil),
        ]
        XCTAssertEqual(CreatorListFilter.apply(items, filter: .all, query: "", sort: .recommended).map(\.creatorID),
                       ["w", "x", "y", "v", "z"])
        XCTAssertEqual(CreatorListFilter.apply(items, filter: .all, query: "", sort: .name).map(\.creatorID),
                       ["v", "w", "x", "y", "z"])
    }

    func testSupportAmountSort() {
        let items = [facts("a", total: 500), facts("b", total: 6500), facts("c", total: 0)]
        XCTAssertEqual(CreatorListFilter.apply(items, filter: .all, query: "", sort: .supportAmount).map(\.creatorID), ["b", "a", "c"])
    }

    func testFactsFromSwiftDataCreatorUseCrossTableKnowledge() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = LocalStore(container: container)
        let plain = Creator(creatorID: "plain", name: "Plain")
        let supportedOnlyByRows = Creator(creatorID: "rows", name: "Rows")
        let followed = Creator(creatorID: "fol", name: "Followed")
        followed.followedByAccountIDs = ["acc1"]
        let mine = Creator(creatorID: "mine", name: "Mine")
        [plain, supportedOnlyByRows, followed, mine].forEach(store.context.insert)
        store.save()

        let totals = ["rows": 1500]
        let own: Set<String> = ["mine"]
        let latest = ["plain": t0]
        let enabled: Set<String> = ["acc1"]
        let f1 = CreatorFilterFacts(creator: plain, activeSupportTotals: totals, ownCreatorIDs: own, enabledAccountIDs: enabled,
                                    localLatestPostAt: latest)
        XCTAssertFalse(f1.isSupported)
        XCTAssertTrue(f1.hasPosts, "local posts count as 投稿あり even if hasKnownPosts is not denormalized")
        XCTAssertEqual(f1.latestPostAt, t0)
        XCTAssertFalse(f1.isOnlyRelatedToDisabledAccounts, "a creator without any account relation stays listed")

        let f2 = CreatorFilterFacts(creator: supportedOnlyByRows, activeSupportTotals: totals, ownCreatorIDs: own, enabledAccountIDs: enabled)
        XCTAssertTrue(f2.isSupported)
        XCTAssertEqual(f2.monthlySupportTotal, 1500)

        let f3 = CreatorFilterFacts(creator: followed, activeSupportTotals: totals, ownCreatorIDs: own, enabledAccountIDs: enabled)
        XCTAssertTrue(f3.isFollowed)
        XCTAssertFalse(f3.isOwnCreator)

        let f4 = CreatorFilterFacts(creator: mine, activeSupportTotals: totals, ownCreatorIDs: own, enabledAccountIDs: enabled)
        XCTAssertTrue(f4.isOwnCreator)
    }

    /// A disabled account's relations stay stored but count nowhere: a creator supported by A (enabled) and B (disabled)
    /// shows with A's total only; one related to disabled accounts only is hidden under every chip; re-enabling brings it back.
    func testDisabledAccountsRelationsAreIgnoredAndTheirCreatorsHidden() throws {
        let store = LocalStore(container: try PersistenceController.makeContainer(inMemory: true))
        let a = Account(id: "A", kind: .demo, displayName: "A", isMain: true, sortOrder: 0)
        let b = Account(id: "B", kind: .demo, displayName: "B", sortOrder: 1)
        [a, b].forEach(store.context.insert)
        let shared = Creator(creatorID: "shared", name: "Shared")
        shared.supportedByAccountIDs = ["A", "B"]
        let onlyB = Creator(creatorID: "onlyB", name: "Only B")
        onlyB.supportedByAccountIDs = ["B"]
        onlyB.followedByAccountIDs = ["B"]
        let ownedByB = Creator(creatorID: "ownedByB", name: "Owned by B")
        ownedByB.ownedByAccountID = "B"
        let plain = Creator(creatorID: "plain", name: "Plain")
        let creators = [shared, onlyB, ownedByB, plain]
        creators.forEach(store.context.insert)
        let supports = [
            Support(accountID: "A", creatorID: "shared", creatorName: "Shared", planID: "p1", planTitle: "P1", amount: 500),
            Support(accountID: "B", creatorID: "shared", creatorName: "Shared", planID: "p2", planTitle: "P2", amount: 1000),
            Support(accountID: "B", creatorID: "onlyB", creatorName: "Only B", planID: "p3", planTitle: "P3", amount: 300),
        ]
        supports.forEach(store.context.insert)
        b.enabled = false
        store.save()

        func model() -> CreatorsListModel {
            CreatorsListModel(creators: creators, activeSupports: supports, accounts: store.accounts(), localLatestPostAt: [:])
        }
        var m = model()
        var byID = Dictionary(uniqueKeysWithValues: m.facts.map { ($0.creatorID, $0) })
        XCTAssertEqual(byID["shared"]?.monthlySupportTotal, 500, "only A's support counts")
        XCTAssertEqual(m.supportingAccounts(creatorID: "shared").map(\.id), ["A"])
        XCTAssertEqual(byID["onlyB"]?.isOnlyRelatedToDisabledAccounts, true)
        XCTAssertEqual(byID["onlyB"]?.isSupported, false)
        XCTAssertEqual(byID["ownedByB"]?.isOnlyRelatedToDisabledAccounts, true)
        XCTAssertEqual(byID["ownedByB"]?.isOwnCreator, false)
        XCTAssertEqual(Set(CreatorListFilter.apply(m.facts, filter: .all, query: "").map(\.creatorID)), ["shared", "plain"])
        XCTAssertEqual(CreatorListFilter.apply(m.facts, filter: .supporting, query: "").map(\.creatorID), ["shared"])
        let counts = CreatorListFilter.counts(m.facts)
        XCTAssertEqual(counts[.all], 2)
        XCTAssertEqual(counts[.supporting], 1)
        XCTAssertEqual(counts[.following], 0)
        XCTAssertEqual(counts[.ownCreatorAccount], 0)
        // The offline creator picker applies the same rule to the stored relations.
        func hiddenInPicker() -> [String] {
            let enabled = store.enabledAccountIDs()
            return creators.filter { CreatorFilterFacts.isOnlyRelatedToDisabledAccounts($0, enabledAccountIDs: enabled) }.map(\.creatorID)
        }
        XCTAssertEqual(hiddenInPicker(), ["onlyB", "ownedByB"])

        b.enabled = true
        store.save()
        XCTAssertEqual(hiddenInPicker(), [])
        m = model()
        byID = Dictionary(uniqueKeysWithValues: m.facts.map { ($0.creatorID, $0) })
        XCTAssertEqual(byID["shared"]?.monthlySupportTotal, 1500)
        XCTAssertEqual(m.supportingAccounts(creatorID: "shared").map(\.id), ["A", "B"])
        XCTAssertEqual(CreatorListFilter.counts(m.facts)[.all], 4)
        XCTAssertEqual(Set(CreatorListFilter.apply(m.facts, filter: .supporting, query: "").map(\.creatorID)), ["shared", "onlyB"])
        XCTAssertEqual(CreatorListFilter.apply(m.facts, filter: .ownCreatorAccount, query: "").map(\.creatorID), ["ownedByB"])
    }
}

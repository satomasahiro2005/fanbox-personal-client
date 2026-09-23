import XCTest
import SwiftData
@testable import FANBOXClient

@MainActor
final class CreatorSupportSummaryTests: XCTestCase {
    private func input(_ account: String, _ creator: String = "cA", amount: Int, status: SupportStatus = .active, plan: String? = nil,
                       attention: Bool = false, reason: String? = nil) -> CreatorSupportInput {
        CreatorSupportInput(accountID: account, creatorID: creator, planID: plan ?? "p\(amount)", planTitle: "\(amount)円プラン",
                            amount: amount, status: status, needsAttention: attention, attentionReason: reason)
    }

    /// SPEC §9 example: A ¥500 / B ¥1,000 / C ¥5,000 → 合計 ¥6,500 / 月.
    func testSpecExampleTotal() {
        let supports = [input("B", amount: 1000), input("C", amount: 5000), input("A", amount: 500)]
        let summary = CreatorSupportSummary.make(creatorID: "cA", supports: supports, accountOrder: ["A", "B", "C"])
        XCTAssertEqual(summary.monthlyTotal, 6500)
        XCTAssertEqual(summary.monthlyTotalText, "¥6,500 / 月")
        XCTAssertEqual(summary.accountIDs, ["A", "B", "C"], "lines follow account display order")
        XCTAssertEqual(summary.lines.map(\.amountText), ["¥500", "¥1,000", "¥5,000"])
        XCTAssertTrue(summary.isSupporting)
        XCTAssertTrue(summary.attentions.isEmpty)
    }

    func testOnlyActiveSupportsOfThisCreatorAreSummed() {
        let supports = [
            input("A", amount: 500),
            input("B", amount: 1000, status: .ended),
            input("C", amount: 3000, status: .missing),
            input("A", "other", amount: 9999),
        ]
        let summary = CreatorSupportSummary.make(creatorID: "cA", supports: supports, accountOrder: ["A", "B", "C"])
        XCTAssertEqual(summary.monthlyTotal, 500)
        XCTAssertEqual(summary.accountIDs, ["A"])
        // A disappeared support is surfaced as an observed fact, never as a payment failure (SPEC §15).
        XCTAssertEqual(summary.attentions.map(\.accountID), ["C"])
        XCTAssertEqual(summary.attentions.first?.reason, "支援が一覧から見つかりません")
        XCTAssertFalse(summary.attentions.contains { $0.reason.contains("決済失敗") })
    }

    func testAttentionUsesObservedReasonWhenPresent() {
        let supports = [input("A", amount: 1000, attention: true, reason: "以前: ¥1,000 / 月 → 現在: 支援なし")]
        let summary = CreatorSupportSummary.make(creatorID: "cA", supports: supports)
        XCTAssertEqual(summary.attentions.first?.reason, "以前: ¥1,000 / 月 → 現在: 支援なし")
        XCTAssertEqual(summary.monthlyTotal, 1000, "an active support flagged for attention still counts")
    }

    func testUnknownAccountsIgnoredAndEmptySummary() {
        let supports = [input("ghost", amount: 500)]
        let summary = CreatorSupportSummary.make(creatorID: "cA", supports: supports, knownAccountIDs: ["A"])
        XCTAssertFalse(summary.isSupporting)
        XCTAssertEqual(summary.monthlyTotal, 0)
        XCTAssertEqual(summary.monthlyTotalText, "¥0 / 月")
    }

    func testDuplicateRowsForSameAccountAreNotDoubleCounted() {
        let supports = [input("A", amount: 500), input("A", amount: 1000)]
        let summary = CreatorSupportSummary.make(creatorID: "cA", supports: supports)
        XCTAssertEqual(summary.lines.count, 1)
        XCTAssertEqual(summary.monthlyTotal, 1000)
        XCTAssertEqual(CreatorSupportSummary.totalsByCreator(supports)["cA"], 1000, "totals use the same rule as the summary")
    }

    func testTotalsAndAccountsByCreator() {
        let supports = [
            input("B", "c1", amount: 1000),
            input("A", "c1", amount: 500),
            input("A", "c2", amount: 300),
            input("C", "c2", amount: 700, status: .ended),
        ]
        let totals = CreatorSupportSummary.totalsByCreator(supports)
        XCTAssertEqual(totals, ["c1": 1500, "c2": 300])
        let accounts = CreatorSupportSummary.accountsByCreator(supports, accountOrder: ["A", "B", "C"])
        XCTAssertEqual(accounts["c1"], ["A", "B"])
        XCTAssertEqual(accounts["c2"], ["A"])
        XCTAssertEqual(CreatorSupportSummary.totalsByCreator(supports, knownAccountIDs: ["B"]), ["c1": 1000])
    }

    func testBuildsFromSwiftDataSupportRows() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = LocalStore(container: container)
        store.context.insert(Support(accountID: "A", creatorID: "cA", creatorName: "Creator A", planID: "p1", planTitle: "ワンコイン", amount: 500))
        store.context.insert(Support(accountID: "B", creatorID: "cA", creatorName: "Creator A", planID: "p2", planTitle: "スタンダード", amount: 1000))
        store.context.insert(Support(accountID: "C", creatorID: "cA", creatorName: "Creator A", planID: "p3", planTitle: "プレミアム", amount: 5000))
        store.save()

        let rows = store.supports(creatorID: "cA")
        let summary = CreatorSupportSummary.make(creatorID: "cA", supports: rows.map(CreatorSupportInput.init), accountOrder: ["A", "B", "C"])
        XCTAssertEqual(summary.monthlyTotalText, "¥6,500 / 月")
        XCTAssertEqual(summary.lines.map(\.planTitle), ["ワンコイン", "スタンダード", "プレミアム"])
    }

    func testProfileLinkParsing() {
        XCTAssertEqual(CreatorProfileLink("https://www.pixiv.net/users/1")?.title, "pixiv.net/users/1")
        XCTAssertEqual(CreatorProfileLink(" https://example.com/ ")?.title, "example.com")
        XCTAssertNil(CreatorProfileLink("javascript:alert(1)"))
        XCTAssertNil(CreatorProfileLink("not a url"))
    }

    func testAccountOrderingPutsRelatedAccountsFirst() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = LocalStore(container: container)
        let a = Account(id: "A", displayName: "A", sortOrder: 0)
        let b = Account(id: "B", displayName: "B", sortOrder: 1)
        let c = Account(id: "C", displayName: "C", sortOrder: 2)
        [a, b, c].forEach(store.context.insert)
        XCTAssertEqual(CreatorAccountOrdering.preferred([a, b, c], first: ["C", "A", "C"]).map(\.id), ["C", "A", "B"])
    }
}

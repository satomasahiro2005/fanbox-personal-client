import SwiftData
import XCTest
@testable import FANBOXClient

/// SPEC §10.3: 来月予定 differs from 定常月額 when stops are known; JST billing months; unknown payment amounts;
/// "決済状態を確認できません" accounts in 要確認.
final class FixSupportDashboardTests: XCTestCase {
    private var tokyo: Calendar { SupportBilling.calendar }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func jst(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        tokyo.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func support(_ account: String, _ creator: String, _ amount: Int, status: SupportStatus = .active,
                         stoppingObservedAt: Date? = nil, userStopMarkedAt: Date? = nil) -> SupportSnapshot {
        SupportSnapshot(accountID: account, creatorID: creator, creatorName: "Creator \(creator)", amount: amount, status: status,
                        stoppingObservedAt: stoppingObservedAt, userStopMarkedAt: userStopMarkedAt)
    }

    // MARK: SupportStopRule

    func testStopAppliesToItsOwnBillingMonthOnly() {
        let now = jst(2026, 9, 24)
        XCTAssertEqual(SupportStopRule.scheduledStop(stoppingObservedAt: jst(2026, 9, 2), userStopMarkedAt: nil, now: now), .observed)
        XCTAssertEqual(SupportStopRule.scheduledStop(stoppingObservedAt: nil, userStopMarkedAt: jst(2026, 9, 1, 0, 5), now: now), .userMarked)
        XCTAssertNil(SupportStopRule.scheduledStop(stoppingObservedAt: jst(2026, 8, 31, 23, 59), userStopMarkedAt: nil, now: now),
                     "a stop of last month is stale: the support is still listed, so it continues")
        XCTAssertEqual(SupportStopRule.scheduledStop(stoppingObservedAt: jst(2026, 9, 3), userStopMarkedAt: jst(2026, 9, 3), now: now),
                       .observed, "FANBOX's observation wins for labeling")
    }

    func testStopMonthUsesJapanTimeNotTheDeviceCalendar() {
        // 2026-10-01 00:30 JST is still 2026-09-30 in UTC.
        let marked = jst(2026, 10, 1, 0, 30)
        let now = jst(2026, 10, 20)
        XCTAssertEqual(SupportStopRule.scheduledStop(stoppingObservedAt: nil, userStopMarkedAt: marked, now: now), .userMarked)
        XCTAssertNil(SupportStopRule.scheduledStop(stoppingObservedAt: nil, userStopMarkedAt: marked, now: now, calendar: utc))
    }

    func testDisappearanceIsExplainedByThisOrPreviousMonthOnly() {
        let now = jst(2026, 10, 2)
        XCTAssertTrue(SupportStopRule.explainsDisappearance(jst(2026, 10, 1), now: now))
        XCTAssertTrue(SupportStopRule.explainsDisappearance(jst(2026, 9, 20), now: now), "stopped in September, gone in October")
        XCTAssertFalse(SupportStopRule.explainsDisappearance(jst(2026, 8, 20), now: now), "too old to explain it")
        XCTAssertFalse(SupportStopRule.explainsDisappearance(nil, now: now))
        XCTAssertFalse(SupportStopRule.explainsDisappearance(jst(2026, 10, 5), now: now), "a future record explains nothing")
    }

    // MARK: 来月予定

    func testNextMonthExcludesScheduledStopsButRecurringKeepsThem() {
        let now = jst(2026, 9, 24)
        let supports = [
            support("A", "c1", 500),
            support("A", "c2", 1_000, stoppingObservedAt: jst(2026, 9, 10)),     // FANBOX: stopped, valid until 9/30
            support("B", "c3", 3_000, userStopMarkedAt: jst(2026, 9, 20)),       // user-entered stop
            support("B", "c4", 2_000, userStopMarkedAt: jst(2026, 8, 20)),       // stale record → continues
            support("C", "c5", 700, status: .ended, userStopMarkedAt: jst(2026, 9, 1)),
            support("C", "c6", 900, status: .missing),
        ]
        let s = SupportAnalyzer.summarize(supports: supports, payments: [], now: now)
        XCTAssertEqual(s.recurringMonthly, 6_500, "stopped supports are still in effect this month")
        XCTAssertEqual(s.nextMonthPlanned, 2_500)
        XCTAssertLessThan(s.nextMonthPlanned, s.recurringMonthly)
        XCTAssertEqual(s.scheduledStopObservedCount, 1)
        XCTAssertEqual(s.scheduledStopUserMarkedCount, 1)
        XCTAssertEqual(s.scheduledStopCount, 2)
        XCTAssertEqual(SupportText.nextMonthCaption(s), "停止予定2件を除く（FANBOXで観測1 / 自分で記録1）")

        let october = SupportAnalyzer.summarize(supports: supports, payments: [], now: jst(2026, 10, 1, 9))
        XCTAssertEqual(october.nextMonthPlanned, october.recurringMonthly, "September's stops do not carry over")
    }

    func testNextMonthEqualsRecurringWithoutStops() {
        let s = SupportAnalyzer.summarize(supports: [support("A", "c1", 500), support("B", "c1", 1_000)], payments: [], now: jst(2026, 9, 1))
        XCTAssertEqual(s.nextMonthPlanned, 1_500)
        XCTAssertEqual(s.scheduledStopCount, 0)
        XCTAssertNil(SupportText.nextMonthCaption(s), "nothing to add under 来月予定 without stops")
    }

    // MARK: 今月実請求 (JST)

    func testActualThisMonthUsesJapanBillingMonthByDefault() {
        // Charged 2026-10-01 00:30 JST = 2026-09-30 15:30 UTC.
        let payments = [PaymentSnapshot(accountID: "A", amount: 500, paidAt: jst(2026, 10, 1, 0, 30)),
                        PaymentSnapshot(accountID: "A", amount: 1, paidAt: jst(2026, 9, 30, 23, 59))]
        let now = jst(2026, 10, 3)
        let s = SupportAnalyzer.summarize(supports: [], payments: payments, now: now)
        XCTAssertEqual(s.month, "2026-10")
        XCTAssertEqual(s.actualThisMonth, 500)
        XCTAssertEqual(SupportAnalyzer.monthLabel(now), "10月")
        XCTAssertEqual(SupportAnalyzer.paymentsInPreviousMonth(payments, before: now).map(\.amount), [1])
        let deviceUTC = SupportAnalyzer.summarize(supports: [], payments: payments, now: now, calendar: utc)
        XCTAssertEqual(deviceUTC.actualThisMonth, 0, "the device calendar would have put it into September")
    }

    func testPreviousMonthRangeIsHalfOpenInJST() throws {
        let range = try XCTUnwrap(SupportAnalyzer.previousMonthRange(before: jst(2026, 3, 31)))
        XCTAssertEqual(range.lowerBound, jst(2026, 2, 1, 0))
        XCTAssertEqual(range.upperBound, jst(2026, 3, 1, 0))
    }

    func testPaymentsWithoutReportedAmountAreNotCountedAsZero() {
        let payments = [PaymentSnapshot(accountID: "A", amount: 500, paidAt: jst(2026, 9, 3)),
                        PaymentSnapshot(accountID: "A", amount: 0, paidAt: jst(2026, 9, 4), isAmountKnown: false)]
        let s = SupportAnalyzer.summarize(supports: [], payments: payments, now: jst(2026, 9, 10))
        XCTAssertEqual(s.actualThisMonth, 500)
        XCTAssertEqual(s.actualUnknownAmountCount, 1)
        XCTAssertEqual(SupportText.actualCaption(s), "金額不明1件を除く")

        let onlyUnknown = SupportAnalyzer.summarize(supports: [], payments: [payments[1]], now: jst(2026, 9, 10))
        XCTAssertEqual(onlyUnknown.actualThisMonth, 0)
        XCTAssertEqual(onlyUnknown.actualUnknownAmountCount, 1)
    }

    // MARK: 決済状態を確認できません

    func testUnpaidAccountsAreAttentionItemsWithObservationalWording() {
        let states = [
            AccountPaymentState(accountID: "A", hasUnpaidPayments: true, checkedAt: jst(2026, 9, 3)),
            AccountPaymentState(accountID: "B", hasUnpaidPayments: false),
            AccountPaymentState(accountID: "C", hasUnpaidPayments: nil),
            AccountPaymentState(accountID: "D", enabled: false, hasUnpaidPayments: true),
        ]
        let ids = SupportAnalyzer.paymentStateAttentionAccountIDs(states)
        XCTAssertEqual(ids, ["A"])
        let s = SupportAnalyzer.summarize(supports: [support("B", "c1", 500, status: .missing)].map { var x = $0; x.needsAttention = true; return x },
                                          payments: [], now: jst(2026, 9, 3), paymentStateAttentionAccountIDs: ids)
        XCTAssertEqual(s.attentionCount, 2)
        XCTAssertEqual(SupportText.paymentStateUnknown, "決済状態を確認できません")
        XCTAssertFalse(SupportText.assertsCause(SupportText.paymentStateUnknown))
        XCTAssertFalse(SupportText.assertsCause(SupportText.paymentStateUnknownDetail))
    }

    /// A disabled account is left out of the dashboard (定常月額 / 今月実請求 / 来月予定, counts, 要確認) and of the
    /// Creator別 lines; enabling it again brings everything back. Local rows are kept either way.
    @MainActor
    func testDisabledAccountsAreLeftOutOfTheDashboard() throws {
        let store = LocalStore(container: try PersistenceController.makeContainer(inMemory: true))
        let a = Account(id: "A", kind: .demo, displayName: "A", isMain: true, sortOrder: 0)
        let b = Account(id: "B", kind: .demo, displayName: "B", sortOrder: 1)
        b.hasUnpaidPayments = true
        [a, b].forEach(store.context.insert)
        store.context.insert(Support(accountID: "A", creatorID: "c1", creatorName: "C1", planID: "p1", planTitle: "P", amount: 500))
        store.context.insert(Support(accountID: "B", creatorID: "c1", creatorName: "C1", planID: "p2", planTitle: "P", amount: 1_000))
        let stopping = Support(accountID: "B", creatorID: "c2", creatorName: "C2", planID: "p3", planTitle: "P", amount: 300)
        stopping.stoppingObservedAt = jst(2026, 9, 2)
        store.context.insert(stopping)
        let missing = Support(accountID: "B", creatorID: "c3", creatorName: "C3", planID: "p4", planTitle: "P", amount: 700, status: .missing)
        missing.needsAttention = true
        store.context.insert(missing)
        store.context.insert(PaymentRecord(paymentID: "pay-b", accountID: "B", creatorID: "c1", creatorName: "C1", amount: 1_000,
                                           paidAt: jst(2026, 9, 1, 9)))
        b.enabled = false
        store.save()
        let now = jst(2026, 9, 10)

        func creatorLines() -> [String: [String]] {
            let enabled = store.enabledAccountIDs()
            let snapshots = store.fetch(FetchDescriptorFactorySupport.allSupports()).filter { enabled.contains($0.accountID) }
                .map(SupportSnapshot.init)
            let groups = SupportAnalyzer.byCreator(supports: snapshots, accountOrder: store.accounts().map(\.id))
            return Dictionary(uniqueKeysWithValues: groups.map { ($0.creatorID, $0.lines.map(\.support.accountID)) })
        }

        let disabled = SupportAnalyzer.summary(store: store, now: now)
        XCTAssertEqual(disabled.recurringMonthly, 500)
        XCTAssertEqual(disabled.nextMonthPlanned, 500)
        XCTAssertNil(disabled.actualThisMonth, "B's payment is hidden and A has none")
        XCTAssertEqual(disabled.creatorCount, 1)
        XCTAssertEqual(disabled.accountCount, 1)
        XCTAssertEqual(disabled.attentionCount, 0, "neither B's anomaly nor B's unpaid flag")
        XCTAssertEqual(creatorLines(), ["c1": ["A"]])

        b.enabled = true
        store.save()
        let enabled = SupportAnalyzer.summary(store: store, now: now)
        XCTAssertEqual(enabled.recurringMonthly, 1_800)
        XCTAssertEqual(enabled.nextMonthPlanned, 1_500)
        XCTAssertEqual(enabled.actualThisMonth, 1_000)
        XCTAssertEqual(enabled.accountCount, 2)
        XCTAssertEqual(enabled.attentionCount, 2)
        XCTAssertEqual(creatorLines(), ["c1": ["A", "B"], "c2": ["B"]])
    }

    func testStopLabelsSeparateObservedFromUserEntered() {
        XCTAssertEqual(SupportStopRule.label(.observed), "停止予定（FANBOXで観測）")
        XCTAssertEqual(SupportStopRule.label(.userMarked), "停止予定（自分で記録）")
        XCTAssertNil(support("A", "c1", 500, status: .missing, stoppingObservedAt: .now).scheduledStop(),
                     "only active supports can be scheduled to stop")
    }
}

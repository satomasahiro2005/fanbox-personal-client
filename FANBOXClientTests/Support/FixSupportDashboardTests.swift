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
        XCTAssertEqual(SupportText.nextMonthCaption(s), "停止予定 2 件を除く（FANBOX で観測 1 / 自分で記録 1）")

        let october = SupportAnalyzer.summarize(supports: supports, payments: [], now: jst(2026, 10, 1, 9))
        XCTAssertEqual(october.nextMonthPlanned, october.recurringMonthly, "September's stops do not carry over")
    }

    func testNextMonthEqualsRecurringWithoutStops() {
        let s = SupportAnalyzer.summarize(supports: [support("A", "c1", 500), support("B", "c1", 1_000)], payments: [], now: jst(2026, 9, 1))
        XCTAssertEqual(s.nextMonthPlanned, 1_500)
        XCTAssertEqual(s.scheduledStopCount, 0)
        XCTAssertEqual(SupportText.nextMonthCaption(s), "停止予定を除く継続中の支援の合計")
    }

    func testFootnoteDocumentsTheRules() {
        XCTAssertTrue(SupportText.dashboardFootnote.contains("日本時間"))
        XCTAssertTrue(SupportText.dashboardFootnote.contains("停止予定"))
        XCTAssertTrue(SupportText.dashboardFootnote.contains("自分で記録"))
        XCTAssertTrue(SupportText.dashboardFootnote.contains("プラン変更"))
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
        XCTAssertEqual(SupportText.actualCaption(s), "観測したお支払いの合計（金額不明 1 件を除く）")

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

    func testStopLabelsSeparateObservedFromUserEntered() {
        XCTAssertEqual(SupportStopRule.label(.observed), "停止予定（FANBOX で観測）")
        XCTAssertEqual(SupportStopRule.label(.userMarked), "停止予定（自分で記録）")
        XCTAssertNil(support("A", "c1", 500, status: .missing, stoppingObservedAt: .now).scheduledStop(),
                     "only active supports can be scheduled to stop")
    }
}

import XCTest
import SwiftData
@testable import FANBOXClient

final class SupportAnalyzerTests: XCTestCase {
    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
        tokyo.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    private func support(_ account: String, _ creator: String, _ amount: Int, status: SupportStatus = .active,
                         attention: Bool = false, acknowledged: Date? = nil, missingSince: Date? = nil) -> SupportSnapshot {
        SupportSnapshot(accountID: account, creatorID: creator, creatorName: "Creator \(creator)", planID: "plan-\(creator)-\(amount)",
                        planTitle: "¥\(amount) Plan", amount: amount, status: status, missingSince: missingSince,
                        needsAttention: attention, acknowledgedAt: acknowledged)
    }

    // MARK: summarize

    func testRecurringCountsOnlyActiveSupports() {
        let supports = [
            support("A", "c1", 500), support("B", "c1", 1_000), support("C", "c1", 5_000),
            support("A", "c2", 1_000), support("A", "c3", 2_000),
            support("B", "c4", 3_000, status: .missing, attention: true),
            support("C", "c5", 700, status: .ended),
            support("C", "c6", 900, status: .unknown),
        ]
        let s = SupportAnalyzer.summarize(supports: supports, payments: [], now: date(2026, 9, 15), calendar: tokyo)
        XCTAssertEqual(s.month, "2026-09")
        XCTAssertEqual(s.recurringMonthly, 9_500)
        XCTAssertEqual(s.nextMonthPlanned, 9_500)
        XCTAssertEqual(s.creatorCount, 3)   // c1, c2, c3
        XCTAssertEqual(s.accountCount, 3)   // A, B, C
        XCTAssertEqual(s.attentionCount, 1)
    }

    func testActualIsNilWithoutAnyPaymentRecords() {
        let s = SupportAnalyzer.summarize(supports: [support("A", "c1", 500)], payments: [], now: date(2026, 9, 15), calendar: tokyo)
        XCTAssertNil(s.actualThisMonth, "no payment data must not be shown as ¥0")
        XCTAssertEqual(s.recurringMonthly, 500)
    }

    func testActualIsZeroWhenPaymentsExistOnlyInOtherMonths() {
        let payments = [PaymentSnapshot(accountID: "A", amount: 500, paidAt: date(2026, 8, 10))]
        let s = SupportAnalyzer.summarize(supports: [], payments: payments, now: date(2026, 9, 15), calendar: tokyo)
        XCTAssertEqual(s.actualThisMonth, 0)
    }

    func testActualRespectsMonthBoundaries() {
        let payments = [
            PaymentSnapshot(accountID: "A", amount: 1, paidAt: date(2026, 8, 31, 23, 59, 59)),     // previous month
            PaymentSnapshot(accountID: "A", amount: 10, paidAt: date(2026, 9, 1, 0, 0, 0)),        // first instant: included
            PaymentSnapshot(accountID: "B", amount: 100, paidAt: date(2026, 9, 15, 12)),
            PaymentSnapshot(accountID: "C", amount: 1_000, paidAt: date(2026, 9, 30, 23, 59, 59)), // last second: included
            PaymentSnapshot(accountID: "A", amount: 10_000, paidAt: date(2026, 10, 1, 0, 0, 0)),   // next month: excluded
        ]
        let s = SupportAnalyzer.summarize(supports: [], payments: payments, now: date(2026, 9, 1, 0, 0, 0), calendar: tokyo)
        XCTAssertEqual(s.actualThisMonth, 1_110)
        let october = SupportAnalyzer.summarize(supports: [], payments: payments, now: date(2026, 10, 1, 9), calendar: tokyo)
        XCTAssertEqual(october.actualThisMonth, 10_000)
        XCTAssertEqual(october.month, "2026-10")
    }

    func testMonthBoundaryDependsOnCalendarTimeZone() {
        // 2026-08-31 16:00 UTC == 2026-09-01 01:00 JST
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let paidAt = utc.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 16))!
        let payments = [PaymentSnapshot(accountID: "A", amount: 500, paidAt: paidAt)]
        let now = date(2026, 9, 10)
        XCTAssertEqual(SupportAnalyzer.summarize(supports: [], payments: payments, now: now, calendar: tokyo).actualThisMonth, 500)
        XCTAssertEqual(SupportAnalyzer.summarize(supports: [], payments: payments, now: now, calendar: utc).actualThisMonth, 0)
    }

    func testPreviousMonthPaymentsAcrossYearBoundary() {
        let payments = [
            PaymentSnapshot(accountID: "A", amount: 300, paidAt: date(2025, 12, 31, 23)),
            PaymentSnapshot(accountID: "A", amount: 400, paidAt: date(2026, 1, 1)),
        ]
        let previous = SupportAnalyzer.paymentsInPreviousMonth(payments, before: date(2026, 1, 5), calendar: tokyo)
        XCTAssertEqual(previous.map(\.amount), [300])
        XCTAssertEqual(SupportAnalyzer.paymentsInMonth(payments, containing: date(2026, 1, 20), calendar: tokyo).map(\.amount), [400])
    }

    // MARK: lastPayments (前回)

    func testLastPaymentIsTheNewestPerAccountAndCreator() {
        let payments = [
            PaymentSnapshot(accountID: "A", creatorID: "c1", amount: 500, paidAt: date(2026, 8, 2, 9)),
            PaymentSnapshot(accountID: "A", creatorID: "c1", amount: 500, paidAt: date(2026, 9, 2, 9)),
            PaymentSnapshot(accountID: "A", creatorID: "c1", amount: 500, paidAt: date(2026, 7, 2, 9)),
            PaymentSnapshot(accountID: "A", creatorID: "c2", amount: 1_000, paidAt: date(2026, 9, 3, 9)),
        ]
        let last = SupportAnalyzer.lastPayments(payments)
        XCTAssertEqual(Set(last.keys), ["A|c1", "A|c2"])
        XCTAssertEqual(last["A|c1"]?.paidAt, date(2026, 9, 2, 9))
        XCTAssertEqual(last["A|c1"]?.amount, 500)
        XCTAssertEqual(last["A|c2"]?.paidAt, date(2026, 9, 3, 9))
        XCTAssertEqual(last["A|c2"]?.amount, 1_000)
    }

    func testLastPaymentKeepsAccountsSeparate() {
        let payments = [
            PaymentSnapshot(accountID: "A", creatorID: "c1", amount: 500, paidAt: date(2026, 9, 2, 9)),
            PaymentSnapshot(accountID: "B", creatorID: "c1", amount: 1_000, paidAt: date(2026, 9, 4, 9)),
        ]
        let last = SupportAnalyzer.lastPayments(payments)
        XCTAssertEqual(last["A|c1"]?.paidAt, date(2026, 9, 2, 9), "B's newer payment is not A's")
        XCTAssertEqual(last["A|c1"]?.amount, 500)
        XCTAssertEqual(last["B|c1"]?.paidAt, date(2026, 9, 4, 9))
        XCTAssertEqual(last["B|c1"]?.amount, 1_000)
    }

    func testLastPaymentSkipsRecordsWithoutCreator() {
        let payments = [
            PaymentSnapshot(accountID: "A", creatorID: nil, amount: 9_999, paidAt: date(2026, 9, 20)),
            PaymentSnapshot(accountID: "A", creatorID: "", amount: 9_999, paidAt: date(2026, 9, 21)),
            PaymentSnapshot(accountID: "A", creatorID: "c1", amount: 500, paidAt: date(2026, 9, 2)),
        ]
        let last = SupportAnalyzer.lastPayments(payments)
        XCTAssertEqual(Array(last.keys), ["A|c1"])
        XCTAssertEqual(last["A|c1"]?.amount, 500)
    }

    func testSameMonthUpgradePaymentIsTheLastPayment() throws {
        // Monthly ¥500 charge on 9/2, then an upgrade to ¥3,000 on 9/15 charges the ¥2,500 difference at once.
        let payments = [
            PaymentSnapshot(accountID: "A", creatorID: "c1", amount: 500, paidAt: date(2026, 9, 2, 9)),
            PaymentSnapshot(accountID: "A", creatorID: "c1", amount: 2_500, paidAt: date(2026, 9, 15, 21)),
        ]
        let last = try XCTUnwrap(SupportAnalyzer.lastPayments(payments)["A|c1"])
        XCTAssertEqual(last.paidAt, date(2026, 9, 15, 21))
        XCTAssertEqual(last.amount, 2_500, "the newest charge as it is, never summed with the monthly one")
    }

    func testUnknownAmountStillGivesTheDate() throws {
        let payments = [
            PaymentSnapshot(accountID: "A", creatorID: "c1", amount: 500, paidAt: date(2026, 8, 2)),
            PaymentSnapshot(accountID: "A", creatorID: "c1", amount: 0, paidAt: date(2026, 9, 2, 9), isAmountKnown: false),
        ]
        let last = try XCTUnwrap(SupportAnalyzer.lastPayments(payments)["A|c1"])
        XCTAssertEqual(last.paidAt, date(2026, 9, 2, 9))
        XCTAssertNil(last.amount, "never shown as ¥0")
        XCTAssertEqual(SupportText.lastPaymentText(last, now: date(2026, 9, 24), calendar: tokyo), "前回9/2")
        let known = LastPayment(accountID: "A", creatorID: "c1", paidAt: date(2026, 9, 2, 9), amount: 500)
        XCTAssertEqual(SupportText.lastPaymentText(known, now: date(2026, 9, 24), calendar: tokyo), "前回9/2 ¥500")
        XCTAssertEqual(SupportText.lastPaymentText(known, showsAmount: false, now: date(2026, 9, 24), calendar: tokyo), "前回9/2")
    }

    func testMonthLabel() {
        XCTAssertEqual(SupportAnalyzer.monthLabel(date(2026, 9, 24), calendar: tokyo), "9月")
        XCTAssertEqual(SupportAnalyzer.monthKey(date(2026, 1, 2), calendar: tokyo), "2026-01")
    }

    // MARK: attention

    func testAttentionCountIgnoresAcknowledged() {
        let supports = [
            support("A", "c1", 1_000, status: .missing, attention: true),
            support("B", "c1", 500, status: .missing, attention: true, acknowledged: date(2026, 9, 2)),
            support("C", "c2", 700, status: .unknown, attention: true),
            support("A", "c3", 300, status: .missing, attention: false),
        ]
        let s = SupportAnalyzer.summarize(supports: supports, payments: [], now: date(2026, 9, 5), calendar: tokyo)
        XCTAssertEqual(s.attentionCount, 2)
        XCTAssertEqual(Set(SupportAnalyzer.attentionItems(supports).map(\.id)), ["A|c1", "C|c2"])
    }

    func testAttentionItemsNewestFirst() {
        let supports = [
            support("A", "old", 1_000, status: .missing, attention: true, missingSince: date(2026, 9, 1)),
            support("A", "new", 1_000, status: .missing, attention: true, missingSince: date(2026, 9, 3)),
        ]
        XCTAssertEqual(SupportAnalyzer.attentionItems(supports).map(\.creatorID), ["new", "old"])
    }

    // MARK: groupings

    func testByCreatorGroupsAccountsAndTotals() {
        let supports = [
            support("B", "c1", 1_000), support("A", "c1", 500), support("C", "c1", 5_000),
            support("A", "c2", 1_000),
            support("B", "c3", 3_000, status: .missing, attention: true),
        ]
        let assignments = [AssignmentSnapshot(accountID: "B", creatorID: "c1", paymentProfileID: "p1", verificationState: .verified)]
        let groups = SupportAnalyzer.byCreator(supports: supports, assignments: assignments, accountOrder: ["A", "B", "C"])
        XCTAssertEqual(groups.map(\.creatorID), ["c1", "c2"], "inactive-only creators are hidden; sorted by total desc")
        XCTAssertEqual(groups[0].total, 6_500)
        XCTAssertEqual(groups[0].lines.map(\.support.accountID), ["A", "B", "C"], "lines follow account order")
        XCTAssertEqual(groups[0].lines[1].assignment?.paymentProfileID, "p1")
        XCTAssertNil(groups[0].lines[0].assignment)
        XCTAssertEqual(groups[0].activeAccountIDs, ["A", "B", "C"])

        let withInactive = SupportAnalyzer.byCreator(supports: supports, accountOrder: ["A", "B", "C"], includeInactive: true)
        let c3 = withInactive.first { $0.creatorID == "c3" }
        XCTAssertEqual(c3?.total, 0, "missing supports never count toward the total")
        XCTAssertEqual(c3?.lines.count, 1)
    }

    func testByAccountGroupsCreatorsAndTotals() {
        let supports = [
            support("A", "c1", 500), support("A", "c2", 1_000), support("A", "c3", 2_000),
            support("B", "c1", 1_000),
            support("A", "c4", 9_000, status: .ended),
            support("Z", "c1", 100),
        ]
        let groups = SupportAnalyzer.byAccount(supports: supports, accountOrder: ["B", "A"])
        XCTAssertEqual(groups.map(\.accountID), ["B", "A", "Z"], "unknown accounts sort last")
        let a = groups[1]
        XCTAssertEqual(a.total, 3_500)
        XCTAssertEqual(a.lines.map(\.support.creatorID), ["c3", "c2", "c1"], "amount desc")
        XCTAssertEqual(a.activeCreatorCount, 3)

        let withInactive = SupportAnalyzer.byAccount(supports: supports, accountOrder: ["B", "A"], includeInactive: true)
        let aAll = withInactive.first { $0.accountID == "A" }!
        XCTAssertEqual(aAll.total, 3_500)
        XCTAssertEqual(aAll.lines.last?.support.creatorID, "c4", "inactive lines after active ones")
    }

    func testInferredProfileRequiresSingleMatchingProfile() {
        let profiles: [(id: String, type: PaymentProfileType)] = [("visa", .creditCard), ("pp", .paypal)]
        XCTAssertEqual(SupportAnalyzer.inferredProfileID(reportedPaymentMethod: "paypal", profiles: profiles), "pp")
        XCTAssertEqual(SupportAnalyzer.inferredProfileID(reportedPaymentMethod: "card", profiles: profiles), "visa")
        XCTAssertNil(SupportAnalyzer.inferredProfileID(reportedPaymentMethod: nil, profiles: profiles))
        XCTAssertNil(SupportAnalyzer.inferredProfileID(reportedPaymentMethod: "default", profiles: profiles))
        let twoCards: [(id: String, type: PaymentProfileType)] = [("visa", .creditCard), ("mc", .creditCard)]
        XCTAssertNil(SupportAnalyzer.inferredProfileID(reportedPaymentMethod: "card", profiles: twoCards), "ambiguous ⇒ no guess")
    }

    // MARK: summary(store:)

    @MainActor
    func testSummaryFromStoreUsesLocalRowsAndIgnoresOrphans() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = LocalStore(container: container)
        let a = Account(id: "A", kind: .demo, displayName: "A")
        let b = Account(id: "B", kind: .demo, displayName: "B", enabled: false)
        store.context.insert(a)
        store.context.insert(b)
        store.context.insert(Support(accountID: "A", creatorID: "c1", creatorName: "C1", planID: "p1", planTitle: "P", amount: 500))
        store.context.insert(Support(accountID: "B", creatorID: "c2", creatorName: "C2", planID: "p2", planTitle: "P", amount: 1_000))
        store.context.insert(Support(accountID: "ghost", creatorID: "c3", creatorName: "C3", planID: "p3", planTitle: "P", amount: 9_999))
        let missing = Support(accountID: "A", creatorID: "c4", creatorName: "C4", planID: "p4", planTitle: "P", amount: 300, status: .missing)
        missing.needsAttention = true
        store.context.insert(missing)
        store.context.insert(PaymentRecord(paymentID: "x", accountID: "A", creatorID: "c1", creatorName: "C1", amount: 500,
                                           paidAt: date(2026, 9, 1, 3)))
        store.save()

        let s = SupportAnalyzer.summary(store: store, now: date(2026, 9, 20), calendar: tokyo)
        XCTAssertEqual(s.recurringMonthly, 500, "disabled and unknown accounts are left out")
        XCTAssertEqual(s.actualThisMonth, 500)
        XCTAssertEqual(s.creatorCount, 1)
        XCTAssertEqual(s.accountCount, 1)
        XCTAssertEqual(s.attentionCount, 1)

        // Re-enabling brings the account's supports back into the totals.
        b.enabled = true
        store.save()
        let enabled = SupportAnalyzer.summary(store: store, now: date(2026, 9, 20), calendar: tokyo)
        XCTAssertEqual(enabled.recurringMonthly, 1_500)
        XCTAssertEqual(enabled.accountCount, 2)
    }
}

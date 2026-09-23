import Foundation
import SwiftData

/// SPEC §10.3 dashboard numbers. Recurring monthly, actual billed this month and next month plan are separate fields,
/// each computed from its own observed input (see `SupportAnalyzer.summarize`).
struct SupportDashboardSummary: Sendable, Equatable {
    /// "yyyy-MM" of the billing month (JST).
    var month: String
    /// 定常月額: sum of active supports (the plans FANBOX currently lists, including ones stopped this month).
    var recurringMonthly: Int
    /// 今月実請求: sum of observed payments of this billing month whose amount FANBOX reported;
    /// nil when no payment data is available at all.
    var actualThisMonth: Int?
    /// Payments of this billing month whose amount FANBOX did not report (not included in `actualThisMonth`).
    var actualUnknownAmountCount: Int = 0
    /// 来月予定: active supports minus the ones with a scheduled stop (`SupportStopRule`).
    var nextMonthPlanned: Int
    /// Active supports excluded from 来月予定, by source.
    var scheduledStopObservedCount: Int = 0
    var scheduledStopUserMarkedCount: Int = 0
    var creatorCount: Int
    var accountCount: Int
    /// Unacknowledged support anomalies + accounts whose payment state could not be confirmed.
    var attentionCount: Int

    var scheduledStopCount: Int { scheduledStopObservedCount + scheduledStopUserMarkedCount }
}

// MARK: - Snapshots

/// Sendable value copy of a `Support` row so aggregation stays pure and testable.
struct SupportSnapshot: Sendable, Hashable, Identifiable {
    var accountID: String
    var creatorID: String
    var creatorName: String
    var creatorIconURL: String?
    var planID: String?
    var planTitle: String
    var amount: Int
    var status: SupportStatus
    var reportedPaymentMethod: String?
    var lastObservedAt: Date
    var missingSince: Date?
    var needsAttention: Bool
    var attentionReason: String?
    var acknowledgedAt: Date?
    /// Observed stop (FANBOX `isStopped`). See `Support.stoppingObservedAt`.
    var stoppingObservedAt: Date?
    /// User-entered stop record. See `Support.userStopMarkedAt`.
    var userStopMarkedAt: Date?

    init(accountID: String, creatorID: String, creatorName: String, creatorIconURL: String? = nil, planID: String? = nil,
         planTitle: String = "", amount: Int, status: SupportStatus = .active, reportedPaymentMethod: String? = nil,
         lastObservedAt: Date = .distantPast, missingSince: Date? = nil, needsAttention: Bool = false,
         attentionReason: String? = nil, acknowledgedAt: Date? = nil, stoppingObservedAt: Date? = nil,
         userStopMarkedAt: Date? = nil) {
        self.accountID = accountID
        self.creatorID = creatorID
        self.creatorName = creatorName
        self.creatorIconURL = creatorIconURL
        self.planID = planID
        self.planTitle = planTitle
        self.amount = amount
        self.status = status
        self.reportedPaymentMethod = reportedPaymentMethod
        self.lastObservedAt = lastObservedAt
        self.missingSince = missingSince
        self.needsAttention = needsAttention
        self.attentionReason = attentionReason
        self.acknowledgedAt = acknowledgedAt
        self.stoppingObservedAt = stoppingObservedAt
        self.userStopMarkedAt = userStopMarkedAt
    }

    init(_ support: Support) {
        self.init(accountID: support.accountID, creatorID: support.creatorID, creatorName: support.creatorName,
                  creatorIconURL: support.creatorIconURL, planID: support.planID, planTitle: support.planTitle,
                  amount: support.amount, status: support.status, reportedPaymentMethod: support.reportedPaymentMethod,
                  lastObservedAt: support.lastObservedAt, missingSince: support.missingSince,
                  needsAttention: support.needsAttention, attentionReason: support.attentionReason,
                  acknowledgedAt: support.acknowledgedAt, stoppingObservedAt: support.stoppingObservedAt,
                  userStopMarkedAt: support.userStopMarkedAt)
    }

    /// Same key format as `Support.key`.
    var id: String { "\(accountID)|\(creatorID)" }
    var isActive: Bool { status == .active }
    /// SPEC §15: listed in "要確認" until the user acknowledges it.
    var isUnacknowledgedAttention: Bool { needsAttention && acknowledgedAt == nil }

    /// Scheduled stop of an ACTIVE support in the billing month of `now` (nil = expected to renew). See `SupportStopRule`.
    func scheduledStop(now: Date = .now, calendar: Calendar = SupportBilling.calendar) -> SupportStopSource? {
        guard isActive else { return nil }
        return SupportStopRule.scheduledStop(stoppingObservedAt: stoppingObservedAt, userStopMarkedAt: userStopMarkedAt,
                                             now: now, calendar: calendar)
    }
}

/// Sendable value copy of a `PaymentRecord` row.
struct PaymentSnapshot: Sendable, Hashable {
    var accountID: String
    var creatorID: String?
    var amount: Int
    var paidAt: Date
    /// false when FANBOX did not report the amount: excluded from sums and counted separately.
    var isAmountKnown: Bool

    init(accountID: String, creatorID: String? = nil, amount: Int, paidAt: Date, isAmountKnown: Bool = true) {
        self.accountID = accountID
        self.creatorID = creatorID
        self.amount = amount
        self.paidAt = paidAt
        self.isAmountKnown = isAmountKnown
    }

    init(_ record: PaymentRecord) {
        self.init(accountID: record.accountID, creatorID: record.creatorID, amount: record.amount, paidAt: record.paidAt,
                  isAmountKnown: record.amountUnknown != true)
    }
}

/// Payment-state flag of one account (SPEC §15 "決済状態を確認できない").
struct AccountPaymentState: Sendable, Hashable {
    var accountID: String
    var enabled: Bool
    /// Observed by sync; nil = never observed.
    var hasUnpaidPayments: Bool?
    var checkedAt: Date?

    init(accountID: String, enabled: Bool = true, hasUnpaidPayments: Bool?, checkedAt: Date? = nil) {
        self.accountID = accountID
        self.enabled = enabled
        self.hasUnpaidPayments = hasUnpaidPayments
        self.checkedAt = checkedAt
    }

    init(_ account: Account) {
        self.init(accountID: account.id, enabled: account.enabled, hasUnpaidPayments: account.hasUnpaidPayments,
                  checkedAt: account.unpaidPaymentsCheckedAt)
    }
}

/// Sendable value copy of a `SupportPaymentAssignment` row.
struct AssignmentSnapshot: Sendable, Hashable {
    var accountID: String
    var creatorID: String
    var planID: String?
    var paymentProfileID: String?
    var verificationState: VerificationState
    var lastVerifiedAt: Date?

    init(accountID: String, creatorID: String, planID: String? = nil, paymentProfileID: String? = nil,
         verificationState: VerificationState = .unknown, lastVerifiedAt: Date? = nil) {
        self.accountID = accountID
        self.creatorID = creatorID
        self.planID = planID
        self.paymentProfileID = paymentProfileID
        self.verificationState = verificationState
        self.lastVerifiedAt = lastVerifiedAt
    }

    init(_ assignment: SupportPaymentAssignment) {
        self.init(accountID: assignment.accountID, creatorID: assignment.creatorID, planID: assignment.planID,
                  paymentProfileID: assignment.paymentProfileID, verificationState: assignment.verificationState,
                  lastVerifiedAt: assignment.lastVerifiedAt)
    }

    var key: String { "\(accountID)|\(creatorID)" }
}

// MARK: - Groupings

/// One support line (account × creator) with the user's payment assignment, if any.
struct SupportLine: Sendable, Hashable, Identifiable {
    var support: SupportSnapshot
    var assignment: AssignmentSnapshot?

    var id: String { support.id }
}

/// SPEC §10.1: one creator, one line per account.
struct CreatorSupportGroup: Sendable, Hashable, Identifiable {
    var creatorID: String
    var creatorName: String
    var creatorIconURL: String?
    var lines: [SupportLine]
    /// 合計月額 of active lines.
    var total: Int

    var id: String { creatorID }
    var activeAccountIDs: [String] { lines.filter { $0.support.isActive }.map(\.support.accountID) }
}

/// SPEC §10.2: one account, one line per creator.
struct AccountSupportGroup: Sendable, Hashable, Identifiable {
    var accountID: String
    var lines: [SupportLine]
    /// 合計 of active lines.
    var total: Int

    var id: String { accountID }
    var activeCreatorCount: Int { Set(lines.filter { $0.support.isActive }.map(\.support.creatorID)).count }
}

// MARK: - Analyzer

/// Pure aggregation + anomaly helpers for supports (SPEC §10 / §15).
/// Everything except `summary(store:)` is a pure function over Sendable snapshots.
enum SupportAnalyzer {
    @MainActor
    static func summary(store: LocalStore, now: Date = .now, calendar: Calendar = SupportBilling.calendar) -> SupportDashboardSummary {
        let accounts = store.accounts(includeDisabled: true)
        let known = Set(accounts.map(\.id))
        let supports = store.fetch(FetchDescriptorFactorySupport.allSupports())
            .filter { known.contains($0.accountID) }
            .map(SupportSnapshot.init)
        let payments = store.fetch(FetchDescriptorFactorySupport.allPayments())
            .filter { known.contains($0.accountID) }
            .map(PaymentSnapshot.init)
        return summarize(supports: supports, payments: payments, now: now, calendar: calendar,
                         paymentStateAttentionAccountIDs: paymentStateAttentionAccountIDs(accounts.map(AccountPaymentState.init)))
    }

    /// SPEC §10.3. The three money values are computed independently, all in billing months (JST, `SupportBilling`):
    /// - recurringMonthly (定常月額): Σ amount of active supports — the plans FANBOX currently lists for each account.
    ///   A support stopped this month is still included (it is charged for, and valid until the end of, this month).
    /// - actualThisMonth (今月実請求): Σ observed payments whose `paidAt` is in the billing month of `now`, amount reported
    ///   by FANBOX only (records without an amount are counted in `actualUnknownAmountCount`, never as ¥0);
    ///   nil when there is no payment data at all (UI shows "データなし"; never estimated).
    /// - nextMonthPlanned (来月予定): Σ active supports WITHOUT a scheduled stop (`SupportStopRule`): FANBOX-observed stops
    ///   (`isSupported && isStopped`) and stops the user recorded in the app, both of the current billing month.
    ///   Ended / missing / unknown supports are in neither 定常月額 nor 来月予定. Plan changes use the plan FANBOX lists
    ///   now: FANBOX exposes no pending plan, so a downgrade that only takes effect next month cannot be predicted.
    static func summarize(supports: [SupportSnapshot], payments: [PaymentSnapshot], now: Date = .now,
                          calendar: Calendar = SupportBilling.calendar,
                          paymentStateAttentionAccountIDs: Set<String> = []) -> SupportDashboardSummary {
        let active = supports.filter(\.isActive)
        let recurring = active.reduce(0) { $0 + $1.amount }
        let thisMonth = paymentsInMonth(payments, containing: now, calendar: calendar)
        let actual: Int? = payments.isEmpty ? nil : thisMonth.filter(\.isAmountKnown).reduce(0) { $0 + $1.amount }
        var next = 0
        var stoppedObserved = 0
        var stoppedUserMarked = 0
        for support in active {
            switch support.scheduledStop(now: now, calendar: calendar) {
            case .none: next += support.amount
            case .observed?: stoppedObserved += 1
            case .userMarked?: stoppedUserMarked += 1
            }
        }
        return SupportDashboardSummary(
            month: monthKey(now, calendar: calendar),
            recurringMonthly: recurring,
            actualThisMonth: actual,
            actualUnknownAmountCount: thisMonth.filter { !$0.isAmountKnown }.count,
            nextMonthPlanned: next,
            scheduledStopObservedCount: stoppedObserved,
            scheduledStopUserMarkedCount: stoppedUserMarked,
            creatorCount: Set(active.map(\.creatorID)).count,
            accountCount: Set(active.map(\.accountID)).count,
            attentionCount: supports.filter(\.isUnacknowledgedAttention).count + paymentStateAttentionAccountIDs.count
        )
    }

    static func monthKey(_ date: Date, calendar: Calendar = SupportBilling.calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// Dashboard heading, e.g. "9月".
    static func monthLabel(_ date: Date, calendar: Calendar = SupportBilling.calendar) -> String {
        "\(calendar.component(.month, from: date))月"
    }

    /// Half-open [start, end) interval of the billing month containing `date`.
    static func monthRange(containing date: Date, calendar: Calendar = SupportBilling.calendar) -> Range<Date>? {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return nil }
        return interval.start..<interval.end
    }

    /// Half-open interval of the billing month before the one containing `date`.
    static func previousMonthRange(before date: Date, calendar: Calendar = SupportBilling.calendar) -> Range<Date>? {
        guard let range = monthRange(containing: date, calendar: calendar),
              let previous = calendar.date(byAdding: .month, value: -1, to: range.lowerBound) else { return nil }
        return monthRange(containing: previous, calendar: calendar)
    }

    /// Payments whose `paidAt` falls in the billing month of `date` (month boundaries are half-open).
    static func paymentsInMonth(_ payments: [PaymentSnapshot], containing date: Date,
                                calendar: Calendar = SupportBilling.calendar) -> [PaymentSnapshot] {
        guard let range = monthRange(containing: date, calendar: calendar) else { return [] }
        return payments.filter { range.contains($0.paidAt) }
    }

    /// Payments of the month before the one containing `date`.
    static func paymentsInPreviousMonth(_ payments: [PaymentSnapshot], before date: Date,
                                        calendar: Calendar = SupportBilling.calendar) -> [PaymentSnapshot] {
        guard let range = previousMonthRange(before: date, calendar: calendar) else { return [] }
        return payments.filter { range.contains($0.paidAt) }
    }

    // MARK: Anomalies (SPEC §15)

    /// Supports shown in "要確認": flagged and not yet acknowledged. Newest observation first.
    static func attentionItems(_ supports: [SupportSnapshot]) -> [SupportSnapshot] {
        supports.filter(\.isUnacknowledgedAttention).sorted { lhs, rhs in
            let l = lhs.missingSince ?? lhs.lastObservedAt
            let r = rhs.missingSince ?? rhs.lastObservedAt
            if l != r { return l > r }
            return lhs.id < rhs.id
        }
    }

    /// Accounts for which FANBOX reported unpaid payments (`Account.hasUnpaidPayments`, filled in by sync).
    /// Shown as "決済状態を確認できません" — an observation, never "決済失敗" (SPEC §15). Disabled accounts are skipped.
    static func paymentStateAttentionAccountIDs(_ accounts: [AccountPaymentState]) -> Set<String> {
        Set(accounts.filter { $0.enabled && $0.hasUnpaidPayments == true }.map(\.accountID))
    }

    // MARK: Groupings

    /// SPEC §10.1 rows per creator. Only active supports unless `includeInactive`.
    /// Sorted by total (desc), then creator name. Lines follow `accountOrder` (unknown accounts last).
    static func byCreator(supports: [SupportSnapshot], assignments: [AssignmentSnapshot] = [], accountOrder: [String] = [],
                          includeInactive: Bool = false) -> [CreatorSupportGroup] {
        let assignmentByKey = Dictionary(assignments.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let order = orderIndex(accountOrder)
        let relevant = includeInactive ? supports : supports.filter(\.isActive)
        let grouped = Dictionary(grouping: relevant, by: \.creatorID)
        return grouped.map { creatorID, items in
            let lines = items
                .sorted { lhs, rhs in
                    let l = order[lhs.accountID] ?? Int.max, r = order[rhs.accountID] ?? Int.max
                    return l != r ? l < r : lhs.accountID < rhs.accountID
                }
                .map { SupportLine(support: $0, assignment: assignmentByKey[$0.id]) }
            let named = items.first(where: \.isActive) ?? items[0]
            return CreatorSupportGroup(creatorID: creatorID, creatorName: named.creatorName, creatorIconURL: named.creatorIconURL,
                                       lines: lines, total: items.filter(\.isActive).reduce(0) { $0 + $1.amount })
        }
        .sorted { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            if lhs.creatorName != rhs.creatorName { return lhs.creatorName < rhs.creatorName }
            return lhs.creatorID < rhs.creatorID
        }
    }

    /// SPEC §10.2 rows per account, ordered by `accountOrder` (unknown accounts last).
    /// Lines are sorted by amount (desc), then creator name.
    static func byAccount(supports: [SupportSnapshot], assignments: [AssignmentSnapshot] = [], accountOrder: [String] = [],
                          includeInactive: Bool = false) -> [AccountSupportGroup] {
        let assignmentByKey = Dictionary(assignments.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let order = orderIndex(accountOrder)
        let relevant = includeInactive ? supports : supports.filter(\.isActive)
        let grouped = Dictionary(grouping: relevant, by: \.accountID)
        return grouped.map { accountID, items in
            let lines = items
                .sorted { lhs, rhs in
                    if lhs.isActive != rhs.isActive { return lhs.isActive }
                    if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
                    if lhs.creatorName != rhs.creatorName { return lhs.creatorName < rhs.creatorName }
                    return lhs.creatorID < rhs.creatorID
                }
                .map { SupportLine(support: $0, assignment: assignmentByKey[$0.id]) }
            return AccountSupportGroup(accountID: accountID, lines: lines, total: items.filter(\.isActive).reduce(0) { $0 + $1.amount })
        }
        .sorted { lhs, rhs in
            let l = order[lhs.accountID] ?? Int.max, r = order[rhs.accountID] ?? Int.max
            return l != r ? l < r : lhs.accountID < rhs.accountID
        }
    }

    // MARK: Payment profile inference (display only)

    /// Guesses which profile pays a support from the payment *kind* FANBOX reports (e.g. "paypal" / "card"),
    /// only when exactly one profile of that kind exists. The result MUST be shown as "推定（未確認）" (SPEC §13),
    /// never as a fact, and is never written as `.verified`.
    static func inferredProfileID(reportedPaymentMethod: String?, profiles: [(id: String, type: PaymentProfileType)]) -> String? {
        guard let raw = reportedPaymentMethod?.lowercased(), !raw.isEmpty else { return nil }
        let types: Set<PaymentProfileType>
        if raw.contains("paypal") {
            types = [.paypal]
        } else if raw.contains("card") || raw.contains("credit") || raw.contains("カード") {
            types = [.creditCard, .debitCard]
        } else if raw.contains("carrier") || raw.contains("docomo") || raw.contains("softbank") || raw == "au" {
            types = [.carrierBilling]
        } else {
            return nil
        }
        let candidates = profiles.filter { types.contains($0.type) }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    private static func orderIndex(_ order: [String]) -> [String: Int] {
        var index: [String: Int] = [:]
        for (i, id) in order.enumerated() where index[id] == nil { index[id] = i }
        return index
    }
}

/// Fetch descriptors used by the Support feature.
enum FetchDescriptorFactorySupport {
    static func allSupports() -> FetchDescriptor<Support> {
        FetchDescriptor<Support>(sortBy: [SortDescriptor(\.creatorName), SortDescriptor(\.accountID)])
    }

    static func allPayments() -> FetchDescriptor<PaymentRecord> {
        FetchDescriptor<PaymentRecord>(sortBy: [SortDescriptor(\.paidAt, order: .reverse)])
    }
}

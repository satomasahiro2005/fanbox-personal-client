import Foundation

/// SPEC §10.3 dashboard numbers. Recurring monthly, actual billed this month and next month plan are separate fields.
struct SupportDashboardSummary: Sendable, Equatable {
    /// "yyyy-MM"
    var month: String
    /// 定常月額: sum of active supports.
    var recurringMonthly: Int
    /// 今月実請求: sum of observed payments this month; nil when no payment data is available.
    var actualThisMonth: Int?
    /// 来月予定: sum of supports expected to continue next month.
    var nextMonthPlanned: Int
    var creatorCount: Int
    var accountCount: Int
    var attentionCount: Int
}

/// Pure aggregation + anomaly helpers for supports (SPEC §10 / §15). Implemented in the Support feature work.
enum SupportAnalyzer {
    @MainActor
    static func summary(store: LocalStore, now: Date = .now, calendar: Calendar = .current) -> SupportDashboardSummary {
        SupportDashboardSummary(month: monthKey(now, calendar: calendar), recurringMonthly: 0, actualThisMonth: nil, nextMonthPlanned: 0,
                                creatorCount: 0, accountCount: 0, attentionCount: 0)
    }

    static func monthKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}

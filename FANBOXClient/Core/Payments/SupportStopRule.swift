import Foundation

/// Where a "停止予定" (support that will not renew next month) comes from. The two are never merged in the UI.
enum SupportStopSource: String, Sendable, Hashable {
    /// OBSERVED: FANBOX reported `isSupported && isStopped` for the account (docs/API.md §7.2 / §18.10).
    case observed
    /// USER-ENTERED: the user recorded the stop in this app; not verified against FANBOX.
    case userMarked
}

/// Billing-month rules of the Support dashboard (SPEC §10.3).
///
/// FANBOX bills in Japan time: automatic charges run on the 1st–5th (JST), a stopped support is still charged for the
/// whole month and stays valid until the month ends, and a downgrade takes effect next month (Help Center, docs/API.md
/// §18.10). All month arithmetic of the Support feature therefore uses `SupportBilling.calendar`, never the device
/// calendar, so a device outside Japan still puts a charge made at 00:30 JST on the 1st into the right month.
enum SupportBilling {
    /// Gregorian calendar in Asia/Tokyo.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? TimeZone(secondsFromGMT: 9 * 3600)!
        c.locale = Locale(identifier: "ja_JP")
        return c
    }()

    static func isSameMonth(_ a: Date, _ b: Date, calendar: Calendar = SupportBilling.calendar) -> Bool {
        calendar.isDate(a, equalTo: b, toGranularity: .month)
    }
}

/// When a support counts as "停止予定" for 来月予定, and when a stop explains a support vanishing from FANBOX.
///
/// Rule (also shown as the dashboard footnote):
/// - A stop signal applies to the billing month (JST) it was observed / recorded in. During that month the support is
///   still part of 定常月額 (it is paid and valid until the month ends) but is excluded from 来月予定.
/// - FANBOX-observed stops win over user-entered ones for labeling; both exclude the amount the same way.
/// - A signal from an earlier month is ignored: a support FANBOX still lists as active in a later month is treated
///   as continuing (the user resumed it, or the record was wrong).
/// - When an active support disappears from FANBOX's supporting list, a stop signal of the same or the previous
///   billing month explains it: the support is recorded as 支援終了 instead of an unexplained "要確認" anomaly.
enum SupportStopRule {
    static func scheduledStop(stoppingObservedAt: Date?, userStopMarkedAt: Date?, now: Date,
                              calendar: Calendar = SupportBilling.calendar) -> SupportStopSource? {
        if let observed = stoppingObservedAt, SupportBilling.isSameMonth(observed, now, calendar: calendar) { return .observed }
        if let marked = userStopMarkedAt, SupportBilling.isSameMonth(marked, now, calendar: calendar) { return .userMarked }
        return nil
    }

    /// True when `signal` (a stop observation / record) was made in the billing month of `now` or the one before.
    static func explainsDisappearance(_ signal: Date?, now: Date, calendar: Calendar = SupportBilling.calendar) -> Bool {
        guard let signal, signal <= now.addingTimeInterval(60) else { return false }
        if SupportBilling.isSameMonth(signal, now, calendar: calendar) { return true }
        guard let previous = calendar.date(byAdding: .month, value: -1, to: now) else { return false }
        return SupportBilling.isSameMonth(signal, previous, calendar: calendar)
    }

    static func label(_ source: SupportStopSource) -> String {
        switch source {
        case .observed: return "停止予定（FANBOX で観測）"
        case .userMarked: return "停止予定（自分で記録）"
        }
    }

    static func shortLabel(_ source: SupportStopSource) -> String {
        switch source {
        case .observed: return "停止予定"
        case .userMarked: return "停止予定（自分で記録）"
        }
    }
}

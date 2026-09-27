import Foundation

/// User-facing strings for the Support feature (SPEC §10–§15).
/// Anomaly texts state OBSERVED FACTS only — never that a payment failed (SPEC §15).
enum SupportText {
    // MARK: Verification (SPEC §13)

    /// verified "確認済み" / inferred "推定（未確認）" / manual "手動設定" / unknown "不明".
    static func verificationLabel(_ state: VerificationState) -> String {
        switch state {
        case .verified: return "確認済み"
        case .inferred: return "推定（未確認）"
        case .manual: return "手動設定"
        case .unknown: return "不明"
        }
    }

    static func verificationSymbol(_ state: VerificationState) -> String {
        switch state {
        case .verified: return "checkmark.seal.fill"
        case .inferred: return "questionmark.circle"
        case .manual: return "hand.raised"
        case .unknown: return "questionmark"
        }
    }

    /// Only `.verified` may be presented as a fact.
    static func isFact(_ state: VerificationState) -> Bool { state == .verified }

    // MARK: Support status

    static func statusLabel(_ status: SupportStatus) -> String {
        switch status {
        case .active: return "支援中"
        case .ended: return "支援終了"
        case .missing: return "支援中一覧にありません"
        case .unknown: return "状態不明"
        }
    }

    /// "¥1,000 / 月"
    static func monthly(_ amount: Int) -> String { "\(Formatters.yen(amount)) / 月" }

    /// "以前:" value of the recovery card.
    static func previousText(amount: Int) -> String { monthly(amount) }

    /// "現在:" value of the recovery card, derived from the observed status only.
    static func currentText(status: SupportStatus, amount: Int) -> String {
        switch status {
        case .active: return monthly(amount)
        case .ended, .missing: return "支援なし"
        case .unknown: return "確認できません"
        }
    }

    /// Observed-fact sentence for the "要確認" card (SPEC §15).
    /// `attentionReason` written by sync is shown only when it does not assert a cause such as a payment failure.
    static func observedFact(status: SupportStatus, attentionReason: String?) -> String {
        if let reason = attentionReason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty, !assertsCause(reason) {
            return reason
        }
        switch status {
        case .missing, .ended: return "支援中一覧から消えました"
        case .unknown: return "決済状態を確認できません"
        case .active: return "支援状態を確認してください"
        }
    }

    /// True when a text claims a cause (payment failure / card declined …) instead of an observation.
    static func assertsCause(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = ["失敗", "エラーにより", "拒否", "否認", "declined", "failed", "failure", "カードが使え", "残高不足", "期限切れ"]
        return markers.contains { lowered.contains($0) }
    }

    /// Account-level observation when FANBOX reports unpaid payments (`Account.hasUnpaidPayments`). SPEC §15:
    /// an observed fact only — never "決済失敗".
    static let paymentStateUnknown = "決済状態を確認できません"
    static let paymentStateUnknownDetail = "FANBOXのアカウント情報に未払いのお支払いがある旨の表示があります"

    // MARK: Dashboard (SPEC §10.3)

    /// Data under 今月実請求: missing history, or payments left out of the sum. nil when there is nothing to add.
    static func actualCaption(_ summary: SupportDashboardSummary) -> String? {
        guard summary.actualThisMonth != nil else { return "お支払い履歴が未取得です" }
        if summary.actualUnknownAmountCount > 0 {
            return "金額不明\(summary.actualUnknownAmountCount)件を除く"
        }
        return nil
    }

    /// Data under 来月予定: the stops it leaves out. nil without stops.
    static func nextMonthCaption(_ summary: SupportDashboardSummary) -> String? {
        guard summary.scheduledStopCount > 0 else { return nil }
        var parts: [String] = []
        if summary.scheduledStopObservedCount > 0 { parts.append("FANBOXで観測\(summary.scheduledStopObservedCount)") }
        if summary.scheduledStopUserMarkedCount > 0 { parts.append("自分で記録\(summary.scheduledStopUserMarkedCount)") }
        return "停止予定\(summary.scheduledStopCount)件を除く（\(parts.joined(separator: " / "))）"
    }

    // MARK: History (SPEC §11)

    /// "¥500 → ¥1,000" / "支援開始¥3,000" / "支援終了" / "支援中一覧から消えました" / "再び確認されました".
    static func historyText(kind: SupportHistoryKind, oldAmount: Int?, newAmount: Int?, oldPlan: String? = nil, newPlan: String? = nil) -> String {
        switch kind {
        case .started:
            if let newAmount { return "支援開始\(Formatters.yen(newAmount))" }
            return "支援開始"
        case .planChanged:
            if let oldAmount, let newAmount { return "\(Formatters.yen(oldAmount)) → \(Formatters.yen(newAmount))" }
            let from = oldPlan?.isEmpty == false ? oldPlan! : "不明"
            let to = newPlan?.isEmpty == false ? newPlan! : "不明"
            return "プラン変更（\(from) → \(to)）"
        case .ended: return "支援終了"
        case .disappeared: return "支援中一覧から消えました"
        case .restored: return "再び確認されました"
        }
    }

    static func historyText(_ h: SupportHistory) -> String {
        historyText(kind: h.kind, oldAmount: h.oldAmount, newAmount: h.newAmount, oldPlan: h.oldPlan, newPlan: h.newPlan)
    }

    static func historySymbol(_ kind: SupportHistoryKind) -> String {
        switch kind {
        case .started: return "plus.circle"
        case .planChanged: return "arrow.left.arrow.right.circle"
        case .ended: return "minus.circle"
        case .disappeared: return "exclamationmark.triangle"
        case .restored: return "arrow.uturn.backward.circle"
        }
    }

    static func observedSourceLabel(_ source: ObservedSource) -> String {
        switch source {
        case .sync: return "同期で観測"
        case .backgroundSync: return "バックグラウンド同期で観測"
        case .notification: return "通知で観測"
        case .webBridge: return "Web操作後に観測"
        case .manual: return "手動記録"
        case .demo: return "デモ"
        }
    }

    // MARK: Payment profiles (SPEC §12)

    static func profileTypeLabel(_ type: PaymentProfileType) -> String {
        switch type {
        case .creditCard: return "クレジットカード"
        case .debitCard: return "デビットカード"
        case .paypal: return "PayPal"
        case .carrierBilling: return "キャリア決済"
        case .other: return "その他"
        }
    }

    static func isCardType(_ type: PaymentProfileType) -> Bool { type == .creditCard || type == .debitCard }

    // MARK: Payment line (支払い方法・前回・次回)

    /// FANBOX's payment type (docs/API.md §18.9) in Japanese: カード / PayPal / コンビニ, その他 for a type the app does not
    /// know, nil when FANBOX reported none. The raw API string is never shown.
    static func paymentMethodLabel(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch FanboxAdapter.paymentMethodFamily(raw) {
        case "card": return "カード"
        case "paypal": return "PayPal"
        case "cvs": return "コンビニ"
        default: return "その他"
        }
    }

    /// "楽天Visa•••1234": the nickname and the last four digits; the brand stands in for an empty nickname.
    static func profileShortLabel(nickname: String, brand: String?, last4: String?) -> String {
        let name = nickname.isEmpty ? (brand ?? "") : nickname
        guard let last4, !last4.isEmpty else { return name.isEmpty ? "支払い方法" : name }
        return "\(name)•••\(last4)"
    }

    /// "9/2" in JST; "2025/12/2" when the year is not the year of `now`.
    static func billingDate(_ date: Date, now: Date = .now, calendar: Calendar = SupportBilling.calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let md = "\(c.month ?? 0)/\(c.day ?? 0)"
        return c.year == calendar.component(.year, from: now) ? md : "\(c.year ?? 0)/\(md)"
    }

    /// "2026/10/1" in JST: the date of a payment row, in the same calendar as its month section and 前回.
    static func paymentDate(_ date: Date, calendar: Calendar = SupportBilling.calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)/\(c.month ?? 0)/\(c.day ?? 0)"
    }

    /// "前回9/2 ¥500", or "前回9/2" when FANBOX did not report the amount.
    static func lastPaymentText(_ payment: LastPayment, showsAmount: Bool = true, now: Date = .now,
                                calendar: Calendar = SupportBilling.calendar) -> String {
        let date = "前回\(billingDate(payment.paidAt, now: now, calendar: calendar))"
        guard showsAmount, let amount = payment.amount else { return date }
        return "\(date) \(Formatters.yen(amount))"
    }

    /// "次回10/1〜5予定" ("次回10/1〜5" without the suffix) / "次回なし" / "次回なし（自分で記録）".
    static func nextChargeText(_ next: NextCharge, showsPlannedSuffix: Bool = true, calendar: Calendar = SupportBilling.calendar) -> String {
        switch next {
        case .planned(let window):
            let start = calendar.dateComponents([.month, .day], from: window.start)
            let lastDay = calendar.component(.day, from: window.end.addingTimeInterval(-1))
            return "次回\(start.month ?? 0)/\(start.day ?? 0)〜\(lastDay)\(showsPlannedSuffix ? "予定" : "")"
        case .stopped(.observed): return "次回なし"
        case .stopped(.userMarked): return "次回なし（自分で記録）"
        }
    }

    /// Brand picker choices.
    static let brands = ["Visa", "Mastercard", "JCB", "American Express", "Diners", "その他"]
}

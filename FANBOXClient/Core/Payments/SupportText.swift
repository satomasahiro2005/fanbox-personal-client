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

    // MARK: History (SPEC §11)

    /// "¥500 → ¥1,000" / "支援開始 ¥3,000" / "支援終了" / "支援中一覧から消えました" / "再び確認されました".
    static func historyText(kind: SupportHistoryKind, oldAmount: Int?, newAmount: Int?, oldPlan: String? = nil, newPlan: String? = nil) -> String {
        switch kind {
        case .started:
            if let newAmount { return "支援開始 \(Formatters.yen(newAmount))" }
            return "支援開始"
        case .planChanged:
            if let oldAmount, let newAmount { return "\(Formatters.yen(oldAmount)) → \(Formatters.yen(newAmount))" }
            let from = oldPlan?.isEmpty == false ? oldPlan! : "不明"
            let to = newPlan?.isEmpty == false ? newPlan! : "不明"
            return "プラン変更 \(from) → \(to)"
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
        case .webBridge: return "Web 操作後に観測"
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

    /// Brand picker choices.
    static let brands = ["Visa", "Mastercard", "JCB", "American Express", "Diners", "その他"]

    static let storagePolicyNote = "カード番号・セキュリティコード・有効期限・暗証番号は保存しません"
    static let paymentChoiceNote = "実際の支払い方法の選択は FANBOX / pixiv の画面で行います"
}

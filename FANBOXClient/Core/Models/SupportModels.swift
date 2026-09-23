import Foundation
import SwiftData

/// Current support relationship of one local account to one creator (SPEC §10).
@Model
final class Support {
    /// "\(accountID)|\(creatorID)"
    @Attribute(.unique) var key: String
    var accountID: String
    var creatorID: String
    var creatorName: String
    var creatorIconURL: String?
    var planID: String?
    var planTitle: String
    /// Monthly fee of the plan (JPY).
    var amount: Int
    var statusRaw: String
    /// Payment method kind as reported by FANBOX (e.g. card / paypal), if any. Observed value only.
    var reportedPaymentMethod: String?
    var firstObservedAt: Date
    var lastObservedAt: Date
    /// When the support stopped appearing in FANBOX responses (status == .missing).
    var missingSince: Date?
    /// Support Dashboard "要確認".
    var needsAttention: Bool
    /// Observed fact only, e.g. "支援が一覧から消えました". Never an asserted cause.
    var attentionReason: String?
    var acknowledgedAt: Date?
    /// OBSERVED: last time FANBOX (`creator.listFollowing`) reported `isSupported && isStopped` for this account — the
    /// support was stopped and stays valid until the end of the billing month (docs/API.md §7.2 / §18.10).
    /// See `SupportStopRule` for how it affects 来月予定. nil = never observed.
    var stoppingObservedAt: Date?
    /// USER-ENTERED (not observed): the user recorded in this app that this support will not renew ("停止予定").
    /// Never verified against FANBOX; always labeled "自分で記録" in the UI. nil = not recorded.
    var userStopMarkedAt: Date?

    init(accountID: String, creatorID: String, creatorName: String, planID: String?, planTitle: String, amount: Int,
         status: SupportStatus = .active, observedAt: Date = .now) {
        self.key = Support.key(accountID: accountID, creatorID: creatorID)
        self.accountID = accountID
        self.creatorID = creatorID
        self.creatorName = creatorName
        self.planID = planID
        self.planTitle = planTitle
        self.amount = amount
        self.statusRaw = status.rawValue
        self.firstObservedAt = observedAt
        self.lastObservedAt = observedAt
        self.needsAttention = false
    }

    static func key(accountID: String, creatorID: String) -> String { "\(accountID)|\(creatorID)" }

    var status: SupportStatus {
        get { SupportStatus(rawValue: statusRaw) ?? .unknown }
        set { statusRaw = newValue.rawValue }
    }

    var isActive: Bool { status == .active }
}

/// Locally observed support change (SPEC §11).
@Model
final class SupportHistory {
    @Attribute(.unique) var id: String
    var timestamp: Date
    var creatorID: String
    var creatorName: String
    var accountID: String
    var kindRaw: String
    var oldPlanID: String?
    var newPlanID: String?
    var oldPlan: String?
    var newPlan: String?
    var oldAmount: Int?
    var newAmount: Int?
    var observedSourceRaw: String

    init(id: String = UUID().uuidString, timestamp: Date = .now, creatorID: String, creatorName: String, accountID: String,
         kind: SupportHistoryKind, oldPlanID: String? = nil, newPlanID: String? = nil, oldPlan: String? = nil, newPlan: String? = nil,
         oldAmount: Int? = nil, newAmount: Int? = nil, observedSource: ObservedSource) {
        self.id = id
        self.timestamp = timestamp
        self.creatorID = creatorID
        self.creatorName = creatorName
        self.accountID = accountID
        self.kindRaw = kind.rawValue
        self.oldPlanID = oldPlanID
        self.newPlanID = newPlanID
        self.oldPlan = oldPlan
        self.newPlan = newPlan
        self.oldAmount = oldAmount
        self.newAmount = newAmount
        self.observedSourceRaw = observedSource.rawValue
    }

    var kind: SupportHistoryKind {
        get { SupportHistoryKind(rawValue: kindRaw) ?? .planChanged }
        set { kindRaw = newValue.rawValue }
    }

    var observedSource: ObservedSource {
        get { ObservedSource(rawValue: observedSourceRaw) ?? .sync }
        set { observedSourceRaw = newValue.rawValue }
    }
}

/// A payment actually made (from FANBOX paid-payment history). Used for "今月実請求".
@Model
final class PaymentRecord {
    /// "\(accountID)|\(paymentID)"
    @Attribute(.unique) var key: String
    var paymentID: String
    var accountID: String
    var creatorID: String?
    var creatorName: String?
    var amount: Int
    var paidAt: Date
    var reportedPaymentMethod: String?
    var fetchedAt: Date
    /// true when FANBOX did not report the paid amount (`amount` is then 0 and MUST NOT be summed as ¥0).
    /// nil / false = the amount was reported.
    var amountUnknown: Bool?

    init(paymentID: String, accountID: String, creatorID: String?, creatorName: String?, amount: Int, paidAt: Date,
         reportedPaymentMethod: String? = nil, fetchedAt: Date = .now) {
        self.key = "\(accountID)|\(paymentID)"
        self.paymentID = paymentID
        self.accountID = accountID
        self.creatorID = creatorID
        self.creatorName = creatorName
        self.amount = amount
        self.paidAt = paidAt
        self.reportedPaymentMethod = reportedPaymentMethod
        self.fetchedAt = fetchedAt
    }
}

/// Logical payment method the user recognizes (SPEC §12).
/// MUST NOT hold PAN / CVC / PIN / 3DS credentials / card password / expiry. See `PaymentProfileValidator`.
@Model
final class PaymentProfile {
    @Attribute(.unique) var id: String
    var nickname: String
    var typeRaw: String
    var brand: String?
    /// Exactly 4 digits or nil.
    var last4: String?
    var memo: String
    var sortOrder: Int
    var createdAt: Date

    init(id: String = UUID().uuidString, nickname: String, type: PaymentProfileType, brand: String? = nil, last4: String? = nil,
         memo: String = "", sortOrder: Int = 0, createdAt: Date = .now) {
        self.id = id
        self.nickname = nickname
        self.typeRaw = type.rawValue
        self.brand = brand
        self.last4 = last4
        self.memo = memo
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    var type: PaymentProfileType {
        get { PaymentProfileType(rawValue: typeRaw) ?? .other }
        set { typeRaw = newValue.rawValue }
    }

    /// e.g. "Visa •••• 1234" / "PayPal"
    var displayDetail: String {
        var parts: [String] = []
        if let brand, !brand.isEmpty { parts.append(brand) }
        if let last4, !last4.isEmpty { parts.append("•••• \(last4)") }
        if parts.isEmpty {
            switch type {
            case .paypal: return "PayPal"
            case .carrierBilling: return "キャリア決済"
            case .creditCard: return "クレジットカード"
            case .debitCard: return "デビットカード"
            case .other: return "その他"
            }
        }
        return parts.joined(separator: " ")
    }
}

/// Which payment profile the user believes pays a given support (SPEC §13).
@Model
final class SupportPaymentAssignment {
    /// "\(accountID)|\(creatorID)"
    @Attribute(.unique) var key: String
    var accountID: String
    var creatorID: String
    var planID: String?
    var paymentProfileID: String?
    var verificationStateRaw: String
    var lastVerifiedAt: Date?
    var updatedAt: Date

    init(accountID: String, creatorID: String, planID: String?, paymentProfileID: String?, verificationState: VerificationState,
         lastVerifiedAt: Date? = nil, updatedAt: Date = .now) {
        self.key = Support.key(accountID: accountID, creatorID: creatorID)
        self.accountID = accountID
        self.creatorID = creatorID
        self.planID = planID
        self.paymentProfileID = paymentProfileID
        self.verificationStateRaw = verificationState.rawValue
        self.lastVerifiedAt = lastVerifiedAt
        self.updatedAt = updatedAt
    }

    var verificationState: VerificationState {
        get { VerificationState(rawValue: verificationStateRaw) ?? .unknown }
        set { verificationStateRaw = newValue.rawValue }
    }
}

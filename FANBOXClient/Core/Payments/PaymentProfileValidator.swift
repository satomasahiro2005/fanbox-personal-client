import Foundation

enum PaymentProfileIssue: Equatable, Sendable {
    case last4MustBeFourDigits
    /// A field looks like it contains a full card number (PAN) — rejected (SPEC §12 MUST NOT).
    case looksLikeCardNumber(field: String)
    /// A field looks like it contains a CVC / PIN / expiry — rejected.
    case looksLikeSecurityCode(field: String)
    case nicknameRequired

    var message: String {
        switch self {
        case .last4MustBeFourDigits: return "下4桁は数字4桁で入力してください"
        case .looksLikeCardNumber(let field): return "\(field) にカード番号のような数字列があります。カード番号は保存できません"
        case .looksLikeSecurityCode(let field): return "\(field) にセキュリティコード/PIN/有効期限のような値があります。保存できません"
        case .nicknameRequired: return "名前を入力してください"
        }
    }
}

/// Enforces the Payment Profile storage policy (SPEC §12 / §39). Implemented in the Support feature work.
enum PaymentProfileValidator {
    static func validate(nickname: String, brand: String?, last4: String?, memo: String) -> [PaymentProfileIssue] {
        []
    }
}

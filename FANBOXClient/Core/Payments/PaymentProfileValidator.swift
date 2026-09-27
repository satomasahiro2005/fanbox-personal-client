import Foundation

enum PaymentProfileIssue: Equatable, Sendable {
    case last4MustBeFourDigits
    /// A field looks like it contains a full card number (PAN) — rejected (SPEC §12 MUST NOT).
    case looksLikeCardNumber(field: String)
    /// A field looks like it contains a CVC / PIN / expiry — rejected.
    case looksLikeSecurityCode(field: String)
    /// A field looks like it contains a card / account password, a 3-D Secure credential or a one-time code — rejected.
    case looksLikeCredential(field: String)
    case nicknameRequired

    var message: String {
        switch self {
        case .last4MustBeFourDigits: return "下4桁は数字4桁で入力してください"
        case .looksLikeCardNumber(let field): return "\(field)にカード番号のような数字列があります。カード番号は保存できません"
        case .looksLikeSecurityCode(let field): return "\(field)にセキュリティコード/PIN/有効期限のような値があります。保存できません"
        case .looksLikeCredential(let field):
            return "\(field)にパスワード/3Dセキュア/ワンタイムパスワードのような値があります。保存できません"
        case .nicknameRequired: return "名前を入力してください"
        }
    }
}

/// Enforces the Payment Profile storage policy (SPEC §12 / §39):
/// PAN, CVC, PIN, 3D Secure credentials, card passwords and (in principle) expiry dates are never stored.
/// The app never asks for any of them; these checks keep them out of the free-text fields (nickname / brand / memo).
/// Detection is deliberately conservative — a false positive only blocks saving; a false negative would persist a secret.
enum PaymentProfileValidator {
    /// Field names used in `PaymentProfileIssue` (shown to the user).
    enum Field {
        static let nickname = "名前"
        static let brand = "ブランド"
        static let last4 = "下4桁"
        static let memo = "メモ"
    }

    /// Minimum run of digits (spaces / hyphens ignored) treated as a possible card number.
    static let cardNumberMinDigits = 12

    static func validate(nickname: String, brand: String?, last4: String?, memo: String) -> [PaymentProfileIssue] {
        var issues: [PaymentProfileIssue] = []

        if nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.nicknameRequired)
        }

        if let last4 {
            let trimmed = last4.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !isFourASCIIDigits(trimmed) {
                issues.append(.last4MustBeFourDigits)
            }
        }

        let textFields: [(String, String?)] = [(Field.nickname, nickname), (Field.brand, brand), (Field.last4, last4), (Field.memo, memo)]
        for (name, value) in textFields {
            guard let value, !value.isEmpty else { continue }
            if containsCardNumber(value) {
                issues.append(.looksLikeCardNumber(field: name))
            }
        }
        // Security-code / credential checks do not apply to last4 (4 digits are allowed there by design).
        for (name, value) in textFields where name != Field.last4 {
            guard let value, !value.isEmpty else { continue }
            if containsSecurityCode(value) {
                issues.append(.looksLikeSecurityCode(field: name))
            } else if containsCredential(value) {
                issues.append(.looksLikeCredential(field: name))
            }
        }
        return issues
    }

    static func isValid(nickname: String, brand: String?, last4: String?, memo: String) -> Bool {
        validate(nickname: nickname, brand: brand, last4: last4, memo: memo).isEmpty
    }

    // MARK: - Detectors

    /// `^[0-9]{4}$` (ASCII digits only).
    static func isFourASCIIDigits(_ s: String) -> Bool {
        s.count == 4 && s.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    /// True when the text contains a run of `cardNumberMinDigits`+ digits once spaces and hyphens are ignored
    /// (full-width digits / separators are normalized first).
    static func containsCardNumber(_ text: String) -> Bool {
        var run = 0
        for scalar in normalize(text).unicodeScalars {
            if scalar.value >= 48 && scalar.value <= 57 {
                run += 1
                if run >= cardNumberMinDigits { return true }
            } else if isIgnorableSeparator(scalar) {
                continue
            } else {
                run = 0
            }
        }
        return false
    }

    /// True when the text mentions a security code / PIN / expiry together with digits,
    /// or contains an MM/YY-like expiry pattern.
    static func containsSecurityCode(_ text: String) -> Bool {
        let s = normalize(text)
        let hasDigit = s.unicodeScalars.contains { $0.value >= 48 && $0.value <= 57 }
        if hasDigit && matches(s, keywordPattern) { return true }
        return matches(s, expiryPattern)
    }

    /// True when the text looks like it carries a password, 3-D Secure credential or one-time code (SPEC §12 MUST NOT):
    /// - a credential keyword with digits anywhere outside the keyword ("3Dセキュア 1234abcd", "OTP 482913"),
    /// - a keyword used as a label: "パスワード: abcd", "password=hunter", "パスワード＝…",
    /// - "パスワードは abcdef" / "password is abcdef" (4+ ASCII characters after は / is).
    /// Mentions without a value ("3Dセキュア対応", "パスワードは手帳で管理") are allowed.
    static func containsCredential(_ text: String) -> Bool {
        let s = normalize(text)
        guard let regex = credentialRegex else { return false }
        let ns = s as NSString
        let found = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !found.isEmpty else { return false }
        var outside = s
        for match in found.reversed() {
            if let range = Range(match.range, in: outside) { outside.replaceSubrange(range, with: " ") }
        }
        if outside.unicodeScalars.contains(where: { $0.value >= 48 && $0.value <= 57 }) { return true }
        for match in found {
            let rest = ns.substring(from: match.range.location + match.range.length)
            if matches(rest, credentialValuePattern) { return true }
        }
        return false
    }

    // MARK: - Internals

    /// Password / 3-D Secure / one-time-code keywords (after `normalize`, so full-width "３Ｄ" is "3D").
    private static let credentialKeywordPattern =
        "(?i)(?<![a-z])(pass\\s*words?|passwd|pwd|pass\\s*codes?|3\\s*-?\\s*d\\s*-?\\s*secure|3ds(ecure)?|otp|"
        + "one\\s*-?\\s*time\\s*(pass\\s*(word|code)|code))(?![a-z])"
        + "|パスワード|ﾊﾟｽﾜｰﾄﾞ|パスコード|ﾊﾟｽｺｰﾄﾞ|3\\s*-?\\s*d\\s*セキュア|3\\s*-?\\s*d\\s*ｾｷｭｱ|本人認証|セキュアコード|ｾｷｭｱｺｰﾄﾞ"
        + "|ワンタイム|ﾜﾝﾀｲﾑ|認証コード|確認コード|暗証番号"

    /// What follows a credential keyword when a value is being written down.
    private static let credentialValuePattern = "^\\s*([:：=＝]\\s*\\S|(は|is\\s)\\s*[\\x21-\\x7E]{4,})"

    private static let credentialRegex = try? NSRegularExpression(pattern: credentialKeywordPattern)

    /// ASCII keywords must not be part of a longer word ("shopping" is not "PIN"); digits may touch them ("CVC123").
    private static let keywordPattern =
        "(?i)(?<![a-z])(cvc2?|cvv2?|cid|pin|security\\s*code|exp|expiry|expiration|valid\\s*thru)(?![a-z])"
        + "|セキュリティ[ー・ ]?コード|ｾｷｭﾘﾃｨ[ｰ]?ｺｰﾄﾞ|暗証番号|暗証|有効期限|ピン番号"

    /// MM/YY, MM/YYYY, MM-YY … not part of a longer date such as 2026/12/28 or 12/28/2026.
    private static let expiryPattern = "(?<![0-9/\\-])(0[1-9]|1[0-2])\\s*[/\\-]\\s*([0-9]{2}|20[0-9]{2})(?![0-9]|\\s*[/\\-]\\s*[0-9])"

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    /// Full-width ASCII (U+FF01–U+FF5E: digits, latin letters, "／", "－" …) and the ideographic space → ASCII,
    /// so the detectors see "４１１１" as "4111". Katakana / kanji are left untouched (keywords stay matchable).
    static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFF01...0xFF5E:
                scalars.append(Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar)
            case 0x3000:
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static func isIgnorableSeparator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case " ", "\u{3000}", "\t", "\u{00A0}", "-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}", "\u{FF0D}":
            return true
        default:
            return false
        }
    }
}

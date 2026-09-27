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

    /// True when the text contains a run of `cardNumberMinDigits`+ digits once spaces and dashes are ignored (full-width
    /// digits / separators are normalized first). Digits split by line breaks, dots or underscores count only as a
    /// card number that passes the Luhn check: per-line amounts or dotted dates in a memo are not one.
    static func containsCardNumber(_ text: String) -> Bool {
        var chain: [String] = []
        var segment = ""
        for scalar in normalize(text).unicodeScalars {
            if scalar.value >= 48 && scalar.value <= 57 {
                segment.unicodeScalars.append(scalar)
                if segment.count >= cardNumberMinDigits { return true }
            } else if isDash(scalar) || spaceSeparators.contains(scalar) {
                continue
            } else if groupSeparators.contains(scalar) {
                if !segment.isEmpty { chain.append(segment) }
                segment = ""
            } else {
                if !segment.isEmpty { chain.append(segment) }
                if containsLuhnNumber(chain) { return true }
                chain = []
                segment = ""
            }
        }
        if !segment.isEmpty { chain.append(segment) }
        return containsLuhnNumber(chain)
    }

    /// Consecutive digit groups of card-group size (3+ digits) that add up to a card number's length and pass the Luhn
    /// check.
    private static func containsLuhnNumber(_ groups: [String]) -> Bool {
        for start in groups.indices {
            var digits = ""
            for group in groups[start...] {
                guard group.count >= 3 else { break }
                digits += group
                if digits.count > 19 { break }
                if digits.count >= cardNumberMinDigits && passesLuhn(digits) { return true }
            }
        }
        return false
    }

    static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard var digit = character.wholeNumberValue else { return false }
            if index % 2 == 1 {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
        }
        return sum % 10 == 0
    }

    /// True when the text mentions a security code / PIN / expiry together with digits,
    /// or contains an MM/YY-like expiry pattern.
    static func containsSecurityCode(_ text: String) -> Bool {
        let s = normalize(text)
        let hasDigit = s.unicodeScalars.contains { $0.value >= 48 && $0.value <= 57 }
        if hasDigit && matches(s, keywordPattern) { return true }
        return matches(unifyingDashes(s), expiryPattern)
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

    /// Separators people type inside a card number: spaces and every dash (`isDash`), including the "ー" / "ｰ" a Japanese
    /// keyboard produces for "-".
    private static let spaceSeparators: Set<Unicode.Scalar> = [" ", "\u{3000}", "\t", "\u{00A0}"]

    /// Separators that also split ordinary numbers in a memo (dates, one amount per line): see `containsCardNumber`.
    private static let groupSeparators: Set<Unicode.Scalar> = ["\n", "\r", "\u{2028}", ".", "_"]

    private static func isDash(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2D, 0x2010...0x2015, 0x2212, 0x30FC, 0xFE58, 0xFE63, 0xFF0D, 0xFF70: return true
        default: return false
        }
    }

    /// Every dash → "-" (for the expiry pattern only: "ー" stays in katakana keywords such as パスワード elsewhere).
    private static func unifyingDashes(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in s.unicodeScalars { scalars.append(isDash(scalar) ? "-" : scalar) }
        return String(scalars)
    }
}

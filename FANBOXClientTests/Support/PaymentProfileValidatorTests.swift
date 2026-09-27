import XCTest
@testable import FANBOXClient

final class PaymentProfileValidatorTests: XCTestCase {
    private typealias F = PaymentProfileValidator.Field

    private func issues(nickname: String = "楽天カード", brand: String? = "Visa", last4: String? = "1234", memo: String = "") -> [PaymentProfileIssue] {
        PaymentProfileValidator.validate(nickname: nickname, brand: brand, last4: last4, memo: memo)
    }

    func testValidProfiles() {
        XCTAssertEqual(issues(), [])
        XCTAssertEqual(issues(nickname: "PayPal", brand: nil, last4: nil, memo: "メイン口座から引き落とし"), [])
        XCTAssertEqual(issues(last4: ""), [], "last4 is optional")
        XCTAssertEqual(issues(memo: "月額 ¥1,000 まで / 2026年9月から利用"), [])
        XCTAssertEqual(issues(memo: "電話 090-1234-5678"), [], "11 digits is not a card number")
        XCTAssertEqual(issues(memo: "shopping 用"), [], "\"PIN\" inside a word is not a keyword")
        XCTAssertEqual(issues(memo: "更新日 2026/12/28"), [], "a full date is not an expiry")
    }

    func testNicknameRequired() {
        XCTAssertEqual(issues(nickname: "  "), [.nicknameRequired])
    }

    func testLast4MustBeFourDigits() {
        XCTAssertEqual(issues(last4: "12a4"), [.last4MustBeFourDigits])
        XCTAssertEqual(issues(last4: "123"), [.last4MustBeFourDigits])
        XCTAssertEqual(issues(last4: "12345"), [.last4MustBeFourDigits])
        XCTAssertEqual(issues(last4: "１２３４"), [.last4MustBeFourDigits], "full-width digits are not accepted")
    }

    func testCardNumberWithSpacesIsRejected() {
        XCTAssertEqual(issues(memo: "4111 1111 1111 1111"), [.looksLikeCardNumber(field: F.memo)])
    }

    func testCardNumberWithHyphensAndFullWidthIsRejected() {
        XCTAssertEqual(issues(memo: "番号 4111-1111-1111-1111 のカード"), [.looksLikeCardNumber(field: F.memo)])
        XCTAssertEqual(issues(memo: "４１１１１１１１１１１１１１１１"), [.looksLikeCardNumber(field: F.memo)])
        XCTAssertEqual(issues(nickname: "Visa 411111111111"), [.looksLikeCardNumber(field: F.nickname)], "12 digits already counts")
    }

    /// The Japanese keyboard types "-" as "ー" (and full-width digits); a memo may also split the number over lines.
    func testCardNumberTypedWithJapaneseDashesOrLineBreaksIsRejected() {
        XCTAssertEqual(issues(memo: "４１１１ー１１１１ー１１１１ー１１１１"), [.looksLikeCardNumber(field: F.memo)])
        XCTAssertEqual(issues(memo: "4111ｰ1111ｰ1111ｰ1111"), [.looksLikeCardNumber(field: F.memo)], "half-width ｰ")
        XCTAssertEqual(issues(memo: "4111 1111\n1111 1111"), [.looksLikeCardNumber(field: F.memo)])
        XCTAssertEqual(issues(memo: "4111.1111.1111.1111"), [.looksLikeCardNumber(field: F.memo)])
        XCTAssertEqual(issues(memo: "有効期限 12ー28"), [.looksLikeSecurityCode(field: F.memo)])
        XCTAssertEqual(issues(memo: "カード 07ー27"), [.looksLikeSecurityCode(field: F.memo)], "MM-YY typed with ー")
        XCTAssertEqual(issues(memo: "パスワードマネージャーで管理"), [], "ー inside katakana is not a separator for keywords")
        XCTAssertEqual(issues(memo: "メモ\n1.\n4111\n1111\n1111\n1111"), [.looksLikeCardNumber(field: F.memo)], "after a short line")

        // Line breaks / dots also split ordinary numbers: only a Luhn-valid card number counts across them.
        XCTAssertEqual(issues(memo: "2026.09.27\n2026.10.27"), [], "dotted dates on separate lines")
        XCTAssertEqual(issues(memo: "500\n1000\n1500\n2000\n3000"), [], "one amount per line")
        XCTAssertEqual(issues(memo: "v1.2.3_20260927.1200"), [])
        XCTAssertTrue(PaymentProfileValidator.passesLuhn("4111111111111111"))
        XCTAssertFalse(PaymentProfileValidator.passesLuhn("4111111111111112"))
    }

    func testPANInLast4IsRejected() {
        let result = issues(last4: "4111111111111111")
        XCTAssertTrue(result.contains(.last4MustBeFourDigits))
        XCTAssertTrue(result.contains(.looksLikeCardNumber(field: F.last4)))
    }

    func testSecurityCodeKeywordsAreRejected() {
        XCTAssertEqual(issues(memo: "CVC 123"), [.looksLikeSecurityCode(field: F.memo)])
        XCTAssertEqual(issues(memo: "cvv:456"), [.looksLikeSecurityCode(field: F.memo)])
        XCTAssertEqual(issues(memo: "セキュリティコードは 789"), [.looksLikeSecurityCode(field: F.memo)])
        XCTAssertEqual(issues(memo: "ｾｷｭﾘﾃｨｺｰﾄﾞ 789"), [.looksLikeSecurityCode(field: F.memo)], "half-width katakana")
        XCTAssertEqual(issues(memo: "暗証番号 0000"), [.looksLikeSecurityCode(field: F.memo)])
        XCTAssertEqual(issues(memo: "PIN1234"), [.looksLikeSecurityCode(field: F.memo)])
        XCTAssertEqual(issues(brand: "Visa CVC 321"), [.looksLikeSecurityCode(field: F.brand)])
    }

    func testKeywordWithoutDigitsIsAllowed() {
        XCTAssertEqual(issues(memo: "暗証番号はここに書かない"), [])
    }

    func testExpiryIsRejected() {
        XCTAssertEqual(issues(memo: "有効期限 12/28"), [.looksLikeSecurityCode(field: F.memo)])
        XCTAssertEqual(issues(memo: "exp 03/2029"), [.looksLikeSecurityCode(field: F.memo)])
        XCTAssertEqual(issues(memo: "カード 07/27"), [.looksLikeSecurityCode(field: F.memo)], "MM/YY without keyword")
        XCTAssertEqual(issues(memo: "０７／２７"), [.looksLikeSecurityCode(field: F.memo)], "full-width MM/YY")
    }

    func testDraftNormalizationDropsCardFieldsForNonCardTypes() {
        var draft = PaymentProfileDraft(nickname: " PayPal ", type: .paypal, brand: "Visa", last4: "12a4", memo: " memo ")
        XCTAssertEqual(draft.issues, [], "last4 / brand are not stored for PayPal, so they are not validated")
        XCTAssertEqual(draft.normalized.nickname, "PayPal")
        XCTAssertNil(draft.normalized.brand)
        XCTAssertEqual(draft.normalized.last4, "")
        draft.type = .creditCard
        XCTAssertEqual(draft.issues, [.last4MustBeFourDigits])
    }

    func testNormalizationKeepsKatakana() {
        XCTAssertEqual(PaymentProfileValidator.normalize("４１１１／セキュリティ　ＰＩＮ"), "4111/セキュリティ PIN")
    }

    func testPasswordsAndThreeDSecureCredentialsAreRejected() {
        XCTAssertEqual(issues(memo: "パスワード: abcd1234"), [.looksLikeCredential(field: F.memo)])
        XCTAssertEqual(issues(memo: "パスワード：hunter"), [.looksLikeCredential(field: F.memo)], "full-width colon, no digits")
        XCTAssertEqual(issues(memo: "3Dセキュア 1234abcd"), [.looksLikeCredential(field: F.memo)])
        XCTAssertEqual(issues(memo: "３Ｄセキュア＝ｓｅｃｒｅｔ"), [.looksLikeCredential(field: F.memo)], "full-width")
        XCTAssertEqual(issues(memo: "password=hunter"), [.looksLikeCredential(field: F.memo)])
        XCTAssertEqual(issues(memo: "Password is hunter"), [.looksLikeCredential(field: F.memo)])
        XCTAssertEqual(issues(memo: "パスワードはabcdef"), [.looksLikeCredential(field: F.memo)])
        XCTAssertEqual(issues(memo: "3DS pass 998877"), [.looksLikeCredential(field: F.memo)])
        XCTAssertEqual(issues(memo: "OTP 482913"), [.looksLikeCredential(field: F.memo)])
        XCTAssertEqual(issues(memo: "ワンタイムパスワード 123456"), [.looksLikeCredential(field: F.memo)])
        XCTAssertEqual(issues(memo: "本人認証：kitty"), [.looksLikeCredential(field: F.memo)])
        XCTAssertEqual(issues(memo: "ﾊﾟｽﾜｰﾄﾞ ab12"), [.looksLikeCredential(field: F.memo)], "half-width katakana")
        XCTAssertEqual(issues(nickname: "楽天 pw: x", memo: ""), [], "\"pw\" alone is not a keyword")
        XCTAssertEqual(issues(nickname: "楽天 passcode:x"), [.looksLikeCredential(field: F.nickname)])
        XCTAssertEqual(issues(brand: "Visa 3D Secure: 0000"), [.looksLikeCredential(field: F.brand)])
    }

    func testCredentialMentionsWithoutValuesAreAllowed() {
        XCTAssertEqual(issues(memo: "3Dセキュア対応"), [], "the 3 in 3D is not a value")
        XCTAssertEqual(issues(memo: "3D Secure 対応カード"), [])
        XCTAssertEqual(issues(memo: "パスワードは手帳で管理"), [])
        XCTAssertEqual(issues(memo: "ワンタイムパスワードはSMSで届く"), [], "3 ASCII letters after は are not a value")
        XCTAssertEqual(issues(memo: "passport 用"), [])
        XCTAssertEqual(PaymentProfileValidator.containsCredential("本人認証あり"), false)
    }

    func testSecurityCodeTakesPrecedenceOverCredentialForTheSameField() {
        XCTAssertEqual(issues(memo: "暗証番号 0000"), [.looksLikeSecurityCode(field: F.memo)], "one issue per field")
    }

    func testCredentialIssueNamesTheFieldAndPasswords() {
        XCTAssertTrue(PaymentProfileIssue.looksLikeCredential(field: F.memo).message.contains("メモ"))
        XCTAssertTrue(PaymentProfileIssue.looksLikeCredential(field: F.memo).message.contains("パスワード"))
    }

    func testIssueMessagesNameTheField() {
        XCTAssertTrue(PaymentProfileIssue.looksLikeCardNumber(field: F.memo).message.contains("メモ"))
        XCTAssertTrue(PaymentProfileIssue.looksLikeSecurityCode(field: F.brand).message.contains("ブランド"))
    }
}

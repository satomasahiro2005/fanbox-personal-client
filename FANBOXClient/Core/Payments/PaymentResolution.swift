import Foundation

/// Sendable value copy of a `PaymentProfile` row.
struct PaymentProfileSnapshot: Sendable, Hashable, Identifiable {
    var id: String
    var nickname: String
    var type: PaymentProfileType
    var brand: String?
    var last4: String?

    init(id: String, nickname: String, type: PaymentProfileType, brand: String? = nil, last4: String? = nil) {
        self.id = id
        self.nickname = nickname
        self.type = type
        self.brand = brand
        self.last4 = last4
    }

    init(_ profile: PaymentProfile) {
        self.init(id: profile.id, nickname: profile.nickname, type: profile.type, brand: profile.brand, last4: profile.last4)
    }

    /// "楽天Visa•••1234"
    var shortLabel: String { SupportText.profileShortLabel(nickname: nickname, brand: brand, last4: last4) }
}

/// The account-level default profile (`Account.defaultPaymentProfileID`).
struct AccountPaymentDefault: Sendable, Hashable {
    var accountID: String
    var profileID: String?
    var verifiedAt: Date?

    init(accountID: String, profileID: String?, verifiedAt: Date? = nil) {
        self.accountID = accountID
        self.profileID = profileID
        self.verifiedAt = verifiedAt
    }

    init(_ account: Account) {
        self.init(accountID: account.id, profileID: account.defaultPaymentProfileID, verifiedAt: account.defaultPaymentVerifiedAt)
    }
}

/// The profile a support line shows and how sure the app is about it (SPEC §13).
struct ResolvedPayment: Sendable, Hashable {
    enum Source: Sendable, Hashable {
        /// The support's own linked profile (`SupportPaymentAssignment`).
        case support
        /// Inherited from the account default (shown with a 既定 pill).
        case accountDefault
        /// Display-only guess from FANBOX's payment type (`SupportAnalyzer.inferredProfileID`).
        case inferred
        case none
    }

    var source: Source
    var profileID: String?
    /// `.verified` only for a support verified on the web, or an inherited default the user confirmed
    /// (`Account.defaultPaymentVerifiedAt`); an unconfirmed default is `.manual`.
    var verificationState: VerificationState
    var verifiedAt: Date?

    static let unresolved = ResolvedPayment(source: .none, profileID: nil, verificationState: .unknown, verifiedAt: nil)
}

/// Resolves a support's payment profile at render time, so changing an account default updates every support that
/// inherits it. Precedence:
/// 1. the support's own linked profile;
/// 2. the account default, unless FANBOX reports a payment type that contradicts it (a card default on a support
///    FANBOX lists as PayPal);
/// 3. the single profile of FANBOX's reported type (推定（未確認）, never stored);
/// 4. none.
/// A link to a profile that no longer exists is ignored and resolution falls through to the next step.
enum PaymentResolution {
    static func resolve(assignment: AssignmentSnapshot?, accountDefault: AccountPaymentDefault?,
                        profiles: [PaymentProfileSnapshot], reportedPaymentMethod: String?) -> ResolvedPayment {
        if let id = assignment?.paymentProfileID, let assignment, profiles.contains(where: { $0.id == id }) {
            let state = assignment.verificationState
            return ResolvedPayment(source: .support, profileID: id, verificationState: state,
                                   verifiedAt: state == .verified ? assignment.lastVerifiedAt : nil)
        }
        if let id = accountDefault?.profileID, let profile = profiles.first(where: { $0.id == id }),
           !contradicts(profile.type, reportedPaymentMethod: reportedPaymentMethod) {
            let verifiedAt = accountDefault?.verifiedAt
            return ResolvedPayment(source: .accountDefault, profileID: id, verificationState: verifiedAt == nil ? .manual : .verified,
                                   verifiedAt: verifiedAt)
        }
        if let id = SupportAnalyzer.inferredProfileID(reportedPaymentMethod: reportedPaymentMethod,
                                                      profiles: profiles.map { (id: $0.id, type: $0.type) }) {
            return ResolvedPayment(source: .inferred, profileID: id, verificationState: .inferred, verifiedAt: nil)
        }
        return .unresolved
    }

    /// True when FANBOX's reported payment type (`FanboxAdapter.paymentMethodFamily`) is known and is not the profile's.
    static func contradicts(_ type: PaymentProfileType, reportedPaymentMethod: String?) -> Bool {
        guard let reported = FanboxAdapter.paymentMethodFamily(reportedPaymentMethod) else { return false }
        switch type {
        case .creditCard, .debitCard: return reported != "card"
        case .paypal: return reported != "paypal"
        case .carrierBilling: return true
        case .other: return false
        }
    }
}

/// What one support line shows about payment: the resolved profile, 前回 and 次回 (`SupportPaymentLine`).
struct SupportPaymentSummary: Sendable, Hashable {
    var resolution: ResolvedPayment
    var profile: PaymentProfileSnapshot?
    /// FANBOX's payment type in Japanese (`SupportText.paymentMethodLabel`), nil when none was reported.
    var paymentMethodLabel: String?
    var lastPayment: LastPayment?
    var nextCharge: NextCharge?

    /// The resolved profile ("楽天Visa•••1234"), else FANBOX's payment type ("カード"), else 未設定.
    var cardLabel: String { profile?.shortLabel ?? paymentMethodLabel ?? "未設定" }
}

/// Inputs shared by every support line of one screen. Built once per render from the local rows.
struct SupportPaymentContext: Sendable {
    var profiles: [PaymentProfileSnapshot]
    var defaults: [String: AccountPaymentDefault]
    var lastPayments: [String: LastPayment]
    var now: Date
    var calendar: Calendar

    init(profiles: [PaymentProfileSnapshot], defaults: [AccountPaymentDefault], payments: [PaymentSnapshot], now: Date = .now,
         calendar: Calendar = SupportBilling.calendar) {
        self.profiles = profiles
        self.defaults = Dictionary(defaults.map { ($0.accountID, $0) }, uniquingKeysWith: { first, _ in first })
        self.lastPayments = SupportAnalyzer.lastPayments(payments)
        self.now = now
        self.calendar = calendar
    }

    @MainActor
    init(profiles: [PaymentProfile], accounts: [Account], payments: [PaymentRecord], now: Date = .now) {
        self.init(profiles: profiles.map(PaymentProfileSnapshot.init), defaults: accounts.map(AccountPaymentDefault.init),
                  payments: payments.map(PaymentSnapshot.init), now: now)
    }

    func summary(support: SupportSnapshot, assignment: AssignmentSnapshot?) -> SupportPaymentSummary {
        let resolution = PaymentResolution.resolve(assignment: assignment, accountDefault: defaults[support.accountID],
                                                   profiles: profiles, reportedPaymentMethod: support.reportedPaymentMethod)
        return SupportPaymentSummary(
            resolution: resolution,
            profile: resolution.profileID.flatMap { id in profiles.first { $0.id == id } },
            paymentMethodLabel: SupportText.paymentMethodLabel(support.reportedPaymentMethod),
            lastPayment: lastPayments[support.id],
            nextCharge: SupportBilling.nextCharge(support, now: now, calendar: calendar)
        )
    }

    func summary(for line: SupportLine) -> SupportPaymentSummary {
        summary(support: line.support, assignment: line.assignment)
    }
}

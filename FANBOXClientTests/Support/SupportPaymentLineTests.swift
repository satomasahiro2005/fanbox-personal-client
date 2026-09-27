import SwiftData
import SwiftUI
import XCTest
@testable import FANBOXClient

/// The payment line of a support (card, 前回, 次回): next charge window, profile resolution with account defaults,
/// Japanese payment-type labels, persistence of the new account fields, and the demo rows.
final class SupportPaymentLineTests: XCTestCase {
    private var tokyo: Calendar { SupportBilling.calendar }

    private func jst(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        tokyo.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func support(_ account: String = "A", _ creator: String = "c1", amount: Int = 500, status: SupportStatus = .active,
                         method: String? = "card", stoppingObservedAt: Date? = nil, userStopMarkedAt: Date? = nil) -> SupportSnapshot {
        SupportSnapshot(accountID: account, creatorID: creator, creatorName: "Creator \(creator)", amount: amount, status: status,
                        reportedPaymentMethod: method, stoppingObservedAt: stoppingObservedAt, userStopMarkedAt: userStopMarkedAt)
    }

    private let visa = PaymentProfileSnapshot(id: "visa", nickname: "楽天Visa", type: .creditCard, brand: "Visa", last4: "1234")
    private let master = PaymentProfileSnapshot(id: "mc", nickname: "三井住友", type: .creditCard, brand: "Mastercard", last4: "5678")
    private let paypal = PaymentProfileSnapshot(id: "pp", nickname: "PayPal", type: .paypal)

    private func resolve(_ assignment: AssignmentSnapshot?, _ accountDefault: AccountPaymentDefault?,
                         _ profiles: [PaymentProfileSnapshot], _ reported: String?) -> ResolvedPayment {
        PaymentResolution.resolve(assignment: assignment, accountDefault: accountDefault, profiles: profiles, reportedPaymentMethod: reported)
    }

    // MARK: 次回 (SupportBilling.nextCharge)

    func testNextChargeIsTheFirstFiveDaysOfNextMonth() throws {
        let next = try XCTUnwrap(SupportBilling.nextCharge(support(), now: jst(2026, 9, 24)))
        XCTAssertEqual(next, .planned(DateInterval(start: jst(2026, 10, 1, 0), end: jst(2026, 10, 6, 0))))
        XCTAssertEqual(SupportText.nextChargeText(next), "次回10/1〜5予定")
        XCTAssertEqual(SupportText.nextChargeText(next, showsPlannedSuffix: false), "次回10/1〜5", "narrow payment lines")
        XCTAssertEqual(SupportBilling.nextCharge(support(), now: jst(2026, 12, 31, 23, 59)),
                       .planned(DateInterval(start: jst(2027, 1, 1, 0), end: jst(2027, 1, 6, 0))), "across the year end")
        XCTAssertNotNil(SupportBilling.nextCharge(support(method: nil), now: jst(2026, 9, 24)), "an unreported type still renews")
    }

    func testNextChargeUsesTheJapanBillingMonth() throws {
        // 2026-09-30T15:30Z is already 10/1 00:30 in Japan: October's charges are running, the next window is November's.
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-30T15:30:00Z"))
        let next = try XCTUnwrap(SupportBilling.nextCharge(support(), now: now))
        XCTAssertEqual(next, .planned(DateInterval(start: jst(2026, 11, 1, 0), end: jst(2026, 11, 6, 0))))
        XCTAssertEqual(SupportText.nextChargeText(next), "次回11/1〜5予定")
    }

    func testScheduledStopsMeanNoNextCharge() throws {
        let now = jst(2026, 9, 24)
        let observed = try XCTUnwrap(SupportBilling.nextCharge(support(stoppingObservedAt: jst(2026, 9, 10)), now: now))
        XCTAssertEqual(observed, .stopped(.observed))
        XCTAssertEqual(SupportText.nextChargeText(observed), "次回なし")
        let marked = try XCTUnwrap(SupportBilling.nextCharge(support(userStopMarkedAt: jst(2026, 9, 20)), now: now))
        XCTAssertEqual(marked, .stopped(.userMarked))
        XCTAssertEqual(SupportText.nextChargeText(marked), "次回なし（自分で記録）")
        XCTAssertEqual(SupportBilling.nextCharge(support(userStopMarkedAt: jst(2026, 8, 20)), now: now),
                       .planned(DateInterval(start: jst(2026, 10, 1, 0), end: jst(2026, 10, 6, 0))),
                       "a stop of last month is stale: the support continues")
        for text in [observed, marked].map({ SupportText.nextChargeText($0) }) {
            XCTAssertFalse(SupportText.assertsCause(text))
        }
    }

    func testNoNextChargeForConvenienceStoreOrInactiveSupports() {
        let now = jst(2026, 9, 24)
        XCTAssertNil(SupportBilling.nextCharge(support(method: "cvs"), now: now))
        XCTAssertNil(SupportBilling.nextCharge(support(method: "gmo_cvs"), now: now))
        XCTAssertNil(SupportBilling.nextCharge(support(status: .ended), now: now))
        XCTAssertNil(SupportBilling.nextCharge(support(status: .missing), now: now))
        XCTAssertNil(SupportBilling.nextCharge(support(status: .unknown), now: now))
        XCTAssertNil(SupportBilling.nextCharge(support(status: .ended, stoppingObservedAt: jst(2026, 9, 10)), now: now))
    }

    // MARK: PaymentResolution

    func testResolutionPrecedence() {
        let profiles = [visa, master, paypal]
        let accountDefault = AccountPaymentDefault(accountID: "A", profileID: "visa")
        let own = AssignmentSnapshot(accountID: "A", creatorID: "c1", paymentProfileID: "mc", verificationState: .verified,
                                     lastVerifiedAt: jst(2026, 9, 3))
        let fromSupport = resolve(own, accountDefault, profiles, "card")
        XCTAssertEqual(fromSupport.source, .support, "the support's own profile wins over the default")
        XCTAssertEqual(fromSupport.profileID, "mc")
        XCTAssertEqual(fromSupport.verificationState, .verified)
        XCTAssertEqual(fromSupport.verifiedAt, jst(2026, 9, 3))

        // The sync placeholder has no profile: the support inherits the account default.
        let placeholder = AssignmentSnapshot(accountID: "A", creatorID: "c1")
        let inherited = resolve(placeholder, accountDefault, profiles, "card")
        XCTAssertEqual(inherited.source, .accountDefault)
        XCTAssertEqual(inherited.profileID, "visa")
        XCTAssertEqual(resolve(nil, accountDefault, profiles, "card"), inherited)

        // No default: the single profile of the reported type is a guess; two cards are ambiguous.
        let guessed = resolve(placeholder, nil, profiles, "paypal")
        XCTAssertEqual(guessed.source, .inferred)
        XCTAssertEqual(guessed.profileID, "pp")
        XCTAssertEqual(guessed.verificationState, .inferred)
        XCTAssertEqual(resolve(placeholder, nil, profiles, "card"), .unresolved)
        XCTAssertEqual(resolve(nil, AccountPaymentDefault(accountID: "A", profileID: nil), profiles, nil), .unresolved)
    }

    func testDefaultIsSkippedWhenFANBOXReportsAnotherType() {
        let cardDefault = AccountPaymentDefault(accountID: "A", profileID: "visa")
        let onPayPal = resolve(nil, cardDefault, [visa, paypal], "PAYPAL")
        XCTAssertEqual(onPayPal.source, .inferred, "a card default is not shown on a PayPal support")
        XCTAssertEqual(onPayPal.profileID, "pp")
        XCTAssertEqual(resolve(nil, cardDefault, [visa, paypal], "gmo_cvs"), .unresolved)
        XCTAssertEqual(resolve(nil, AccountPaymentDefault(accountID: "A", profileID: "pp"), [visa, paypal], "gmo_card").profileID, "visa")
        // A type the app cannot map, or none, contradicts nothing.
        XCTAssertEqual(resolve(nil, cardDefault, [visa], "pixivcoban").source, .accountDefault)
        XCTAssertEqual(resolve(nil, cardDefault, [visa], nil).source, .accountDefault)
        // The support's own link is kept even on a mismatch (sync downgrades its verification instead).
        let own = AssignmentSnapshot(accountID: "A", creatorID: "c1", paymentProfileID: "visa", verificationState: .manual)
        XCTAssertEqual(resolve(own, nil, [visa, paypal], "paypal").source, .support)
        XCTAssertTrue(PaymentResolution.contradicts(.debitCard, reportedPaymentMethod: "paypal"))
        XCTAssertFalse(PaymentResolution.contradicts(.debitCard, reportedPaymentMethod: "CARD"))
        XCTAssertFalse(PaymentResolution.contradicts(.other, reportedPaymentMethod: "cvs"))
    }

    func testDeletedProfileFallsBack() {
        let ownDeleted = AssignmentSnapshot(accountID: "A", creatorID: "c1", paymentProfileID: "gone", verificationState: .verified)
        let toDefault = resolve(ownDeleted, AccountPaymentDefault(accountID: "A", profileID: "visa"), [visa], "card")
        XCTAssertEqual(toDefault.source, .accountDefault)
        XCTAssertEqual(toDefault.profileID, "visa")
        let deletedDefault = AccountPaymentDefault(accountID: "A", profileID: "gone", verifiedAt: jst(2026, 9, 1))
        let toGuess = resolve(ownDeleted, deletedDefault, [visa], "card")
        XCTAssertEqual(toGuess.source, .inferred)
        XCTAssertEqual(toGuess.profileID, "visa")
        XCTAssertEqual(resolve(ownDeleted, deletedDefault, [], "card"), .unresolved)
    }

    func testInheritedDefaultIsVerifiedOnlyWithItsOwnConfirmation() {
        let unconfirmed = resolve(nil, AccountPaymentDefault(accountID: "A", profileID: "visa"), [visa], "card")
        XCTAssertEqual(unconfirmed.verificationState, .manual)
        XCTAssertNil(unconfirmed.verifiedAt)
        XCTAssertFalse(SupportText.isFact(unconfirmed.verificationState))
        // A verified state on a placeholder without a profile does not carry over to the inherited default.
        let stalePlaceholder = AssignmentSnapshot(accountID: "A", creatorID: "c1", paymentProfileID: nil, verificationState: .verified,
                                                  lastVerifiedAt: jst(2026, 9, 3))
        XCTAssertEqual(resolve(stalePlaceholder, AccountPaymentDefault(accountID: "A", profileID: "visa"), [visa], "card").verificationState,
                       .manual)
        let confirmed = resolve(nil, AccountPaymentDefault(accountID: "A", profileID: "visa", verifiedAt: jst(2026, 9, 5)), [visa], "card")
        XCTAssertEqual(confirmed.source, .accountDefault)
        XCTAssertEqual(confirmed.verificationState, .verified)
        XCTAssertEqual(confirmed.verifiedAt, jst(2026, 9, 5))
    }

    // MARK: Labels

    func testPaymentTypeLabelsAreJapanese() {
        let cases: [(String?, String?)] = [
            ("card", "カード"), ("CARD", "カード"), ("gmo_card", "カード"),
            ("paypal", "PayPal"), ("PAYPAL", "PayPal"),
            ("cvs", "コンビニ"), ("gmo_cvs", "コンビニ"),
            ("unknown", "その他"), ("pixivcoban", "その他"),
            (nil, nil), ("", nil), ("  ", nil),
        ]
        for (raw, label) in cases {
            XCTAssertEqual(SupportText.paymentMethodLabel(raw), label, raw ?? "nil")
        }
    }

    func testCardLabelsAndDates() throws {
        XCTAssertEqual(visa.shortLabel, "楽天Visa•••1234")
        XCTAssertEqual(PaymentProfileSnapshot(id: "x", nickname: "", type: .creditCard, brand: "Visa", last4: "1234").shortLabel, "Visa•••1234")
        XCTAssertEqual(paypal.shortLabel, "PayPal")
        XCTAssertEqual(SupportText.billingDate(jst(2026, 9, 2, 9), now: jst(2026, 9, 24)), "9/2")
        XCTAssertEqual(SupportText.billingDate(jst(2025, 12, 2, 9), now: jst(2026, 1, 24)), "2025/12/2")
        let edge = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-30T15:30:00Z"))
        XCTAssertEqual(SupportText.billingDate(edge, now: jst(2026, 10, 3)), "10/1", "dates are Japan dates")
    }

    func testSummaryOfOneSupportLine() {
        let context = SupportPaymentContext(
            profiles: [visa, master, paypal],
            defaults: [AccountPaymentDefault(accountID: "A", profileID: "visa"), AccountPaymentDefault(accountID: "B", profileID: nil)],
            payments: [PaymentSnapshot(accountID: "A", creatorID: "c1", amount: 500, paidAt: jst(2026, 9, 2, 9)),
                       PaymentSnapshot(accountID: "B", creatorID: "c1", amount: 1_000, paidAt: jst(2026, 9, 3, 9))],
            now: jst(2026, 9, 24))
        let a = context.summary(support: support("A", method: "gmo_card"), assignment: AssignmentSnapshot(accountID: "A", creatorID: "c1"))
        XCTAssertEqual(a.cardLabel, "楽天Visa•••1234")
        XCTAssertEqual(a.resolution.source, .accountDefault)
        XCTAssertEqual(a.paymentMethodLabel, "カード")
        XCTAssertEqual(a.lastPayment?.amount, 500)
        XCTAssertEqual(a.nextCharge, .planned(DateInterval(start: jst(2026, 10, 1, 0), end: jst(2026, 10, 6, 0))))

        let b = context.summary(support: support("B", amount: 1_000, method: "gmo_card"), assignment: nil)
        XCTAssertEqual(b.cardLabel, "カード", "no default and two cards: FANBOX's type in Japanese, never the raw gmo_card")
        XCTAssertEqual(b.resolution, .unresolved)
        XCTAssertEqual(b.lastPayment?.amount, 1_000)

        let unknown = context.summary(support: support("B", "c9", method: nil), assignment: nil)
        XCTAssertEqual(unknown.cardLabel, "未設定")
        XCTAssertNil(unknown.lastPayment)
    }

    // MARK: Persistence

    /// The two optional `Account` fields are additive: a store written with them opens again, and rows without them read nil.
    func testStoreOpensWithTheAccountDefaultFields() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("payment-line-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("FANBOXClient.store")
        let verifiedAt = Date(timeIntervalSince1970: 1_790_000_000)
        do {
            let container = try ModelContainer(for: AppSchema.schema, configurations: [ModelConfiguration(schema: AppSchema.schema, url: url)])
            let context = ModelContext(container)
            let a = Account(id: "A", kind: .demo, displayName: "A")
            a.defaultPaymentProfileID = "visa"
            a.defaultPaymentVerifiedAt = verifiedAt
            context.insert(a)
            context.insert(Account(id: "B", kind: .demo, displayName: "B"))
            try context.save()
        }
        let reopened = try ModelContainer(for: AppSchema.schema, configurations: [ModelConfiguration(schema: AppSchema.schema, url: url)])
        let accounts = try ModelContext(reopened).fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.id)]))
        XCTAssertEqual(accounts.map(\.id), ["A", "B"])
        XCTAssertEqual(accounts[0].defaultPaymentProfileID, "visa")
        XCTAssertEqual(accounts[0].defaultPaymentVerifiedAt, verifiedAt)
        XCTAssertNil(accounts[1].defaultPaymentProfileID)
        XCTAssertNil(accounts[1].defaultPaymentVerifiedAt)
        XCTAssertNoThrow(try PersistenceController.makeContainer(inMemory: true))
    }
}

/// Demo data through the real upserts: every support row shows a card label and 前回, and the Support screens render.
@MainActor
final class SupportPaymentLineSmokeTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    private func seededEnvironment() async throws -> AppEnvironment {
        let env = AppEnvironment.preview(seedDemo: true)
        let source = DemoRemoteDataSource(policy: nil, world: DemoWorld(now: .now, latencyScale: 0))
        for account in env.store.accounts() {
            let context = account.context
            env.store.applySupports(try await source.supportingPlans(account: context), account: context, source: .demo, isBaseline: true)
            env.store.upsertPayments(try await source.paidRecords(account: context), account: context)
        }
        return env
    }

    private func summaries(_ env: AppEnvironment) -> [(line: SupportLine, summary: SupportPaymentSummary)] {
        let accounts = env.store.accounts()
        let supports = env.store.fetch(FetchDescriptorFactorySupport.allSupports()).map(SupportSnapshot.init)
        let assignments = env.store.fetch(FetchDescriptor<SupportPaymentAssignment>()).map(AssignmentSnapshot.init)
        let context = SupportPaymentContext(profiles: env.store.fetch(FetchDescriptor<PaymentProfile>()), accounts: accounts,
                                            payments: env.store.fetch(FetchDescriptorFactorySupport.allPayments()))
        return SupportAnalyzer.byCreator(supports: supports, assignments: assignments, accountOrder: accounts.map(\.id))
            .flatMap(\.lines)
            .map { (line: $0, summary: context.summary(for: $0)) }
    }

    private func render<V: View>(_ view: V, env: AppEnvironment) async throws {
        let root = NavigationStack { view }
            .environment(env)
            .environment(env.router)
            .environment(env.settings)
            .modelContainer(env.container)
        let controller = UIHostingController(rootView: root)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("no window scene in the test host")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(controller.view)
        self.window?.isHidden = true
        self.window = window
    }

    func testDemoRowsShowTheCardLabelAndTheLastPayment() async throws {
        let env = try await seededEnvironment()
        let rows = summaries(env)
        XCTAssertFalse(rows.isEmpty)
        let labels = Set(rows.map(\.summary.cardLabel))
        XCTAssertTrue(labels.contains("カード"), "\(labels)")
        XCTAssertTrue(labels.contains("PayPal"), "\(labels)")
        XCTAssertFalse(labels.contains { $0.lowercased().contains("card") || $0.contains("gmo") }, "raw API strings are never shown")
        let lastTexts = rows.compactMap(\.summary.lastPayment).map { SupportText.lastPaymentText($0) }
        XCTAssertFalse(lastTexts.isEmpty)
        XCTAssertTrue(lastTexts.allSatisfy { $0.hasPrefix("前回") }, "\(lastTexts)")
        XCTAssertTrue(rows.contains { if case .planned? = $0.summary.nextCharge { return true } else { return false } })

        // A default card on the first account shows on its card supports at once (resolved at render time).
        guard case .success(let card) = SupportMutations.saveProfile(
            PaymentProfileDraft(nickname: "楽天Visa", type: .creditCard, brand: "Visa", last4: "1234"), store: env.store) else {
            return XCTFail("valid profile must save")
        }
        let first = try XCTUnwrap(env.store.accounts().first)
        SupportMutations.setAccountDefault(store: env.store, accountID: first.id, profileID: card.id)
        let firstRows = summaries(env).filter { $0.line.support.accountID == first.id }
        XCTAssertFalse(firstRows.isEmpty)
        for row in firstRows {
            if SupportText.paymentMethodLabel(row.line.support.reportedPaymentMethod) == "カード" {
                XCTAssertEqual(row.summary.cardLabel, "楽天Visa•••1234")
                XCTAssertEqual(row.summary.resolution.source, .accountDefault)
            } else {
                XCTAssertNotEqual(row.summary.resolution.source, .accountDefault, "a card default is skipped on other types")
            }
        }

        try await render(SupportRootView(), env: env)
        try await render(SupportCreatorDetailView(creatorID: "demo-aoi"), env: env)
        try await render(SupportAccountDetailView(accountID: first.id), env: env)
        try await render(SupportPaymentRecordsView(accountID: first.id), env: env)
        try await render(CreatorDetailView(creatorID: "demo-aoi", initialSection: .support), env: env)
        try await render(PaymentProfilesView(), env: env)
    }
}

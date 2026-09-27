import XCTest
import SwiftData
@testable import FANBOXClient

@MainActor
final class SupportMutationsTests: XCTestCase {
    private func makeStore() throws -> LocalStore {
        LocalStore(container: try PersistenceController.makeContainer(inMemory: true))
    }

    private func allAssignments(_ store: LocalStore) -> [SupportPaymentAssignment] {
        store.fetch(FetchDescriptor<SupportPaymentAssignment>())
    }

    func testSaveProfileRejectsSecretsAndWritesNothing() throws {
        let store = try makeStore()
        let result = SupportMutations.saveProfile(PaymentProfileDraft(nickname: "Card", type: .creditCard, brand: "Visa",
                                                                      last4: "1234", memo: "CVC 123"), store: store)
        guard case .failure(let failure) = result else { return XCTFail("must be rejected") }
        XCTAssertEqual(failure.issues, [.looksLikeSecurityCode(field: PaymentProfileValidator.Field.memo)])
        XCTAssertTrue(store.fetch(FetchDescriptor<PaymentProfile>()).isEmpty)
    }

    func testSaveProfileCreatesThenUpdates() throws {
        let store = try makeStore()
        guard case .success(let created) = SupportMutations.saveProfile(
            PaymentProfileDraft(nickname: " 楽天カード ", type: .creditCard, brand: "Visa", last4: "1234"), store: store) else {
            return XCTFail("valid draft must save")
        }
        XCTAssertEqual(created.nickname, "楽天カード")
        XCTAssertEqual(created.displayDetail, "Visa •••• 1234")
        guard case .success(let second) = SupportMutations.saveProfile(PaymentProfileDraft(nickname: "PayPal", type: .paypal), store: store) else {
            return XCTFail()
        }
        XCTAssertEqual(second.sortOrder, created.sortOrder + 1)

        var edit = PaymentProfileDraft(created)
        edit.type = .paypal
        edit.nickname = "PayPal 2"
        guard case .success(let updated) = SupportMutations.saveProfile(edit, store: store) else { return XCTFail() }
        XCTAssertEqual(updated.id, created.id)
        XCTAssertNil(updated.brand, "card fields are dropped for non-card types")
        XCTAssertNil(updated.last4)
        XCTAssertEqual(store.fetch(FetchDescriptor<PaymentProfile>()).count, 2)
    }

    func testSetAssignmentVerifiedStampsDateAndManualClearsIt() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let a = SupportMutations.setAssignment(store: store, accountID: "A", creatorID: "c1", planID: "p1",
                                               profileID: "prof", state: .verified, now: now)
        XCTAssertEqual(a.key, "A|c1")
        XCTAssertEqual(a.verificationState, .verified)
        XCTAssertEqual(a.lastVerifiedAt, now)

        SupportMutations.setAssignment(store: store, accountID: "A", creatorID: "c1", planID: nil, profileID: "prof", state: .manual, now: now)
        XCTAssertEqual(allAssignments(store).count, 1, "upsert, not insert")
        XCTAssertEqual(a.verificationState, .manual)
        XCTAssertNil(a.lastVerifiedAt)
        XCTAssertEqual(a.planID, "p1", "nil planID keeps the known plan")

        SupportMutations.setAssignment(store: store, accountID: "A", creatorID: "c1", planID: nil, profileID: nil, state: .verified, now: now)
        XCTAssertEqual(a.verificationState, .unknown, "no profile ⇒ nothing can be verified")
        XCTAssertNil(a.lastVerifiedAt)
    }

    func testRecordPaymentIntentUsesManualAndKeepsExistingWithoutProfile() throws {
        let store = try makeStore()
        let first = SupportMutations.recordPaymentIntent(store: store, accountID: "A", creatorID: "c1", planID: "p1", profileID: "prof")
        XCTAssertEqual(first.verificationState, .manual)
        XCTAssertEqual(first.paymentProfileID, "prof")

        SupportMutations.setAssignment(store: store, accountID: "A", creatorID: "c1", planID: "p1", profileID: "prof", state: .verified)
        let second = SupportMutations.recordPaymentIntent(store: store, accountID: "A", creatorID: "c1", planID: "p2", profileID: nil)
        XCTAssertEqual(second.planID, "p2")
        XCTAssertEqual(second.paymentProfileID, "prof")
        XCTAssertEqual(second.verificationState, .verified, "no new choice ⇒ existing verification is kept")

        let fresh = SupportMutations.recordPaymentIntent(store: store, accountID: "B", creatorID: "c1", planID: "p1", profileID: nil)
        XCTAssertEqual(fresh.verificationState, .unknown)
        XCTAssertNil(fresh.paymentProfileID)
    }

    /// The payment flow preselects the support's own profile; handing off with it unchanged is not a new choice.
    func testRecordPaymentIntentWithTheSameProfileKeepsVerification() throws {
        let store = try makeStore()
        let verifiedAt = Date(timeIntervalSince1970: 1_790_000_000)
        SupportMutations.setAssignment(store: store, accountID: "A", creatorID: "c1", planID: "p1", profileID: "prof", state: .verified,
                                       now: verifiedAt)
        let same = SupportMutations.recordPaymentIntent(store: store, accountID: "A", creatorID: "c1", planID: "p2", profileID: "prof")
        XCTAssertEqual(same.planID, "p2")
        XCTAssertEqual(same.verificationState, .verified)
        XCTAssertEqual(same.lastVerifiedAt, verifiedAt)

        let other = SupportMutations.recordPaymentIntent(store: store, accountID: "A", creatorID: "c1", planID: "p2", profileID: "other")
        XCTAssertEqual(other.paymentProfileID, "other")
        XCTAssertEqual(other.verificationState, .manual, "a different profile is a new choice")
    }

    func testDeleteProfileResetsAssignmentsToUnknown() throws {
        let store = try makeStore()
        guard case .success(let profile) = SupportMutations.saveProfile(PaymentProfileDraft(nickname: "Card", type: .creditCard), store: store),
              case .success(let other) = SupportMutations.saveProfile(PaymentProfileDraft(nickname: "PayPal", type: .paypal), store: store) else {
            return XCTFail()
        }
        SupportMutations.setAssignment(store: store, accountID: "A", creatorID: "c1", planID: nil, profileID: profile.id, state: .verified)
        SupportMutations.setAssignment(store: store, accountID: "B", creatorID: "c1", planID: nil, profileID: profile.id, state: .manual)
        SupportMutations.setAssignment(store: store, accountID: "C", creatorID: "c2", planID: nil, profileID: other.id, state: .manual)
        let profileID = profile.id

        XCTAssertEqual(SupportMutations.deleteProfile(id: profileID, store: store), 2)
        XCTAssertNil(store.first(#Predicate<PaymentProfile> { $0.id == profileID }))
        let byKey = Dictionary(uniqueKeysWithValues: allAssignments(store).map { ($0.key, $0) })
        XCTAssertNil(byKey["A|c1"]?.paymentProfileID)
        XCTAssertEqual(byKey["A|c1"]?.verificationState, .unknown)
        XCTAssertNil(byKey["A|c1"]?.lastVerifiedAt)
        XCTAssertEqual(byKey["B|c1"]?.verificationState, .unknown)
        XCTAssertEqual(byKey["C|c2"]?.paymentProfileID, other.id, "other profiles are untouched")
        XCTAssertEqual(byKey["C|c2"]?.verificationState, .manual)
    }

    func testAcknowledgeRemovesFromAttention() throws {
        let store = try makeStore()
        let s = Support(accountID: "A", creatorID: "c1", creatorName: "C", planID: "p", planTitle: "P", amount: 1_000, status: .missing)
        s.needsAttention = true
        store.context.insert(s)
        XCTAssertTrue(SupportSnapshot(s).isUnacknowledgedAttention)
        SupportMutations.acknowledge(s, store: store, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(s.acknowledgedAt, Date(timeIntervalSince1970: 100))
        XCTAssertFalse(SupportSnapshot(s).isUnacknowledgedAttention)
        XCTAssertTrue(s.needsAttention, "the observation itself is kept")
    }

    func testProfileUsageCountsOnlyActiveSupports() {
        let assignments = [
            AssignmentSnapshot(accountID: "A", creatorID: "c1", paymentProfileID: "p"),
            AssignmentSnapshot(accountID: "B", creatorID: "c1", paymentProfileID: "p"),
            AssignmentSnapshot(accountID: "C", creatorID: "c9", paymentProfileID: "p"),
            AssignmentSnapshot(accountID: "A", creatorID: "c2", paymentProfileID: nil),
        ]
        let supports = [
            SupportSnapshot(accountID: "A", creatorID: "c1", creatorName: "C1", amount: 500),
            SupportSnapshot(accountID: "B", creatorID: "c1", creatorName: "C1", amount: 500),
            SupportSnapshot(accountID: "A", creatorID: "c2", creatorName: "C2", amount: 500),
            SupportSnapshot(accountID: "C", creatorID: "c9", creatorName: "C9", amount: 500, status: .ended),
        ]
        let profiles = [PaymentProfileSnapshot(id: "p", nickname: "Card", type: .creditCard)]
        let counts = PaymentProfileUsage.counts(supports: supports, assignments: assignments, profiles: profiles)
        XCTAssertEqual(counts, ["p": 2])
    }

    func testProfileUsageCountsInheritedSupports() {
        let profiles = [PaymentProfileSnapshot(id: "visa", nickname: "Visa", type: .creditCard),
                        PaymentProfileSnapshot(id: "pp", nickname: "PayPal", type: .paypal)]
        let supports = [
            SupportSnapshot(accountID: "A", creatorID: "c1", creatorName: "C1", amount: 500, reportedPaymentMethod: "card"),
            SupportSnapshot(accountID: "A", creatorID: "c2", creatorName: "C2", amount: 500, reportedPaymentMethod: "card"),
            SupportSnapshot(accountID: "A", creatorID: "c3", creatorName: "C3", amount: 500, reportedPaymentMethod: "paypal"),
            SupportSnapshot(accountID: "A", creatorID: "c4", creatorName: "C4", amount: 500, reportedPaymentMethod: "card"),
            SupportSnapshot(accountID: "B", creatorID: "c1", creatorName: "C1", amount: 500, reportedPaymentMethod: "paypal"),
        ]
        let assignments = [
            AssignmentSnapshot(accountID: "A", creatorID: "c1"),                                 // placeholder ⇒ inherits
            AssignmentSnapshot(accountID: "A", creatorID: "c4", paymentProfileID: "pp", verificationState: .manual),
        ]
        let defaults = [AccountPaymentDefault(accountID: "A", profileID: "visa")]
        let counts = PaymentProfileUsage.counts(supports: supports, assignments: assignments, accountDefaults: defaults, profiles: profiles)
        // A|c1, A|c2 inherit visa; A|c3 is PayPal on FANBOX (default skipped, the PayPal guess is not counted);
        // A|c4 links pp itself; B has no default and B|c1's PayPal guess is not counted.
        XCTAssertEqual(counts, ["visa": 2, "pp": 1])
    }

    // MARK: Account default

    func testSetAndClearAccountDefault() throws {
        let store = try makeStore()
        let account = Account(id: "A", kind: .demo, displayName: "A")
        store.context.insert(account)
        store.save()
        let t1 = Date(timeIntervalSince1970: 1_790_000_000)
        let t2 = t1.addingTimeInterval(3_600)

        XCTAssertTrue(SupportMutations.setAccountDefault(store: store, accountID: "A", profileID: "visa", now: t1))
        XCTAssertEqual(account.defaultPaymentProfileID, "visa")
        XCTAssertNil(account.defaultPaymentVerifiedAt, "choosing a default is not a confirmation")
        XCTAssertFalse(SupportMutations.setAccountDefault(store: store, accountID: "A", profileID: "visa", now: t1), "no change")

        XCTAssertTrue(SupportMutations.setAccountDefault(store: store, accountID: "A", profileID: "visa", verified: true, now: t1))
        XCTAssertEqual(account.defaultPaymentVerifiedAt, t1)
        XCTAssertFalse(SupportMutations.setAccountDefault(store: store, accountID: "A", profileID: "visa", verified: true, now: t2),
                       "re-confirming keeps the first date")
        XCTAssertEqual(account.defaultPaymentVerifiedAt, t1)

        XCTAssertTrue(SupportMutations.setAccountDefault(store: store, accountID: "A", profileID: "mc", now: t2))
        XCTAssertEqual(account.defaultPaymentProfileID, "mc")
        XCTAssertNil(account.defaultPaymentVerifiedAt, "another profile drops the confirmation")

        XCTAssertTrue(SupportMutations.setAccountDefault(store: store, accountID: "A", profileID: nil, verified: true, now: t2))
        XCTAssertNil(account.defaultPaymentProfileID)
        XCTAssertNil(account.defaultPaymentVerifiedAt, "nothing to confirm without a profile")
        XCTAssertFalse(SupportMutations.setAccountDefault(store: store, accountID: "missing", profileID: "visa"))
    }

    func testDeletingAProfileClearsAccountDefaults() throws {
        let store = try makeStore()
        guard case .success(let card) = SupportMutations.saveProfile(PaymentProfileDraft(nickname: "Card", type: .creditCard), store: store),
              case .success(let other) = SupportMutations.saveProfile(PaymentProfileDraft(nickname: "PayPal", type: .paypal), store: store) else {
            return XCTFail()
        }
        let a = Account(id: "A", kind: .demo, displayName: "A")
        let b = Account(id: "B", kind: .demo, displayName: "B", enabled: false)
        let c = Account(id: "C", kind: .demo, displayName: "C")
        [a, b, c].forEach(store.context.insert)
        SupportMutations.setAccountDefault(store: store, accountID: "A", profileID: card.id, verified: true)
        SupportMutations.setAccountDefault(store: store, accountID: "B", profileID: card.id)
        SupportMutations.setAccountDefault(store: store, accountID: "C", profileID: other.id)

        SupportMutations.deleteProfile(id: card.id, store: store)
        XCTAssertNil(a.defaultPaymentProfileID)
        XCTAssertNil(a.defaultPaymentVerifiedAt)
        XCTAssertNil(b.defaultPaymentProfileID, "disabled accounts are cleared too")
        XCTAssertEqual(c.defaultPaymentProfileID, other.id, "other profiles are untouched")
    }

    /// Resolution happens at render time: changing the default changes every support that inherits it, and a support
    /// with its own profile keeps it.
    func testChangingTheDefaultUpdatesEveryInheritingSupport() throws {
        let store = try makeStore()
        guard case .success(let visa) = SupportMutations.saveProfile(
                PaymentProfileDraft(nickname: "楽天Visa", type: .creditCard, brand: "Visa", last4: "1234"), store: store),
              case .success(let master) = SupportMutations.saveProfile(
                PaymentProfileDraft(nickname: "三井住友", type: .creditCard, brand: "Mastercard", last4: "5678"), store: store) else {
            return XCTFail()
        }
        let account = Account(id: "A", kind: .demo, displayName: "A")
        store.context.insert(account)
        for creator in ["c1", "c2", "c3"] {
            let s = Support(accountID: "A", creatorID: creator, creatorName: creator, planID: "p-\(creator)", planTitle: "P", amount: 500)
            s.reportedPaymentMethod = "card"
            store.context.insert(s)
        }
        SupportMutations.setAssignment(store: store, accountID: "A", creatorID: "c3", planID: nil, profileID: master.id, state: .manual)

        func labels() -> [String: String] {
            let context = SupportPaymentContext(profiles: store.fetch(FetchDescriptor<PaymentProfile>()), accounts: store.accounts(),
                                                payments: [])
            let assignments = Dictionary(uniqueKeysWithValues: store.fetch(FetchDescriptor<SupportPaymentAssignment>()).map { ($0.key, $0) })
            return Dictionary(uniqueKeysWithValues: store.fetch(FetchDescriptorFactorySupport.allSupports()).map { s in
                (s.creatorID, context.summary(support: SupportSnapshot(s), assignment: assignments[s.key].map(AssignmentSnapshot.init)).cardLabel)
            })
        }

        XCTAssertEqual(labels(), ["c1": "カード", "c2": "カード", "c3": "三井住友•••5678"])
        SupportMutations.setAccountDefault(store: store, accountID: "A", profileID: visa.id)
        XCTAssertEqual(labels(), ["c1": "楽天Visa•••1234", "c2": "楽天Visa•••1234", "c3": "三井住友•••5678"])
        SupportMutations.setAccountDefault(store: store, accountID: "A", profileID: master.id)
        XCTAssertEqual(labels(), ["c1": "三井住友•••5678", "c2": "三井住友•••5678", "c3": "三井住友•••5678"])
        SupportMutations.setAccountDefault(store: store, accountID: "A", profileID: nil)
        XCTAssertEqual(labels()["c1"], "カード")
    }
}

final class SupportTextTests: XCTestCase {
    func testHistoryTexts() {
        XCTAssertEqual(SupportText.historyText(kind: .planChanged, oldAmount: 500, newAmount: 1_000), "¥500 → ¥1,000")
        XCTAssertEqual(SupportText.historyText(kind: .started, oldAmount: nil, newAmount: 3_000), "支援開始¥3,000")
        XCTAssertEqual(SupportText.historyText(kind: .ended, oldAmount: 500, newAmount: nil), "支援終了")
        XCTAssertEqual(SupportText.historyText(kind: .disappeared, oldAmount: 500, newAmount: nil), "支援中一覧から消えました")
        XCTAssertEqual(SupportText.historyText(kind: .restored, oldAmount: nil, newAmount: 500), "再び確認されました")
        XCTAssertEqual(SupportText.historyText(kind: .planChanged, oldAmount: nil, newAmount: nil, oldPlan: "A", newPlan: "B"), "プラン変更（A → B）")
    }

    func testVerificationLabelsNeverLookLikeFacts() {
        XCTAssertEqual(SupportText.verificationLabel(.verified), "確認済み")
        XCTAssertEqual(SupportText.verificationLabel(.inferred), "推定（未確認）")
        XCTAssertEqual(SupportText.verificationLabel(.manual), "手動設定")
        XCTAssertEqual(SupportText.verificationLabel(.unknown), "不明")
        XCTAssertEqual(VerificationState.allCases.filter(SupportText.isFact), [.verified])
    }

    func testObservedFactNeverAssertsPaymentFailure() {
        XCTAssertEqual(SupportText.observedFact(status: .missing, attentionReason: nil), "支援中一覧から消えました")
        XCTAssertEqual(SupportText.observedFact(status: .unknown, attentionReason: nil), "決済状態を確認できません")
        XCTAssertEqual(SupportText.observedFact(status: .missing, attentionReason: "決済に失敗しました"), "支援中一覧から消えました")
        XCTAssertEqual(SupportText.observedFact(status: .missing, attentionReason: "支援が一覧から消えました"), "支援が一覧から消えました")
        for status in SupportStatus.allCases {
            XCTAssertFalse(SupportText.observedFact(status: status, attentionReason: nil).contains("失敗"))
        }
        XCTAssertEqual(SupportText.currentText(status: .missing, amount: 1_000), "支援なし")
        XCTAssertEqual(SupportText.previousText(amount: 1_000), "¥1,000 / 月")
    }

    func testHistoryFilter() {
        XCTAssertTrue(SupportHistoryFilter.matches(accountID: "A", creatorID: "c", accountFilter: nil, creatorFilter: nil))
        XCTAssertTrue(SupportHistoryFilter.matches(accountID: "A", creatorID: "c", accountFilter: "A", creatorFilter: "c"))
        XCTAssertFalse(SupportHistoryFilter.matches(accountID: "A", creatorID: "c", accountFilter: "B", creatorFilter: nil))
        XCTAssertFalse(SupportHistoryFilter.matches(accountID: "A", creatorID: "c", accountFilter: nil, creatorFilter: "d"))
        let creators = SupportHistoryFilter.creators(in: [("c2", "Beta"), ("c1", "Alpha"), ("c2", "Beta renamed")])
        XCTAssertEqual(creators.map(\.id), ["c1", "c2"])
        XCTAssertEqual(creators.last?.name, "Beta")
    }
}

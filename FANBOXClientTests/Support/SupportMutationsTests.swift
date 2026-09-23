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
        let counts = PaymentProfileUsage.counts(assignments: assignments, activeSupportKeys: ["A|c1", "B|c1", "A|c2"])
        XCTAssertEqual(counts, ["p": 2])
    }
}

final class SupportTextTests: XCTestCase {
    func testHistoryTexts() {
        XCTAssertEqual(SupportText.historyText(kind: .planChanged, oldAmount: 500, newAmount: 1_000), "¥500 → ¥1,000")
        XCTAssertEqual(SupportText.historyText(kind: .started, oldAmount: nil, newAmount: 3_000), "支援開始 ¥3,000")
        XCTAssertEqual(SupportText.historyText(kind: .ended, oldAmount: 500, newAmount: nil), "支援終了")
        XCTAssertEqual(SupportText.historyText(kind: .disappeared, oldAmount: 500, newAmount: nil), "支援中一覧から消えました")
        XCTAssertEqual(SupportText.historyText(kind: .restored, oldAmount: nil, newAmount: 500), "再び確認されました")
        XCTAssertEqual(SupportText.historyText(kind: .planChanged, oldAmount: nil, newAmount: nil, oldPlan: "A", newPlan: "B"), "プラン変更 A → B")
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

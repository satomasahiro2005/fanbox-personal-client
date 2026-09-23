import SwiftData
import XCTest
@testable import FANBOXClient

/// Support anomaly detection (SPEC §10–§15, §24.1 決済要確認) and payment refresh frequency.
@MainActor
final class FixSyncNotifySupportTests: XCTestCase {
    private func attentionCount(_ h: SyncHarness, accountID: String) -> Int {
        let snapshots = h.store.supports(accountID: accountID).map(SupportSnapshot.init)
        return SupportAnalyzer.summarize(supports: snapshots, payments: []).attentionCount
    }

    // MARK: Acknowledgement vs. new anomalies

    func testNewDisappearanceAfterAcknowledgeIsAttentionAgain() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA")
        let c1 = SyncFixtures.support("c1", plan: "p1", fee: 500)
        h.store.applySupports([c1], account: a.context, source: .sync)
        h.store.applySupports([], account: a.context, source: .sync)
        let support = try XCTUnwrap(h.store.supports(accountID: a.id).first)
        XCTAssertTrue(SupportSnapshot(support).isUnacknowledgedAttention)

        SupportMutations.acknowledge(support, store: h.store)
        XCTAssertFalse(SupportSnapshot(support).isUnacknowledgedAttention)

        h.store.applySupports([c1], account: a.context, source: .sync)
        XCTAssertNil(support.acknowledgedAt, "a restored support starts clean")
        XCTAssertFalse(support.needsAttention)

        h.store.applySupports([], account: a.context, source: .sync)
        XCTAssertTrue(SupportSnapshot(support).isUnacknowledgedAttention, "a second disappearance is a new anomaly")
        XCTAssertEqual(attentionCount(h, accountID: a.id), 1)
    }

    // MARK: Shape drift / suspicious listings

    func testIncompleteListingNeverMarksSupportsMissing() async throws {
        let h = try SyncHarness()
        h.setClock(SyncFixtures.midMonthJST)
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update { $0.supports[a.id] = [SyncFixtures.support("c1", plan: "p1", fee: 500), SyncFixtures.support("c2", plan: "p2", fee: 300)] }
        await h.engine.sync(.supports, accountID: a.id, reason: .appLaunch)

        // plan.listSupporting drifted: one item lost its creatorId and was dropped.
        h.mock.update {
            $0.supports[a.id] = [SyncFixtures.support("c1", plan: "p1", fee: 500)]
            $0.supportProblems[a.id] = "id / creatorId のない項目 1 件"
        }
        var delivered: [String] = []
        h.engine.onNewNotificationEvents = { delivered += $0 }
        let outcome = await h.engine.sync(.supports, accountID: a.id, reason: .userRefresh)
        guard case .decoding(let endpoint, _)? = outcome.error else { return XCTFail("expected a decoding failure, got \(String(describing: outcome.error))") }
        XCTAssertEqual(endpoint, "plan.listSupporting")
        XCTAssertTrue(h.store.supports(accountID: a.id).allSatisfy(\.isActive), "a decoding artifact is not an observed disappearance")
        XCTAssertTrue(h.store.fetch(FetchDescriptor<SupportHistory>()).filter { $0.kind == .disappeared }.isEmpty)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertNotNil(h.store.syncState(accountID: a.id, resource: .supports).error)
    }

    func testEverySupportVanishingAtOnceNeedsASecondObservation() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA")
        let both = [SyncFixtures.support("c1", plan: "p1", fee: 500), SyncFixtures.support("c2", plan: "p2", fee: 300)]
        h.store.applySupports(both, account: a.context, source: .sync)

        var diff = h.store.applySupports([], account: a.context, source: .sync)
        XCTAssertTrue(diff.disappeared.isEmpty, "a single empty listing that wipes every support is not trusted yet")
        XCTAssertTrue(h.store.supports(accountID: a.id).allSatisfy(\.isActive))

        diff = h.store.applySupports([], account: a.context, source: .sync)
        XCTAssertEqual(Set(diff.disappeared), ["c1", "c2"], "confirmed by the next listing")
        XCTAssertTrue(h.store.supports(accountID: a.id).allSatisfy { $0.status == .missing && $0.needsAttention })

        // A strike that is not confirmed is forgotten.
        h.store.applySupports(both, account: a.context, source: .sync)
        h.store.applySupports([], account: a.context, source: .sync)
        h.store.applySupports(both, account: a.context, source: .sync)
        diff = h.store.applySupports([], account: a.context, source: .sync)
        XCTAssertTrue(diff.disappeared.isEmpty)
    }

    func testSupportAuditFlagsNullListAndDroppedItems() throws {
        let null = try FanboxFixtures.decodeBody(FanboxSupportingPlanAudit.self, #"{"plans":null}"#)
        XCTAssertNotNil(null.shapeProblem)
        XCTAssertTrue(null.items.isEmpty)

        let mixed = try FanboxFixtures.decodeBody(FanboxSupportingPlanAudit.self, FanboxFixtures.supportingPlansWrapped)
        XCTAssertNil(mixed.shapeProblem)
        XCTAssertEqual(mixed.items.count, 3)
        XCTAssertEqual(mixed.items.compactMap(FanboxAdapter.support).count, 2, "the id-less plan is dropped by the adapter")

        let bareWithJunk = try FanboxFixtures.decodeBody(FanboxSupportingPlanAudit.self, #"[{"id":"1","creatorId":"a"}, 42, null]"#)
        XCTAssertEqual(bareWithJunk.items.count, 1)
        XCTAssertEqual(bareWithJunk.undecodableCount, 2)

        let clean = try FanboxFixtures.decodeBody(FanboxSupportingPlanAudit.self, #"{"plans":[]}"#)
        XCTAssertNil(clean.shapeProblem)
        XCTAssertEqual(clean.undecodableCount, 0)

        XCTAssertThrowsError(try FanboxFixtures.decodeBody(FanboxSupportingPlanAudit.self, #"{"somethingElse":[]}"#))
    }

    func testFanboxListingReportsIncompleteness() async throws {
        let h = FanboxTestHarness()
        h.http.stub("plan.listSupporting", json: FanboxFixtures.envelope(FanboxFixtures.supportingPlansWrapped))
        let listing = try await h.source.supportingPlanListing(account: FanboxTestHarness.fan)
        XCTAssertEqual(listing.supports.map(\.creatorID), ["alice", "bob"])
        XCTAssertFalse(listing.isComplete)

        h.http.stub("plan.listSupporting", json: FanboxFixtures.envelope(#"{"plans":[{"id":"1","creatorId":"a","fee":100}]}"#))
        let clean = try await h.source.supportingPlanListing(account: FanboxTestHarness.fan)
        XCTAssertTrue(clean.isComplete)
        XCTAssertEqual(clean.supports.count, 1)
    }

    // MARK: History accuracy

    func testFirstSyncDoesNotRecordSupportStart() async throws {
        let h = try SyncHarness()
        h.setClock(SyncFixtures.midMonthJST)
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update { $0.supports[a.id] = [SyncFixtures.support("c1", plan: "p1", fee: 500)] }
        await h.engine.sync(.supports, accountID: a.id, reason: .appLaunch)
        XCTAssertTrue(h.store.fetch(FetchDescriptor<SupportHistory>()).isEmpty, "supports found by the first sync have no known start date")
        XCTAssertEqual(h.store.supports(accountID: a.id).count, 1)

        h.mock.update { $0.supports[a.id] = [SyncFixtures.support("c1", plan: "p1", fee: 500), SyncFixtures.support("c2", plan: "p9", fee: 900)] }
        await h.engine.sync(.supports, accountID: a.id, reason: .userRefresh)
        let history = h.store.fetch(FetchDescriptor<SupportHistory>())
        XCTAssertEqual(history.map(\.kind), [.started])
        XCTAssertEqual(history.first?.creatorID, "c2")
    }

    // MARK: Verification vs. contradicting observations (SPEC §13)

    func testVerifiedAssignmentIsDowngradedByContradictions() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA")
        var card = SyncFixtures.support("c1", plan: "p1", fee: 500)
        card.paymentMethod = "gmo_card"
        h.store.applySupports([card], account: a.context, source: .sync)
        let assignment = try XCTUnwrap(h.store.fetch(FetchDescriptor<SupportPaymentAssignment>()).first)
        func verify() {
            assignment.verificationState = .verified
            assignment.paymentProfileID = "profile-1"
            assignment.lastVerifiedAt = .now
            h.store.save()
        }

        verify()
        h.store.applySupports([card], account: a.context, source: .sync)
        XCTAssertEqual(assignment.verificationState, .verified, "an unchanged observation keeps the verification")

        var paypal = card
        paypal.paymentMethod = "PAYPAL"
        h.store.applySupports([paypal], account: a.context, source: .sync)
        XCTAssertEqual(assignment.verificationState, .manual, "payment method changed on FANBOX")
        XCTAssertEqual(assignment.paymentProfileID, "profile-1", "the user's choice is kept")
        XCTAssertNil(assignment.lastVerifiedAt)

        verify()
        var upgraded = paypal
        upgraded.planID = "p2"
        upgraded.fee = 1000
        h.store.applySupports([upgraded], account: a.context, source: .sync)
        XCTAssertEqual(assignment.verificationState, .manual, "plan changed")

        verify()
        h.store.applySupports([], account: a.context, source: .sync)
        XCTAssertEqual(assignment.verificationState, .manual, "support disappeared")

        verify()
        h.store.applySupports([upgraded], account: a.context, source: .sync)
        XCTAssertEqual(assignment.verificationState, .manual, "support restored")
    }

    // MARK: 決済要確認 (paymentAttention)

    func testUnpaidSignalsCreatePaymentAttentionAfterBaseline() async throws {
        let h = try SyncHarness()
        h.setClock(SyncFixtures.midMonthJST)
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        var delivered: [String] = []
        h.engine.onNewNotificationEvents = { delivered += $0 }
        h.mock.update {
            $0.supports[a.id] = [SyncFixtures.support("c1", plan: "p1", fee: 500), SyncFixtures.support("c2", plan: "p2", fee: 300)]
            $0.paymentStatuses[a.id] = RemotePaymentStatus(hasUnpaidPayments: false, unpaidRecords: [])
        }
        await h.engine.sync(.supports, accountID: a.id, reason: .appLaunch)
        XCTAssertEqual(h.store.account(id: a.id)?.hasUnpaidPayments, false)
        XCTAssertNotNil(h.store.account(id: a.id)?.unpaidPaymentsCheckedAt)
        XCTAssertTrue(delivered.isEmpty)

        // FANBOX now lists an unpaid payment for c2.
        let unpaid = RemotePayment(id: "u1", creatorID: "c2", creatorName: "Creator c2", amount: 300, paidAt: .now, paymentMethod: nil)
        h.mock.update { $0.paymentStatuses[a.id] = RemotePaymentStatus(hasUnpaidPayments: true, unpaidRecords: [unpaid]) }
        h.advanceClock(by: SyncEngine.userRefreshDedupeInterval + 1)
        await h.engine.sync(.supports, accountID: a.id, reason: .userRefresh)
        XCTAssertEqual(delivered.count, 1)
        let event = try XCTUnwrap(h.store.notificationEvent(id: delivered[0]))
        XCTAssertEqual(event.type, .paymentAttention)
        XCTAssertEqual(event.priority, .critical)
        XCTAssertEqual(event.creatorID, "c2")
        XCTAssertFalse(SupportText.assertsCause(event.message), "observed facts only (SPEC §15)")
        let c2 = try XCTUnwrap(h.store.supports(accountID: a.id).first { $0.creatorID == "c2" })
        XCTAssertTrue(c2.needsAttention)
        XCTAssertEqual(c2.attentionReason, LocalStore.paymentAttentionReason)
        XCTAssertEqual(SupportText.observedFact(status: c2.status, attentionReason: c2.attentionReason), LocalStore.paymentAttentionReason)
        XCTAssertEqual(h.store.account(id: a.id)?.hasUnpaidPayments, true)

        // The same observation is not announced twice; a later supports sync keeps the attention.
        h.advanceClock(by: SyncEngine.userRefreshDedupeInterval + 1)
        await h.engine.sync(.supports, accountID: a.id, reason: .userRefresh)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertTrue(c2.needsAttention)

        // Cleared once FANBOX no longer lists it.
        h.mock.update { $0.paymentStatuses[a.id] = RemotePaymentStatus(hasUnpaidPayments: false, unpaidRecords: []) }
        h.advanceClock(by: SyncEngine.userRefreshDedupeInterval + 1)
        await h.engine.sync(.supports, accountID: a.id, reason: .userRefresh)
        XCTAssertFalse(c2.needsAttention)
        XCTAssertNil(c2.attentionReason)
    }

    func testUnpaidFlagWithoutRecordsCreatesAccountLevelEvent() async throws {
        let h = try SyncHarness()
        h.setClock(SyncFixtures.midMonthJST)
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        var delivered: [String] = []
        h.engine.onNewNotificationEvents = { delivered += $0 }
        h.mock.update { $0.paymentStatuses[a.id] = RemotePaymentStatus(hasUnpaidPayments: false, unpaidRecords: nil) }
        await h.engine.sync(.supports, accountID: a.id, reason: .appLaunch)
        h.mock.update { $0.paymentStatuses[a.id] = RemotePaymentStatus(hasUnpaidPayments: true, unpaidRecords: nil) }
        h.advanceClock(by: SyncEngine.paymentStatusInterval + 1)
        await h.engine.sync(.supports, accountID: a.id, reason: .backgroundRefresh)
        XCTAssertEqual(delivered.count, 1)
        let event = try XCTUnwrap(h.store.notificationEvent(id: delivered[0]))
        XCTAssertEqual(event.type, .paymentAttention)
        XCTAssertNil(event.creatorID)
        XCTAssertEqual(NotificationService.destination(for: event), .support(nil))
    }

    func testDisappearanceOnFirstDaysOfMonthIsPaymentAttention() async throws {
        let h = try SyncHarness()
        h.setClock(SyncFixtures.dayOfCurrentMonthJST(2))
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        var delivered: [String] = []
        h.engine.onNewNotificationEvents = { delivered += $0 }
        h.mock.update { $0.supports[a.id] = [SyncFixtures.support("c1", plan: "p1", fee: 500), SyncFixtures.support("c2", plan: "p2", fee: 300)] }
        await h.engine.sync(.supports, accountID: a.id, reason: .appLaunch)
        h.mock.update { $0.supports[a.id] = [SyncFixtures.support("c2", plan: "p2", fee: 300)] }
        await h.engine.sync(.supports, accountID: a.id, reason: .userRefresh)

        let events = delivered.compactMap { h.store.notificationEvent(id: $0) }
        XCTAssertEqual(events.map(\.type), [.paymentAttention], "one Critical event instead of a second 支援状態変化 banner")
        XCTAssertEqual(events.first?.creatorID, "c1")
        XCTAssertFalse(SupportText.assertsCause(events.first?.message ?? "失敗"))
        XCTAssertEqual(h.store.supports(accountID: a.id).first { $0.creatorID == "c1" }?.status, .missing)
    }

    // MARK: Payment history frequency (docs/API.md §19.2)

    func testPaidRecordsAreFetchedAtLowFrequency() async throws {
        let h = try SyncHarness()
        h.setClock(SyncFixtures.midMonthJST)
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)

        await h.engine.sync(.supports, accountID: a.id, reason: .appLaunch)
        XCTAssertEqual(h.mock.count("payments|"), 1, "first launch fetches the paid history once")

        // Support screen refresh: supports then payments back to back → no second listPaid.
        let explicit = await h.engine.sync(.payments, accountID: a.id, reason: .userRefresh)
        XCTAssertNil(explicit.error)
        XCTAssertEqual(h.mock.count("payments|"), 1)

        // Background refreshes within the automatic interval never download it again.
        h.advanceClock(by: 60 * 60)
        await h.engine.sync(.supports, accountID: a.id, reason: .backgroundRefresh)
        await h.engine.syncLightweight(reason: .backgroundRefresh)
        XCTAssertEqual(h.mock.count("payments|"), 1)

        // A user refresh later does refresh it, once.
        await h.engine.sync(.supports, accountID: a.id, reason: .userRefresh)
        await h.engine.sync(.payments, accountID: a.id, reason: .userRefresh)
        XCTAssertEqual(h.mock.count("payments|"), 2)

        // After the automatic interval, background refresh fetches it again.
        h.advanceClock(by: SyncEngine.paymentsAutomaticInterval + 1)
        await h.engine.sync(.supports, accountID: a.id, reason: .backgroundRefresh)
        XCTAssertEqual(h.mock.count("payments|"), 3)
    }
}

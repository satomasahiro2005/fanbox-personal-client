import SwiftData
import XCTest
@testable import FANBOXClient

/// Stop observations (creator.listFollowing `isStopped`), stop-explained disappearances, the `.webBridge` observed
/// source of post-payment re-syncs, and payment records without an amount.
@MainActor
final class FixSupportSyncTests: XCTestCase {
    private func context(_ account: Account) -> AccountContext { account.context }

    private func stopped(_ creatorID: String, supported: Bool = true, stopped: Bool? = true) -> RemoteCreator {
        RemoteCreator(creatorID: creatorID, name: "Creator \(creatorID)", isFollowed: true, isSupported: supported, isStopped: stopped)
    }

    private func history(_ store: LocalStore, creatorID: String) -> [SupportHistory] {
        store.fetch(FetchDescriptor<SupportHistory>(predicate: #Predicate { $0.creatorID == creatorID },
                                                    sortBy: [SortDescriptor(\.timestamp)]))
    }

    // MARK: LocalStore

    func testFollowingStopFlagMarksActiveSupportAndCanBeCleared() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.applySupports([SyncFixtures.support("c1", plan: "p1", fee: 500), SyncFixtures.support("c2", plan: "p2", fee: 1_000)],
                              account: context(a), source: .sync)
        h.store.applyFollowing([stopped("c1"), stopped("c2", stopped: nil)], account: context(a))
        let rows = Dictionary(uniqueKeysWithValues: h.store.supports(accountID: a.id).map { ($0.creatorID, $0) })
        XCTAssertNotNil(rows["c1"]?.stoppingObservedAt)
        XCTAssertNil(rows["c2"]?.stoppingObservedAt, "unknown isStopped leaves the row alone")
        XCTAssertEqual(rows["c1"]?.status, .active, "still valid until month end")

        let summary = SupportAnalyzer.summary(store: h.store)
        XCTAssertEqual(summary.recurringMonthly, 1_500)
        XCTAssertEqual(summary.nextMonthPlanned, 1_000)

        h.store.applyFollowing([stopped("c1", stopped: false)], account: context(a))
        XCTAssertNil(h.store.supports(accountID: a.id).first { $0.creatorID == "c1" }?.stoppingObservedAt, "resumed")
    }

    func testStoppedSupportLeavingTheListIsEndedNotAnAnomaly() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.applySupports([SyncFixtures.support("c1", plan: "p1", fee: 500)], account: context(a), source: .sync)
        h.store.applyFollowing([stopped("c1")], account: context(a))

        let (diff, rows) = h.store.applySupportsDetailed([], account: context(a), source: .sync)
        XCTAssertEqual(diff.ended, ["c1"])
        XCTAssertTrue(diff.disappeared.isEmpty)
        let s = try XCTUnwrap(h.store.supports(accountID: a.id).first)
        XCTAssertEqual(s.status, .ended)
        XCTAssertFalse(s.needsAttention)
        XCTAssertNil(s.attentionReason)
        XCTAssertEqual(rows.map(\.kind), [.ended])
        XCTAssertEqual(SupportText.historyText(rows[0]), "支援終了")
        XCTAssertFalse(h.store.creator(id: "c1")?.supportedByAccountIDs.contains(a.id) ?? true)
    }

    func testUserStopMarkExplainsDisappearanceButAStaleOneDoesNot() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.applySupports([SyncFixtures.support("c1", plan: "p1", fee: 500), SyncFixtures.support("c2", plan: "p2", fee: 700)],
                              account: context(a), source: .sync)
        let rows = Dictionary(uniqueKeysWithValues: h.store.supports(accountID: a.id).map { ($0.creatorID, $0) })
        XCTAssertTrue(SupportMutations.setUserStopMark(try XCTUnwrap(rows["c1"]), marked: true, store: h.store))
        rows["c2"]?.userStopMarkedAt = Date.now.addingTimeInterval(-100 * 86_400)   // ~3 months ago

        let (diff, _) = h.store.applySupportsDetailed([], account: context(a), source: .sync)
        XCTAssertEqual(diff.ended, ["c1"])
        XCTAssertEqual(diff.disappeared, ["c2"])
        XCTAssertEqual(rows["c1"]?.status, .ended)
        XCTAssertEqual(rows["c2"]?.status, .missing)
        XCTAssertEqual(rows["c2"]?.needsAttention, true)
    }

    func testRestartClearsStopSignals() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.applySupports([SyncFixtures.support("c1", plan: "p1", fee: 500)], account: context(a), source: .sync)
        h.store.applyFollowing([stopped("c1")], account: context(a))
        let s = try XCTUnwrap(h.store.supports(accountID: a.id).first)
        s.userStopMarkedAt = .now
        h.store.applySupports([], account: context(a), source: .sync)
        XCTAssertEqual(s.status, .ended)

        let (diff, _) = h.store.applySupportsDetailed([SyncFixtures.support("c1", plan: "p1", fee: 500)], account: context(a), source: .sync)
        XCTAssertEqual(diff.started, ["c1"])
        XCTAssertEqual(s.status, .active)
        XCTAssertNil(s.stoppingObservedAt)
        XCTAssertNil(s.userStopMarkedAt)
    }

    func testLaterStopObservationExplainsARecentMissingSupport() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.applySupports([SyncFixtures.support("c1", plan: "p1", fee: 500)], account: context(a), source: .sync)
        h.store.applySupports([], account: context(a), source: .sync)
        let s = try XCTUnwrap(h.store.supports(accountID: a.id).first)
        XCTAssertEqual(s.status, .missing)
        XCTAssertTrue(s.needsAttention)

        h.store.applyFollowing([stopped("c1")], account: context(a))
        XCTAssertEqual(s.status, .ended)
        XCTAssertFalse(s.needsAttention, "explained by FANBOX: leaves 要確認")
        XCTAssertEqual(history(h.store, creatorID: "c1").map(\.kind), [.started, .disappeared, .ended])
        XCTAssertTrue(SupportAnalyzer.attentionItems(h.store.supports(accountID: a.id).map(SupportSnapshot.init)).isEmpty)
    }

    func testUserStopMarkMutation() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.applySupports([SyncFixtures.support("c1", plan: "p1", fee: 500)], account: context(a), source: .sync)
        XCTAssertTrue(SupportMutations.setUserStopMark(store: h.store, accountID: a.id, creatorID: "c1", marked: true))
        let s = try XCTUnwrap(h.store.supports(accountID: a.id).first)
        XCTAssertTrue(SupportMutations.hasEffectiveUserStopMark(s))
        XCTAssertEqual(SupportSnapshot(s).scheduledStop(), .userMarked)
        XCTAssertTrue(SupportMutations.setUserStopMark(s, marked: false, store: h.store))
        XCTAssertNil(s.userStopMarkedAt)
        XCTAssertFalse(SupportMutations.setUserStopMark(s, marked: false, store: h.store), "nothing to clear")
        s.status = .missing
        XCTAssertFalse(SupportMutations.setUserStopMark(s, marked: true, store: h.store), "only active supports")
        XCTAssertFalse(SupportMutations.setUserStopMark(store: h.store, accountID: a.id, creatorID: "nope", marked: true))
    }

    func testPaymentWithoutAmountIsFlaggedAndKeepsAKnownAmount() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let paidAt = Date.now
        h.store.upsertPayments([RemotePayment(id: "x", creatorID: "c1", creatorName: nil, amount: 0, paidAt: paidAt, paymentMethod: nil,
                                              isAmountReported: false),
                                RemotePayment(id: "y", creatorID: "c2", creatorName: nil, amount: 800, paidAt: paidAt, paymentMethod: nil)],
                               account: context(a))
        var records = Dictionary(uniqueKeysWithValues: h.store.fetch(FetchDescriptor<PaymentRecord>()).map { ($0.paymentID, $0) })
        XCTAssertEqual(records["x"]?.amountUnknown, true)
        XCTAssertEqual(PaymentSnapshot(try XCTUnwrap(records["x"])).isAmountKnown, false)
        XCTAssertNil(records["y"]?.amountUnknown)

        h.store.upsertPayments([RemotePayment(id: "x", creatorID: "c1", creatorName: nil, amount: 300, paidAt: paidAt, paymentMethod: nil),
                                RemotePayment(id: "y", creatorID: "c2", creatorName: nil, amount: 0, paidAt: paidAt, paymentMethod: nil,
                                              isAmountReported: false)],
                               account: context(a))
        records = Dictionary(uniqueKeysWithValues: h.store.fetch(FetchDescriptor<PaymentRecord>()).map { ($0.paymentID, $0) })
        XCTAssertEqual(records["x"]?.amount, 300)
        XCTAssertNil(records["x"]?.amountUnknown, "reported later → known")
        XCTAssertEqual(records["y"]?.amount, 800, "a known amount is not overwritten by a missing one")
        XCTAssertNil(records["y"]?.amountUnknown)
    }

    // MARK: SyncEngine

    func testObservedSourceMapping() {
        XCTAssertEqual(SyncEngine.supportObservedSource(reason: .afterWrite, kind: .fanbox), .webBridge)
        XCTAssertEqual(SyncEngine.supportObservedSource(reason: .backgroundRefresh, kind: .fanbox), .backgroundSync)
        XCTAssertEqual(SyncEngine.supportObservedSource(reason: .notification, kind: .fanbox), .notification)
        XCTAssertEqual(SyncEngine.supportObservedSource(reason: .userRefresh, kind: .fanbox), .sync)
        XCTAssertEqual(SyncEngine.supportObservedSource(reason: .afterWrite, kind: .demo), .demo)
        XCTAssertEqual(SupportText.observedSourceLabel(.webBridge), "Web操作後に観測")
    }

    func testAfterPaymentResyncLabelsHistoryAsWebBridge() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update { $0.supports[a.id] = [SyncFixtures.support("c1", plan: "p1", fee: 500)] }
        await h.engine.sync(.supports, accountID: a.id, reason: .appLaunch)
        h.mock.update { $0.supports[a.id] = [SyncFixtures.support("c1", plan: "p2", fee: 1_000)] }
        await h.engine.sync(.supports, accountID: a.id, reason: .afterWrite)
        let rows = history(h.store, creatorID: "c1")
        // The first sync is a baseline (supports that already existed are not "支援開始"), so only the change is recorded.
        XCTAssertEqual(rows.map(\.kind), [.planChanged])
        XCTAssertEqual(rows.last?.observedSource, .webBridge)
        XCTAssertEqual(h.mock.count("following|"), 0, "no support vanished → listFollowing is not read")
    }

    func testVanishedSupportIsCheckedAgainstFollowingAndEndsWithoutAnomaly() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        var delivered: [String] = []
        h.engine.onNewNotificationEvents = { ids in delivered += ids }
        h.mock.update { $0.supports[a.id] = [SyncFixtures.support("c1", plan: "p1", fee: 500)] }
        await h.engine.sync(.supports, accountID: a.id, reason: .appLaunch)

        h.mock.update {
            $0.supports[a.id] = []
            $0.following[a.id] = [RemoteCreator(creatorID: "c1", name: "Creator c1", isFollowed: true, isSupported: true, isStopped: true)]
        }
        let outcome = await h.engine.sync(.supports, accountID: a.id, reason: .backgroundRefresh)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.newItemIDs, ["c1"])
        XCTAssertEqual(h.mock.count("following|"), 1)
        let s = try XCTUnwrap(h.store.supports(accountID: a.id).first)
        XCTAssertEqual(s.status, .ended)
        XCTAssertFalse(s.needsAttention)
        let event = try XCTUnwrap(delivered.first.flatMap { h.store.notificationEvent(id: $0) })
        XCTAssertEqual(event.message, "支援終了")
    }

    func testUnexplainedDisappearanceStaysAnObservedAnomaly() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update { $0.supports[a.id] = [SyncFixtures.support("c1", plan: "p1", fee: 500)] }
        await h.engine.sync(.supports, accountID: a.id, reason: .appLaunch)
        h.mock.update { $0.supports[a.id] = [] }   // following returns [] → nothing explains it
        let outcome = await h.engine.sync(.supports, accountID: a.id, reason: .userRefresh)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(h.store.supports(accountID: a.id).first?.status, .missing)
        XCTAssertEqual(h.store.supports(accountID: a.id).first?.needsAttention, true)
    }

    // MARK: Adapter

    func testAdapterKeepsStopFlagAndFlagsMissingPaidAmount() throws {
        let body = try FanboxFixtures.decodeBody(FanboxPaymentListBody.self,
            #"[{"id":"1","paymentDatetime":"2026-10-01T00:30:00+09:00"},{"id":"2","paidAmount":500,"paymentDatetime":"2026-10-01T00:30:00+09:00"}]"#)
        let payments = FanboxAdapter.payments(body.items)
        let byID = Dictionary(uniqueKeysWithValues: payments.map { ($0.id, $0) })
        XCTAssertEqual(byID["1"]?.isAmountReported, false)
        XCTAssertEqual(byID["2"]?.isAmountReported, true)
        XCTAssertEqual(byID["2"]?.amount, 500)

        let creators = try FanboxFixtures.decodeBody(FanboxCreatorListBody.self,
            #"[{"creatorId":"alice","user":{"userId":"1","name":"Alice"},"isFollowed":true,"isSupported":true,"isStopped":true}]"#)
        let alice = try XCTUnwrap(creators.items.compactMap(FanboxAdapter.creator).first)
        XCTAssertEqual(alice.isStopped, true)
        XCTAssertEqual(alice.isSupported, true)
    }
}

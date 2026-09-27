import SwiftData
import XCTest
@testable import FANBOXClient

/// Several accounts exist to support the same creator more than once (FANBOX allows one plan per account per creator,
/// SPEC §0 / §46). Supports and their state events therefore stay one per account: per-creator totals add them up, and
/// one account's stop, change or payment problem is never merged into another account's support of the same creator.
@MainActor
final class MultiAccountSupportTests: XCTestCase {
    // MARK: Mock FANBOX

    func testSupportEventsOfASharedCreatorStayOnePerAccount() async throws {
        let h = try SyncHarness()
        h.setClock(SyncFixtures.midMonthJST)
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        h.mock.update {
            $0.supports[a.id] = [SyncFixtures.support("c1", plan: "p500", fee: 500)]
            $0.supports[b.id] = [SyncFixtures.support("c1", plan: "p1000", fee: 1000)]
        }
        await h.engine.sync(.supports, accountID: a.id, reason: .appLaunch)
        await h.engine.sync(.supports, accountID: b.id, reason: .appLaunch)
        let snapshots = h.store.fetch(FetchDescriptorFactorySupport.allSupports()).map(SupportSnapshot.init)
        let group = try XCTUnwrap(SupportAnalyzer.byCreator(supports: snapshots, accountOrder: [a.id, b.id]).first)
        XCTAssertEqual(group.lines.map(\.support.accountID), [a.id, b.id], "one line per account")
        XCTAssertEqual(group.total, 1500, "the creator total adds up both accounts")

        var delivered: [String] = []
        h.engine.onNewNotificationEvents = { delivered += $0 }
        // B stops first while A keeps supporting: only B's event.
        h.mock.update { $0.supports[b.id] = [] }
        await h.engine.sync(.supports, accountID: b.id, reason: .backgroundRefresh)
        await h.engine.sync(.supports, accountID: a.id, reason: .backgroundRefresh)
        XCTAssertEqual(delivered.count, 1)
        let first = try XCTUnwrap(h.store.notificationEvent(id: delivered[0]))
        XCTAssertEqual(first.type, .supportChanged)
        XCTAssertEqual(first.accountIDs, [b.id])
        XCTAssertEqual(h.store.supports(accountID: a.id).first?.status, .active)

        // A's later change of the same creator is its own event, not a duplicate of B's.
        h.mock.update { $0.supports[a.id] = [] }
        await h.engine.sync(.supports, accountID: a.id, reason: .backgroundRefresh)
        XCTAssertEqual(delivered.count, 2)
        let events = delivered.compactMap { h.store.notificationEvent(id: $0) }
        XCTAssertEqual(Set(events.map(\.id)).count, 2)
        XCTAssertEqual(events.map(\.accountIDs), [[b.id], [a.id]])
        XCTAssertTrue(events.allSatisfy { $0.type == .supportChanged && $0.creatorID == "c1" })
    }

    func testPaymentAttentionForTheSameCreatorIsOnePerAccount() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        let forA = h.store.recordPaymentAttentionEvents(.unpaidRecord, creatorIDs: ["c1"], account: a.context, accountName: "A")
        let forB = h.store.recordPaymentAttentionEvents(.unpaidRecord, creatorIDs: ["c1"], account: b.context, accountName: "B")
        XCTAssertEqual(forA.count, 1)
        XCTAssertEqual(forB.count, 1)
        XCTAssertNotEqual(forA, forB)
        XCTAssertEqual(h.store.notificationEvent(id: forA[0])?.accountIDs, [a.id])
        XCTAssertEqual(h.store.notificationEvent(id: forB[0])?.accountIDs, [b.id])
        // Still announced once per account, creator and month.
        XCTAssertTrue(h.store.recordPaymentAttentionEvents(.unpaidRecord, creatorIDs: ["c1"], account: a.context,
                                                           accountName: "A").isEmpty)
    }

    func testTheSamePostSeenByTwoAccountsIsOneEvent() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        let idsA = h.store.upsertNotifications([SyncFixtures.notification("bell-a", type: .newPost, postID: "p1")], account: a.context)
        let idsB = h.store.upsertNotifications([SyncFixtures.notification("bell-b", type: .newPost, postID: "p1")], account: b.context)
        XCTAssertEqual(idsA.count, 1)
        XCTAssertTrue(idsB.isEmpty, "B's copy joins A's event")
        XCTAssertEqual(Set(h.store.notificationEvent(id: idsA[0])?.accountIDs ?? []), [a.id, b.id])
    }

    // MARK: Demo accounts

    private struct DemoOnlyProvider: RemoteDataSourceProvider {
        let demo: DemoRemoteDataSource
        func dataSource(for account: AccountContext) -> RemoteDataSource { demo }
    }

    private func addDemoAccount(_ store: LocalStore, _ name: String) -> Account {
        let account = Account(kind: .demo, displayName: name, pixivUserID: "demo-multi-\(name)", creatorID: nil,
                              isMain: store.accounts(includeDisabled: true).isEmpty,
                              sortOrder: store.accounts(includeDisabled: true).count, sessionState: .valid)
        store.context.insert(account)
        store.save()
        return account
    }

    private func creatorGroup(_ creatorID: String, store: LocalStore, order: [String]) -> CreatorSupportGroup? {
        let snapshots = store.fetch(FetchDescriptorFactorySupport.allSupports()).map(SupportSnapshot.init)
        return SupportAnalyzer.byCreator(supports: snapshots, accountOrder: order).first { $0.creatorID == creatorID }
    }

    func testDemoAccountsKeepTheirOwnSupportsOfTheSameCreators() async throws {
        let store = LocalStore(container: try PersistenceController.makeContainer(inMemory: true))
        let settings = AppSettings(defaults: UserDefaults(suiteName: "multi-account-demo-\(UUID().uuidString)")!)
        let network = NetworkModeController(settings: settings, policyStore: NetworkPolicyStore())
        let world = DemoWorld(now: Date(), latencyScale: 0)
        let engine = SyncEngine(store: store, remote: DemoOnlyProvider(demo: DemoRemoteDataSource(policy: nil, world: world)),
                                settings: settings, network: network)
        let midMonth = SyncFixtures.midMonthJST
        engine.clock = { midMonth }
        let first = addDemoAccount(store, "A"), second = addDemoAccount(store, "B")
        let firstIsA = await world.profile(for: first.context) == .viewerA
        let (a, b) = firstIsA ? (first, second) : (second, first)

        await engine.sync(.supports, accountID: a.id, reason: .appLaunch)
        await engine.sync(.supports, accountID: b.id, reason: .appLaunch)
        await engine.sync(.creators, accountID: a.id, reason: .appLaunch)
        await engine.sync(.creators, accountID: b.id, reason: .appLaunch)

        // Both accounts support ミント and シオン on their own plans; the creator totals add them up.
        let mint = try XCTUnwrap(creatorGroup("demo-mint", store: store, order: [a.id, b.id]))
        XCTAssertEqual(mint.lines.map(\.support.accountID), [a.id, b.id])
        XCTAssertEqual(mint.total, 1500)
        let shion = try XCTUnwrap(creatorGroup("demo-shion", store: store, order: [a.id, b.id]))
        XCTAssertEqual(shion.lines.map(\.support.accountID), [a.id, b.id])

        // A stops シオン, B keeps it: only A's support leaves next month's total.
        XCTAssertNotNil(store.supports(accountID: a.id).first { $0.creatorID == "demo-shion" }?.stoppingObservedAt)
        XCTAssertNil(store.supports(accountID: b.id).first { $0.creatorID == "demo-shion" }?.stoppingObservedAt)
        let snapshots = store.fetch(FetchDescriptorFactorySupport.allSupports()).map(SupportSnapshot.init)
        let summary = SupportAnalyzer.summarize(supports: snapshots, payments: [], now: .now)
        XCTAssertEqual(summary.scheduledStopObservedCount, 1)
        XCTAssertEqual(summary.nextMonthPlanned, summary.recurringMonthly - 100)

        // B's ミント support disappears on its next listing; A keeps supporting ミント.
        var delivered: [String] = []
        engine.onNewNotificationEvents = { delivered += $0 }
        await engine.sync(.supports, accountID: b.id, reason: .backgroundRefresh)
        await engine.sync(.supports, accountID: a.id, reason: .backgroundRefresh)
        let mintEvents = delivered.compactMap { store.notificationEvent(id: $0) }.filter { $0.creatorID == "demo-mint" }
        XCTAssertEqual(mintEvents.map(\.type), [.supportChanged])
        XCTAssertEqual(mintEvents.first?.accountIDs, [b.id], "the event names only the account that lost the support")
        XCTAssertEqual(store.supports(accountID: b.id).first { $0.creatorID == "demo-mint" }?.status, .missing)
        XCTAssertEqual(store.supports(accountID: a.id).first { $0.creatorID == "demo-mint" }?.status, .active)
        XCTAssertEqual(creatorGroup("demo-mint", store: store, order: [a.id, b.id])?.total, 1000, "A's support stays in the total")
    }
}

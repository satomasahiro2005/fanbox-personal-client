import XCTest
import SwiftData
@testable import FANBOXClient

@MainActor
final class FoundationTests: XCTestCase {
    func testInMemoryContainerOpens() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = LocalStore(container: container)
        XCTAssertTrue(store.accounts().isEmpty)
    }

    func testPreviewEnvironmentSeedsDemoAccounts() {
        let env = AppEnvironment.preview()
        XCTAssertEqual(env.store.accounts().count, 3)
        XCTAssertEqual(env.store.mainAccount()?.displayName, "Demo A")
    }

    func testAccountSelectorPriorityOrder() {
        let base = AccountCandidate(accountID: "x", isCached: false, canView: false, sessionValid: false, planFee: 0, isMain: false, enabled: true)
        var cached = base; cached.accountID = "cached"; cached.isCached = true
        var viewable = base; viewable.accountID = "viewable"; viewable.canView = true; viewable.sessionValid = true; viewable.planFee = 5000
        XCTAssertEqual(AccountSelector.select([viewable, cached]), "cached")
        var main = base; main.accountID = "main"; main.isMain = true
        XCTAssertEqual(AccountSelector.select([main, viewable]), "viewable")
        var rich = viewable; rich.accountID = "rich"; rich.planFee = 10000
        XCTAssertEqual(AccountSelector.select([viewable, rich]), "rich")
        var disabled = cached; disabled.enabled = false
        XCTAssertEqual(AccountSelector.select([disabled, main]), "main")
    }

    func testMediaPolicyTable() {
        var p = NetworkPolicySnapshot.default
        p.mode = .extreme
        XCTAssertEqual(MediaPolicy.decide(kind: .image, variant: .display, trigger: .automatic, policy: p), .manualOnly)
        XCTAssertEqual(MediaPolicy.decide(kind: .image, variant: .display, trigger: .manual, policy: p), .allowed)
        XCTAssertEqual(MediaPolicy.decide(kind: .image, variant: .thumbnail, trigger: .prefetch, policy: p), .blocked)
        p.mode = .lowData
        XCTAssertEqual(MediaPolicy.decide(kind: .image, variant: .original, trigger: .prefetch, policy: p), .blocked)
        XCTAssertEqual(MediaPolicy.decide(kind: .video, variant: .original, trigger: .prefetch, policy: p), .blocked)
        XCTAssertEqual(MediaPolicy.decide(kind: .image, variant: .thumbnail, trigger: .automatic, policy: p), .allowed)
        p.mode = .offline
        XCTAssertEqual(MediaPolicy.decide(kind: .image, variant: .thumbnail, trigger: .manual, policy: p), .blocked)
        p.mode = .normal; p.isOnWiFi = false; p.mediaPrefetchWiFiOnly = true
        XCTAssertEqual(MediaPolicy.decide(kind: .image, variant: .display, trigger: .prefetch, policy: p), .blocked)
    }

    func testAutomaticModeResolution() {
        XCTAssertEqual(NetworkMode.resolve(preference: .automatic, pathSatisfied: false, isConstrained: false, isExpensive: false), .offline)
        XCTAssertEqual(NetworkMode.resolve(preference: .automatic, pathSatisfied: true, isConstrained: true, isExpensive: true), .lowData)
        XCTAssertEqual(NetworkMode.resolve(preference: .automatic, pathSatisfied: true, isConstrained: false, isExpensive: true), .normal)
        XCTAssertEqual(NetworkMode.resolve(preference: .extreme, pathSatisfied: true, isConstrained: false, isExpensive: false), .extreme)
    }
}

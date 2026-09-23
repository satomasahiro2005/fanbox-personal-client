import XCTest
@testable import FANBOXClient

@MainActor
final class NetworkModeControllerTests: XCTestCase {
    private func makeController() -> (NetworkModeController, AppSettings, NetworkPolicyStore) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "netmode-\(UUID().uuidString)")!)
        let policy = NetworkPolicyStore()
        return (NetworkModeController(settings: settings, policyStore: policy), settings, policy)
    }

    func testModeResolutionTable() {
        typealias C = (NetworkModePreference, Bool, Bool, Bool, NetworkMode)
        let cases: [C] = [
            (.automatic, true, false, false, .normal),
            (.automatic, true, false, true, .normal),
            (.automatic, true, true, false, .lowData),
            (.automatic, false, false, false, .offline),
            (.automatic, false, true, true, .offline),
            (.normal, false, true, true, .normal),
            (.lowData, true, false, false, .lowData),
            (.extreme, true, false, false, .extreme),
            (.offline, true, false, false, .offline),
        ]
        for (pref, satisfied, constrained, expensive, expected) in cases {
            XCTAssertEqual(NetworkMode.resolve(preference: pref, pathSatisfied: satisfied, isConstrained: constrained,
                                               isExpensive: expensive), expected, "\(pref) \(satisfied) \(constrained) \(expensive)")
        }
    }

    func testPathUpdatePublishesSnapshot() {
        let (controller, settings, policy) = makeController()
        settings.mediaPrefetchWiFiOnly = false
        controller.updatePath(satisfied: true, onWiFi: false, constrained: true, expensive: true)
        XCTAssertEqual(controller.effectiveMode, .lowData)
        let snap = policy.current
        XCTAssertEqual(snap.mode, .lowData)
        XCTAssertFalse(snap.isOnWiFi)
        XCTAssertTrue(snap.isConstrained)
        XCTAssertTrue(snap.isExpensive)
        XCTAssertFalse(snap.mediaPrefetchWiFiOnly)

        controller.updatePath(satisfied: false, onWiFi: false, constrained: false, expensive: false)
        XCTAssertEqual(policy.current.mode, .offline)
        XCTAssertFalse(policy.current.allowsNetwork)
        XCTAssertFalse(controller.isOnline)
    }

    func testConnectivityRestoredFiresOnUnavailableToAvailable() {
        let (controller, _, _) = makeController()
        var restored = 0
        controller.onConnectivityRestored = { restored += 1 }

        controller.updatePath(satisfied: true, onWiFi: true, constrained: false, expensive: false)
        XCTAssertEqual(restored, 0, "no transition")
        controller.updatePath(satisfied: false, onWiFi: false, constrained: false, expensive: false)
        XCTAssertEqual(restored, 0)
        controller.updatePath(satisfied: true, onWiFi: false, constrained: false, expensive: true)
        XCTAssertEqual(restored, 1)
        controller.updatePath(satisfied: true, onWiFi: true, constrained: false, expensive: false)
        XCTAssertEqual(restored, 1, "interface change while online is not a restore")
    }

    func testLeavingOfflinePreferenceCountsAsRestore() {
        let (controller, settings, policy) = makeController()
        var restored = 0
        controller.onConnectivityRestored = { restored += 1 }
        settings.networkModePreference = .offline
        controller.recompute()
        XCTAssertEqual(policy.current.mode, .offline)
        settings.networkModePreference = .automatic
        controller.recompute()
        XCTAssertEqual(policy.current.mode, .normal)
        XCTAssertEqual(restored, 1)
    }

    func testSettingsChangesAreObserved() async {
        let (controller, settings, policy) = makeController()
        controller.start()
        defer { controller.stop() }
        settings.networkModePreference = .extreme
        await netModWaitUntil { policy.current.mode == .extreme }
        XCTAssertEqual(controller.effectiveMode, .extreme)

        settings.extremeShowsThumbnails = true
        await netModWaitUntil { policy.current.extremeShowsThumbnails }

        // The observation re-arms: a second change is also picked up.
        settings.networkModePreference = .lowData
        await netModWaitUntil { policy.current.mode == .lowData }
    }

    func testStartIsIdempotent() {
        let (controller, _, _) = makeController()
        controller.start()
        controller.start()
        XCTAssertTrue(controller.isStarted)
        controller.stop()
        XCTAssertFalse(controller.isStarted)
    }

    func testMediaDecisionUsesCurrentPolicy() {
        let (controller, settings, _) = makeController()
        settings.networkModePreference = .extreme
        controller.recompute()
        XCTAssertEqual(controller.decision(kind: .image, variant: .display, trigger: .automatic), .manualOnly)
        XCTAssertEqual(controller.decision(kind: .image, variant: .display, trigger: .manual), .allowed)
    }
}

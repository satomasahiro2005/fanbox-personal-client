import Foundation
import Network
import Observation

/// Observes Network.framework path state and resolves the effective `NetworkMode` (SPEC §30).
/// Publishes a thread-safe snapshot into `policyStore` for actors (scheduler, media).
@MainActor
@Observable
final class NetworkModeController {
    private(set) var effectiveMode: NetworkMode = .normal
    private(set) var pathSatisfied: Bool = true
    private(set) var isOnWiFi: Bool = true
    private(set) var isConstrained: Bool = false
    private(set) var isExpensive: Bool = false

    @ObservationIgnored let policyStore: NetworkPolicyStore
    @ObservationIgnored let settings: AppSettings
    /// Called when connectivity transitions from unavailable to available (reply queue flush, etc.).
    @ObservationIgnored var onConnectivityRestored: (() -> Void)?

    init(settings: AppSettings, policyStore: NetworkPolicyStore) {
        self.settings = settings
        self.policyStore = policyStore
        recompute()
    }

    func start() {}

    /// Re-evaluates the effective mode after a settings or path change.
    func recompute() {
        effectiveMode = NetworkMode.resolve(preference: settings.networkModePreference, pathSatisfied: pathSatisfied,
                                            isConstrained: isConstrained, isExpensive: isExpensive)
        let snapshot = NetworkPolicySnapshot(mode: effectiveMode, pathSatisfied: pathSatisfied, isOnWiFi: isOnWiFi,
                                             isConstrained: isConstrained, isExpensive: isExpensive,
                                             mediaPrefetchWiFiOnly: settings.mediaPrefetchWiFiOnly,
                                             extremeShowsThumbnails: settings.extremeShowsThumbnails)
        policyStore.update { $0 = snapshot }
    }

    var policy: NetworkPolicySnapshot { policyStore.current }

    func decision(kind: MediaKind, variant: MediaVariant, trigger: MediaTrigger) -> MediaDecision {
        MediaPolicy.decide(kind: kind, variant: variant, trigger: trigger, policy: policyStore.current)
    }
}

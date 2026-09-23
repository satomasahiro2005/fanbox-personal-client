import Foundation
import Network
import Observation

/// Observes Network.framework path state and resolves the effective `NetworkMode` (SPEC §30).
/// Publishes a thread-safe snapshot into `policyStore` for actors (scheduler, media).
///
/// - `NWPathMonitor` runs on a private queue; updates hop to the main actor and call `recompute()`.
/// - Settings (`networkModePreference`, `mediaPrefetchWiFiOnly`, `extremeShowsThumbnails`) are observed with a
///   re-arming `withObservationTracking` loop, so changing them in Settings takes effect immediately.
/// - `onConnectivityRestored` fires when the app goes from "no network" (path unsatisfied or Offline mode) to
///   "network available" — e.g. to flush the reply queue.
@MainActor
@Observable
final class NetworkModeController {
    private(set) var effectiveMode: NetworkMode = .normal
    private(set) var pathSatisfied: Bool = true
    private(set) var isOnWiFi: Bool = true
    private(set) var isConstrained: Bool = false
    private(set) var isExpensive: Bool = false
    /// Last time the path state changed (diagnostics / Research Mode).
    private(set) var lastPathChangeAt: Date?
    /// False between `start()` and the monitor's first report (prefetch treats that as "not Wi-Fi").
    private(set) var pathReported: Bool = true

    @ObservationIgnored let policyStore: NetworkPolicyStore
    @ObservationIgnored let settings: AppSettings
    /// Called when connectivity transitions from unavailable to available (reply queue flush, etc.).
    @ObservationIgnored var onConnectivityRestored: (() -> Void)?

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var observingSettings = false
    @ObservationIgnored private var lastOnline: Bool?
    @ObservationIgnored private let monitorQueue = DispatchQueue(label: "ai.nemut.FANBOXClient.network-path", qos: .utility)

    init(settings: AppSettings, policyStore: NetworkPolicyStore) {
        self.settings = settings
        self.policyStore = policyStore
        recompute()
        // Settings changes apply even before `start()` (cheap; no network side effects).
        observeSettings()
    }

    /// Whether the controller is monitoring (idempotent `start()`).
    var isStarted: Bool { monitor != nil }

    /// Starts path monitoring and settings observation. Safe to call more than once and cheap (no network traffic), so
    /// it is called as soon as the environment exists — also for background launches (BGAppRefresh / silent push) that
    /// never connect a scene (SPEC §30 / §35).
    func start() {
        observeSettings()
        guard monitor == nil else { return }
        pathReported = false
        recompute()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let satisfied = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            let constrained = path.isConstrained
            let expensive = path.isExpensive
            Task { @MainActor [weak self] in
                self?.updatePath(satisfied: satisfied, onWiFi: wifi, constrained: constrained, expensive: expensive)
            }
        }
        self.monitor = monitor
        monitor.start(queue: monitorQueue)
    }

    /// Stops path monitoring (tests / teardown). Settings observation ends with the controller.
    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    /// Applies a path state (called from the monitor; internal for tests).
    func updatePath(satisfied: Bool, onWiFi: Bool, constrained: Bool, expensive: Bool) {
        pathReported = true
        let changed = satisfied != pathSatisfied || onWiFi != isOnWiFi || constrained != isConstrained || expensive != isExpensive
        if changed {
            pathSatisfied = satisfied
            isOnWiFi = onWiFi
            isConstrained = constrained
            isExpensive = expensive
            lastPathChangeAt = .now
            AppLog.network.info("path: satisfied=\(satisfied) wifi=\(onWiFi) constrained=\(constrained) expensive=\(expensive)")
        }
        recompute()
    }

    /// Re-evaluates the effective mode after a settings or path change.
    func recompute() {
        let mode = NetworkMode.resolve(preference: settings.networkModePreference, pathSatisfied: pathSatisfied,
                                       isConstrained: isConstrained, isExpensive: isExpensive)
        if effectiveMode != mode { effectiveMode = mode }
        let snapshot = NetworkPolicySnapshot(mode: effectiveMode, pathSatisfied: pathSatisfied, isOnWiFi: isOnWiFi,
                                             isConstrained: isConstrained, isExpensive: isExpensive,
                                             mediaPrefetchWiFiOnly: settings.mediaPrefetchWiFiOnly,
                                             extremeShowsThumbnails: settings.extremeShowsThumbnails, pathKnown: pathReported)
        policyStore.update { $0 = snapshot }

        let online = isOnline
        let previous = lastOnline
        lastOnline = online
        if previous == false && online {
            AppLog.network.info("connectivity restored")
            onConnectivityRestored?()
        }
    }

    /// Network may be used right now (path satisfied and not in Offline mode).
    var isOnline: Bool { pathSatisfied && effectiveMode != .offline }

    var policy: NetworkPolicySnapshot { policyStore.current }

    func decision(kind: MediaKind, variant: MediaVariant, trigger: MediaTrigger) -> MediaDecision {
        MediaPolicy.decide(kind: kind, variant: variant, trigger: trigger, policy: policyStore.current)
    }

    /// Short status for UI (e.g. "Automatic → Low Data").
    var statusDescription: String {
        let preference = settings.networkModePreference
        if preference == .automatic { return "\(preference.displayName) → \(effectiveMode.displayName)" }
        return effectiveMode.displayName
    }

    // MARK: - Settings observation

    private func observeSettings() {
        guard !observingSettings else { return }
        observingSettings = true
        armSettingsObservation()
    }

    private func armSettingsObservation() {
        withObservationTracking {
            _ = settings.networkModePreference
            _ = settings.mediaPrefetchWiFiOnly
            _ = settings.extremeShowsThumbnails
        } onChange: { [weak self] in
            // Called on willSet: hop to the main actor so the new value is visible, then re-arm.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recompute()
                self.armSettingsObservation()
            }
        }
    }
}

import Foundation
import os

/// User-selected communication mode (SPEC §30).
enum NetworkModePreference: String, CaseIterable, Codable, Sendable, Identifiable {
    case automatic, normal, lowData, extreme, offline

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .normal: return "Normal"
        case .lowData: return "Low Data"
        case .extreme: return "Extreme"
        case .offline: return "Offline"
        }
    }
}

/// Effective mode after resolving `.automatic`.
enum NetworkMode: String, Codable, Sendable {
    case normal, lowData, extreme, offline

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .lowData: return "Low Data"
        case .extreme: return "Extreme"
        case .offline: return "Offline"
        }
    }

    /// SPEC §30 Automatic: decided from Network.framework path state + user preference.
    static func resolve(preference: NetworkModePreference, pathSatisfied: Bool, isConstrained: Bool, isExpensive: Bool) -> NetworkMode {
        switch preference {
        case .normal: return .normal
        case .lowData: return .lowData
        case .extreme: return .extreme
        case .offline: return .offline
        case .automatic:
            if !pathSatisfied { return .offline }
            if isConstrained { return .lowData }
            return .normal
        }
    }
}

/// Why a media fetch is requested.
enum MediaTrigger: String, Sendable {
    /// Inline display while the user is looking at the screen.
    case automatic
    /// Background / notification / offline-save prefetch.
    case prefetch
    /// The user explicitly tapped to load.
    case manual
}

enum MediaDecision: Sendable, Equatable {
    case allowed
    /// Show a "tap to load" placeholder.
    case manualOnly
    case blocked
}

/// Immutable snapshot of everything network policy decisions depend on.
struct NetworkPolicySnapshot: Sendable, Equatable {
    var mode: NetworkMode
    var pathSatisfied: Bool
    var isOnWiFi: Bool
    var isConstrained: Bool
    var isExpensive: Bool
    /// SPEC §35: Media Prefetch only on Wi-Fi.
    var mediaPrefetchWiFiOnly: Bool
    /// SPEC §30 Extreme: Thumbnail "Optional".
    var extremeShowsThumbnails: Bool

    static let `default` = NetworkPolicySnapshot(mode: .normal, pathSatisfied: true, isOnWiFi: true, isConstrained: false,
                                                 isExpensive: false, mediaPrefetchWiFiOnly: true, extremeShowsThumbnails: false)

    var allowsNetwork: Bool { mode != .offline }
}

/// Thread-safe holder of the current policy, shared by the main-actor controller and background actors.
final class NetworkPolicyStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: NetworkPolicySnapshot.default)

    init(_ initial: NetworkPolicySnapshot = .default) {
        lock.withLock { $0 = initial }
    }

    var current: NetworkPolicySnapshot { lock.withLock { $0 } }

    func update(_ transform: (inout NetworkPolicySnapshot) -> Void) {
        lock.withLock { transform(&$0) }
    }
}

/// Media policy table (SPEC §30 / §35). Pure and unit-testable.
enum MediaPolicy {
    static func decide(kind: MediaKind, variant: MediaVariant, trigger: MediaTrigger, policy: NetworkPolicySnapshot) -> MediaDecision {
        if policy.mode == .offline || !policy.pathSatisfied { return .blocked }

        // SPEC §35: optional Wi-Fi-only media prefetch.
        if trigger == .prefetch, policy.mediaPrefetchWiFiOnly, !policy.isOnWiFi { return .blocked }

        switch policy.mode {
        case .offline:
            return .blocked

        case .normal:
            switch kind {
            case .image:
                if trigger == .prefetch && variant == .original && !policy.isOnWiFi { return .blocked }
                return .allowed
            case .video, .audio, .file:
                // Large payloads are never fetched implicitly while browsing.
                if trigger == .automatic { return .manualOnly }
                return .allowed
            }

        case .lowData:
            switch kind {
            case .image:
                switch (variant, trigger) {
                case (.original, .prefetch): return .blocked          // Original Prefetch OFF
                case (.original, .automatic): return .manualOnly
                default: return .allowed                                // Thumbnail ON, display on view
                }
            case .video:
                if trigger == .prefetch { return .blocked }             // Video Prefetch OFF
                return trigger == .manual ? .allowed : .manualOnly
            case .audio, .file:
                if trigger == .prefetch { return .blocked }
                return trigger == .manual ? .allowed : .manualOnly
            }

        case .extreme:
            if trigger == .prefetch { return .blocked }
            if trigger == .manual { return .allowed }
            // Automatic: only thumbnails, and only when the user opted in.
            if kind == .image && variant == .thumbnail && policy.extremeShowsThumbnails { return .allowed }
            return .manualOnly
        }
    }

    /// Whether text/JSON requests may run in the given mode (always, unless offline).
    static func allowsText(policy: NetworkPolicySnapshot) -> Bool { policy.allowsNetwork && policy.pathSatisfied }
}

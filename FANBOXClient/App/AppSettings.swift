import Foundation
import Observation

/// Cache capacity options (SPEC §32).
enum CacheCapacity: String, CaseIterable, Codable, Sendable, Identifiable {
    case gb1, gb5, gb10, gb20, unlimited

    var id: String { rawValue }

    /// nil = unlimited
    var bytes: Int64? {
        switch self {
        case .gb1: return 1 * 1_000_000_000
        case .gb5: return 5 * 1_000_000_000
        case .gb10: return 10 * 1_000_000_000
        case .gb20: return 20 * 1_000_000_000
        case .unlimited: return nil
        }
    }

    var displayName: String {
        switch self {
        case .gb1: return "1 GB"
        case .gb5: return "5 GB"
        case .gb10: return "10 GB"
        case .gb20: return "20 GB"
        case .unlimited: return "Unlimited"
        }
    }
}

/// App-wide user settings persisted in UserDefaults (non-secret values only).
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var networkModePreference: NetworkModePreference { didSet { defaults.set(networkModePreference.rawValue, forKey: Keys.networkMode) } }
    var cacheCapacity: CacheCapacity { didSet { defaults.set(cacheCapacity.rawValue, forKey: Keys.cacheCapacity) } }
    /// SPEC §35: Media Prefetch only on Wi-Fi.
    var mediaPrefetchWiFiOnly: Bool { didSet { defaults.set(mediaPrefetchWiFiOnly, forKey: Keys.wifiOnly) } }
    /// SPEC §30 Extreme: Thumbnail Optional.
    var extremeShowsThumbnails: Bool { didSet { defaults.set(extremeShowsThumbnails, forKey: Keys.extremeThumbs) } }
    /// SPEC §31: "今後閲覧した投稿を自動保存".
    var autoSaveViewedPosts: Bool { didSet { defaults.set(autoSaveViewedPosts, forKey: Keys.autoSave) } }
    /// Default N for "Creator の最近 N 件".
    var creatorRecentCount: Int { didSet { defaults.set(creatorRecentCount, forKey: Keys.recentCount) } }
    /// SPEC §22: long-waiting replies are NOT auto-sent unless enabled (default false → needsConfirmation).
    var autoSendStaleReplies: Bool { didSet { defaults.set(autoSendStaleReplies, forKey: Keys.autoSendStale) } }
    /// Seconds after which a queued reply is considered stale.
    var staleReplyThreshold: TimeInterval { didSet { defaults.set(staleReplyThreshold, forKey: Keys.staleThreshold) } }
    /// Foreground notification polling interval (seconds).
    var foregroundPollingInterval: TimeInterval { didSet { defaults.set(foregroundPollingInterval, forKey: Keys.pollInterval) } }
    /// Post local iOS notifications for detected events.
    var localNotificationsEnabled: Bool { didSet { defaults.set(localNotificationsEnabled, forKey: Keys.localNotifications) } }
    /// Research Mode (SPEC §36): records redacted response bodies and shows inspector UI.
    var researchModeEnabled: Bool { didSet { defaults.set(researchModeEnabled, forKey: Keys.research) } }
    /// Optional APNs relay (SPEC §28). Off by default; requires a self-hosted relay.
    var remoteRelayEnabled: Bool { didSet { defaults.set(remoteRelayEnabled, forKey: Keys.relayEnabled) } }
    var remoteRelayURL: String { didSet { defaults.set(remoteRelayURL, forKey: Keys.relayURL) } }
    /// Show adult content thumbnails (local preference only).
    var showAdultContent: Bool { didSet { defaults.set(showAdultContent, forKey: Keys.adult) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        networkModePreference = NetworkModePreference(rawValue: defaults.string(forKey: Keys.networkMode) ?? "") ?? .automatic
        cacheCapacity = CacheCapacity(rawValue: defaults.string(forKey: Keys.cacheCapacity) ?? "") ?? .gb5
        mediaPrefetchWiFiOnly = defaults.object(forKey: Keys.wifiOnly) as? Bool ?? true
        extremeShowsThumbnails = defaults.object(forKey: Keys.extremeThumbs) as? Bool ?? false
        autoSaveViewedPosts = defaults.object(forKey: Keys.autoSave) as? Bool ?? false
        creatorRecentCount = defaults.object(forKey: Keys.recentCount) as? Int ?? 10
        autoSendStaleReplies = defaults.object(forKey: Keys.autoSendStale) as? Bool ?? false
        staleReplyThreshold = defaults.object(forKey: Keys.staleThreshold) as? TimeInterval ?? 30 * 60
        foregroundPollingInterval = defaults.object(forKey: Keys.pollInterval) as? TimeInterval ?? 60
        localNotificationsEnabled = defaults.object(forKey: Keys.localNotifications) as? Bool ?? true
        researchModeEnabled = defaults.object(forKey: Keys.research) as? Bool ?? false
        remoteRelayEnabled = defaults.object(forKey: Keys.relayEnabled) as? Bool ?? false
        remoteRelayURL = defaults.string(forKey: Keys.relayURL) ?? ""
        showAdultContent = defaults.object(forKey: Keys.adult) as? Bool ?? true
    }

    private enum Keys {
        static let networkMode = "settings.networkMode"
        static let cacheCapacity = "settings.cacheCapacity"
        static let wifiOnly = "settings.mediaPrefetchWiFiOnly"
        static let extremeThumbs = "settings.extremeShowsThumbnails"
        static let autoSave = "settings.autoSaveViewedPosts"
        static let recentCount = "settings.creatorRecentCount"
        static let autoSendStale = "settings.autoSendStaleReplies"
        static let staleThreshold = "settings.staleReplyThreshold"
        static let pollInterval = "settings.foregroundPollingInterval"
        static let localNotifications = "settings.localNotificationsEnabled"
        static let research = "settings.researchModeEnabled"
        static let relayEnabled = "settings.remoteRelayEnabled"
        static let relayURL = "settings.remoteRelayURL"
        static let adult = "settings.showAdultContent"
    }
}

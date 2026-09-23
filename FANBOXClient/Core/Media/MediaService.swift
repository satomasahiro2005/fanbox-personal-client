import Foundation
import Observation
import UIKit

struct MediaRequest: Sendable, Hashable {
    var url: String
    var variant: MediaVariant
    var kind: MediaKind
    var trigger: MediaTrigger
    var priority: RequestPriority
    var postID: String?
    var creatorID: String?
    /// Account whose session is used for authenticated media hosts.
    var accountID: String?
    /// Pin the cached file (offline saved content).
    var pin: Bool

    init(url: String, variant: MediaVariant, kind: MediaKind = .image, trigger: MediaTrigger = .automatic,
         priority: RequestPriority = .foregroundMedia, postID: String? = nil, creatorID: String? = nil, accountID: String? = nil,
         pin: Bool = false) {
        self.url = url
        self.variant = variant
        self.kind = kind
        self.trigger = trigger
        self.priority = priority
        self.postID = postID
        self.creatorID = creatorID
        self.accountID = accountID
        self.pin = pin
    }
}

struct CacheUsage: Sendable, Equatable {
    var totalBytes: Int64 = 0
    var bytesByVariant: [MediaVariant: Int64] = [:]
    var pinnedBytes: Int64 = 0
    var fileCount: Int = 0
}

/// Staged media loading + file cache (SPEC §6 / §32).
/// - Consults `MediaPolicy` before any network fetch; offline / manual-only returns cached data or throws `.blockedByPolicy`.
/// - Files live under Caches/Media with Data Protection; `MediaCacheEntry` rows track them.
/// - Eviction order: unpinned → old → original → display → thumbnail. Text is never evicted here.
@MainActor
@Observable
final class MediaService {
    private(set) var usage = CacheUsage()

    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let http: HTTPClient
    @ObservationIgnored let network: NetworkModeController
    @ObservationIgnored let settings: AppSettings

    init(store: LocalStore, http: HTTPClient, network: NetworkModeController, settings: AppSettings) {
        self.store = store
        self.http = http
        self.network = network
        self.settings = settings
    }

    func decision(kind: MediaKind, variant: MediaVariant, trigger: MediaTrigger) -> MediaDecision {
        network.decision(kind: kind, variant: variant, trigger: trigger)
    }

    /// Local file URL of a cached variant, if present (updates last access).
    func cachedFileURL(url: String, variant: MediaVariant) -> URL? { nil }

    /// Returns a local file URL, downloading if the policy allows.
    func load(_ request: MediaRequest) async throws -> URL { throw RemoteError.blockedByPolicy }

    /// Decoded image for display (downsampled for thumbnail/display variants).
    func image(_ request: MediaRequest) async throws -> UIImage { throw RemoteError.blockedByPolicy }

    /// Best already-cached image among variants <= `maxVariant` (instant display while a better one loads).
    func bestCachedImage(urls: [MediaVariant: String], upTo maxVariant: MediaVariant) -> UIImage? { nil }

    func pin(postID: String) {}
    func unpin(postID: String) {}
    func clearCache(postID: String) {}
    func clearAll(includePinned: Bool) {}
    func refreshUsage() {}
    /// Evicts files until usage fits `settings.cacheCapacity`.
    func enforceCapacity() {}
    func isCached(postID: String) -> Bool { false }
}

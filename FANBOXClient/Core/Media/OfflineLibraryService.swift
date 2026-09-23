import Foundation
import Observation
import SwiftData

/// Result of one offline save (for UI feedback).
struct OfflineSaveSummary: Sendable, Equatable {
    var postID: String
    var textAvailable: Bool
    var mediaRequested: Int
    var mediaSaved: Int
    /// Media skipped because the current network mode does not allow it (text is still saved).
    var mediaBlocked: Int
    var mediaFailed: Int
    var finishedAt: Date

    var isComplete: Bool { textAvailable && mediaSaved == mediaRequested }
}

/// Offline Library (SPEC §31). Save units: this post / creator's recent N / auto-save viewed posts.
/// Never crawls unlimited history.
@MainActor
@Observable
final class OfflineLibraryService {
    private(set) var activeSaves: Set<String> = []
    /// Progress (0...1) of media downloads per post being saved.
    private(set) var saveProgress: [String: Double] = [:]
    /// Last save result per post.
    private(set) var lastSummaries: [String: OfflineSaveSummary] = [:]
    /// Creators whose "recent N" save is running.
    private(set) var activeCreatorSaves: Set<String> = []

    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let engine: SyncEngine
    @ObservationIgnored let media: MediaService
    @ObservationIgnored let settings: AppSettings

    init(store: LocalStore, engine: SyncEngine, media: MediaService, settings: AppSettings) {
        self.store = store
        self.engine = engine
        self.media = media
        self.settings = settings
    }

    /// Saves text + display images of a post and pins them.
    func save(postID: String) async {
        guard !activeSaves.contains(postID) else { return }
        activeSaves.insert(postID)
        saveProgress[postID] = 0
        defer {
            activeSaves.remove(postID)
            saveProgress[postID] = nil
        }

        // 1. Text first (SPEC §46 priority: body before any media).
        if store.post(id: postID)?.hasCachedBody != true {
            await RequestContext.$priority.withValue(.interactiveRead) {
                _ = await engine.refreshPost(postID: postID, priority: .interactiveRead)
            }
        }
        guard let post = store.post(id: postID) else {
            AppLog.media.error("offline save: post not found locally")
            return
        }
        post.offlineState = .saved
        store.save()

        // 2. Media (explicit user action ⇒ manual trigger; policy may still block, e.g. Offline).
        let requests = Self.mediaRequests(for: post, trigger: .manual, priority: .foregroundMedia, pin: true,
                                          includeAttachments: true)
        var summary = OfflineSaveSummary(postID: postID, textAvailable: post.hasCachedBody, mediaRequested: requests.count,
                                         mediaSaved: 0, mediaBlocked: 0, mediaFailed: 0, finishedAt: .now)
        for (index, request) in requests.enumerated() {
            do {
                _ = try await media.load(request)
                summary.mediaSaved += 1
            } catch RemoteError.blockedByPolicy {
                summary.mediaBlocked += 1
            } catch {
                summary.mediaFailed += 1
            }
            saveProgress[postID] = Double(index + 1) / Double(max(requests.count, 1))
        }
        // Anything already cached for this post (e.g. viewed earlier) is kept as well.
        media.pin(postID: postID)
        summary.finishedAt = .now
        lastSummaries[postID] = summary
    }

    func remove(postID: String) {
        if let post = store.post(id: postID) {
            post.offlineState = .none
        }
        media.unpin(postID: postID)
        lastSummaries[postID] = nil
        store.save()
    }

    /// Saves the latest `count` posts of a creator (already-known + one differential fetch, no deep crawl).
    func saveRecent(creatorID: String, count: Int) async {
        let count = max(0, count)
        if let creator = store.creator(id: creatorID) {
            creator.offlineRecentCount = count
            store.save()
        }
        guard count > 0, !activeCreatorSaves.contains(creatorID) else { return }
        activeCreatorSaves.insert(creatorID)
        defer { activeCreatorSaves.remove(creatorID) }

        // One refresh of the creator's latest page — never a deep history crawl (SPEC §3.7 / §31).
        await RequestContext.$priority.withValue(.interactiveRead) {
            _ = await engine.refreshCreator(creatorID: creatorID)
        }
        for postID in recentPostIDs(creatorID: creatorID, count: count) {
            await save(postID: postID)
        }
    }

    /// Re-applies every creator's "recent N" rule to posts that are already known locally (no network crawl beyond
    /// one refresh per creator). Intended for pull-to-refresh in the Offline Library.
    func refreshCreatorRules() async {
        let creators = store.fetch(FetchDescriptor<Creator>(predicate: #Predicate { $0.offlineRecentCount > 0 }))
        for creator in creators {
            await saveRecent(creatorID: creator.creatorID, count: creator.offlineRecentCount)
        }
    }

    /// Called whenever a post detail is displayed.
    func postViewed(postID: String) async {
        guard let post = store.post(id: postID) else { return }
        post.lastViewedAt = .now
        guard settings.autoSaveViewedPosts else {
            store.save()
            return
        }
        if post.offlineState != .saved {
            post.offlineState = .autoSaved
        }
        store.save()

        // Display images only; prefetch trigger so Low Data / Extreme / Wi-Fi-only rules apply (text-only if blocked).
        let requests = Self.mediaRequests(for: post, trigger: .prefetch, priority: .mediaPrefetch, pin: post.offlineState == .saved,
                                          includeAttachments: false, variants: [.display])
        for request in requests {
            do {
                _ = try await media.load(request)
            } catch RemoteError.blockedByPolicy {
                break
            } catch {
                continue
            }
        }
    }

    func isSaving(postID: String) -> Bool { activeSaves.contains(postID) }

    // MARK: - Helpers

    /// Newest `count` locally known posts of the creator.
    func recentPostIDs(creatorID: String, count: Int) -> [String] {
        store.fetch(FetchDescriptorFactory.postsByCreator(creatorID, limit: count)).map(\.postID)
    }

    /// Media to save for a post: cover + image blocks (thumbnail/display), and optionally attachments (file/audio/video).
    static func mediaRequests(for post: Post, trigger: MediaTrigger, priority: RequestPriority, pin: Bool,
                              includeAttachments: Bool, variants: Set<MediaVariant> = [.thumbnail, .display]) -> [MediaRequest] {
        let accountID = post.detailAccountID ?? post.accessAccountIDs.first
        var seen = Set<String>()
        var result: [MediaRequest] = []

        func add(_ url: String?, _ variant: MediaVariant, _ kind: MediaKind) {
            guard let url, !url.isEmpty, isFetchable(url) else { return }
            let key = MediaFileCache.key(url: url, variant: variant)
            guard seen.insert(key).inserted else { return }
            result.append(MediaRequest(url: url, variant: variant, kind: kind, trigger: trigger, priority: priority, postID: post.postID,
                                       creatorID: post.creatorID, accountID: accountID, pin: pin))
        }

        if variants.contains(.display) {
            add(post.coverImageURL, .display, .image)
        }
        for block in post.orderedBlocks {
            switch block.kind {
            case .image:
                if variants.contains(.thumbnail) { add(block.thumbnailURL, .thumbnail, .image) }
                if variants.contains(.display) { add(block.displayURL ?? block.thumbnailURL, .display, .image) }
                if variants.contains(.original) { add(block.originalURL, .original, .image) }
            case .file, .audio, .video:
                guard includeAttachments else { continue }
                // External videos (YouTube etc.) are links, not attachments.
                if block.kind == .video, block.embedProvider != nil { continue }
                let kind: MediaKind = block.kind == .file ? .file : (block.kind == .audio ? .audio : .video)
                add(block.originalURL ?? block.url, .original, kind)
            default:
                continue
            }
        }
        return result
    }

    /// Only http(s) and local demo media are fetched.
    static func isFetchable(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("demo://")
    }
}

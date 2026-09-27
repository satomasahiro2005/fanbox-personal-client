import Foundation
import Observation
import SwiftData
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
    /// Decode (downsample) size for `MediaService.image`. nil = the fetched variant. Lets a small tile show a larger
    /// variant (e.g. FANBOX images that only have display / original URLs) without holding a 1600 px bitmap.
    var decodeAs: MediaVariant?

    init(url: String, variant: MediaVariant, kind: MediaKind = .image, trigger: MediaTrigger = .automatic,
         priority: RequestPriority = .foregroundMedia, postID: String? = nil, creatorID: String? = nil, accountID: String? = nil,
         pin: Bool = false, decodeAs: MediaVariant? = nil) {
        self.url = url
        self.variant = variant
        self.kind = kind
        self.trigger = trigger
        self.priority = priority
        self.postID = postID
        self.creatorID = creatorID
        self.accountID = accountID
        self.pin = pin
        self.decodeAs = decodeAs
    }

    /// Size the image is decoded at: never larger than the fetched variant.
    var decodeVariant: MediaVariant { min(decodeAs ?? variant, variant) }
}

struct CacheUsage: Sendable, Equatable {
    var totalBytes: Int64 = 0
    var bytesByVariant: [MediaVariant: Int64] = [:]
    var pinnedBytes: Int64 = 0
    var fileCount: Int = 0
}

/// Staged media loading + file cache (SPEC §6 / §31 / §32).
/// - Consults `MediaPolicy` before any network fetch; offline / manual-only returns cached data or throws `.blockedByPolicy`.
/// - Ordinary files live under Caches/Media; pinned (saved) files under Application Support/OfflineMedia so the OS never
///   purges them. Both use Data Protection; `MediaCacheEntry` rows track them.
/// - Eviction order: unpinned → old → original → display → thumbnail. Text is never evicted here. When saved (pinned)
///   media has to go (over capacity, or files vanished), the post's offline state is released so the UI never claims
///   "Offline" for images that are gone.
@MainActor
@Observable
final class MediaService {
    private(set) var usage = CacheUsage()
    /// Download progress (0...1) keyed by `MediaFileCache.key(url:variant:)` while a fetch is in flight.
    private(set) var downloadProgress: [String: Double] = [:]
    /// Number of media fetches currently in flight.
    private(set) var activeFetchCount = 0

    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let http: HTTPClient
    @ObservationIgnored let network: NetworkModeController
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let fileCache: MediaFileCache
    /// Delay before usage refresh + capacity enforcement after new files arrive (coalesces bursts).
    @ObservationIgnored var maintenanceDelay: Duration = .milliseconds(600)

    @ObservationIgnored private let memoryCache: NSCache<NSString, UIImage>
    @ObservationIgnored private var inFlight: [String: InFlightFetch] = [:]
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var didScheduleReconcile = false
    /// url → cached variants. Avoids scanning `MediaCacheEntry.url` (not indexed) on every lookup. Built lazily.
    @ObservationIgnored private var urlIndex: [String: Set<MediaVariant>]?

    init(store: LocalStore, http: HTTPClient, network: NetworkModeController, settings: AppSettings, cacheRoot: URL? = nil,
         pinnedRoot: URL? = nil) {
        self.store = store
        self.http = http
        self.network = network
        self.settings = settings
        self.fileCache = MediaFileCache(root: cacheRoot ?? MediaFileCache.defaultRoot, pinnedRoot: pinnedRoot)
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 400
        self.memoryCache = cache
    }

    func decision(kind: MediaKind, variant: MediaVariant, trigger: MediaTrigger) -> MediaDecision {
        network.decision(kind: kind, variant: variant, trigger: trigger)
    }

    // MARK: - Cache lookup

    /// Local file URL of a cached variant, if present (updates last access).
    func cachedFileURL(url: String, variant: MediaVariant) -> URL? {
        guard let entry = cachedEntry(url: url, variant: variant) else { return nil }
        let fileURL = fileCache.fileURL(relativePath: entry.relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            forget(entry)
            return nil
        }
        touch(entry)
        return fileURL
    }

    /// Like `cachedFileURL` but without side effects (safe to call while rendering a view).
    func peekCachedFileURL(url: String, variant: MediaVariant) -> URL? {
        guard let entry = cachedEntry(url: url, variant: variant) else { return nil }
        let fileURL = fileCache.fileURL(relativePath: entry.relativePath)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    func isFileCached(url: String, variant: MediaVariant) -> Bool {
        peekCachedFileURL(url: url, variant: variant) != nil
    }

    /// The cached file under a readable name (share / open / Files), valid after the cached file moves between the
    /// cache roots (pin / unpin). nil when nothing is cached.
    func namedFileURL(url: String, variant: MediaVariant, fileName: String) -> URL? {
        guard let source = peekCachedFileURL(url: url, variant: variant) else { return nil }
        return MediaFileCache.namedLink(to: source, fileName: fileName)
    }

    /// Download progress of an in-flight fetch (nil when not downloading or unknown).
    func progress(url: String, variant: MediaVariant) -> Double? {
        downloadProgress[MediaFileCache.key(url: url, variant: variant)]
    }

    /// Cache entry for `url` + `variant`. Falls back to the same URL cached under another variant
    /// (identical URL ⇒ identical bytes, e.g. a cover image used both as thumbnail and display).
    func cachedEntry(url: String, variant: MediaVariant) -> MediaCacheEntry? {
        let variants = indexedVariants(for: url)
        guard let best = variants.max() else { return nil }
        let chosen = variants.contains(variant) ? variant : best
        let key = MediaFileCache.key(url: url, variant: chosen)
        if let entry = store.first(#Predicate<MediaCacheEntry> { $0.key == key }) { return entry }
        // Index drift (row removed elsewhere): resync this URL from the store.
        let rows = store.fetch(FetchDescriptor<MediaCacheEntry>(predicate: #Predicate { $0.url == url }))
        urlIndex?[url] = rows.isEmpty ? nil : Set(rows.map(\.variant))
        return rows.first { $0.variant == variant } ?? rows.max { $0.variant < $1.variant }
    }

    func entries(postID: String) -> [MediaCacheEntry] {
        store.fetch(FetchDescriptor<MediaCacheEntry>(predicate: #Predicate { $0.postID == postID }))
    }

    func cachedBytes(postID: String) -> Int64 {
        entries(postID: postID).reduce(Int64(0)) { $0 + Int64($1.byteSize) }
    }

    // MARK: - Loading

    /// Returns a local file URL, downloading if the policy allows. The URL is where the file is after this request's
    /// ownership was applied (pinning moves a file between the cache roots).
    func load(_ request: MediaRequest) async throws -> URL {
        let key = MediaFileCache.key(url: request.url, variant: request.variant)
        if let hit = cachedFileURL(url: request.url, variant: request.variant) {
            applyOwnership(url: request.url, variant: request.variant, request: request)
            return currentFileURL(url: request.url, variant: request.variant) ?? hit
        }

        let fetch: InFlightFetch
        if let existing = inFlight[key], !existing.task.isCancelled {
            // A fetch every earlier waiter gave up on is not joined (it ends with `.cancelled`): a new one starts.
            fetch = existing
        } else {
            let decision = decision(kind: request.kind, variant: request.variant, trigger: request.trigger)
            guard decision == .allowed else { throw RemoteError.blockedByPolicy }
            let box = InFlightFetchBox()
            let task = Task { @MainActor [weak self] () throws -> URL in
                guard let self else { throw RemoteError.cancelled }
                defer { self.finishFetch(key: key, fetch: box.fetch) }
                return try await self.fetchAndStore(request, key: key)
            }
            fetch = InFlightFetch(task: task)
            box.fetch = fetch
            inFlight[key] = fetch
            activeFetchCount = inFlight.count
        }

        fetch.waiters += 1
        let fileURL = try await withTaskCancellationHandler {
            do {
                return try await fetch.task.value
            } catch let error as RemoteError where (error == .offline || error == .cancelled) && !network.policy.allowsNetwork {
                // SPEC §30: a transfer stopped because the app went Offline is "blocked by the mode", not a failure.
                throw RemoteError.blockedByPolicy
            }
        } onCancel: {
            // Cancel the shared download only when every waiter has gone away (e.g. cells scrolled off screen).
            Task { @MainActor [weak self] in
                fetch.cancelledWaiters += 1
                if fetch.cancelledWaiters >= fetch.waiters {
                    fetch.task.cancel()
                    // Nobody joins a cancelled fetch: a new request for the key starts its own.
                    if self?.inFlight[key] === fetch { self?.finishFetch(key: key, fetch: fetch) }
                }
            }
        }
        applyOwnership(url: request.url, variant: request.variant, request: request)
        // Another waiter of the same fetch may have pinned (moved) the file meanwhile.
        return currentFileURL(url: request.url, variant: request.variant) ?? fileURL
    }

    /// Where the cached file of `url` + `variant` is now (nil without an entry).
    private func currentFileURL(url: String, variant: MediaVariant) -> URL? {
        cachedEntry(url: url, variant: variant).map { fileCache.fileURL(relativePath: $0.relativePath) }
    }

    /// Decoded image for display (downsampled to `request.decodeVariant`).
    func image(_ request: MediaRequest) async throws -> UIImage {
        guard request.kind == .image else { throw RemoteError.invalidRequest("画像ではありません") }
        let memoryKey = Self.memoryKey(url: request.url, variant: request.decodeVariant)
        if let cached = memoryCache.object(forKey: memoryKey) {
            if request.pin { applyOwnership(url: request.url, variant: request.variant, request: request) }
            return cached
        }
        var fileURL = try await load(request)
        let variant = request.variant
        let decodeVariant = request.decodeVariant
        func decode(_ url: URL) async -> UIImage? {
            await Task.detached(priority: .userInitiated) { ImageDownsampler.decode(fileURL: url, variant: decodeVariant) }.value
        }
        var decoded = await decode(fileURL)
        if decoded == nil, let current = currentFileURL(url: request.url, variant: variant), current != fileURL {
            // The file moved between the cache roots (pinned / unpinned) while it was decoded: decode it where it is now.
            fileURL = current
            decoded = await decode(current)
        }
        guard let decoded else {
            // Corrupt / non-image payload: drop file + row so the next attempt re-fetches — only when the row still points
            // at the file that failed (a file that moved is not "corrupt").
            if let entry = cachedEntry(url: request.url, variant: variant),
               fileCache.fileURL(relativePath: entry.relativePath) == fileURL {
                let releasedPost = entry.isPinned ? entry.postID : nil
                remove(entry)
                if let releasedPost { releaseOfflineState(postIDs: [releasedPost]) }
                store.save()
                refreshUsage()
            }
            throw RemoteError.decoding(endpoint: "media.\(variant.rawValue)", detail: "画像をデコードできませんでした")
        }
        memoryCache.setObject(decoded, forKey: memoryKey, cost: ImageDownsampler.memoryCost(of: decoded))
        return decoded
    }

    /// Best already-cached image among variants <= `maxVariant` (instant display while a better one loads).
    func bestCachedImage(urls: [MediaVariant: String], upTo maxVariant: MediaVariant) -> UIImage? {
        bestCachedImageWithVariant(urls: urls, upTo: maxVariant)?.image
    }

    /// Memory-cache-only lookup: cheap enough to call from `View.body`.
    func memoryCachedImage(urls: [MediaVariant: String], upTo maxVariant: MediaVariant) -> UIImage? {
        memoryCachedImageWithVariant(urls: urls, upTo: maxVariant)?.image
    }

    /// Variants above `maxVariant` in `urls` are looked up at the capped decode size (see `MediaRequest.decodeAs`);
    /// the returned variant is the fetched one.
    func memoryCachedImageWithVariant(urls: [MediaVariant: String], upTo maxVariant: MediaVariant)
        -> (variant: MediaVariant, image: UIImage)? {
        for variant in MediaVariant.allCases.reversed() {
            guard let url = urls[variant] else { continue }
            let decoded = min(variant, maxVariant)
            if let image = memoryCache.object(forKey: Self.memoryKey(url: url, variant: decoded)) { return (variant, image) }
        }
        return nil
    }

    /// Memory cache first (highest variant wins); otherwise the smallest cached file is decoded synchronously at
    /// thumbnail size (cheap ImageIO downsample) so something is on screen immediately.
    func bestCachedImageWithVariant(urls: [MediaVariant: String], upTo maxVariant: MediaVariant)
        -> (variant: MediaVariant, image: UIImage)? {
        if let hit = memoryCachedImageWithVariant(urls: urls, upTo: maxVariant) { return hit }
        for variant in MediaVariant.allCases where variant <= maxVariant {
            guard let url = urls[variant], let fileURL = peekCachedFileURL(url: url, variant: variant),
                  let image = ImageDownsampler.decode(fileURL: fileURL, variant: .thumbnail) else { continue }
            memoryCache.setObject(image, forKey: Self.memoryKey(url: url, variant: .thumbnail), cost: ImageDownsampler.memoryCost(of: image))
            return (.thumbnail, image)
        }
        return nil
    }

    // MARK: - Pinning / clearing

    func pin(postID: String) {
        setPinned(true, postID: postID)
    }

    func unpin(postID: String) {
        setPinned(false, postID: postID)
    }

    /// Deletes every cached media file of the post (pinned included) and resets its offline state. Text is kept.
    func clearCache(postID: String) {
        for entry in entries(postID: postID) {
            remove(entry)
        }
        if let post = store.post(id: postID) {
            if post.offlineState != .none { post.mediaReleasedAt = .now }
            post.offlineState = .none
        }
        store.save()
        refreshUsage()
    }

    /// Whether the post's saved media was deleted — by the user (キャッシュ削除 / すべて削除 / one image) or because saved
    /// media exceeded the capacity. A "recent N" rule does not save it again (it would re-download what was just deleted,
    /// on every sync, also after a relaunch) until the user saves the post explicitly.
    func isReleased(postID: String) -> Bool {
        store.post(id: postID)?.mediaReleasedAt != nil
    }

    /// The user saved the post again: rules may cover it again.
    func forgetRelease(postID: String) {
        if let post = store.post(id: postID), post.mediaReleasedAt != nil { post.mediaReleasedAt = nil }
    }

    /// Remembers that these posts' saved media was deleted (`isReleased`). Caller saves.
    private func markReleased(_ postIDs: Set<String>) {
        guard !postIDs.isEmpty else { return }
        let ids = Array(postIDs)
        let now = Date.now
        for post in store.fetch(FetchDescriptor<Post>(predicate: #Predicate { ids.contains($0.postID) })) { post.mediaReleasedAt = now }
    }

    /// Saved media alone is at or above the capacity: saving more would only evict other saved media.
    var isSavedMediaAtCapacity: Bool {
        guard let limit = settings.cacheCapacity.bytes else { return false }
        return usage.pinnedBytes >= limit
    }

    /// `includePinned == false` keeps every saved post's media (explicit, "recent N" and auto-saved posts are pinned).
    func clearAll(includePinned: Bool) {
        if includePinned {
            for entry in store.fetch(FetchDescriptor<MediaCacheEntry>()) {
                store.context.delete(entry)
            }
            urlIndex = [:]
            fileCache.removeEverything()
            let none = OfflineState.none.rawValue
            let now = Date.now
            for post in store.fetch(FetchDescriptor<Post>(predicate: #Predicate { $0.offlineStateRaw != none })) {
                post.mediaReleasedAt = now
                post.offlineState = .none
            }
        } else {
            for entry in store.fetch(FetchDescriptor<MediaCacheEntry>(predicate: #Predicate { !$0.isPinned })) {
                remove(entry)
            }
        }
        memoryCache.removeAllObjects()
        store.save()
        refreshUsage()
    }

    /// Deletes one cached file (e.g. from the Offline Library "Files" list). Deleting a saved file releases the
    /// post's offline state (it is no longer complete offline).
    func removeEntry(key: String) {
        guard let entry = store.first(#Predicate<MediaCacheEntry> { $0.key == key }) else { return }
        let releasedPost = entry.isPinned ? entry.postID : nil
        remove(entry)
        if let releasedPost {
            releaseOfflineState(postIDs: [releasedPost])
            markReleased([releasedPost])
        }
        store.save()
        refreshUsage()
    }

    func refreshUsage() {
        var next = CacheUsage()
        for entry in store.fetch(FetchDescriptor<MediaCacheEntry>()) {
            let bytes = Int64(entry.byteSize)
            next.totalBytes += bytes
            next.bytesByVariant[entry.variant, default: 0] += bytes
            if entry.isPinned { next.pinnedBytes += bytes }
            next.fileCount += 1
        }
        if next != usage { usage = next }
        if !didScheduleReconcile {
            didScheduleReconcile = true
            Task { [weak self] in await self?.reconcile() }
        }
    }

    /// Evicts files until usage fits `settings.cacheCapacity`.
    func enforceCapacity() {
        enforceCapacity(limit: settings.cacheCapacity.bytes)
    }

    /// Evicts files (SPEC §32 order) until the total fits `limit`. `nil` = unlimited.
    func enforceCapacity(limit: Int64?) {
        guard let limit else { return }
        let entries = store.fetch(FetchDescriptor<MediaCacheEntry>())
        let candidates = entries.map {
            MediaEvictionCandidate(key: $0.key, byteSize: Int64($0.byteSize), isPinned: $0.isPinned, variant: $0.variant,
                                   lastAccessedAt: $0.lastAccessedAt)
        }
        let victims = Set(MediaEvictionPlanner.victims(candidates, limit: limit))
        guard !victims.isEmpty else { return }
        var releasedPosts: Set<String> = []
        for entry in entries where victims.contains(entry.key) {
            if entry.isPinned, let postID = entry.postID { releasedPosts.insert(postID) }
            remove(entry)
        }
        // Saved media had to go (pinned data alone exceeds the capacity): those posts are no longer fully offline.
        releaseOfflineState(postIDs: releasedPosts)
        markReleased(releasedPosts)
        store.save()
        refreshUsage()
        AppLog.media.info("evicted \(victims.count, privacy: .public) cached media files (\(releasedPosts.count, privacy: .public) saved posts released)")
    }

    /// Resets the offline state of posts whose saved media is (partly) gone and unpins what is left of it, so the post
    /// no longer shows "Offline" and its remaining files become ordinary cache. Text is kept. Caller saves.
    func releaseOfflineState(postIDs: Set<String>) {
        guard !postIDs.isEmpty else { return }
        let ids = Array(postIDs)
        for post in store.fetch(FetchDescriptor<Post>(predicate: #Predicate { ids.contains($0.postID) })) where post.offlineState != .none {
            post.offlineState = .none
        }
        for postID in ids {
            for entry in entries(postID: postID) where entry.isPinned {
                entry.isPinned = false
                relocate(entry)
            }
        }
    }

    func isCached(postID: String) -> Bool {
        var descriptor = FetchDescriptor<MediaCacheEntry>(predicate: #Predicate { $0.postID == postID })
        descriptor.fetchLimit = 1
        return ((try? store.context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Removes rows whose files vanished and files without rows (e.g. after a crash mid-write), and moves files whose
    /// location does not match their pin state (older builds kept pinned files in Caches). Posts whose saved files
    /// vanished (e.g. purged by iOS before they moved out of Caches) lose their offline state. Never touches text data.
    func reconcile() async {
        let cache = fileCache
        let cutoff = Date.now.addingTimeInterval(-300)
        let onDisk = await Task.detached(priority: .background) { () -> [String] in
            // A "すべて削除" cut short by suspension left its detached copy behind: finish deleting it. Old readable-name
            // links keep deleted files' bytes on disk: they go too.
            cache.removeLeftoverTrash()
            MediaFileCache.removeNamedLinks(modifiedBefore: cutoff)
            return cache.relativePaths(modifiedBefore: cutoff)
        }.value
        let entries = store.fetch(FetchDescriptor<MediaCacheEntry>())
        var changed = false
        var releasedPosts: Set<String> = []
        var known: Set<String> = []
        for entry in entries {
            if !cache.exists(relativePath: entry.relativePath) {
                if entry.isPinned, let postID = entry.postID { releasedPosts.insert(postID) }
                indexRemove(url: entry.url, variant: entry.variant)
                store.context.delete(entry)
                changed = true
                continue
            }
            if entry.isPinned != MediaFileCache.isPinnedPath(entry.relativePath) {
                relocate(entry)
                changed = true
            }
            known.insert(entry.relativePath)
        }
        if !releasedPosts.isEmpty {
            releaseOfflineState(postIDs: releasedPosts)
            AppLog.media.info("saved media vanished for \(releasedPosts.count, privacy: .public) posts; offline state released")
        }
        let orphans = onDisk.filter { !known.contains($0) }
        if !orphans.isEmpty {
            Task.detached(priority: .background) {
                for path in orphans { cache.removeFile(relativePath: path) }
            }
        }
        if changed {
            store.save()
            refreshUsage()
        }
    }

    // MARK: - Private

    private func fetchAndStore(_ request: MediaRequest, key: String) async throws -> URL {
        // Saved media goes straight to the pinned (non-purgeable) root.
        let pinned = request.pin || store.first(#Predicate<MediaCacheEntry> { $0.key == key })?.isPinned == true
        let relativePath = MediaFileCache.relativePath(url: request.url, variant: request.variant, kind: request.kind, pinned: pinned)
        let cache = fileCache
        let byteSize: Int
        if DemoMediaRenderer.canRender(request.url) {
            // Demo media is rendered locally but otherwise follows the exact same cache path as downloads.
            let url = request.url
            let variant = request.variant
            byteSize = try await Task.detached(priority: .utility) {
                let data = try DemoMediaRenderer.render(url: url, requestedVariant: variant)
                return try cache.write(data, relativePath: relativePath)
            }.value
        } else {
            guard let remoteURL = URL(string: request.url), let scheme = remoteURL.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else {
                throw RemoteError.invalidRequest("対応していないメディアURLです")
            }
            let httpRequest = HTTPRequest(url: remoteURL, timeout: 60, priority: request.priority,
                                          endpointKey: "media.\(request.variant.rawValue)")
            let throttle = MediaProgressThrottle()
            // A turned-off account sends nothing, whatever account a row or list still remembers for the media.
            let accountID = request.accountID.flatMap { store.account(id: $0)?.enabled == false ? nil : $0 }
            let (temporaryURL, response) = try await http.download(httpRequest, accountID: accountID) { [weak self] fraction in
                guard throttle.shouldForward(fraction) else { return }
                Task { @MainActor in self?.reportProgress(key: key, fraction: fraction) }
            }
            guard (200..<300).contains(response.statusCode) else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw Self.error(forStatus: response.statusCode)
            }
            byteSize = try await Task.detached(priority: .utility) {
                try cache.moveIntoPlace(from: temporaryURL, relativePath: relativePath)
            }.value
        }

        let now = Date.now
        if let existing = store.first(#Predicate<MediaCacheEntry> { $0.key == key }) {
            existing.relativePath = relativePath
            existing.byteSize = byteSize
            existing.lastAccessedAt = now
            if request.pin { existing.isPinned = true }
            if existing.postID == nil { existing.postID = request.postID }
            if existing.creatorID == nil { existing.creatorID = request.creatorID }
            // The pin state may have changed while downloading.
            relocate(existing)
            store.save()
            indexInsert(url: request.url, variant: request.variant)
            scheduleMaintenance()
            return fileCache.fileURL(relativePath: existing.relativePath)
        } else {
            let entry = MediaCacheEntry(key: key, url: request.url, variant: request.variant, kind: request.kind,
                                        relativePath: relativePath, byteSize: byteSize, postID: request.postID,
                                        creatorID: request.creatorID, isPinned: request.pin, createdAt: now)
            store.context.insert(entry)
        }
        indexInsert(url: request.url, variant: request.variant)
        store.save()
        scheduleMaintenance()
        return fileCache.fileURL(relativePath: relativePath)
    }

    /// Drops the in-flight record of `fetch` (a newer fetch of the same key keeps its own).
    private func finishFetch(key: String, fetch: InFlightFetch?) {
        guard let fetch, inFlight[key] === fetch else { return }
        inFlight[key] = nil
        downloadProgress[key] = nil
        activeFetchCount = inFlight.count
    }

    private func reportProgress(key: String, fraction: Double) {
        guard inFlight[key] != nil else { return }
        let clamped = min(max(fraction, 0), 1)
        let previous = downloadProgress[key] ?? -1
        // Throttle observation updates.
        if clamped >= 1 || clamped - previous >= 0.02 { downloadProgress[key] = clamped }
    }

    /// Applies the pin flag / owner ids of `request` to an existing entry (a cache hit or a shared in-flight fetch).
    private func applyOwnership(url: String, variant: MediaVariant, request: MediaRequest) {
        guard request.pin || request.postID != nil || request.creatorID != nil,
              let entry = cachedEntry(url: url, variant: variant) else { return }
        if request.pin, !entry.isPinned {
            entry.isPinned = true
            relocate(entry)
        }
        if entry.postID == nil, let postID = request.postID { entry.postID = postID }
        if entry.creatorID == nil, let creatorID = request.creatorID { entry.creatorID = creatorID }
    }

    private func setPinned(_ pinned: Bool, postID: String) {
        var changed = false
        for entry in entries(postID: postID) where entry.isPinned != pinned {
            entry.isPinned = pinned
            relocate(entry)
            changed = true
        }
        if changed {
            store.save()
            refreshUsage()
        }
    }

    /// Moves the entry's file to the root matching its pin state (pinned → Application Support, else Caches) and
    /// updates `relativePath`. A missing file keeps the old path (reconcile / the next lookup drops the row).
    private func relocate(_ entry: MediaCacheEntry) {
        let target = MediaFileCache.relocatedPath(entry.relativePath, pinned: entry.isPinned)
        guard target != entry.relativePath else { return }
        if fileCache.moveFile(from: entry.relativePath, to: target) {
            entry.relativePath = target
        }
    }

    /// Updates last access (throttled to avoid a write per frame).
    private func touch(_ entry: MediaCacheEntry) {
        let now = Date.now
        if now.timeIntervalSince(entry.lastAccessedAt) > 60 { entry.lastAccessedAt = now }
    }

    /// Deletes the row of a file that no longer exists (a saved file that vanished releases its post's offline state).
    private func forget(_ entry: MediaCacheEntry) {
        let releasedPost = entry.isPinned ? entry.postID : nil
        purgeMemory(url: entry.url)
        indexRemove(url: entry.url, variant: entry.variant)
        store.context.delete(entry)
        if let releasedPost { releaseOfflineState(postIDs: [releasedPost]) }
        store.save()
    }

    /// Deletes file + row (caller saves).
    private func remove(_ entry: MediaCacheEntry) {
        fileCache.removeFile(relativePath: entry.relativePath)
        purgeMemory(url: entry.url)
        indexRemove(url: entry.url, variant: entry.variant)
        store.context.delete(entry)
    }

    private func indexedVariants(for url: String) -> Set<MediaVariant> {
        if urlIndex == nil {
            var index: [String: Set<MediaVariant>] = [:]
            for entry in store.fetch(FetchDescriptor<MediaCacheEntry>()) {
                index[entry.url, default: []].insert(entry.variant)
            }
            urlIndex = index
        }
        return urlIndex?[url] ?? []
    }

    private func indexInsert(url: String, variant: MediaVariant) {
        guard urlIndex != nil else { return }
        urlIndex?[url, default: []].insert(variant)
    }

    private func indexRemove(url: String, variant: MediaVariant) {
        guard urlIndex != nil else { return }
        urlIndex?[url]?.remove(variant)
        if urlIndex?[url]?.isEmpty == true { urlIndex?[url] = nil }
    }

    private func purgeMemory(url: String) {
        for variant in MediaVariant.allCases {
            memoryCache.removeObject(forKey: Self.memoryKey(url: url, variant: variant))
        }
    }

    private func scheduleMaintenance() {
        guard maintenanceTask == nil else { return }
        let delay = maintenanceDelay
        maintenanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.maintenanceTask = nil
            self.refreshUsage()
            self.enforceCapacity()
        }
    }

    static func memoryKey(url: String, variant: MediaVariant) -> NSString {
        MediaFileCache.key(url: url, variant: variant) as NSString
    }

    static func error(forStatus status: Int) -> RemoteError {
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404, 410: return .notFound
        case 429: return .rateLimited(retryAfter: nil)
        default: return .server(status: status)
        }
    }
}

/// Forwards download progress at most every 2 % (URLSession reports per chunk).
private final class MediaProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Double = -1

    func shouldForward(_ value: Double) -> Bool {
        lock.withLock {
            guard value >= 1 || value - last >= 0.02 else { return false }
            last = value
            return true
        }
    }
}

/// One shared download per cache key (in-flight dedupe).
@MainActor
private final class InFlightFetch {
    let task: Task<URL, Error>
    var waiters = 0
    var cancelledWaiters = 0

    init(task: Task<URL, Error>) {
        self.task = task
    }
}

/// Lets the fetch task refer to its own `InFlightFetch` (created after the task). The reference cycle ends when the
/// task finishes and releases its closure.
@MainActor
private final class InFlightFetchBox {
    var fetch: InFlightFetch?
}

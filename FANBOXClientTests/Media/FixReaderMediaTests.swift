import SwiftData
import XCTest
@testable import FANBOXClient

/// Reader fixes: gallery sources for FANBOX-shaped images, decode-size cap, pinned storage outside Caches,
/// offline-state release when saved media goes away, and media prefetch.
@MainActor
final class FixReaderMediaTests: XCTestCase {
    private var h: MediaTestHarness!

    override func setUp() async throws {
        h = MediaTestHarness()
    }

    override func tearDown() async throws {
        h.cleanup()
        h = nil
    }

    // MARK: - Gallery sources (SPEC §6 Image Gallery)

    func testSourcesFallBackToSmallestLargerVariantWhenNoThumbnail() {
        // FANBOX image block: thumbnailURL nil, display + original only.
        let fanbox = RemoteImageSources.make(thumbnail: nil, display: "https://img/d.jpg", original: "https://img/o.jpg", maxVariant: .thumbnail)
        XCTAssertEqual(fanbox, [.display: "https://img/d.jpg"], "real variant key, never the original")
        // Only an original exists.
        XCTAssertEqual(RemoteImageSources.make(thumbnail: nil, display: nil, original: "https://img/o.jpg", maxVariant: .thumbnail),
                       [.original: "https://img/o.jpg"])
        // A thumbnail exists: no fallback, higher variants are not loaded by a thumbnail view.
        XCTAssertEqual(RemoteImageSources.make(thumbnail: "https://img/t.jpg", display: "https://img/d.jpg", original: nil,
                                               maxVariant: .thumbnail), [.thumbnail: "https://img/t.jpg"])
        // Display view keeps the staged thumbnail → display ladder.
        XCTAssertEqual(RemoteImageSources.make(thumbnail: "t", display: "d", original: "o", maxVariant: .display),
                       [.thumbnail: "t", .display: "d"])
        XCTAssertEqual(RemoteImageSources.make(thumbnail: "", display: "", original: nil, maxVariant: .thumbnail), [:])
    }

    func testTransientErrorsAreRetried() {
        XCTAssertTrue(RemoteImageSources.isTransient(RemoteError.network(code: -1001, detail: "timeout")))
        XCTAssertTrue(RemoteImageSources.isTransient(RemoteError.server(status: 503)))
        XCTAssertTrue(RemoteImageSources.isTransient(URLError(.timedOut)))
        XCTAssertFalse(RemoteImageSources.isTransient(RemoteError.notFound))
        XCTAssertFalse(RemoteImageSources.isTransient(RemoteError.forbidden))
        XCTAssertFalse(RemoteImageSources.isTransient(CancellationError()))
    }

    /// A cached display image decodes at thumbnail size for a grid tile, and the memory lookup of a tile finds it
    /// under the real (display) variant while a full-size view does not get the small bitmap.
    func testDisplayImageDecodedAtThumbnailSizeForTiles() async throws {
        let url = "demo://image/g1?w=1600&h=1200&v=display"
        _ = try await h.media.load(MediaRequest(url: url, variant: .display, postID: "p1"))
        let tile = try await h.media.image(MediaRequest(url: url, variant: .display, postID: "p1", decodeAs: .thumbnail))
        XCTAssertLessThanOrEqual(max(tile.size.width, tile.size.height) * tile.scale, 400)
        XCTAssertEqual(h.http.downloadCount, 0, "demo media is rendered locally; nothing downloaded")

        let hit = h.media.memoryCachedImageWithVariant(urls: [.display: url], upTo: .thumbnail)
        XCTAssertEqual(hit?.variant, .display)
        XCTAssertNil(h.media.memoryCachedImage(urls: [.display: url], upTo: .display), "the tile bitmap is not reused full size")
        XCTAssertEqual(MediaRequest(url: url, variant: .thumbnail, decodeAs: .display).decodeVariant, .thumbnail,
                       "never decoded larger than fetched")
    }

    /// Offline, a FANBOX-shaped gallery tile finds the display file saved by Offline save (no network, no policy).
    func testOfflineGalleryTileUsesSavedDisplayFile() async throws {
        let post = h.insertPost(id: "fx1")
        let display = "https://downloads.example/fx1/1200.jpg"
        h.addImageBlock(to: post, index: 0, thumbnail: nil, display: display, original: "https://downloads.example/fx1/orig.jpg")
        h.addImageBlock(to: post, index: 1, thumbnail: nil, display: "https://downloads.example/fx1/b1200.jpg", original: nil)
        let offline = h.makeOfflineService()
        let summary = await offline.save(postID: "fx1")
        XCTAssertEqual(summary.mediaSaved, 2, "display images of both blocks (no thumbnail URLs exist)")

        h.setMode(.offline)
        let sources = RemoteImageSources.make(thumbnail: nil, display: display, original: nil, maxVariant: .thumbnail)
        let variant = try XCTUnwrap(sources.keys.first)
        XCTAssertTrue(h.media.isFileCached(url: display, variant: variant))
        let image = try await h.media.image(MediaRequest(url: display, variant: variant, postID: "fx1", decodeAs: .thumbnail))
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertEqual(h.http.downloadCount, 2, "offline tile decode never downloads")
    }

    // MARK: - Pinned storage (SPEC §31 / §39)

    func testPinnedFilesLiveOutsideCachesAndMoveBackWhenUnpinned() async throws {
        _ = h.insertPost(id: "p1")
        _ = try await h.media.load(MediaRequest(url: "demo://image/pin1?v=display", variant: .display, postID: "p1", pin: true))
        _ = try await h.media.load(MediaRequest(url: "demo://image/pin2?v=display", variant: .display, postID: "p1"))

        let pinned = try XCTUnwrap(h.entries.first { $0.url.contains("pin1") })
        XCTAssertTrue(MediaFileCache.isPinnedPath(pinned.relativePath))
        let pinnedFile = h.media.fileCache.fileURL(relativePath: pinned.relativePath)
        XCTAssertTrue(pinnedFile.path.hasPrefix(h.media.fileCache.pinnedRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedFile.path))
        let excluded = try h.media.fileCache.pinnedRoot.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true, "re-downloadable saved media is excluded from backups")

        let plain = try XCTUnwrap(h.entries.first { $0.url.contains("pin2") })
        XCTAssertFalse(MediaFileCache.isPinnedPath(plain.relativePath))

        // Pin the post: the ordinary file moves out of Caches; unpin moves both back.
        h.media.pin(postID: "p1")
        XCTAssertTrue(h.entries.allSatisfy { MediaFileCache.isPinnedPath($0.relativePath) && h.fileExists($0) })
        h.media.unpin(postID: "p1")
        XCTAssertTrue(h.entries.allSatisfy { !MediaFileCache.isPinnedPath($0.relativePath) && h.fileExists($0) })
        XCTAssertTrue(h.entries.allSatisfy { h.media.fileCache.fileURL(relativePath: $0.relativePath).path.hasPrefix(h.root.path) })
    }

    func testReconcileMovesLegacyPinnedFilesAndReleasesPurgedSaves() async throws {
        let kept = h.insertPost(id: "keep")
        kept.offlineState = .saved
        let purged = h.insertPost(id: "gone")
        purged.offlineState = .saved
        _ = try await h.media.load(MediaRequest(url: "demo://image/legacy?v=display", variant: .display, postID: "keep"))
        _ = try await h.media.load(MediaRequest(url: "demo://image/purged?v=display", variant: .display, postID: "gone", pin: true))
        _ = try await h.media.load(MediaRequest(url: "demo://image/purged2?v=thumb", variant: .thumbnail, postID: "gone", pin: true))

        // An older build: pinned row whose file still sits in Caches.
        let legacy = try XCTUnwrap(h.entries.first { $0.postID == "keep" })
        legacy.isPinned = true
        h.env.store.save()
        XCTAssertFalse(MediaFileCache.isPinnedPath(legacy.relativePath))
        // iOS purged one saved file.
        let victim = try XCTUnwrap(h.entries.first { $0.url.contains("purged?") })
        try FileManager.default.removeItem(at: h.media.fileCache.fileURL(relativePath: victim.relativePath))

        await h.media.reconcile()

        let moved = try XCTUnwrap(h.entries.first { $0.postID == "keep" })
        XCTAssertTrue(MediaFileCache.isPinnedPath(moved.relativePath))
        XCTAssertTrue(h.fileExists(moved))
        XCTAssertEqual(kept.offlineState, .saved)
        XCTAssertEqual(purged.offlineState, OfflineState.none, "a saved post whose files vanished no longer claims Offline")
        let rest = h.entries(postID: "gone")
        XCTAssertEqual(rest.count, 1)
        XCTAssertFalse(rest[0].isPinned, "what is left becomes ordinary cache")
        XCTAssertTrue(h.fileExists(rest[0]))
    }

    func testCapacityEvictionOfSavedMediaReleasesThePost() async throws {
        let old = h.insertPost(id: "old")
        old.offlineState = .saved
        let fresh = h.insertPost(id: "fresh")
        fresh.offlineState = .autoSaved
        _ = try await h.media.load(MediaRequest(url: "demo://image/old1?w=1600&h=1200&v=display", variant: .display, postID: "old", pin: true))
        _ = try await h.media.load(MediaRequest(url: "demo://image/old2?w=400&h=300&v=thumb", variant: .thumbnail, postID: "old", pin: true))
        _ = try await h.media.load(MediaRequest(url: "demo://image/new1?w=1600&h=1200&v=display", variant: .display, postID: "fresh", pin: true))
        let oldDisplay = try XCTUnwrap(h.entries.first { $0.url.contains("old1") })
        oldDisplay.lastAccessedAt = .now.addingTimeInterval(-40 * 24 * 3600)
        h.env.store.save()

        let total = h.entries.reduce(Int64(0)) { $0 + Int64($1.byteSize) }
        h.media.enforceCapacity(limit: total - 1)

        XCTAssertNil(h.entries.first { $0.url.contains("old1") }, "old saved display image goes first among pinned")
        XCTAssertEqual(old.offlineState, OfflineState.none)
        XCTAssertFalse(h.entries(postID: "old").contains(where: \.isPinned))
        XCTAssertEqual(fresh.offlineState, .autoSaved, "untouched saves keep their state")
        XCTAssertTrue(h.entries(postID: "fresh").allSatisfy(\.isPinned))
    }

    func testRemovingOneSavedImageReleasesThePost() async throws {
        let post = h.insertPost(id: "p1")
        post.offlineState = .saved
        _ = try await h.media.load(MediaRequest(url: "demo://image/r1?v=display", variant: .display, postID: "p1", pin: true))
        _ = try await h.media.load(MediaRequest(url: "demo://image/r2?v=display", variant: .display, postID: "p1", pin: true))
        let key = try XCTUnwrap(h.entries.first?.key)
        h.media.removeEntry(key: key)
        XCTAssertEqual(post.offlineState, OfflineState.none)
        XCTAssertEqual(h.entries.count, 1)
        XCTAssertFalse(h.entries[0].isPinned)
    }

    func testSavedExceedsCapacityWarning() {
        var usage = CacheUsage()
        usage.pinnedBytes = 2_000_000_000
        XCTAssertTrue(CacheUsageText.savedExceedsCapacity(usage: usage, capacity: .gb1))
        XCTAssertFalse(CacheUsageText.savedExceedsCapacity(usage: usage, capacity: .gb5))
        XCTAssertFalse(CacheUsageText.savedExceedsCapacity(usage: usage, capacity: .unlimited))
    }

    // MARK: - Media prefetch (SPEC §1 item 6 / §25 / §30)

    private func makePrefetcher() -> MediaPrefetcher {
        let prefetcher = MediaPrefetcher(store: h.env.store, media: h.media)
        prefetcher.isAppInBackground = { false }
        return prefetcher
    }

    private func feedPost(_ id: String, minutesAgo: Double) -> Post {
        let post = h.insertPost(id: id, creatorID: "c1", publishedAt: .now.addingTimeInterval(-minutesAgo * 60), bodyFetched: false)
        post.coverImageURL = "demo://image/\(id)-cover?w=1200&h=630&v=thumb"
        post.creatorIconURL = "demo://image/c1-icon?w=200&h=200&v=thumb"
        post.isFromFollowedCreator = true
        h.env.store.save()
        return post
    }

    func testTimelineSyncPrefetchesThumbnailsOfNewPosts() async throws {
        _ = feedPost("n1", minutesAgo: 1)
        _ = feedPost("n2", minutesAgo: 2)
        let draft = feedPost("n3", minutesAgo: 3)
        draft.remoteStatusRaw = RemotePostStatus.draft.rawValue
        h.env.store.save()
        let prefetcher = makePrefetcher()

        let outcome = SyncOutcome(resource: .timeline, accountID: "A", scope: "", newItemIDs: ["n1", "n2", "n3"], error: nil)
        prefetcher.syncFinished(outcome, reason: .appLaunch)
        await prefetcher.waitUntilIdle()

        let urls = Set(h.entries.map(\.url))
        XCTAssertEqual(urls, ["demo://image/n1-cover?w=1200&h=630&v=thumb", "demo://image/n2-cover?w=1200&h=630&v=thumb",
                              "demo://image/c1-icon?w=200&h=200&v=thumb"], "covers + creator icon once; drafts skipped")
        XCTAssertTrue(h.entries.allSatisfy { $0.variant == .thumbnail && !$0.isPinned })
    }

    func testPrefetchRespectsPolicyReasonAndBackground() async throws {
        _ = feedPost("q1", minutesAgo: 1)
        let prefetcher = makePrefetcher()
        let outcome = SyncOutcome(resource: .timeline, accountID: "A", scope: "", newItemIDs: ["q1"], error: nil)

        prefetcher.syncFinished(outcome, reason: .backgroundRefresh)
        await prefetcher.waitUntilIdle()
        XCTAssertTrue(h.entries.isEmpty, "never in background refresh (SPEC §35)")

        prefetcher.isAppInBackground = { true }
        prefetcher.syncFinished(outcome, reason: .appLaunch)
        await prefetcher.waitUntilIdle()
        XCTAssertTrue(h.entries.isEmpty, "never while the app is in the background")
        prefetcher.isAppInBackground = { false }

        // Normal mode but not on Wi-Fi with the Wi-Fi-only setting (default on).
        h.env.networkMode.updatePath(satisfied: true, onWiFi: false, constrained: false, expensive: true)
        prefetcher.syncFinished(outcome, reason: .appLaunch)
        await prefetcher.waitUntilIdle()
        XCTAssertTrue(h.entries.isEmpty, "Wi-Fi only")

        h.env.networkMode.updatePath(satisfied: true, onWiFi: true, constrained: false, expensive: false)
        h.setMode(.extreme)
        prefetcher.syncFinished(outcome, reason: .appLaunch)
        await prefetcher.waitUntilIdle()
        XCTAssertTrue(h.entries.isEmpty, "Extreme blocks prefetch")

        h.setMode(.normal)
        prefetcher.syncFinished(outcome, reason: .foregroundPolling)
        await prefetcher.waitUntilIdle()
        XCTAssertFalse(h.entries.isEmpty)
    }

    func testNotificationPrefetchQueuesSmallMediaBeforeDisplayImages() async throws {
        let post = h.insertPost(id: "np1", creatorID: "c7")
        post.coverImageURL = "demo://image/np1-cover?v=thumb"
        for i in 0..<5 {
            h.addImageBlock(to: post, index: i, thumbnail: nil, display: "demo://image/np1-\(i)?v=display", original: "demo://image/np1-\(i)?v=original")
        }
        let event = NotificationEvent(id: "newPost|np1", type: .newPost, accountIDs: ["A"], title: "t", message: "m", timestamp: .now,
                                      creatorID: "c7", postID: "np1")
        event.actorIconURL = "demo://image/actor?v=thumb"
        h.env.store.context.insert(event)
        h.env.store.save()

        let prefetcher = makePrefetcher()
        prefetcher.notificationEventsProcessed(["newPost|np1"])
        await prefetcher.waitUntilIdle()

        let ordered = h.entries.sorted { $0.createdAt < $1.createdAt }
        XCTAssertEqual(ordered.prefix(2).map(\.variant), [.thumbnail, .thumbnail], "Priority 2 (avatar, thumbnail) first")
        XCTAssertEqual(ordered.filter { $0.variant == .display }.count, MediaPrefetcher.notificationDisplayLimit, "Priority 3, bounded")
        XCTAssertFalse(ordered.contains { $0.variant == .original }, "Priority 4 is never prefetched")
    }
}

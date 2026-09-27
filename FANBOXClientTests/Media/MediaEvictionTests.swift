import SwiftData
import XCTest
@testable import FANBOXClient

@MainActor
final class MediaEvictionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func candidate(_ key: String, pinned: Bool = false, _ variant: MediaVariant, daysAgo: Double,
                           size: Int64 = 100) -> MediaEvictionCandidate {
        MediaEvictionCandidate(key: key, byteSize: size, isPinned: pinned, variant: variant,
                               lastAccessedAt: now.addingTimeInterval(-daysAgo * day))
    }

    /// SPEC §32: Unpinned → Old → Original → Display → Thumbnail (then least recently used).
    func testPlannerOrder() {
        let candidates = [
            candidate("A", .display, daysAgo: 1),
            candidate("B", .thumbnail, daysAgo: 40),
            candidate("C", .original, daysAgo: 1),
            candidate("D", pinned: true, .original, daysAgo: 60),
            candidate("E", .thumbnail, daysAgo: 2),
            candidate("F", .display, daysAgo: 3),
            candidate("G", pinned: true, .thumbnail, daysAgo: 1),
        ]
        let order = MediaEvictionPlanner.order(candidates, now: now).map(\.key)
        XCTAssertEqual(order, ["B", "C", "F", "A", "E", "D", "G"])
    }

    func testVictimsStopOnceWithinLimit() {
        let candidates = [
            candidate("A", .display, daysAgo: 1),
            candidate("B", .thumbnail, daysAgo: 40),
            candidate("C", .original, daysAgo: 1),
            candidate("D", pinned: true, .original, daysAgo: 60),
            candidate("E", .thumbnail, daysAgo: 2),
            candidate("F", .display, daysAgo: 3),
        ]
        XCTAssertEqual(MediaEvictionPlanner.victims(candidates, limit: 350, now: now), ["B", "C", "F"])
        XCTAssertEqual(MediaEvictionPlanner.victims(candidates, limit: 600, now: now), [])
        XCTAssertEqual(MediaEvictionPlanner.victims(candidates, limit: 50, now: now), ["B", "C", "F", "A", "E", "D"])
    }

    /// A file the user just downloaded (and may be playing / previewing / sharing) is not the first victim.
    func testFreshDownloadIsEvictedAfterOlderCache() {
        let candidates = [
            candidate("video", .original, daysAgo: 0),
            candidate("A", .display, daysAgo: 1),
            candidate("B", .thumbnail, daysAgo: 2),
        ]
        XCTAssertEqual(MediaEvictionPlanner.victims(candidates, limit: 150, now: now), ["A", "B"])
        XCTAssertEqual(MediaEvictionPlanner.victims(candidates, limit: 50, now: now), ["A", "B", "video"])
    }

    func testEnforceCapacityDeletesInSpecOrderAndKeepsText() async throws {
        let h = MediaTestHarness()
        defer { h.cleanup() }
        let post = h.insertPost(id: "p1")
        post.bodyText = "text survives eviction"

        let thumb = "demo://image/e1?w=1600&h=1200&v=thumb"
        let display = "demo://image/e1?w=1600&h=1200&v=display"
        let original = "demo://image/e1?w=1600&h=1200&v=original"
        let pinned = "demo://image/e2?w=1600&h=1200&v=display"
        _ = try await h.media.load(MediaRequest(url: thumb, variant: .thumbnail, postID: "p1"))
        _ = try await h.media.load(MediaRequest(url: display, variant: .display, postID: "p1"))
        _ = try await h.media.load(MediaRequest(url: original, variant: .original, trigger: .manual, postID: "p1"))
        _ = try await h.media.load(MediaRequest(url: pinned, variant: .display, postID: "p2", pin: true))

        func entry(_ url: String) -> MediaCacheEntry? { h.entries.first { $0.url == url } }
        let sizes = Dictionary(uniqueKeysWithValues: h.entries.map { ($0.url, Int64($0.byteSize)) })
        let total = sizes.values.reduce(0, +)
        XCTAssertEqual(h.entries.count, 4)

        // Just over the limit by the original's size ⇒ only the original goes.
        h.media.enforceCapacity(limit: total - sizes[original]!)
        XCTAssertNil(entry(original))
        XCTAssertNotNil(entry(display))
        XCTAssertNotNil(entry(thumb))
        XCTAssertNotNil(entry(pinned))

        // Limit = pinned size ⇒ every unpinned file goes before the pinned one (display before thumbnail).
        h.media.enforceCapacity(limit: sizes[pinned]!)
        XCTAssertNil(entry(display))
        XCTAssertNil(entry(thumb))
        let pinnedEntry = try XCTUnwrap(entry(pinned))
        XCTAssertTrue(h.fileExists(pinnedEntry))
        XCTAssertEqual(h.media.usage.totalBytes, sizes[pinned]!)
        XCTAssertEqual(h.media.usage.fileCount, 1)

        // Capacity reached with pinned content only ⇒ pinned is evicted last.
        h.media.enforceCapacity(limit: 0)
        XCTAssertTrue(h.entries.isEmpty)
        XCTAssertEqual(h.env.store.post(id: "p1")?.bodyText, "text survives eviction")
    }

    func testOldUnpinnedIsEvictedBeforeRecentOriginal() async throws {
        let h = MediaTestHarness()
        defer { h.cleanup() }
        let oldThumb = "demo://image/old?w=400&h=400&v=thumb"
        let freshOriginal = "demo://image/fresh?w=400&h=400&v=original"
        _ = try await h.media.load(MediaRequest(url: oldThumb, variant: .thumbnail))
        _ = try await h.media.load(MediaRequest(url: freshOriginal, variant: .original, trigger: .manual))
        let old = try XCTUnwrap(h.entries.first { $0.url == oldThumb })
        old.lastAccessedAt = .now.addingTimeInterval(-45 * day)
        h.env.store.save()
        let fresh = try XCTUnwrap(h.entries.first { $0.url == freshOriginal })

        h.media.enforceCapacity(limit: Int64(fresh.byteSize))
        XCTAssertEqual(h.entries.map(\.url), [freshOriginal])
    }

    func testUnlimitedCapacityNeverEvicts() async throws {
        let h = MediaTestHarness()
        defer { h.cleanup() }
        _ = try await h.media.load(MediaRequest(url: "demo://image/u?v=display", variant: .display))
        h.env.settings.cacheCapacity = .unlimited
        h.media.enforceCapacity()
        h.media.enforceCapacity(limit: nil)
        XCTAssertEqual(h.entries.count, 1)
        h.env.settings.cacheCapacity = .gb1
        h.media.enforceCapacity()
        XCTAssertEqual(h.entries.count, 1, "far below 1 GB")
    }
}

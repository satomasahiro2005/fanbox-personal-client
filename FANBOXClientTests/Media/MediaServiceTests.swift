import SwiftData
import XCTest
@testable import FANBOXClient

@MainActor
final class MediaServiceTests: XCTestCase {
    private var h: MediaTestHarness!

    override func setUp() async throws {
        h = MediaTestHarness()
    }

    override func tearDown() async throws {
        h.cleanup()
        h = nil
    }

    // MARK: - Demo rendering path

    func testDemoImageIsRenderedLocallyIntoCacheWithEntry() async throws {
        let url = "demo://image/cover-1?w=1200&h=800&v=display"
        let fileURL = try await h.media.load(MediaRequest(url: url, variant: .display, postID: "p1", creatorID: "c1"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(fileURL.path.hasPrefix(h.root.path))
        XCTAssertEqual(fileURL.deletingLastPathComponent().lastPathComponent, "display")
        XCTAssertEqual(fileURL.lastPathComponent, MediaFileCache.hash(url) + ".jpg")
        XCTAssertEqual(h.http.downloadCount, 0, "demo media must never hit the network")

        let entries = h.entries
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.key, MediaFileCache.key(url: url, variant: .display))
        XCTAssertEqual(entry.variant, .display)
        XCTAssertEqual(entry.kind, .image)
        XCTAssertEqual(entry.postID, "p1")
        XCTAssertEqual(entry.creatorID, "c1")
        XCTAssertFalse(entry.isPinned)
        XCTAssertGreaterThan(entry.byteSize, 0)
        XCTAssertEqual(entry.byteSize, MediaFileCache.byteSize(of: fileURL))

        let image = try await h.media.image(MediaRequest(url: url, variant: .display))
        XCTAssertEqual(max(image.size.width, image.size.height), 1200, accuracy: 1)
        XCTAssertEqual(h.entries.count, 1, "second access is a cache hit")
    }

    func testThumbnailDecodeIsDownsampled() async throws {
        let url = "demo://image/big?w=3000&h=2000&v=original"
        let original = try await h.media.image(MediaRequest(url: url, variant: .original, trigger: .manual))
        XCTAssertEqual(max(original.size.width, original.size.height), 2400, accuracy: 1)

        let thumb = try await h.media.image(MediaRequest(url: url, variant: .thumbnail, trigger: .manual))
        XCTAssertLessThanOrEqual(max(thumb.size.width, thumb.size.height), 400)

        let best = h.media.bestCachedImage(urls: [.thumbnail: url], upTo: .display)
        XCTAssertNotNil(best, "same URL cached under another variant is reused")
    }

    func testDemoFileIsGeneratedWithRequestedSize() async throws {
        let url = "demo://file/sample.zip?size=2048"
        let fileURL = try await h.media.load(MediaRequest(url: url, variant: .original, kind: .file, trigger: .manual, postID: "p1"))
        XCTAssertEqual(fileURL.pathExtension, "zip")
        XCTAssertEqual(MediaFileCache.byteSize(of: fileURL), 2048)
        XCTAssertEqual(h.entries.first?.kind, .file)
    }

    func testDemoURLParsing() {
        XCTAssertEqual(DemoMediaURL("demo://image/abc?w=10&h=20&v=thumb"), .image(seed: "abc", width: 10, height: 20, variant: .thumbnail))
        XCTAssertEqual(DemoMediaURL("demo://file/a.pdf?size=5"), .file(name: "a.pdf", size: 5))
        XCTAssertNil(DemoMediaURL("https://example.com/a.jpg"))
        XCTAssertEqual(MediaFileCache.fileExtension(for: "https://example.com/x/y.JPEG?token=1", kind: .image), "jpeg")
        XCTAssertEqual(MediaFileCache.fileExtension(for: "https://example.com/noext", kind: .file), "bin")
        XCTAssertEqual(MediaFileCache.hash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Policy

    func testExtremeBlocksAutomaticDisplayButManualIsAllowed() async throws {
        h.setMode(.extreme)
        let remote = "https://downloads.example.com/images/1.jpg"

        do {
            _ = try await h.media.load(MediaRequest(url: remote, variant: .display, trigger: .automatic))
            XCTFail("automatic display must be blocked in Extreme")
        } catch {
            XCTAssertEqual(error as? RemoteError, .blockedByPolicy)
        }
        do {
            _ = try await h.media.load(MediaRequest(url: "demo://image/x?w=100&h=100&v=display", variant: .display))
            XCTFail("demo media follows the same policy")
        } catch {
            XCTAssertEqual(error as? RemoteError, .blockedByPolicy)
        }
        XCTAssertEqual(h.http.downloadCount, 0)
        XCTAssertTrue(h.entries.isEmpty)

        _ = try await h.media.load(MediaRequest(url: remote, variant: .display, trigger: .manual, accountID: "acc-1"))
        XCTAssertEqual(h.http.downloadCount, 1)
        let request = try XCTUnwrap(h.http.requests.first)
        XCTAssertEqual(request.endpointKey, "media.display")
        XCTAssertEqual(request.priority, .foregroundMedia)
        XCTAssertEqual(request.url.absoluteString, remote)
        XCTAssertEqual(h.http.requestedAccountIDs.first ?? nil, "acc-1")

        // Once cached, the automatic request is served locally even in Extreme.
        _ = try await h.media.load(MediaRequest(url: remote, variant: .display, trigger: .automatic))
        XCTAssertEqual(h.http.downloadCount, 1)
    }

    func testOfflineServesCacheOnly() async throws {
        let cached = "https://example.com/cached.png"
        _ = try await h.media.load(MediaRequest(url: cached, variant: .thumbnail))
        h.setMode(.offline)

        let hit = try await h.media.load(MediaRequest(url: cached, variant: .thumbnail, trigger: .manual))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hit.path))
        do {
            _ = try await h.media.load(MediaRequest(url: "https://example.com/other.png", variant: .thumbnail, trigger: .manual))
            XCTFail("offline must not fetch")
        } catch {
            XCTAssertEqual(error as? RemoteError, .blockedByPolicy)
        }
        XCTAssertEqual(h.http.downloadCount, 1)
    }

    func testLowDataBlocksOriginalPrefetchAndAttachmentAutomatic() async throws {
        h.setMode(.lowData)
        do {
            _ = try await h.media.load(MediaRequest(url: "https://example.com/o.jpg", variant: .original, trigger: .prefetch))
            XCTFail("Original Prefetch OFF")
        } catch {
            XCTAssertEqual(error as? RemoteError, .blockedByPolicy)
        }
        do {
            _ = try await h.media.load(MediaRequest(url: "https://example.com/a.zip", variant: .original, kind: .file))
            XCTFail("attachments are manual-only")
        } catch {
            XCTAssertEqual(error as? RemoteError, .blockedByPolicy)
        }
        _ = try await h.media.load(MediaRequest(url: "https://example.com/t.jpg", variant: .thumbnail))
        XCTAssertEqual(h.http.downloadCount, 1)
    }

    // MARK: - HTTP path

    func testConcurrentLoadsAreDeduplicated() async throws {
        h.http.delay = .milliseconds(150)
        let request = MediaRequest(url: "https://example.com/dedupe.png", variant: .display)
        async let first = h.media.load(request)
        async let second = h.media.load(request)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(h.http.downloadCount, 1)
        XCTAssertEqual(h.media.activeFetchCount, 0)

        _ = try await h.media.load(request)
        XCTAssertEqual(h.http.downloadCount, 1)
        XCTAssertEqual(h.entries.count, 1)
    }

    func testCacheSelfHealsWhenRowOrFileDisappears() async throws {
        let url = "https://example.com/drift.png"
        _ = try await h.media.load(MediaRequest(url: url, variant: .display))

        // Row removed behind the service's back ⇒ lookup resyncs and the next load re-fetches.
        for entry in h.entries { h.env.store.context.delete(entry) }
        h.env.store.save()
        XCTAssertNil(h.media.cachedEntry(url: url, variant: .display))
        _ = try await h.media.load(MediaRequest(url: url, variant: .display))
        XCTAssertEqual(h.http.downloadCount, 2)

        // File removed from disk ⇒ the stale row is dropped and the file re-fetched.
        let entry = try XCTUnwrap(h.entries.first)
        try FileManager.default.removeItem(at: h.media.fileCache.fileURL(relativePath: entry.relativePath))
        XCTAssertNil(h.media.cachedFileURL(url: url, variant: .display))
        let refetched = try await h.media.load(MediaRequest(url: url, variant: .display))
        XCTAssertTrue(FileManager.default.fileExists(atPath: refetched.path))
        XCTAssertEqual(h.http.downloadCount, 3)
        XCTAssertEqual(h.entries.count, 1)
    }

    func testHTTPErrorIsMappedAndNothingIsCached() async throws {
        h.http.statusCode = 404
        do {
            _ = try await h.media.load(MediaRequest(url: "https://example.com/missing.png", variant: .display))
            XCTFail("404 must throw")
        } catch {
            XCTAssertEqual(error as? RemoteError, .notFound)
        }
        XCTAssertTrue(h.entries.isEmpty)
    }

    func testCorruptPayloadIsDroppedOnDecodeFailure() async throws {
        h.http.payload = Data("<html>not an image</html>".utf8)
        do {
            _ = try await h.media.image(MediaRequest(url: "https://example.com/bad.png", variant: .display))
            XCTFail("decode must fail")
        } catch {
            guard case .decoding = error as? RemoteError else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertTrue(h.entries.isEmpty, "undecodable files are removed so they can be re-fetched")
    }

    // MARK: - Pin / clear

    func testPinUnpinAndClearCacheForPost() async throws {
        let post = h.insertPost(id: "p1")
        post.offlineState = .saved
        post.bodyText = "本文は残る"
        _ = try await h.media.load(MediaRequest(url: "demo://image/p1a?w=800&h=600&v=thumb", variant: .thumbnail, postID: "p1"))
        _ = try await h.media.load(MediaRequest(url: "demo://image/p1a?w=800&h=600&v=display", variant: .display, postID: "p1"))
        _ = try await h.media.load(MediaRequest(url: "demo://image/p2a?w=800&h=600&v=display", variant: .display, postID: "p2"))

        XCTAssertTrue(h.media.isCached(postID: "p1"))
        XCTAssertFalse(h.media.isCached(postID: "zzz"))

        h.media.pin(postID: "p1")
        XCTAssertTrue(h.entries(postID: "p1").allSatisfy(\.isPinned))
        XCTAssertFalse(h.entries(postID: "p2").contains(where: \.isPinned))

        h.media.refreshUsage()
        let p1Bytes = h.entries(postID: "p1").reduce(Int64(0)) { $0 + Int64($1.byteSize) }
        XCTAssertEqual(h.media.usage.fileCount, 3)
        XCTAssertEqual(h.media.usage.pinnedBytes, p1Bytes)
        XCTAssertEqual(h.media.usage.totalBytes, h.entries.reduce(Int64(0)) { $0 + Int64($1.byteSize) })
        XCTAssertEqual((h.media.usage.bytesByVariant[.thumbnail] ?? 0) + (h.media.usage.bytesByVariant[.display] ?? 0),
                       h.media.usage.totalBytes)

        h.media.unpin(postID: "p1")
        XCTAssertFalse(h.entries(postID: "p1").contains(where: \.isPinned))

        h.media.pin(postID: "p1")
        let p1Files = h.entries(postID: "p1").map { h.media.fileCache.fileURL(relativePath: $0.relativePath) }
        h.media.clearCache(postID: "p1")

        XCTAssertTrue(h.entries(postID: "p1").isEmpty, "clearCache deletes pinned files too")
        XCTAssertTrue(p1Files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(h.entries(postID: "p2").count, 1)
        let kept = try XCTUnwrap(h.env.store.post(id: "p1"))
        XCTAssertEqual(kept.offlineState, OfflineState.none)
        XCTAssertEqual(kept.bodyText, "本文は残る", "text is never evicted")
        XCTAssertFalse(h.media.isCached(postID: "p1"))
    }

    func testPinnedRequestOnCacheHitPinsExistingEntry() async throws {
        let url = "https://example.com/pin.png"
        _ = try await h.media.load(MediaRequest(url: url, variant: .display))
        XCTAssertEqual(h.entries.first?.isPinned, false)
        _ = try await h.media.load(MediaRequest(url: url, variant: .display, postID: "p9", pin: true))
        XCTAssertEqual(h.entries.first?.isPinned, true)
        XCTAssertEqual(h.entries.first?.postID, "p9")
        XCTAssertEqual(h.http.downloadCount, 1)
    }

    func testClearAllKeepsPinnedUnlessRequested() async throws {
        let post = h.insertPost(id: "p1")
        post.offlineState = .saved
        _ = try await h.media.load(MediaRequest(url: "demo://image/keep?v=display", variant: .display, postID: "p1", pin: true))
        _ = try await h.media.load(MediaRequest(url: "demo://image/drop?v=display", variant: .display, postID: "p2"))

        h.media.clearAll(includePinned: false)
        XCTAssertEqual(h.entries.count, 1)
        XCTAssertEqual(h.entries.first?.isPinned, true)
        XCTAssertEqual(post.offlineState, .saved)

        h.media.clearAll(includePinned: true)
        XCTAssertTrue(h.entries.isEmpty)
        XCTAssertEqual(post.offlineState, OfflineState.none)
        XCTAssertEqual(h.media.usage, CacheUsage())
    }
}

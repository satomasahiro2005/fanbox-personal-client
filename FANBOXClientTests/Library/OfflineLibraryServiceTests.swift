import SwiftData
import XCTest
@testable import FANBOXClient

@MainActor
final class OfflineLibraryServiceTests: XCTestCase {
    private var h: MediaTestHarness!
    private var offline: OfflineLibraryService!

    override func setUp() async throws {
        h = MediaTestHarness()
        offline = h.makeOfflineService()
    }

    override func tearDown() async throws {
        h.cleanup()
        offline = nil
        h = nil
    }

    private func makeRichPost(id: String = "p1") -> Post {
        let post = h.insertPost(id: id, title: "Rich post")
        post.coverImageURL = "https://img.example.com/\(id)/cover.jpg"
        post.detailAccountID = "acc-A"
        h.addImageBlock(to: post, index: 0, thumbnail: "https://img.example.com/\(id)/1-t.jpg",
                        display: "https://img.example.com/\(id)/1-d.jpg", original: "https://img.example.com/\(id)/1-o.jpg")
        h.addImageBlock(to: post, index: 1, thumbnail: "https://img.example.com/\(id)/2-t.jpg",
                        display: "https://img.example.com/\(id)/2-d.jpg", original: "https://img.example.com/\(id)/2-o.jpg")
        h.addFileBlock(to: post, index: 2, url: "https://files.example.com/\(id)/data.zip", name: "data", ext: "zip")
        let text = PostBlock(postID: id, index: 3, kind: .paragraph, text: "hello")
        h.env.store.context.insert(text)
        text.post = post
        h.env.store.save()
        return post
    }

    func testSaveMarksStateAndPinsThumbnailsDisplayAndAttachments() async throws {
        let post = makeRichPost()
        await offline.save(postID: "p1")

        XCTAssertEqual(post.offlineState, .saved)
        XCTAssertFalse(offline.activeSaves.contains("p1"))

        let entries = h.entries(postID: "p1")
        // cover (display) + 2 thumbnails + 2 displays + 1 attachment
        XCTAssertEqual(entries.count, 6)
        XCTAssertTrue(entries.allSatisfy(\.isPinned))
        XCTAssertEqual(entries.filter { $0.kind == .file }.count, 1)
        XCTAssertEqual(entries.filter { $0.variant == .thumbnail }.count, 2)
        XCTAssertTrue(entries.allSatisfy { h.fileExists($0) })

        let urls = h.http.requests.map(\.url.absoluteString)
        XCTAssertFalse(urls.contains { $0.hasSuffix("-o.jpg") }, "original images are not part of an offline save")
        XCTAssertTrue(h.http.requestedAccountIDs.allSatisfy { $0 == "acc-A" })

        let summary = try XCTUnwrap(offline.lastSummaries["p1"])
        XCTAssertEqual(summary.mediaRequested, 6)
        XCTAssertEqual(summary.mediaSaved, 6)
        XCTAssertTrue(summary.isComplete)

        // Saving twice does not re-download.
        await offline.save(postID: "p1")
        XCTAssertEqual(h.http.downloadCount, 6)
    }

    func testRemoveUnpinsButKeepsFilesAsNormalCache() async throws {
        let post = makeRichPost()
        await offline.save(postID: "p1")
        offline.remove(postID: "p1")

        XCTAssertEqual(post.offlineState, OfflineState.none)
        let entries = h.entries(postID: "p1")
        XCTAssertEqual(entries.count, 6)
        XCTAssertFalse(entries.contains(where: \.isPinned))
    }

    /// Offline解除 while the save is still downloading: nothing stays pinned for a post that is not saved.
    func testReleasingAPostWhileItIsBeingSavedLeavesNothingPinned() async throws {
        let post = makeRichPost()
        h.http.delay = .milliseconds(100)
        let saving = Task { await offline.save(postID: "p1") }
        var spins = 0
        while h.http.downloadCount == 0 && spins < 100_000 { spins += 1; await Task.yield() }
        offline.remove(postID: "p1")
        _ = await saving.value
        XCTAssertEqual(post.offlineState, OfflineState.none)
        XCTAssertFalse(h.entries(postID: "p1").contains(where: \.isPinned))
        // Sequential, checked before each request: at most the one in flight (and the next already started) went out.
        XCTAssertLessThanOrEqual(h.http.downloadCount, 2, "the rest is not downloaded")
    }

    /// Media requests never carry a disabled account's session.
    func testMediaIsNeverFetchedWithADisabledAccountsSession() {
        let post = h.insertPost(id: "d1")
        post.detailAccountID = "B"
        post.accessAccountIDs = ["B", "A"]
        h.addImageBlock(to: post, index: 0, thumbnail: nil, display: "https://img.example.com/d1.jpg", original: nil)
        let requests = OfflineLibraryService.mediaRequests(for: post, trigger: .manual, priority: .foregroundMedia, pin: true,
                                                           includeAttachments: false, disabledAccountIDs: ["B"])
        XCTAssertEqual(requests.map(\.accountID), ["A"])
        XCTAssertEqual(OfflineLibraryService.mediaAccount(for: post, excluding: []), "B")
    }

    func testSaveWhileOfflineKeepsTextOnly() async throws {
        let post = makeRichPost()
        post.bodyText = "offline body"
        h.setMode(.offline)
        await offline.save(postID: "p1")

        XCTAssertEqual(post.offlineState, .saved)
        XCTAssertTrue(h.entries.isEmpty)
        XCTAssertEqual(h.http.downloadCount, 0)
        let summary = try XCTUnwrap(offline.lastSummaries["p1"])
        XCTAssertEqual(summary.mediaBlocked, 6)
        XCTAssertEqual(summary.mediaSaved, 0)
    }

    func testSaveInExtremeUsesManualTrigger() async throws {
        _ = makeRichPost()
        h.setMode(.extreme)
        await offline.save(postID: "p1")
        XCTAssertEqual(h.entries(postID: "p1").count, 6, "explicit save is a manual action, allowed in Extreme")
    }

    func testSaveRecentSavesNewestNOfCreator() async throws {
        let creator = Creator(creatorID: "c9", name: "Creator 9")
        h.env.store.context.insert(creator)
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        for i in 0..<5 {
            let post = h.insertPost(id: "c9-\(i)", creatorID: "c9", title: "Post \(i)", publishedAt: base.addingTimeInterval(Double(i) * 3600))
            h.addImageBlock(to: post, index: 0, thumbnail: "demo://image/c9-\(i)?w=800&h=600&v=thumb",
                            display: "demo://image/c9-\(i)?w=800&h=600&v=display", original: nil)
        }
        await offline.saveRecent(creatorID: "c9", count: 2)

        // Rule-saved posts carry their own state (updated: they used to be indistinguishable from explicit saves).
        XCTAssertEqual(creator.offlineRecentCount, 2)
        XCTAssertEqual(h.env.store.post(id: "c9-4")?.offlineState, .ruleSaved)
        XCTAssertEqual(h.env.store.post(id: "c9-3")?.offlineState, .ruleSaved)
        XCTAssertEqual(h.env.store.post(id: "c9-2")?.offlineState, OfflineState.none)
        XCTAssertEqual(h.entries(postID: "c9-4").count, 2)
        XCTAssertTrue(h.entries(postID: "c9-4").allSatisfy(\.isPinned))
        XCTAssertTrue(h.entries(postID: "c9-0").isEmpty)
        XCTAssertTrue(offline.activeCreatorSaves.isEmpty)

        // Removing the rule releases what it saved (files stay as ordinary cache).
        await offline.saveRecent(creatorID: "c9", count: 0)
        XCTAssertEqual(creator.offlineRecentCount, 0)
        XCTAssertEqual(h.env.store.post(id: "c9-4")?.offlineState, OfflineState.none)
        XCTAssertFalse(h.entries(postID: "c9-4").contains(where: \.isPinned))
    }

    func testPostViewedRecordsHistoryAndAutoSavesWhenEnabled() async throws {
        let post = h.insertPost(id: "v1")
        h.addImageBlock(to: post, index: 0, thumbnail: "demo://image/v1?w=640&h=480&v=thumb",
                        display: "demo://image/v1?w=640&h=480&v=display", original: "demo://image/v1?w=640&h=480&v=original")

        h.env.settings.autoSaveViewedPosts = false
        await offline.postViewed(postID: "v1")
        XCTAssertNotNil(post.lastViewedAt)
        XCTAssertEqual(post.offlineState, OfflineState.none)
        XCTAssertTrue(h.entries.isEmpty)

        h.env.settings.autoSaveViewedPosts = true
        await offline.postViewed(postID: "v1")
        XCTAssertEqual(post.offlineState, .autoSaved)
        let entries = h.entries(postID: "v1")
        XCTAssertEqual(entries.map(\.variant), [.display], "auto-save prefetches display images only")
        // Updated: auto-saved media is pinned like every save unit (it used to be evicted first).
        XCTAssertTrue(entries.allSatisfy(\.isPinned))

        post.offlineState = .saved
        await offline.postViewed(postID: "v1")
        XCTAssertEqual(post.offlineState, .saved, "an explicit save is never downgraded")
    }

    func testAutoSavePrefetchBlockedInExtremeKeepsTextOnly() async throws {
        let post = h.insertPost(id: "v2")
        h.addImageBlock(to: post, index: 0, thumbnail: nil, display: "demo://image/v2?v=display", original: nil)
        h.env.settings.autoSaveViewedPosts = true
        h.setMode(.extreme)
        await offline.postViewed(postID: "v2")
        XCTAssertEqual(post.offlineState, .autoSaved)
        XCTAssertTrue(h.entries.isEmpty)
    }

    func testMediaRequestsSkipExternalVideoAndNonFetchableURLs() {
        let post = h.insertPost(id: "m1")
        let video = PostBlock(postID: "m1", index: 0, kind: .video)
        video.url = "https://www.youtube.com/watch?v=abc"
        video.embedProvider = "youtube"
        h.env.store.context.insert(video)
        video.post = post
        h.addImageBlock(to: post, index: 1, thumbnail: "file:///etc/passwd", display: "demo://image/m1?v=display", original: nil)
        h.addFileBlock(to: post, index: 2, kind: .audio, url: "https://files.example.com/a.mp3", name: "a", ext: "mp3")

        let requests = OfflineLibraryService.mediaRequests(for: post, trigger: .manual, priority: .foregroundMedia, pin: true,
                                                           includeAttachments: true)
        XCTAssertEqual(requests.map(\.url), ["demo://image/m1?v=display", "https://files.example.com/a.mp3"])
        XCTAssertEqual(requests.last?.kind, .audio)
        XCTAssertTrue(requests.allSatisfy { $0.pin && $0.postID == "m1" })
    }
}

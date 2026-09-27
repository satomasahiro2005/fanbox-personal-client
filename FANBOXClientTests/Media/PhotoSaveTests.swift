import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import FANBOXClient

/// 「写真に保存」 and the full-screen viewer for icons / covers: pximg originals, viewer items, which variant is saved
/// under each network mode, and the image type Photos receives.
@MainActor
final class PhotoSaveTests: XCTestCase {
    private var h: MediaTestHarness!

    override func setUp() async throws {
        h = MediaTestHarness()
    }

    override func tearDown() async throws {
        h.cleanup()
        h = nil
    }

    // MARK: - pximg originals (docs/API.md §1.9)

    func testPximgOriginalDropsTheSizeSegment() {
        XCTAssertEqual(FanboxMediaURL.pximgOriginal(of: "https://pixiv.pximg.net/c/160x160_90_a2_g5/fanbox/public/images/user/123/icon/aBc.jpeg"),
                       "https://pixiv.pximg.net/fanbox/public/images/user/123/icon/aBc.jpeg")
        XCTAssertEqual(FanboxMediaURL.pximgOriginal(of: "https://pixiv.pximg.net/c/1620x580_90_a2_g5/fanbox/public/images/creator/123/cover/x.png"),
                       "https://pixiv.pximg.net/fanbox/public/images/creator/123/cover/x.png")
        XCTAssertEqual(FanboxMediaURL.pximgOriginal(of: "https://pixiv.pximg.net/c/936x600_90_a2_g5/fanbox/public/images/plan/9/cover/k.jpeg"),
                       "https://pixiv.pximg.net/fanbox/public/images/plan/9/cover/k.jpeg")
    }

    func testPximgOriginalIgnoresOtherURLs() {
        XCTAssertNil(FanboxMediaURL.pximgOriginal(of: "https://pixiv.pximg.net/fanbox/public/images/user/123/icon/a.jpeg"),
                     "already un-resized")
        XCTAssertNil(FanboxMediaURL.pximgOriginal(of: "https://downloads.fanbox.cc/images/post/1/c/1200x630/a.jpeg"))
        XCTAssertNil(FanboxMediaURL.pximgOriginal(of: "https://example.com/c/160x160_90_a2_g5/fanbox/public/images/a.jpeg"))
        XCTAssertNil(FanboxMediaURL.pximgOriginal(of: "https://pixiv.pximg.net/c/160x160_90_a2_g5/img-master/a.jpeg"))
        XCTAssertNil(FanboxMediaURL.pximgOriginal(of: "https://pixiv.pximg.net/c/160x160_90_a2_g5/fanbox/public/images"))
        XCTAssertNil(FanboxMediaURL.pximgOriginal(of: "demo://image/icon-x?w=160&h=160&v=thumb"))
        XCTAssertNil(FanboxMediaURL.pximgOriginal(of: ""))
    }

    // MARK: - Viewer items

    func testResizedItemUsesPximgOriginalOrTheSameURL() {
        let icon = "https://pixiv.pximg.net/c/160x160_90_a2_g5/fanbox/public/images/user/1/icon/a.jpeg"
        let item = ImageViewerItem(id: "icon", resizedURL: icon)
        XCTAssertEqual(item.urls, [.thumbnail: icon, .display: icon,
                                   .original: "https://pixiv.pximg.net/fanbox/public/images/user/1/icon/a.jpeg"])
        XCTAssertTrue(item.originalIsDerived)
        XCTAssertTrue(item.saveSource().derivedOriginal)

        let demo = "demo://image/icon-a?w=160&h=160&v=thumb"
        let demoItem = ImageViewerItem(id: "icon", resizedURL: demo)
        XCTAssertEqual(demoItem.urls, [.thumbnail: demo, .display: demo, .original: demo])
        XCTAssertFalse(demoItem.originalIsDerived)

        let block = ImageViewerItem(id: "b", displayURL: "https://downloads.fanbox.cc/images/post/1/w/1200/a.jpeg",
                                    originalURL: "https://downloads.fanbox.cc/images/post/1/a.png")
        XCTAssertFalse(block.saveSource(postID: "1").derivedOriginal, "an original the API returned")
    }

    func testCreatorHeaderItemsStartAtTheTappedImage() {
        let items = CreatorHeaderImage.viewerItems(iconURL: "https://pixiv.pximg.net/c/160x160_90_a2_g5/fanbox/public/images/user/1/icon/i.jpeg",
                                                   coverURL: "https://pixiv.pximg.net/c/1620x580_90_a2_g5/fanbox/public/images/creator/1/cover/c.jpeg")
        XCTAssertEqual(items.map(\.id), ["icon", "cover"])
        XCTAssertEqual(items.map(\.originalURL), ["https://pixiv.pximg.net/fanbox/public/images/user/1/icon/i.jpeg",
                                                  "https://pixiv.pximg.net/fanbox/public/images/creator/1/cover/c.jpeg"])
        XCTAssertEqual(CreatorHeaderImage.startIndex(of: .icon, in: items), 0)
        XCTAssertEqual(CreatorHeaderImage.startIndex(of: .cover, in: items), 1)

        let coverOnly = CreatorHeaderImage.viewerItems(iconURL: "", coverURL: "demo://image/cover?w=1620&h=580&v=display")
        XCTAssertEqual(coverOnly.map(\.id), ["cover"])
        XCTAssertEqual(CreatorHeaderImage.startIndex(of: .cover, in: coverOnly), 0)
        XCTAssertEqual(CreatorHeaderImage.startIndex(of: .icon, in: coverOnly), 0, "missing image → first page")
        XCTAssertTrue(CreatorHeaderImage.viewerItems(iconURL: nil, coverURL: nil).isEmpty)
    }

    func testPostCoverOpensAsItsOwnViewerStart() {
        let cover = PostDetailImageViewerStart(index: 0, showsCover: true)
        let firstBlock = PostDetailImageViewerStart(index: 0)
        XCTAssertNotEqual(cover.id, firstBlock.id)
    }

    // MARK: - Which variant is saved (pure)

    func testChoicePrefersTheOriginal() {
        let urls: [MediaVariant: String] = [.display: "d", .original: "o"]
        let allowed: (MediaVariant) -> MediaDecision = { _ in .allowed }
        let blocked: (MediaVariant) -> MediaDecision = { _ in .blocked }

        XCTAssertEqual(ImageSaveChoice.choose(urls: urls, cached: [.display, .original], decision: blocked), .cached(.original))
        XCTAssertEqual(ImageSaveChoice.choose(urls: urls, cached: [.display], decision: allowed), .download(.original, fallback: .display))
        XCTAssertEqual(ImageSaveChoice.choose(urls: urls, cached: [], decision: allowed), .download(.original, fallback: nil))
    }

    func testChoiceFallsBackToTheBestCachedVariantWhenBlocked() {
        let urls: [MediaVariant: String] = [.thumbnail: "t", .display: "d", .original: "o"]
        let blocked: (MediaVariant) -> MediaDecision = { _ in .blocked }
        XCTAssertEqual(ImageSaveChoice.choose(urls: urls, cached: [.thumbnail, .display], decision: blocked), .cached(.display))
        XCTAssertEqual(ImageSaveChoice.choose(urls: urls, cached: [.thumbnail], decision: blocked), .cached(.thumbnail))
        XCTAssertEqual(ImageSaveChoice.choose(urls: urls, cached: [], decision: blocked), .unavailable)
        // Only the original is held back: nothing cached → the largest variant that may load.
        XCTAssertEqual(ImageSaveChoice.choose(urls: urls, cached: [], decision: { $0 == .original ? .manualOnly : .allowed }),
                       .download(.display, fallback: nil))
    }

    func testChoiceWithoutOriginalURL() {
        // Offline library items carry only the cached variant's URL.
        XCTAssertEqual(ImageSaveChoice.choose(urls: [.display: "d"], cached: [.display], decision: { _ in .blocked }), .cached(.display))
        XCTAssertEqual(ImageSaveChoice.choose(urls: [.display: "d"], cached: [], decision: { _ in .allowed }),
                       .download(.display, fallback: nil))
        XCTAssertEqual(ImageSaveChoice.choose(urls: [:], cached: [], decision: { _ in .allowed }), .unavailable)
    }

    // MARK: - File resolution with MediaService (network modes)

    func testExtremeLoadsTheOriginalAsAManualAction() async throws {
        h.setMode(.extreme)
        let source = ImageSaveSource(urls: [.display: "https://downloads.example/p1/1200.jpg", .original: "https://downloads.example/p1/o.png"],
                                     postID: "p1", creatorID: "c1", accountID: "acc-1")
        XCTAssertEqual(h.media.saveChoice(for: source), .download(.original, fallback: nil))

        let file = try await h.media.fileForSaving(source)
        XCTAssertEqual(file.variant, .original)
        XCTAssertTrue(file.downloaded)
        XCTAssertTrue(file.isBestAvailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.fileURL.path))
        XCTAssertEqual(h.http.downloadCount, 1)
        XCTAssertEqual(h.http.requests.first?.endpointKey, "media.original")
        XCTAssertEqual(h.http.requests.first?.url.absoluteString, "https://downloads.example/p1/o.png")
        XCTAssertEqual(h.http.requestedAccountIDs.first ?? nil, "acc-1", "authenticated originals load with the viewing account")
        let entry = try XCTUnwrap(h.entries.first)
        XCTAssertEqual(entry.postID, "p1")
        XCTAssertEqual(entry.creatorID, "c1")

        // Now cached: saved again without a download.
        XCTAssertEqual(h.media.saveChoice(for: source), .cached(.original))
        let again = try await h.media.fileForSaving(source)
        XCTAssertFalse(again.downloaded)
        XCTAssertEqual(h.http.downloadCount, 1)
    }

    func testOfflineSavesTheCachedDisplayImage() async throws {
        let display = "https://downloads.example/p2/1200.jpg"
        let displayFile = try await h.media.load(MediaRequest(url: display, variant: .display, postID: "p2"))
        h.setMode(.offline)
        let source = ImageSaveSource(urls: [.display: display, .original: "https://downloads.example/p2/o.png"], postID: "p2")

        XCTAssertEqual(h.media.saveChoice(for: source), .cached(.display))
        let file = try await h.media.fileForSaving(source)
        XCTAssertEqual(file.variant, .display)
        XCTAssertFalse(file.downloaded)
        XCTAssertFalse(file.isBestAvailable, "the original can still be saved once online")
        XCTAssertEqual(file.fileURL, displayFile)
        XCTAssertEqual(h.http.downloadCount, 1, "offline never downloads")
    }

    func testOfflineWithNothingCachedIsUnavailable() async throws {
        h.setMode(.offline)
        let source = ImageSaveSource(urls: [.display: "https://downloads.example/p3/1200.jpg", .original: "https://downloads.example/p3/o.png"])
        XCTAssertEqual(h.media.saveChoice(for: source), .unavailable)
        do {
            _ = try await h.media.fileForSaving(source)
            XCTFail("nothing to save offline")
        } catch {
            XCTAssertEqual(error as? PhotoSaveError, .unavailable)
        }
        XCTAssertEqual(h.http.downloadCount, 0)
    }

    func testRefusedDerivedOriginalFallsBackToTheCachedDisplayImage() async throws {
        let display = "https://pixiv.pximg.net/c/1620x580_90_a2_g5/fanbox/public/images/creator/1/cover/c.jpeg"
        _ = try await h.media.load(MediaRequest(url: display, variant: .display, creatorID: "c1"))
        let source = ImageViewerItem(id: "cover", resizedURL: display).saveSource(creatorID: "c1")
        XCTAssertEqual(h.media.saveChoice(for: source), .download(.original, fallback: .display))

        for status in [404, 403] {
            h.http.statusCode = status
            let file = try await h.media.fileForSaving(source)
            XCTAssertEqual(file.variant, .display, "\(status)")
            XCTAssertFalse(file.downloaded)
            XCTAssertTrue(file.isBestAvailable, "FANBOX does not serve a larger one")
            XCTAssertEqual(h.http.requests.last?.url.absoluteString,
                           "https://pixiv.pximg.net/fanbox/public/images/creator/1/cover/c.jpeg")
        }
    }

    /// Saved offline (smaller image), saved again online, FANBOX refuses the derived original: the fallback is the file
    /// already in Photos, so it is not added a second time.
    func testSecondSaveDoesNotAddTheSameSmallerImageAgain() async throws {
        let display = "https://pixiv.pximg.net/c/160x160_90_a2_g5/fanbox/public/images/user/1/icon/again.jpeg"
        _ = try await h.media.load(MediaRequest(url: display, variant: .display, creatorID: "c1"))
        let source = ImageViewerItem(id: "icon", resizedURL: display).saveSource(creatorID: "c1")
        h.http.statusCode = 404
        let file = try await h.media.fileForSaving(source)
        XCTAssertEqual(file.variant, .display)
        XCTAssertTrue(PhotoLibrarySaver.isAlreadyInPhotos(file, source: source, savedVariant: .display), "the offline save put it there")
        XCTAssertTrue(PhotoLibrarySaver.isAlreadyInPhotos(file, source: source, savedVariant: .thumbnail), "same URL, same file")
        XCTAssertFalse(PhotoLibrarySaver.isAlreadyInPhotos(file, source: source, savedVariant: nil), "a first save adds it")
        let original = ImageSaveFile(fileURL: file.fileURL, variant: .original, downloaded: true, isBestAvailable: true)
        XCTAssertFalse(PhotoLibrarySaver.isAlreadyInPhotos(original, source: source, savedVariant: .display), "a larger file is new")
    }

    /// A timeout, 5xx or dropped connection is not a refusal: the save fails so it can be retried for the original.
    func testTransientFailureOfADerivedOriginalIsReported() async throws {
        let display = "https://pixiv.pximg.net/c/160x160_90_a2_g5/fanbox/public/images/user/1/icon/i.jpeg"
        _ = try await h.media.load(MediaRequest(url: display, variant: .display, creatorID: "c1"))
        h.http.statusCode = 503
        let source = ImageViewerItem(id: "icon", resizedURL: display).saveSource(creatorID: "c1")
        do {
            _ = try await h.media.fileForSaving(source)
            XCTFail("a 503 is reported")
        } catch {
            guard case .failed? = error as? PhotoSaveError else { return XCTFail("\(error)") }
        }
    }

    /// An original the API returned (a post image) never silently falls back to the smaller cached variant.
    func testFailedAPIOriginalIsReportedEvenWithACachedDisplay() async throws {
        let display = "https://downloads.example/p5/1200.jpg"
        _ = try await h.media.load(MediaRequest(url: display, variant: .display, postID: "p5"))
        h.setMode(.lowData)
        let item = ImageViewerItem(id: "b", displayURL: display, originalURL: "https://downloads.example/p5/o.png")
        let source = item.saveSource(postID: "p5", accountID: "acc-1")
        XCTAssertEqual(h.media.saveChoice(for: source), .download(.original, fallback: .display))
        for status in [403, 404, 500] {
            h.http.statusCode = status
            do {
                _ = try await h.media.fileForSaving(source)
                XCTFail("\(status) is reported")
            } catch {
                guard case .failed? = error as? PhotoSaveError else { return XCTFail("\(status): \(error)") }
            }
        }
    }

    func testFailedDownloadWithoutFallbackIsReported() async throws {
        h.http.statusCode = 404
        let source = ImageSaveSource(urls: [.original: "https://downloads.example/p4/o.png"])
        do {
            _ = try await h.media.fileForSaving(source)
            XCTFail("404 with nothing cached")
        } catch {
            XCTAssertEqual(error as? PhotoSaveError, .failed(RemoteError.notFound.userMessage))
        }
    }

    /// An icon cached by the avatar (thumbnail variant) is saved offline through the same-URL cache fallback.
    func testIconCachedAsThumbnailIsSavedOffline() async throws {
        let icon = "https://example.com/icon.png"
        let iconFile = try await h.media.load(MediaRequest(url: icon, variant: .thumbnail))
        h.setMode(.offline)
        let source = ImageSaveSource(urls: ImageViewerItem(id: "icon", resizedURL: icon).urls)
        XCTAssertEqual(h.media.saveChoice(for: source), .cached(.original), "same URL ⇒ same bytes")
        let file = try await h.media.fileForSaving(source)
        XCTAssertEqual(file.fileURL, iconFile)
        XCTAssertTrue(file.isBestAvailable)
    }

    // MARK: - What Photos receives

    func testImageTypeComesFromTheBytes() throws {
        XCTAssertEqual(PhotoLibrarySaver.imageType(of: MediaTestFixtures.pngData()), .png)
        XCTAssertEqual(PhotoLibrarySaver.imageType(of: try Self.gifData()), .gif)
        let jpeg = try XCTUnwrap(UIImage(data: MediaTestFixtures.pngData())?.jpegData(compressionQuality: 0.8))
        XCTAssertEqual(PhotoLibrarySaver.imageType(of: jpeg), .jpeg)
        XCTAssertNil(PhotoLibrarySaver.imageType(of: Data("not an image".utf8)))
    }

    func testFileNameUsesTheRealType() {
        XCTAssertEqual(PhotoLibrarySaver.fileName(remoteURL: "https://downloads.fanbox.cc/images/post/1/abc.jpeg", type: .png), "abc.png")
        XCTAssertEqual(PhotoLibrarySaver.fileName(remoteURL: "https://pixiv.pximg.net/fanbox/public/images/user/1/icon/i.gif", type: .gif), "i.gif")
        XCTAssertNil(PhotoLibrarySaver.fileName(remoteURL: "demo://image/seed?w=1&h=1&v=display", type: .jpeg))
        XCTAssertNil(PhotoLibrarySaver.fileName(remoteURL: "https://example.com/", type: .jpeg))
    }

    func testErrorsMapToMessages() {
        XCTAssertEqual(PhotoSaveError(RemoteError.blockedByPolicy), .unavailable)
        XCTAssertEqual(PhotoSaveError(RemoteError.forbidden), .failed(RemoteError.forbidden.userMessage))
        XCTAssertEqual(PhotoSaveError(PhotoSaveError.denied), .denied)
        XCTAssertFalse(PhotoSaveError.denied.message.isEmpty)
        XCTAssertFalse(PhotoSaveError.unavailable.message.isEmpty)
    }

    private static func gifData() throws -> Data {
        let image = try XCTUnwrap(UIImage(data: MediaTestFixtures.pngData())?.cgImage)
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, UTType.gif.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

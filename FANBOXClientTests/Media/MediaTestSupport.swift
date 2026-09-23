import Foundation
import SwiftData
import UIKit
import XCTest
@testable import FANBOXClient

/// Fake HTTP transport for media tests: every download returns a fresh temp file containing `payload`.
final class MediaMockHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    private var accountIDs: [String?] = []

    var payload: Data
    var statusCode = 200
    var delay: Duration?

    init(payload: Data = MediaTestFixtures.pngData()) {
        self.payload = payload
    }

    var requests: [HTTPRequest] { lock.withLock { recorded } }
    var downloadCount: Int { lock.withLock { recorded.count } }
    var requestedAccountIDs: [String?] { lock.withLock { accountIDs } }

    func send(_ request: HTTPRequest, accountID: String?) async throws -> HTTPResponse {
        throw RemoteError.unsupported(operation: "send")
    }

    func download(_ request: HTTPRequest, accountID: String?,
                  progress: (@Sendable (Double) -> Void)?) async throws -> (URL, HTTPResponse) {
        lock.withLock {
            recorded.append(request)
            accountIDs.append(accountID)
        }
        if let delay { try await Task.sleep(for: delay) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("media-mock-\(UUID().uuidString).tmp")
        try payload.write(to: temporary)
        progress?(0.5)
        progress?(1)
        return (temporary, HTTPResponse(statusCode: statusCode, headers: [:], data: Data(), url: request.url, duration: 0.01))
    }

    func upload(_ request: HTTPRequest, bodyFileURL: URL, accountID: String?,
                progress: (@Sendable (Double) -> Void)?) async throws -> HTTPResponse {
        throw RemoteError.unsupported(operation: "upload")
    }
}

enum MediaTestFixtures {
    static func pngData(width: CGFloat = 64, height: CGFloat = 48) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { ctx in
            UIColor.systemPurple.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}

/// In-memory environment + a MediaService writing into a throwaway cache directory.
@MainActor
final class MediaTestHarness {
    let env: AppEnvironment
    let http: MediaMockHTTPClient
    let media: MediaService
    let root: URL

    init() {
        env = AppEnvironment.preview(seedDemo: false)
        http = MediaMockHTTPClient()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaTests-\(UUID().uuidString)", isDirectory: true)
        media = MediaService(store: env.store, http: http, network: env.networkMode, settings: env.settings, cacheRoot: root)
        // Keep background maintenance out of the way; tests call refreshUsage / enforceCapacity explicitly.
        media.maintenanceDelay = .seconds(3600)
    }

    func makeOfflineService() -> OfflineLibraryService {
        OfflineLibraryService(store: env.store, engine: env.sync, media: media, settings: env.settings)
    }

    func setMode(_ preference: NetworkModePreference) {
        env.settings.networkModePreference = preference
        env.networkMode.recompute()
    }

    var entries: [MediaCacheEntry] { env.store.fetch(FetchDescriptor<MediaCacheEntry>()) }

    func entries(postID: String) -> [MediaCacheEntry] { media.entries(postID: postID) }

    func fileExists(_ entry: MediaCacheEntry) -> Bool {
        FileManager.default.fileExists(atPath: media.fileCache.fileURL(relativePath: entry.relativePath).path)
    }

    @discardableResult
    func insertPost(id: String, creatorID: String = "c1", title: String = "Post", publishedAt: Date = .now,
                    bodyFetched: Bool = true) -> Post {
        let post = Post(postID: id, creatorID: creatorID, creatorName: "Creator \(creatorID)", title: title, publishedAt: publishedAt)
        if bodyFetched { post.bodyFetchedAt = .now }
        env.store.context.insert(post)
        env.store.save()
        return post
    }

    func addImageBlock(to post: Post, index: Int, thumbnail: String?, display: String?, original: String?) {
        let block = PostBlock(postID: post.postID, index: index, kind: .image)
        block.thumbnailURL = thumbnail
        block.displayURL = display
        block.originalURL = original
        env.store.context.insert(block)
        block.post = post
        env.store.save()
    }

    func addFileBlock(to post: Post, index: Int, kind: PostBlockKind = .file, url: String, name: String = "attachment", ext: String = "zip") {
        let block = PostBlock(postID: post.postID, index: index, kind: kind)
        block.originalURL = url
        block.fileName = name
        block.fileExtension = ext
        env.store.context.insert(block)
        block.post = post
        env.store.save()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: media.fileCache.pinnedRoot)
    }
}

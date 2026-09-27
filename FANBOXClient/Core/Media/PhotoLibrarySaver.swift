import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// The image 「写真に保存」 writes: its URLs by variant and the ids its downloads are attributed to.
struct ImageSaveSource: Sendable, Equatable {
    var urls: [MediaVariant: String]
    var postID: String?
    var creatorID: String?
    /// Account whose session loads authenticated media (downloads.fanbox.cc originals).
    var accountID: String?
    /// The original URL was derived by the app from a resized pximg URL (`FanboxMediaURL.pximgOriginal`), not returned by
    /// the API: FANBOX may refuse it for good.
    var derivedOriginal = false

    /// The largest variant the image has a URL for.
    var largestVariant: MediaVariant? { urls.keys.max() }
}

/// Which file 「写真に保存」 writes (pure, unit-tested).
enum ImageSaveChoice: Equatable, Sendable {
    /// A file already in the media cache.
    case cached(MediaVariant)
    /// Load this variant first (manual trigger). `fallback` (a cached variant) is saved instead only when FANBOX refuses
    /// an original the app derived (`ImageSaveSource.derivedOriginal`).
    case download(MediaVariant, fallback: MediaVariant?)
    /// Nothing cached and the network mode blocks every load.
    case unavailable

    /// The largest variant wins (the original when there is one): cached, or loaded now when the policy lets a manual
    /// load through. Otherwise the best cached variant; with nothing cached, the largest variant that may be loaded.
    static func choose(urls: [MediaVariant: String], cached: Set<MediaVariant>,
                       decision: (MediaVariant) -> MediaDecision) -> ImageSaveChoice {
        let available = MediaVariant.allCases.filter { urls[$0] != nil }
        guard let largest = available.last else { return .unavailable }
        if cached.contains(largest) { return .cached(largest) }
        let bestCached = available.last { cached.contains($0) }
        if decision(largest) == .allowed { return .download(largest, fallback: bestCached) }
        if let bestCached { return .cached(bestCached) }
        if let smaller = available.dropLast().last(where: { decision($0) == .allowed }) { return .download(smaller, fallback: nil) }
        return .unavailable
    }
}

/// The local file chosen for 「写真に保存」.
struct ImageSaveFile: Equatable {
    var fileURL: URL
    var variant: MediaVariant
    /// Loaded for this save (the viewer then shows it).
    var downloaded: Bool
    /// Nothing larger can be saved later: the largest variant the image has, or the cached variant saved because FANBOX
    /// refused a derived original. False when a smaller cached variant was saved while the original could not be loaded.
    var isBestAvailable: Bool
}

/// Why 「写真に保存」 did not save.
enum PhotoSaveError: Error, Equatable {
    /// Adding to Photos is not allowed (denied or restricted).
    case denied
    /// Nothing cached and the network mode blocks loading.
    case unavailable
    case failed(String)

    init(_ error: Error) {
        if let error = error as? PhotoSaveError {
            self = error
        } else if let remote = error as? RemoteError {
            self = remote == .blockedByPolicy ? .unavailable : .failed(remote.userMessage)
        } else {
            self = .failed(error.localizedDescription)
        }
    }

    var message: String {
        switch self {
        case .denied: return "設定で写真への追加を許可してください。"
        case .unavailable: return "オフラインのため画像を読み込めません。"
        case .failed(let detail): return detail
        }
    }
}

extension MediaService {
    /// What 「写真に保存」 would write now. Loads count as manual (SPEC §30: allowed in every mode except Offline).
    func saveChoice(for source: ImageSaveSource) -> ImageSaveChoice {
        let cached = Set(source.urls.compactMap { isFileCached(url: $0.value, variant: $0.key) ? $0.key : nil })
        return ImageSaveChoice.choose(urls: source.urls, cached: cached) { decision(kind: .image, variant: $0, trigger: .manual) }
    }

    /// The local file 「写真に保存」 writes: the original when it is cached or may be loaded now, otherwise the best cached
    /// variant. A failed load is reported (so the save can be retried), except when FANBOX refuses an original the app
    /// derived itself: then the cached smaller variant is the best there is.
    func fileForSaving(_ source: ImageSaveSource) async throws -> ImageSaveFile {
        let largest = source.largestVariant
        switch saveChoice(for: source) {
        case .cached(let variant):
            guard let file = cachedFile(source, variant) else { throw PhotoSaveError.unavailable }
            return ImageSaveFile(fileURL: file, variant: variant, downloaded: false, isBestAvailable: variant == largest)
        case .download(let variant, let fallback):
            guard let url = source.urls[variant] else { throw PhotoSaveError.unavailable }
            do {
                let file = try await load(MediaRequest(url: url, variant: variant, kind: .image, trigger: .manual,
                                                       priority: .foregroundMedia, postID: source.postID,
                                                       creatorID: source.creatorID, accountID: source.accountID))
                return ImageSaveFile(fileURL: file, variant: variant, downloaded: true, isBestAvailable: variant == largest)
            } catch {
                if variant == .original, source.derivedOriginal, Self.isRefusal(error),
                   let fallback, let file = cachedFile(source, fallback) {
                    return ImageSaveFile(fileURL: file, variant: fallback, downloaded: false, isBestAvailable: true)
                }
                throw PhotoSaveError(error)
            }
        case .unavailable:
            throw PhotoSaveError.unavailable
        }
    }

    /// FANBOX answered that the file is not there / not served (a timeout, 5xx or lost connection is not a refusal).
    private static func isRefusal(_ error: Error) -> Bool {
        guard let remote = error as? RemoteError else { return false }
        return remote == .notFound || remote == .forbidden
    }

    private func cachedFile(_ source: ImageSaveSource, _ variant: MediaVariant) -> URL? {
        source.urls[variant].flatMap { cachedFileURL(url: $0, variant: variant) }
    }
}

/// Saves images to the photo library (add-only access). The file's bytes are added unchanged, so GIF / PNG / JPEG keep
/// their format.
@MainActor
enum PhotoLibrarySaver {
    /// Asks for add-only access, picks (and if needed loads) the file, then adds it to Photos.
    @discardableResult
    static func save(_ source: ImageSaveSource, media: MediaService) async throws -> ImageSaveFile {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotoSaveError.denied }
        let file = try await media.fileForSaving(source)
        let fileURL = file.fileURL
        let data: Data
        do {
            data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: fileURL) }.value
        } catch {
            throw PhotoSaveError(error)
        }
        guard let type = imageType(of: data) else { throw PhotoSaveError.failed("画像として読み取れませんでした。") }
        let name = source.urls[file.variant].flatMap { fileName(remoteURL: $0, type: type) }
        do {
            // Photos runs the change block on its own queue: it must not be isolated to the main actor.
            try await PHPhotoLibrary.shared().performChanges { @Sendable in addPhoto(data, type: type, name: name) }
        } catch {
            throw PhotoSaveError(error)
        }
        return file
    }

    /// The creation request of `performChanges` (runs on the Photos queue).
    nonisolated static func addPhoto(_ data: Data, type: UTType, name: String?) {
        let options = PHAssetResourceCreationOptions()
        options.uniformTypeIdentifier = type.identifier
        options.originalFilename = name
        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
    }

    /// The real type from the bytes (the cache file's extension comes from the URL and is informational only).
    nonisolated static func imageType(of data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) else { return nil }
        return UTType(identifier as String)
    }

    /// File name shown in Photos: the URL's last path component with the extension of the real type.
    nonisolated static func fileName(remoteURL: String, type: UTType) -> String? {
        guard let url = URL(string: remoteURL), url.scheme == "https" || url.scheme == "http" else { return nil }
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        guard !base.isEmpty, base != "/" else { return nil }
        guard let ext = type.preferredFilenameExtension else { return base }
        return "\(base).\(ext)"
    }
}

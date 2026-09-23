import CryptoKit
import Foundation

/// On-disk layout of the media file cache (SPEC §32 / §39).
///
///     Caches/Media/<variant>/<sha256(url)>.<ext>
///
/// - Files are protected with `completeUntilFirstUserAuthentication` so background refresh can still read them.
/// - Pure value type: safe to use from detached tasks for file I/O off the main actor.
/// - Only media files live here. Text (post bodies, comments, metadata) lives in SwiftData and is never touched.
struct MediaFileCache: Sendable {
    let root: URL

    static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Media", isDirectory: true)
    }

    init(root: URL = MediaFileCache.defaultRoot) {
        self.root = root
    }

    // MARK: - Naming

    /// Lower-case hex SHA-256 of the remote URL string.
    static func hash(_ url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `MediaCacheEntry.key`: sha256(url) + variant.
    static func key(url: String, variant: MediaVariant) -> String {
        "\(hash(url)):\(variant.rawValue)"
    }

    /// File extension used for the cached file. ImageIO sniffs the real type, so this is informational
    /// (and keeps shared files recognizable by other apps).
    static func fileExtension(for url: String, kind: MediaKind) -> String {
        if let demo = DemoMediaURL(url) {
            switch demo {
            case .image: return "jpg"
            case .file(let name, _): return sanitizedExtension((name as NSString).pathExtension) ?? "bin"
            }
        }
        if let parsed = URL(string: url), let ext = sanitizedExtension(parsed.pathExtension) {
            return ext
        }
        return kind == .image ? "img" : "bin"
    }

    private static func sanitizedExtension(_ raw: String) -> String? {
        let ext = raw.lowercased()
        guard !ext.isEmpty, ext.count <= 8, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return ext
    }

    static func relativePath(url: String, variant: MediaVariant, kind: MediaKind) -> String {
        "\(variant.rawValue)/\(hash(url)).\(fileExtension(for: url, kind: kind))"
    }

    func fileURL(relativePath: String) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: false)
    }

    // MARK: - File operations (callable off the main actor)

    func ensureDirectory(for relativePath: String) throws {
        let dir = fileURL(relativePath: relativePath).deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: Self.protection])
        }
    }

    /// Moves a downloaded temporary file into the cache (replacing any previous file). Returns the byte size.
    @discardableResult
    func moveIntoPlace(from temporaryURL: URL, relativePath: String) throws -> Int {
        try ensureDirectory(for: relativePath)
        let destination = fileURL(relativePath: relativePath)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        do {
            try fm.moveItem(at: temporaryURL, to: destination)
        } catch {
            // Cross-volume or locked temp file: fall back to copy.
            try fm.copyItem(at: temporaryURL, to: destination)
            try? fm.removeItem(at: temporaryURL)
        }
        try? fm.setAttributes([.protectionKey: Self.protection], ofItemAtPath: destination.path)
        return Self.byteSize(of: destination)
    }

    /// Writes generated data (demo media) into the cache. Returns the byte size.
    @discardableResult
    func write(_ data: Data, relativePath: String) throws -> Int {
        try ensureDirectory(for: relativePath)
        let destination = fileURL(relativePath: relativePath)
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return data.count
    }

    func exists(relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(relativePath: relativePath).path)
    }

    func removeFile(relativePath: String) {
        try? FileManager.default.removeItem(at: fileURL(relativePath: relativePath))
    }

    /// Atomically detaches the whole cache directory (rename) and deletes it in the background.
    func removeEverything() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        let trash = root.deletingLastPathComponent()
            .appendingPathComponent(".media-trash-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.moveItem(at: root, to: trash)
            Task.detached(priority: .background) {
                try? FileManager.default.removeItem(at: trash)
            }
        } catch {
            try? fm.removeItem(at: root)
        }
    }

    /// Relative paths of files on disk that were last modified before `cutoff`
    /// (recent files are skipped so an in-progress move is never mistaken for an orphan).
    func relativePaths(modifiedBefore cutoff: Date) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var result: [String] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            if let modified = values.contentModificationDate, modified >= cutoff { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            var relative = String(path.dropFirst(rootPath.count))
            while relative.hasPrefix("/") { relative.removeFirst() }
            result.append(relative)
        }
        return result
    }

    static func byteSize(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }
}

// MARK: - Eviction (SPEC §32)

/// Minimal, Sendable view of a `MediaCacheEntry` for eviction planning.
struct MediaEvictionCandidate: Sendable, Hashable {
    var key: String
    var byteSize: Int64
    var isPinned: Bool
    var variant: MediaVariant
    var lastAccessedAt: Date
}

/// Pure eviction policy. SPEC §32 deletion priority:
///
///     Unpinned → Old → Original Image → Display Image → Thumbnail
///
/// Sort order used: unpinned before pinned; within that, "old" entries (not accessed for `oldThreshold`) first;
/// then variant original → display → thumbnail; then least-recently-accessed first.
enum MediaEvictionPlanner {
    static let oldThreshold: TimeInterval = 30 * 24 * 60 * 60

    static func variantRank(_ variant: MediaVariant) -> Int {
        switch variant {
        case .original: return 0
        case .display: return 1
        case .thumbnail: return 2
        }
    }

    static func isOld(_ candidate: MediaEvictionCandidate, now: Date) -> Bool {
        now.timeIntervalSince(candidate.lastAccessedAt) > oldThreshold
    }

    /// All candidates in eviction order (first = evicted first).
    static func order(_ candidates: [MediaEvictionCandidate], now: Date = .now) -> [MediaEvictionCandidate] {
        candidates.sorted { a, b in
            if a.isPinned != b.isPinned { return !a.isPinned }
            let oldA = isOld(a, now: now), oldB = isOld(b, now: now)
            if oldA != oldB { return oldA }
            let rankA = variantRank(a.variant), rankB = variantRank(b.variant)
            if rankA != rankB { return rankA < rankB }
            if a.lastAccessedAt != b.lastAccessedAt { return a.lastAccessedAt < b.lastAccessedAt }
            return a.key < b.key
        }
    }

    /// Keys to delete so that the remaining total fits `limit`. Empty when already within the limit.
    static func victims(_ candidates: [MediaEvictionCandidate], limit: Int64, now: Date = .now) -> [String] {
        var total = candidates.reduce(Int64(0)) { $0 + $1.byteSize }
        guard total > limit else { return [] }
        var result: [String] = []
        for candidate in order(candidates, now: now) {
            guard total > limit else { break }
            result.append(candidate.key)
            total -= candidate.byteSize
        }
        return result
    }
}

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One media file stored inside a draft's directory.
struct DraftMediaItem: Sendable, Equatable {
    /// Stored file name inside the draft directory ("<uuid>.<ext>").
    var fileName: String
    /// Name shown to the user (e.g. "1.jpg", "demo.zip").
    var originalFileName: String
    var mimeType: String
    var size: Int
    var width: Int?
    var height: Int?
    var kind: UploadKind
    var wasResized: Bool
    var wasConverted: Bool
}

enum DraftMediaError: Error, Equatable, LocalizedError {
    case unreadableImage
    case encodingFailed
    case unreadableFile
    case io(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "画像を読み込めませんでした"
        case .encodingFailed: return "画像を変換できませんでした"
        case .unreadableFile: return "ファイルを読み込めませんでした"
        case .io(let detail): return "ファイルを保存できませんでした（\(detail)）"
        }
    }
}

/// Output of `DraftImageProcessor.process`.
struct DraftProcessedImage: Sendable {
    var data: Data
    var type: UTType
    /// Pixel size after applying EXIF orientation.
    var width: Int
    var height: Int
    var wasResized: Bool
    var wasConverted: Bool
}

/// SPEC §18 "Resize / Convert if needed". Pure (no file system access), safe to call off the main actor.
/// - long edge > `maxLongEdge` ⇒ downscale (orientation applied)
/// - HEIC / HEIF (and other formats FANBOX does not take, e.g. TIFF) ⇒ JPEG quality 0.9
/// - an EXIF orientation other than "up" ⇒ redrawn upright in the same format. FANBOX does not apply the tag (its web
///   client redraws such JPEGs itself before `post.addImage`, docs/API.md §15.1), and the stored width / height then match
///   what FANBOX reports.
/// - JPEG / PNG otherwise kept in their format (only re-encoded when resized or redrawn); GIF kept byte-for-byte (animation)
/// - Location (GPS) metadata is stripped whenever the file is rewritten or can be rewritten losslessly.
enum DraftImageProcessor {
    static let maxLongEdge = 4096
    static let jpegQuality: Double = 0.9

    static func process(_ data: Data, maxLongEdge: Int = DraftImageProcessor.maxLongEdge) throws -> DraftProcessedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let typeID = CGImageSourceGetType(source) as String?,
              let sourceType = UTType(typeID) else {
            throw DraftMediaError.unreadableImage
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard let pixelWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let pixelHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              pixelWidth > 0, pixelHeight > 0 else {
            throw DraftMediaError.unreadableImage
        }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        let width = swapsAxes ? pixelHeight : pixelWidth
        let height = swapsAxes ? pixelWidth : pixelHeight
        let longEdge = max(width, height)

        // Animated / palette GIFs are kept untouched.
        if sourceType.conforms(to: .gif) {
            return DraftProcessedImage(data: data, type: .gif, width: width, height: height, wasResized: false, wasConverted: false)
        }

        let isPNG = sourceType.conforms(to: .png)
        let isJPEG = sourceType.conforms(to: .jpeg)
        let needsResize = longEdge > maxLongEdge
        let needsConvert = !(isPNG || isJPEG)
        // Pixels stored sideways / mirrored behind an orientation tag (e.g. an iPhone photo, 4032×3024 with orientation 6).
        let needsUpright = (2...8).contains(orientation)

        if !needsResize && !needsConvert && !needsUpright {
            let stripped = stripLocation(source: source, type: sourceType) ?? data
            return DraftProcessedImage(data: stripped, type: sourceType, width: width, height: height, wasResized: false, wasConverted: false)
        }

        // Re-rendered with the orientation applied (the output carries no orientation tag and no other metadata).
        let targetType: UTType = isPNG ? .png : .jpeg
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: needsResize ? maxLongEdge : longEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw DraftMediaError.unreadableImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, targetType.identifier as CFString, 1, nil) else {
            throw DraftMediaError.encodingFailed
        }
        var destinationOptions: [CFString: Any] = [:]
        if targetType == .jpeg { destinationOptions[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw DraftMediaError.encodingFailed }
        return DraftProcessedImage(data: output as Data, type: targetType, width: image.width, height: image.height,
                                   wasResized: needsResize, wasConverted: targetType != sourceType)
    }

    /// Lossless rewrite without GPS metadata (JPEG / PNG). Returns nil when not possible.
    private static func stripLocation(source: CGImageSource, type: UTType) -> Data? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              props[kCGImagePropertyGPSDictionary] != nil else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            error?.release()
            return nil
        }
        return output as Data
    }

    /// Small decoded thumbnail for list rows (orientation applied).
    static func thumbnail(at url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Local storage of draft media (SPEC §19 / §39): `Application Support/Drafts/<draftID>/<uuid>.<ext>`,
/// protected with iOS Data Protection. Works fully offline. Thread-safe (immutable), so heavy image work
/// can run off the main actor.
final class DraftMediaStore: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? DraftMediaStore.defaultRootDirectory
    }

    static var defaultRootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Drafts", isDirectory: true)
    }

    private static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    // MARK: Paths

    func directory(draftID: String) -> URL {
        rootDirectory.appendingPathComponent(Self.safeComponent(draftID), isDirectory: true)
    }

    func fileURL(draftID: String, fileName: String) -> URL {
        directory(draftID: draftID).appendingPathComponent(Self.safeComponent(fileName), isDirectory: false)
    }

    func fileExists(draftID: String, fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(draftID: draftID, fileName: fileName).path)
    }

    /// Keeps ids / names from escaping the drafts directory.
    static func safeComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "_" : cleaned
    }

    @discardableResult
    func ensureDirectory(draftID: String) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: rootDirectory.path) {
            try fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: [.protectionKey: Self.protection])
        }
        let dir = directory(draftID: draftID)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: Self.protection])
        }
        return dir
    }

    // MARK: Import

    /// Processes (resize / convert) and stores an image. `displayBaseName` becomes "<base>.<ext>" (e.g. "1.jpg").
    func storeImage(data: Data, draftID: String, displayBaseName: String) throws -> DraftMediaItem {
        let processed = try DraftImageProcessor.process(data)
        let ext = processed.type.preferredFilenameExtension ?? "jpg"
        let fileName = "\(UUID().uuidString).\(ext)"
        do {
            try ensureDirectory(draftID: draftID)
            try processed.data.write(to: fileURL(draftID: draftID, fileName: fileName),
                                     options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw DraftMediaError.io((error as NSError).localizedDescription)
        }
        return DraftMediaItem(fileName: fileName, originalFileName: "\(displayBaseName).\(ext)",
                              mimeType: processed.type.preferredMIMEType ?? "image/jpeg", size: processed.data.count,
                              width: processed.width, height: processed.height, kind: .image,
                              wasResized: processed.wasResized, wasConverted: processed.wasConverted)
    }

    /// Copies an attachment picked with `fileImporter` (security-scoped URL) into the draft directory. Not converted.
    func importFile(from url: URL, draftID: String) throws -> DraftMediaItem {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        let fileName = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let destination = fileURL(draftID: draftID, fileName: fileName)
        do {
            try ensureDirectory(draftID: draftID)
        } catch {
            throw DraftMediaError.io((error as NSError).localizedDescription)
        }

        var copyError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
            do {
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: readURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if coordinationError != nil || copyError != nil { throw DraftMediaError.unreadableFile }
        try? FileManager.default.setAttributes([.protectionKey: Self.protection], ofItemAtPath: destination.path)

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
        let type = UTType(filenameExtension: ext)
        return DraftMediaItem(fileName: fileName, originalFileName: url.lastPathComponent,
                              mimeType: type?.preferredMIMEType ?? "application/octet-stream", size: size,
                              width: nil, height: nil, kind: .file, wasResized: false, wasConverted: false)
    }

    // MARK: Export (web editor hand-off)

    /// Temporary directory holding shareable copies of a draft's media.
    func exportDirectory(draftID: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DraftExport", isDirectory: true)
            .appendingPathComponent(Self.safeComponent(draftID), isDirectory: true)
    }

    /// Shareable copies of stored files named "<NN>-<display name>" (NN = body position), so the web editor's file
    /// picker (Files) shows them in body order under recognizable names. The result is aligned with `files` (nil = the
    /// stored file is missing). Previous exports of the draft are replaced.
    func exportCopies(draftID: String, files: [(fileName: String, displayName: String, position: Int)]) -> [URL?] {
        let fm = FileManager.default
        let dir = exportDirectory(draftID: draftID)
        try? fm.removeItem(at: dir)
        guard !files.isEmpty, (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
            return files.map { _ in nil }
        }
        var result: [URL?] = []
        for file in files {
            let source = fileURL(draftID: draftID, fileName: file.fileName)
            guard fm.fileExists(atPath: source.path) else {
                result.append(nil)
                continue
            }
            var name = Self.safeComponent(file.displayName)
            if URL(fileURLWithPath: name).pathExtension.isEmpty, !source.pathExtension.isEmpty { name += "." + source.pathExtension }
            let target = dir.appendingPathComponent(String(format: "%02d-", file.position) + name, isDirectory: false)
            do {
                try fm.linkItem(at: source, to: target)
            } catch {
                guard (try? fm.copyItem(at: source, to: target)) != nil else {
                    result.append(nil)
                    continue
                }
            }
            result.append(target)
        }
        return result
    }

    // MARK: Upload staging

    /// Per-job links used while uploading (`<root>/_upload/<jobID>/<display name>`), next to the draft directories.
    var uploadStagingDirectory: URL { rootDirectory.appendingPathComponent("_upload", isDirectory: true) }

    /// The draft file under its display name, so the upload's multipart file name is the name the creator sees (FANBOX
    /// shows an attachment's name to supporters; stored files are named `<uuid>.<ext>`). A hard link to the same protected
    /// file (a copy when linking fails) in a per-job directory; remove it with `removeUploadStaging(jobID:)`.
    func stageUpload(draftID: String, fileName: String, displayName: String, jobID: String) throws -> URL {
        let fm = FileManager.default
        let source = fileURL(draftID: draftID, fileName: fileName)
        let dir = uploadStagingDirectory.appendingPathComponent(Self.safeComponent(jobID), isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: Self.protection])
        var name = Self.uploadName(displayName)
        if URL(fileURLWithPath: name).pathExtension.isEmpty, !source.pathExtension.isEmpty { name += "." + source.pathExtension }
        let target = dir.appendingPathComponent(name, isDirectory: false)
        do {
            try fm.linkItem(at: source, to: target)
        } catch {
            try fm.copyItem(at: source, to: target)
        }
        return target
    }

    func removeUploadStaging(jobID: String) {
        try? FileManager.default.removeItem(at: uploadStagingDirectory.appendingPathComponent(Self.safeComponent(jobID), isDirectory: true))
    }

    /// Drops staging links left by an interrupted upload (app killed mid-request). Called when the queue starts.
    func removeAllUploadStaging() {
        try? FileManager.default.removeItem(at: uploadStagingDirectory)
    }

    /// Display name usable as a single path component: keeps Unicode (Japanese names stay readable), drops separators and
    /// control characters, no leading dot, at most 120 characters (extension kept).
    static func uploadName(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != ":" && $0 != "\\" }
        var name = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 120 {
            let ext = URL(fileURLWithPath: name).pathExtension
            let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
            name = String(base.prefix(ext.isEmpty ? 120 : max(1, 119 - ext.count))) + (ext.isEmpty ? "" : "." + ext)
        }
        return name.isEmpty ? "file" : name
    }

    // MARK: Delete

    func removeFile(draftID: String, fileName: String) {
        try? FileManager.default.removeItem(at: fileURL(draftID: draftID, fileName: fileName))
    }

    /// Deletes every file of a draft (called when the draft is deleted).
    func removeAll(draftID: String) {
        try? FileManager.default.removeItem(at: directory(draftID: draftID))
        try? FileManager.default.removeItem(at: exportDirectory(draftID: draftID))
    }

    /// Bytes used by a draft's media.
    func totalSize(draftID: String) -> Int {
        let dir = directory(draftID: draftID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

import Foundation

/// `multipart/form-data` builder. A form with file parts is sent as a streamed body (`streamedBody()`: fields and part
/// headers from memory, files read from disk while they are sent), so an image / file upload never holds the whole
/// payload in memory and never writes it (with the CSRF token it carries) to disk.
struct MultipartFormData: Sendable {
    enum Part: Sendable, Hashable {
        case field(name: String, value: String)
        case file(name: String, fileURL: URL, fileName: String, mimeType: String)
        case data(name: String, data: Data, fileName: String, mimeType: String)
    }

    let boundary: String
    private(set) var parts: [Part] = []

    init(boundary: String = "FANBOXClientBoundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(name: String, value: String) {
        parts.append(.field(name: name, value: value))
    }

    mutating func addFile(name: String, fileURL: URL, fileName: String? = nil, mimeType: String? = nil) {
        let fname = fileName ?? fileURL.lastPathComponent
        parts.append(.file(name: name, fileURL: fileURL, fileName: fname,
                           mimeType: mimeType ?? MultipartFormData.mimeType(forExtension: fileURL.pathExtension)))
    }

    mutating func addData(name: String, data: Data, fileName: String, mimeType: String) {
        parts.append(.data(name: name, data: data, fileName: fileName, mimeType: mimeType))
    }

    /// Whole body in memory (small forms such as post.update, tests).
    func encodedData() throws -> Data {
        var out = Data()
        try write { out.append($0) }
        return out
    }

    /// The body for `HTTPClient.upload(_:streamedBody:...)`: part headers, fields and data parts in memory (adjacent ones
    /// merged), each file part read from disk while it is sent (its current size is announced). Nothing is written
    /// anywhere, so a form carrying the CSRF token (`tt`) may be sent this way.
    func streamedBody() throws -> HTTPStreamedBody {
        var segments: [HTTPStreamedBody.Segment] = []
        var pending = Data()
        for part in parts {
            pending.append(Data(header(for: part).utf8))
            switch part {
            case .field(_, let value):
                pending.append(Data(value.utf8))
            case .data(_, let data, _, _):
                pending.append(data)
            case .file(_, let fileURL, _, _):
                if !pending.isEmpty { segments.append(.data(pending)) }
                pending = Data()
                let size = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                segments.append(.file(fileURL, length: size))
            }
            pending.append(Data("\r\n".utf8))
        }
        pending.append(Data("--\(boundary)--\r\n".utf8))
        segments.append(.data(pending))
        return HTTPStreamedBody(segments: segments)
    }

    /// Whether any part is read from a file (such a form is sent as a streamed body).
    var hasFileParts: Bool {
        parts.contains { if case .file = $0 { return true } else { return false } }
    }

    /// Form field FANBOX's legacy multipart helper puts the CSRF token in.
    static let csrfFieldName = "tt"

    /// Whether the form carries the CSRF token as a field (such a form is never written to a file).
    var carriesCSRFField: Bool {
        parts.contains { part in
            if case .field(let name, _) = part { return name == Self.csrfFieldName }
            return false
        }
    }

    static let temporaryFilePrefix = "fanbox-multipart-"

    /// Writes the body to a new temporary file (complete file protection) and returns its URL. The caller deletes it
    /// after the upload. A form carrying the CSRF token is refused before anything is written (SPEC §39: the token lives
    /// in the Keychain or in memory only); send such a form with `streamedBody()`.
    func writeToTemporaryFile(directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        guard !carriesCSRFField else {
            throw RemoteError.invalidRequest("CSRFトークンを含むフォームはファイルに書き出せません")
        }
        let url = directory.appendingPathComponent("\(Self.temporaryFilePrefix)\(UUID().uuidString).body")
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.protectionKey: FileProtectionType.complete]) else {
            throw RemoteError.invalidRequest("一時ファイルを作成できませんでした")
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try write { try handle.write(contentsOf: $0) }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    /// Deletes multipart body files left behind by an interrupted upload (app killed mid-request; uploads are streamed now,
    /// but files from earlier versions may remain). Called at launch.
    /// Returns the number of files removed.
    @discardableResult
    static func removeStaleTemporaryFiles(in directory: URL = FileManager.default.temporaryDirectory,
                                          olderThan age: TimeInterval = 0, now: Date = .now) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(temporaryFilePrefix) && name.hasSuffix(".body") {
            let url = directory.appendingPathComponent(name)
            if age > 0, let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               now.timeIntervalSince(modified) < age { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Total body size in bytes (the `Content-Length` of a streamed upload); file parts are measured on disk.
    func contentLength() throws -> Int64 {
        try streamedBody().length
    }

    // MARK: - Encoding

    private func header(for part: Part) -> String {
        switch part {
        case .field(let name, _):
            return "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(escape(name))\"\r\n\r\n"
        case .file(let name, _, let fileName, let mimeType), .data(let name, _, let fileName, let mimeType):
            return "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(escape(name))\"; filename=\"\(escape(fileName))\"\r\n"
                + "Content-Type: \(mimeType)\r\n\r\n"
        }
    }

    private func write(_ sink: (Data) throws -> Void) throws {
        let crlf = Data("\r\n".utf8)
        for part in parts {
            try sink(Data(header(for: part).utf8))
            switch part {
            case .field(_, let value):
                try sink(Data(value.utf8))
            case .data(_, let data, _, _):
                try sink(data)
            case .file(_, let fileURL, _, _):
                let input = try FileHandle(forReadingFrom: fileURL)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                    try sink(chunk)
                }
            }
            try sink(crlf)
        }
        try sink(Data("--\(boundary)--\r\n".utf8))
    }

    private func escape(_ value: String) -> String {
        // Filter by Unicode scalar ("\r\n" is a single Character in Swift) so no CR / LF can reach a header line.
        let scalars = value.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }
        return String(String.UnicodeScalarView(scalars)).replacingOccurrences(of: "\"", with: "%22")
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "m4a": return "audio/mp4"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "zip": return "application/zip"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}

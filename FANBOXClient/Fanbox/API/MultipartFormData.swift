import Foundation

/// `multipart/form-data` builder. Large bodies are streamed to a temporary file (for `HTTPClient.upload`), so image /
/// file uploads never hold the whole payload in memory.
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

    /// Writes the body to a new temporary file and returns its URL. The caller deletes it after the upload.
    func writeToTemporaryFile(directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory.appendingPathComponent("fanbox-multipart-\(UUID().uuidString).body")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
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

    /// Total body size in bytes (for progress reporting); file parts are measured on disk.
    func contentLength() throws -> Int64 {
        var total: Int64 = 0
        for part in parts {
            total += Int64(header(for: part).utf8.count) + 2 // header + trailing CRLF
            switch part {
            case .field(_, let value): total += Int64(value.utf8.count)
            case .data(_, let data, _, _): total += Int64(data.count)
            case .file(_, let fileURL, _, _):
                let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                total += (attrs[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        total += Int64("--\(boundary)--\r\n".utf8.count)
        return total
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

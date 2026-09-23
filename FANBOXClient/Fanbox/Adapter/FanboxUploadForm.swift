import Foundation

/// Multipart forms of the FANBOX media endpoints (docs/API.md §15) and the client-side limits of FANBOX's own uploader.
///
/// - `post.addImage` `{postId, image}`, `post.addFile` `{postId, file}`, `post.addUrlEmbed` `{postId, url}`. Every upload
///   is stored INTO an existing post, so a new post is created first (`post.create`).
/// - Security (SPEC §38 / §39): these forms never contain the CSRF token. The web editor's legacy helper sends it as a
///   `tt` form field; the same bundle's newer request layer sends the `X-CSRF-Token` header instead, and that is what this
///   app does (`FanboxEndpoint.requiresCSRF` → the transport adds the header). An image / file body is streamed from a
///   temporary file, and the token must never be written to disk.
/// - Limits mirror the web client's own checks (not verified server limits): images jpeg / png / gif up to 50,000,000
///   bytes, attachments from a fixed extension list up to 300,000,000 bytes. They are checked before anything is sent.
enum FanboxUploadForm {
    enum Kind: Sendable {
        case image
        case file

        var uploadKind: UploadKind { self == .image ? .image : .file }
        var fieldName: String { self == .image ? "image" : "file" }
        var endpoint: FanboxEndpoint { self == .image ? .postAddImage() : .postAddFile() }
    }

    static let maxImageBytes = 50_000_000
    static let maxFileBytes = 300_000_000
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif"]
    static let fileExtensions: Set<String> = [
        "txt", "psd", "pdf", "zip", "jpg", "jpeg", "png", "gif", "wav", "mp3", "flac", "mp4", "mov", "avi", "clip",
    ]
    static let maxURLLength = 2048

    static let limits = DraftMediaLimits(maxImageBytes: maxImageBytes, maxFileBytes: maxFileBytes,
                                         imageExtensions: imageExtensions, fileExtensions: fileExtensions)

    // MARK: Validation

    /// Size / extension of the file about to be uploaded (its multipart file name is `fileURL.lastPathComponent`).
    /// Returns the size in bytes. Throws `RemoteError.invalidRequest` with a message for the creator.
    @discardableResult
    static func validate(fileURL: URL, kind: Kind) throws -> Int {
        let name = fileURL.lastPathComponent
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
            throw RemoteError.invalidRequest("「\(name)」を読み込めません")
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw RemoteError.invalidRequest("「\(name)」は空のファイルです") }
        if let problem = limits.problem(kind: kind.uploadKind, fileName: name, size: size) {
            throw RemoteError.invalidRequest(problem)
        }
        return size
    }

    static func validatePostID(_ postID: String) throws {
        guard !postID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteError.invalidRequest("アップロード先の投稿がありません")
        }
    }

    /// Trimmed http(s) URL for a link card.
    static func linkURL(_ raw: String) throws -> String {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { throw RemoteError.invalidRequest("リンクカードの URL が空です") }
        guard url.count <= maxURLLength else { throw RemoteError.invalidRequest("リンクカードの URL が長すぎます") }
        guard let comps = URLComponents(string: url), let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = comps.host, !host.isEmpty else {
            throw RemoteError.invalidRequest("リンクカードの URL が正しくありません（http / https）")
        }
        return url
    }

    // MARK: Forms

    /// `{postId, image|file}`. No `tt` field: the token is sent in the header only.
    static func uploadForm(kind: Kind, postID: String, fileURL: URL,
                           boundary: String = "FANBOXClientBoundary-\(UUID().uuidString)") throws -> MultipartFormData {
        try validatePostID(postID)
        try validate(fileURL: fileURL, kind: kind)
        var form = MultipartFormData(boundary: boundary)
        form.addField(name: "postId", value: postID)
        form.addFile(name: kind.fieldName, fileURL: fileURL, fileName: fileURL.lastPathComponent,
                     mimeType: MultipartFormData.mimeType(forExtension: fileURL.pathExtension))
        return form
    }

    /// `{postId, url}` (small; sent from memory).
    static func urlEmbedForm(postID: String, url: String,
                             boundary: String = "FANBOXClientBoundary-\(UUID().uuidString)") throws -> MultipartFormData {
        try validatePostID(postID)
        var form = MultipartFormData(boundary: boundary)
        form.addField(name: "postId", value: postID)
        form.addField(name: "url", value: try linkURL(url))
        return form
    }

    // MARK: Results

    static func result(_ image: FanboxImageDTO, postID: String) throws -> RemoteUploadResult {
        guard let id = image.id else { throw RemoteError.decoding(endpoint: "post.addImage", detail: "id がありません") }
        return RemoteUploadResult(mediaID: id, url: image.originalUrl ?? image.thumbnailUrl, postID: postID,
                                  thumbnailURL: image.thumbnailUrl, width: image.width, height: image.height,
                                  fileExtension: image.fileExtension)
    }

    static func result(_ file: FanboxFileDTO, postID: String) throws -> RemoteUploadResult {
        guard let id = file.id else { throw RemoteError.decoding(endpoint: "post.addFile", detail: "id がありません") }
        return RemoteUploadResult(mediaID: id, url: file.url, postID: postID, fileExtension: file.fileExtension, fileName: file.name,
                                  fileSize: file.size)
    }

    static func result(_ embed: FanboxURLEmbedDTO, postID: String, requestedURL: String) throws -> RemoteUploadResult {
        guard let id = embed.id else { throw RemoteError.decoding(endpoint: "post.addUrlEmbed", detail: "id がありません") }
        return RemoteUploadResult(mediaID: id, url: embed.url ?? requestedURL, postID: postID)
    }
}

extension DraftCapabilities {
    /// FANBOX (docs/API.md §14–§15): text / header blocks, image and file uploads (`post.addImage` / `post.addFile`) and
    /// new link cards (`post.addUrlEmbed`) natively, all stored into the post (created first when new); image- and
    /// file-type posts are updated with their own body shapes. Still web-only: new embed blocks (the current web client
    /// has no add-embed call; the old `post.addEmbed` is gone), the R-18 flag and a plan id (post.update has no field for
    /// either; posts are gated by `feeRequired`).
    static let fanbox = DraftCapabilities(nativeWrites: true, uploadsMedia: true, createsLinkCards: true, createsEmbeds: false,
                                          sendsAdultFlag: false, sendsPlanID: false, sendsCommentPermission: true,
                                          updatesNonArticlePosts: false, uploadsNeedPost: true, mediaPostBodies: true,
                                          mediaLimits: FanboxUploadForm.limits)
}

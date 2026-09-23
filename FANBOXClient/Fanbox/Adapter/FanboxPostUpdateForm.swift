import Foundation

/// Builds the `post.update` multipart form (docs/API.md §14.4).
///
/// - Article posts: the `body` field is the blocks array. Image / file / link-card blocks reference media BY ID only
///   (`imageMap` / `fileMap` / `urlEmbedMap` are never sent): ids already on the post (from post.getEditable) and ids
///   this app just stored into the same post (post.addImage / post.addFile / post.addUrlEmbed, `RemoteDraftBlock.media`
///   with that `postID`). Any other id throws `RemoteError.unsupported` (the web editor is the way forward).
/// - Image- / file-type posts: `body` is `{text, images}` / `{text, files}` with the full objects, in block order.
/// - The cover is never sent (omitting `coverImage` keeps it). Nothing here invents fields no source documents (planId,
///   adult flag); see docs/API.md §14.4 / §15.
enum FanboxPostUpdateForm {
    /// Media ids that already exist on the FANBOX post (from post.getEditable), usable in blocks.
    struct ExistingMedia: Sendable, Hashable {
        var imageIDs: Set<String> = []
        var fileIDs: Set<String> = []
        var embedIDs: Set<String> = []
        var urlEmbedIDs: Set<String> = []
        /// Full objects of the post's images / files (image- and file-type post bodies list them whole).
        var imageObjects: [String: FanboxImageDTO] = [:]
        var fileObjects: [String: FanboxFileDTO] = [:]

        init(imageIDs: Set<String> = [], fileIDs: Set<String> = [], embedIDs: Set<String> = [], urlEmbedIDs: Set<String> = []) {
            self.imageIDs = imageIDs
            self.fileIDs = fileIDs
            self.embedIDs = embedIDs
            self.urlEmbedIDs = urlEmbedIDs
        }

        /// Ids in the maps AND ids referenced by the body's blocks (a block whose map entry is missing is still part of the
        /// post and is written back unchanged).
        init(editable: FanboxManagedPostDTO?) {
            let body = editable?.body
            let blocks = body?.blocks ?? []
            imageIDs = Set((body?.imageMap ?? [:]).keys).union((body?.images ?? []).compactMap(\.id)).union(blocks.compactMap(\.imageId))
            fileIDs = Set((body?.fileMap ?? [:]).keys).union((body?.files ?? []).compactMap(\.id)).union(blocks.compactMap(\.fileId))
            embedIDs = Set((body?.embedMap ?? [:]).keys).union(blocks.compactMap(\.embedId))
            urlEmbedIDs = Set((body?.urlEmbedMap ?? [:]).keys).union(blocks.compactMap(\.urlEmbedId))
            for image in (body?.images ?? []) + Array((body?.imageMap ?? [:]).values) {
                if let id = image.id, imageObjects[id] == nil { imageObjects[id] = image }
            }
            for file in (body?.files ?? []) + Array((body?.fileMap ?? [:]).values) {
                if let id = file.id, fileObjects[id] == nil { fileObjects[id] = file }
            }
        }

        /// Adds the ids of media / link cards this app stored into `postID` (post.addImage / addFile / addUrlEmbed). Media
        /// uploaded into another post is never accepted.
        mutating func addUploads(for postID: String, in blocks: [RemoteDraftBlock]) {
            for block in blocks {
                guard let media = block.media, media.postID == postID, let id = block.mediaID, id == media.mediaID else { continue }
                switch block.kind {
                case .image: imageIDs.insert(id)
                case .file: fileIDs.insert(id)
                case .url: urlEmbedIDs.insert(id)
                case .text, .header, .embed: continue
                }
            }
        }
    }

    /// Blocks array JSON (the `body` field is the ARRAY only). Paragraph text is split on newlines into `p` blocks unless
    /// the block is an unchanged imported paragraph (`keepsLineBreaks`). Styles / links are sent only when present (an empty
    /// styles array must not be sent); link styles (`link:<url>`) go to `links`.
    static func blocksJSON(_ blocks: [RemoteDraftBlock], existing: ExistingMedia) throws -> JSONValue {
        var result: [JSONValue] = []
        for block in blocks {
            switch block.kind {
            case .text:
                if block.keepsLineBreaks || !block.text.contains("\n") {
                    result.append(textBlock(type: "p", text: block.text, styles: block.styles))
                } else {
                    for paragraph in DraftPostMapping.paragraphs(of: block.text, styles: block.styles) {
                        result.append(textBlock(type: "p", text: paragraph.text, styles: paragraph.styles))
                    }
                }
            case .header:
                // Same length as the original ("\n" → " "), so style offsets stay valid.
                let text = block.text.replacingOccurrences(of: "\n", with: " ")
                result.append(textBlock(type: "header", text: text, styles: block.styles))
            case .image:
                guard let id = block.mediaID, existing.imageIDs.contains(id) else {
                    throw RemoteError.unsupported(operation: "post.update: この投稿にアップロードされていない画像")
                }
                result.append(["type": "image", "imageId": .string(id)])
            case .file:
                guard let id = block.mediaID, existing.fileIDs.contains(id) else {
                    throw RemoteError.unsupported(operation: "post.update: この投稿にアップロードされていないファイル")
                }
                result.append(["type": "file", "fileId": .string(id)])
            case .url:
                guard let id = block.mediaID, existing.urlEmbedIDs.contains(id) else {
                    throw RemoteError.unsupported(operation: "post.update: この投稿に登録されていないリンクカード")
                }
                result.append(["type": "url_embed", "urlEmbedId": .string(id)])
            case .embed:
                guard let id = block.mediaID, existing.embedIDs.contains(id) else {
                    throw RemoteError.unsupported(operation: "post.update: 新しい埋め込み")
                }
                result.append(["type": "embed", "embedId": .string(id)])
            }
        }
        return .array(result)
    }

    /// `{ type, text, styles?, links? }`. Style offsets are passed through (docs/API.md §18.4).
    static func textBlock(type: String, text: String, styles: [RemoteTextStyle]) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string(type), "text": .string(text)]
        var styleValues: [JSONValue] = []
        var linkValues: [JSONValue] = []
        for style in styles where style.length > 0 && style.offset >= 0 {
            if style.type.hasPrefix(FanboxAdapter.linkStylePrefix) {
                let url = String(style.type.dropFirst(FanboxAdapter.linkStylePrefix.count))
                linkValues.append(["offset": .number(Double(style.offset)), "length": .number(Double(style.length)), "url": .string(url)])
            } else {
                var value: [String: JSONValue] = ["type": .string(style.type), "offset": .number(Double(style.offset)),
                                                  "length": .number(Double(style.length))]
                if let size = style.size { value["size"] = .number(Double(size)) }
                styleValues.append(.object(value))
            }
        }
        if !styleValues.isEmpty { object["styles"] = .array(styleValues) }
        if !linkValues.isEmpty { object["links"] = .array(linkValues) }
        return .object(object)
    }

    /// `commentingPermissionScope` is effectively required. The post's own value is kept when known; otherwise mirror the
    /// only client that sends it (supporters-only for paid posts, everyone for free posts).
    static func commentingScope(feeRequired: Int) -> String {
        CommentPermission.default(feeRequired: feeRequired).rawValue
    }

    static func commentingScope(for draft: RemotePostDraft) -> String {
        draft.commentPermission?.rawValue ?? commentingScope(feeRequired: draft.feeRequired)
    }

    /// Checks that need no request (title, tag count).
    static func validateBasics(_ draft: RemotePostDraft) throws {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteError.invalidRequest("タイトルを入力してください")
        }
        guard draft.tags.count <= DraftPostMapping.maxTags else {
            throw RemoteError.invalidRequest("タグは \(DraftPostMapping.maxTags) 個までです")
        }
    }

    /// `body` of the post by type: the blocks array (article), `{text, images}` (image), `{text, files}` (file).
    /// `existingText` is the post's current text: sent back byte-for-byte when the paragraphs did not change.
    static func bodyJSON(_ blocks: [RemoteDraftBlock], type: PostType, existing: ExistingMedia, existingText: String? = nil) throws -> JSONValue {
        switch type {
        case .article, .unknown:
            return try blocksJSON(blocks, existing: existing)
        case .image, .file:
            return try mediaPostBody(blocks, type: type, existing: existing, existingText: existingText)
        case .text, .video, .entry:
            throw RemoteError.unsupported(operation: "post.update: 「\(type.creatorLabel)」形式の投稿")
        }
    }

    /// Image- / file-type post body: text blocks become the text (paragraphs separated by an empty line, the way
    /// FANBOX's text is split into paragraphs on import) and image (file) blocks the list, in block order, each with the
    /// full object FANBOX reported (post.getEditable for media already on the post, the upload answer for new media).
    static func mediaPostBody(_ blocks: [RemoteDraftBlock], type: PostType, existing: ExistingMedia, existingText: String?) throws -> JSONValue {
        let isImagePost = type == .image
        var items: [JSONValue] = []
        var paragraphs: [String] = []
        for block in blocks {
            switch block.kind {
            case .text:
                guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                paragraphs.append(block.text)
            case .image where isImagePost:
                guard let id = block.mediaID, existing.imageIDs.contains(id) else {
                    throw RemoteError.unsupported(operation: "post.update: この投稿にアップロードされていない画像")
                }
                items.append(imageObject(id: id, known: existing.imageObjects[id], uploaded: block.media))
            case .file where !isImagePost:
                guard let id = block.mediaID, existing.fileIDs.contains(id) else {
                    throw RemoteError.unsupported(operation: "post.update: この投稿にアップロードされていないファイル")
                }
                items.append(fileObject(id: id, known: existing.fileObjects[id], uploaded: block.media))
            default:
                throw RemoteError.invalidRequest("「\(type.creatorLabel)」形式の投稿には\(isImagePost ? "画像" : "ファイル")と本文テキストだけを保存できます")
            }
        }
        var text = paragraphs.joined(separator: "\n\n")
        if let existingText, FanboxAdapter.textParagraphs(existingText).map(\.text) == paragraphs { text = existingText }
        return .object(["text": .string(text), isImagePost ? "images" : "files": .array(items)])
    }

    /// `{id, originalUrl, thumbnailUrl, width, height, extension}`; unknown fields are left out.
    static func imageObject(id: String, known: FanboxImageDTO?, uploaded: RemoteUploadResult?) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(id)]
        let original = known?.originalUrl ?? uploaded?.url
        let thumbnail = known?.thumbnailUrl ?? uploaded?.thumbnailURL
        let width = known?.width ?? uploaded?.width
        let height = known?.height ?? uploaded?.height
        let ext = known?.fileExtension ?? uploaded?.fileExtension
        if let original { object["originalUrl"] = .string(original) }
        if let thumbnail { object["thumbnailUrl"] = .string(thumbnail) }
        if let width { object["width"] = .number(Double(width)) }
        if let height { object["height"] = .number(Double(height)) }
        if let ext { object["extension"] = .string(ext) }
        return .object(object)
    }

    /// `{id, name, extension, size, url}`; unknown fields are left out.
    static func fileObject(id: String, known: FanboxFileDTO?, uploaded: RemoteUploadResult?) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(id)]
        let name = known?.name ?? uploaded?.fileName
        let ext = known?.fileExtension ?? uploaded?.fileExtension
        let size = known?.size ?? uploaded?.fileSize
        let url = known?.url ?? uploaded?.url
        if let name { object["name"] = .string(name) }
        if let ext { object["extension"] = .string(ext) }
        if let size { object["size"] = .number(Double(size)) }
        if let url { object["url"] = .string(url) }
        return .object(object)
    }

    /// `body`: the blocks array unless a prepared body (image- / file-type post) is given.
    static func make(postID: String, draft: RemotePostDraft, csrfToken: String, existing: ExistingMedia, body prepared: JSONValue? = nil,
                     boundary: String = "FANBOXClientBoundary-\(UUID().uuidString)") throws -> MultipartFormData {
        guard !csrfToken.isEmpty else { throw RemoteError.unauthorized }
        try validateBasics(draft)
        let body = try prepared ?? blocksJSON(draft.blocks, existing: existing)
        guard let bodyText = String(data: try body.encoded(), encoding: .utf8) else {
            throw RemoteError.invalidRequest("本文を変換できませんでした")
        }
        var form = MultipartFormData(boundary: boundary)
        form.addField(name: "postId", value: postID)
        form.addField(name: "status", value: draft.publish ? "published" : "draft")
        form.addField(name: "feeRequired", value: String(max(0, draft.feeRequired)))
        form.addField(name: "title", value: draft.title)
        form.addField(name: "commentingPermissionScope", value: commentingScope(for: draft))
        form.addField(name: "body", value: bodyText)
        for tag in draft.tags where !tag.isEmpty { form.addField(name: "tags", value: tag) }
        form.addField(name: "tt", value: csrfToken)
        return form
    }

    /// Fails early (before anything is created on FANBOX) when a NEW post would need uploads / new embeds, or when the
    /// title / tags would make the following post.update fail.
    static func validateForCreate(_ draft: RemotePostDraft) throws {
        try validateBasics(draft)
        _ = try blocksJSON(draft.blocks, existing: ExistingMedia())
    }
}

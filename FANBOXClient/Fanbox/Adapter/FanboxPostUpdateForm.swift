import Foundation

/// Builds the `post.update` multipart form (docs/API.md §14.4).
///
/// Scope (API.md "App scope"): native publishing covers article posts made of text / header blocks. Media blocks are
/// accepted ONLY when they reference media that already belongs to the post on FANBOX (round-trip of an edited post);
/// anything that would need an upload or a new URL embed throws `RemoteError.unsupported` so the UI falls back to the
/// web editor (SPEC §18 / §40). Nothing here invents fields that no source documents (planId, cover, schedule, adult flag).
enum FanboxPostUpdateForm {
    /// Media ids that already exist on the FANBOX post (from post.getEditable), usable in blocks.
    struct ExistingMedia: Sendable, Hashable {
        var imageIDs: Set<String> = []
        var fileIDs: Set<String> = []
        var embedIDs: Set<String> = []
        var urlEmbedIDs: Set<String> = []

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
                    throw RemoteError.unsupported(operation: "post.update: 新しい画像のアップロード")
                }
                result.append(["type": "image", "imageId": .string(id)])
            case .file:
                guard let id = block.mediaID, existing.fileIDs.contains(id) else {
                    throw RemoteError.unsupported(operation: "post.update: 新しいファイルのアップロード")
                }
                result.append(["type": "file", "fileId": .string(id)])
            case .url:
                guard let id = block.mediaID, existing.urlEmbedIDs.contains(id) else {
                    throw RemoteError.unsupported(operation: "post.update: 新しいリンクカード")
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

    static func make(postID: String, draft: RemotePostDraft, csrfToken: String, existing: ExistingMedia,
                     boundary: String = "FANBOXClientBoundary-\(UUID().uuidString)") throws -> MultipartFormData {
        guard !csrfToken.isEmpty else { throw RemoteError.unauthorized }
        try validateBasics(draft)
        let body = try blocksJSON(draft.blocks, existing: existing)
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

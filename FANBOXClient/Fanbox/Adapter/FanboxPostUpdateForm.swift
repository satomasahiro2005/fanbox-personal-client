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

        init(editable: FanboxManagedPostDTO?) {
            let body = editable?.body
            imageIDs = Set((body?.imageMap ?? [:]).keys).union((body?.images ?? []).compactMap(\.id))
            fileIDs = Set((body?.fileMap ?? [:]).keys).union((body?.files ?? []).compactMap(\.id))
            embedIDs = Set((body?.embedMap ?? [:]).keys)
            urlEmbedIDs = Set((body?.urlEmbedMap ?? [:]).keys)
        }
    }

    /// Blocks array JSON (the `body` field is the ARRAY only). Paragraph text is split on newlines into `p` blocks;
    /// no `styles` key is sent (an empty styles array must not be sent).
    static func blocksJSON(_ blocks: [RemoteDraftBlock], existing: ExistingMedia) throws -> JSONValue {
        var result: [JSONValue] = []
        for block in blocks {
            switch block.kind {
            case .text:
                let lines = block.text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
                for line in lines { result.append(["type": "p", "text": .string(line)]) }
            case .header:
                let text = block.text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
                result.append(["type": "header", "text": .string(text)])
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

    /// `commentingPermissionScope` is effectively required; mirror the behaviour of the only client that sends it
    /// (supporters-only for paid posts, everyone for free posts).
    static func commentingScope(feeRequired: Int) -> String {
        feeRequired > 0 ? "supporters" : "everyone"
    }

    static func make(postID: String, draft: RemotePostDraft, csrfToken: String, existing: ExistingMedia,
                     boundary: String = "FANBOXClientBoundary-\(UUID().uuidString)") throws -> MultipartFormData {
        guard !csrfToken.isEmpty else { throw RemoteError.unauthorized }
        guard draft.tags.count <= 6 else { throw RemoteError.invalidRequest("タグは 6 個までです") }
        let body = try blocksJSON(draft.blocks, existing: existing)
        guard let bodyText = String(data: try body.encoded(), encoding: .utf8) else {
            throw RemoteError.invalidRequest("本文を変換できませんでした")
        }
        var form = MultipartFormData(boundary: boundary)
        form.addField(name: "postId", value: postID)
        form.addField(name: "status", value: draft.publish ? "published" : "draft")
        form.addField(name: "feeRequired", value: String(max(0, draft.feeRequired)))
        form.addField(name: "title", value: draft.title)
        form.addField(name: "commentingPermissionScope", value: commentingScope(feeRequired: draft.feeRequired))
        form.addField(name: "body", value: bodyText)
        for tag in draft.tags where !tag.isEmpty { form.addField(name: "tags", value: tag) }
        form.addField(name: "tt", value: csrfToken)
        return form
    }

    /// Fails early (before anything is created on FANBOX) when a NEW post would need uploads / new embeds.
    static func validateForCreate(_ draft: RemotePostDraft) throws {
        _ = try blocksJSON(draft.blocks, existing: ExistingMedia())
    }
}

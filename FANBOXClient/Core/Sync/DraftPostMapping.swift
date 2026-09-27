import Foundation

/// Embed providers offered by the native editor ("+ Embed"). Raw values are FANBOX-neutral provider keys;
/// the FANBOX adapter maps them to the service's own identifiers.
enum DraftEmbedProvider: String, CaseIterable, Identifiable, Sendable {
    case youtube
    case vimeo
    case soundcloud
    case twitter
    case gist
    case googleForms = "google_forms"
    case fanbox

    var id: String { rawValue }

    /// Display name for a stored provider key (reader embed cards, editor). nil for keys this app does not know.
    static func displayName(forKey key: String?) -> String? {
        guard let key = key?.lowercased(), !key.isEmpty else { return nil }
        if key == "x" { return DraftEmbedProvider.twitter.displayName }
        return DraftEmbedProvider(rawValue: key)?.displayName
    }

    var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .vimeo: return "Vimeo"
        case .soundcloud: return "SoundCloud"
        case .twitter: return "X (Twitter)"
        case .gist: return "GitHub Gist"
        case .googleForms: return "Google Forms"
        case .fanbox: return "FANBOX"
        }
    }

    /// Best-effort extraction of the content id from a pasted URL. Returns the trimmed input when it is not a known URL shape.
    func contentID(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return trimmed }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch self {
        case .youtube:
            if host.hasSuffix("youtu.be"), let first = parts.first { return first }
            if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
                return v
            }
            if let i = parts.firstIndex(where: { ["shorts", "embed", "live"].contains($0) }), i + 1 < parts.count { return parts[i + 1] }
            return trimmed
        case .vimeo:
            return parts.last(where: { $0.allSatisfy(\.isNumber) }) ?? trimmed
        case .twitter:
            if let i = parts.firstIndex(of: "status"), i + 1 < parts.count { return parts[i + 1] }
            return trimmed
        case .gist:
            return parts.last ?? trimmed
        case .googleForms:
            if let i = parts.firstIndex(of: "e"), i + 1 < parts.count { return parts[i + 1] }
            if let i = parts.firstIndex(of: "d"), i + 1 < parts.count { return parts[i + 1] }
            return trimmed
        case .soundcloud, .fanbox:
            return trimmed
        }
    }
}

/// Pure mapping between local drafts and FANBOX-neutral remote shapes (no I/O).
enum DraftPostMapping {
    /// FANBOX accepts at most this many tags per post (docs/API.md §14.4).
    static let maxTags = 6
    /// Longest link-card URL sent to the service (`FanboxUploadForm.linkURL` refuses longer ones); checked in the plan so a
    /// bad URL never fails after a FANBOX draft was created for it.
    static let maxLinkCardURLLength = 2048

    /// Image / file blocks with neither a FANBOX id nor a local copy (media of a deleted FANBOX post).
    static func missingCopiesMessage(count: Int) -> String {
        "端末内にない画像・ファイルがあります（\(count)件）。ブロックを削除して追加し直してください。"
    }

    /// Normalized FANBOX tags: trimmed, leading "#" removed, empty and duplicate entries dropped (order kept).
    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in tags {
            var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while tag.hasPrefix("#") || tag.hasPrefix("＃") { tag.removeFirst() }
            tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, !seen.contains(tag) else { continue }
            seen.insert(tag)
            result.append(tag)
        }
        return result
    }

    /// Checks done BEFORE anything is sent (so a failure can never leave a half-made post behind).
    static func validateBasics(title: String, tags: [String]) throws {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw RemoteError.invalidRequest("タイトルを入力してください") }
        let count = normalizedTags(tags).count
        if count > maxTags { throw RemoteError.invalidRequest("タグは\(maxTags)個までです（現在\(count)個）") }
    }

    /// Payload plus what could not be carried natively.
    struct Payload: Sendable, Equatable {
        var draft: RemotePostDraft
        /// Blocks left out because they must be added in the web editor (text-first send).
        var webItemBlockIDs: [String]
        /// Edited paragraphs whose bold / link / size styles could not all be kept.
        var formattingLossBlockIDs: [String]
        /// Image / file blocks still to be uploaded (only with `allowPendingUploads`, i.e. when planning).
        var pendingUploadBlockIDs: [String] = []
        /// New link cards still to be registered in the post (`DraftCapabilities.uploadsNeedPost`; only when planning).
        var pendingLinkCardBlockIDs: [String] = []
    }

    /// Builds the create / update payload (legacy entry point: every block kind is sendable).
    static func remotePostDraft(from draft: Draft, publish: Bool) throws -> RemotePostDraft {
        try payload(from: draft, publish: publish, capabilities: .full).draft
    }

    /// Builds the create / update payload.
    /// - A title is required for every send, and at most `maxTags` tags (checked before any request).
    /// - Unchanged imported paragraphs (including empty spacing paragraphs) are sent back exactly, with their styles.
    ///   Edited paragraphs keep the styles outside the edited range; the others are reported in `formattingLossBlockIDs`.
    /// - New blocks the capabilities cannot send (uploads, new link cards / embeds) are left out and reported in
    ///   `webItemBlockIDs`; with upload capability an image / file block without `remoteMediaID` throws (upload first)
    ///   unless `allowPendingUploads` (planning before the upload queue ran), which reports it in `pendingUploadBlockIDs`
    ///   after checking it against `DraftCapabilities.mediaLimits`. One without a local copy either (media of a deleted
    ///   FANBOX post) always throws: nothing could be sent for it.
    /// - With `uploadsNeedPost` a new link card is registered in the post first (its id is then sent): unregistered cards
    ///   throw, or are reported in `pendingLinkCardBlockIDs` when planning.
    /// - Blocks that already reference FANBOX content (`remoteMediaID`) are sent back by id, with the upload / registration
    ///   result (`media`) when this app stored them.
    /// - An existing image- / file-type post (`DraftCapabilities.allowedKinds(in:)`) only takes image (file) blocks and
    ///   text; each text block is one paragraph of the post's text.
    static func payload(from draft: Draft, publish: Bool, capabilities: DraftCapabilities,
                        allowPendingUploads: Bool = false) throws -> Payload {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateBasics(title: title, tags: draft.tags)

        let postType: PostType = draft.remotePostID == nil ? .article : draft.remotePostType
        let allowedKinds = capabilities.allowedKinds(in: postType)
        var blocks: [RemoteDraftBlock] = []
        var webItems: [String] = []
        var formattingLoss: [String] = []
        var pendingUploads: [String] = []
        var pendingLinks: [String] = []
        var missingMedia = 0
        var missingCopies = 0
        var missingLinks = 0
        var disallowed = 0
        var problems: [String] = []
        for block in draft.orderedBlocks {
            // A locked note stands for FANBOX content that cannot be written back (the draft is then blocked anyway).
            if block.isLockedRemote && block.remoteMediaID == nil && (block.kind == .text || block.kind == .header) { continue }
            if let allowedKinds, !allowedKinds.contains(block.kind) {
                if hasContent(block) { disallowed += 1 }
                continue
            }
            switch block.kind {
            case .text, .header:
                if allowedKinds != nil {
                    // Image / file post: the text is plain; one block = one paragraph of it.
                    guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    blocks.append(RemoteDraftBlock(kind: .text, text: block.text, mediaID: nil, url: nil, embedProvider: nil,
                                                   embedContentID: nil, keepsLineBreaks: true))
                    continue
                }
                if let imported = block.importedText, imported == block.text {
                    blocks.append(RemoteDraftBlock(kind: block.kind, text: block.text, mediaID: nil, url: nil, embedProvider: nil,
                                                   embedContentID: nil, styles: block.importedStyles, keepsLineBreaks: true))
                    continue
                }
                guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let sent = sentStyles(of: block)
                if sent.lost > 0 { formattingLoss.append(block.id) }
                if block.kind == .header {
                    blocks.append(RemoteDraftBlock(kind: .header, text: block.text, mediaID: nil, url: nil, embedProvider: nil,
                                                   embedContentID: nil, styles: sent.styles))
                } else {
                    // One paragraph per line (the service has no line breaks inside a paragraph); empty lines are spacing.
                    for paragraph in paragraphs(of: block.text, styles: sent.styles) {
                        blocks.append(RemoteDraftBlock(kind: .text, text: paragraph.text, mediaID: nil, url: nil, embedProvider: nil,
                                                       embedContentID: nil, styles: paragraph.styles))
                    }
                }
            case .image, .file:
                if let mediaID = block.remoteMediaID, !mediaID.isEmpty {
                    blocks.append(RemoteDraftBlock(kind: block.kind, text: "", mediaID: mediaID, url: nil, embedProvider: nil,
                                                   embedContentID: nil, media: block.remoteMedia))
                } else if block.localFileName != nil, !capabilities.sendsNew(block.kind) {
                    webItems.append(block.id)
                } else if let local = block.localFileName, allowPendingUploads {
                    if let limits = capabilities.mediaLimits,
                       let problem = limits.problem(kind: block.kind == .image ? .image : .file, fileName: block.originalFileName ?? local,
                                                    size: block.fileSize) {
                        problems.append(problem)
                    }
                    pendingUploads.append(block.id)
                } else if block.localFileName == nil {
                    // Neither on FANBOX nor on this device (media of a deleted FANBOX post, `detachFromRemotePost`).
                    missingCopies += 1
                } else {
                    missingMedia += 1
                }
            case .url:
                let url = (block.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let mediaID = block.remoteMediaID, !mediaID.isEmpty {
                    blocks.append(RemoteDraftBlock(kind: .url, text: block.text, mediaID: mediaID, url: url.isEmpty ? nil : url,
                                                   embedProvider: nil, embedContentID: nil, media: block.remoteMedia))
                    continue
                }
                guard !url.isEmpty else { continue }
                if !capabilities.sendsNew(.url) {
                    webItems.append(block.id)
                    continue
                }
                if capabilities.uploadsNeedPost {
                    if !isWebURL(url) {
                        problems.append("リンクカードのURLが正しくありません（http / https）: \(url.prefix(60))")
                    } else if url.count > maxLinkCardURLLength {
                        problems.append("リンクカードのURLが長すぎます（\(maxLinkCardURLLength)文字まで）: \(url.prefix(60))…")
                    } else if allowPendingUploads {
                        pendingLinks.append(block.id)
                    } else {
                        missingLinks += 1
                    }
                    continue
                }
                blocks.append(RemoteDraftBlock(kind: .url, text: block.text, mediaID: nil, url: url, embedProvider: nil,
                                               embedContentID: nil))
            case .embed:
                let provider = (block.embedProvider ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let rawURL = (block.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var contentID = (block.embedContentID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let mediaID = block.remoteMediaID, !mediaID.isEmpty {
                    blocks.append(RemoteDraftBlock(kind: .embed, text: "", mediaID: mediaID, url: rawURL.isEmpty ? nil : rawURL,
                                                   embedProvider: provider.isEmpty ? nil : provider,
                                                   embedContentID: contentID.isEmpty ? nil : contentID))
                    continue
                }
                if contentID.isEmpty, !rawURL.isEmpty, let known = DraftEmbedProvider(rawValue: provider) {
                    contentID = known.contentID(from: rawURL)
                }
                guard !provider.isEmpty, !contentID.isEmpty else { continue }
                if !capabilities.sendsNew(.embed) {
                    webItems.append(block.id)
                    continue
                }
                blocks.append(RemoteDraftBlock(kind: .embed, text: "", mediaID: nil, url: rawURL.isEmpty ? nil : rawURL,
                                               embedProvider: provider, embedContentID: contentID))
            }
        }
        if disallowed > 0 {
            let media = postType == .image ? "画像" : "ファイル"
            throw RemoteError.invalidRequest("「\(postType.creatorLabel)」形式の投稿には\(media)と本文テキストだけを保存できます。"
                + "見出し・リンクカード・埋め込みなど（\(disallowed)件）は削除するか、Webエディタで編集してください。")
        }
        if let first = problems.first {
            throw RemoteError.invalidRequest(problems.count > 1 ? "\(first)ほか\(problems.count - 1)件" : first)
        }
        if missingCopies > 0 { throw RemoteError.invalidRequest(missingCopiesMessage(count: missingCopies)) }
        if missingMedia > 0 { throw RemoteError.invalidRequest("未アップロードの画像・ファイルがあります（\(missingMedia)件）") }
        if missingLinks > 0 { throw RemoteError.invalidRequest("FANBOXに未登録のリンクカードがあります（\(missingLinks)件）") }
        let hasContent = blocks.contains { !($0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.mediaID == nil && $0.url == nil
                                              && $0.embedContentID == nil) }
        if publish && !hasContent && webItems.isEmpty && pendingUploads.isEmpty && pendingLinks.isEmpty {
            throw RemoteError.invalidRequest("本文が空です")
        }

        let payload = RemotePostDraft(title: title, feeRequired: max(0, draft.feeRequired), planID: draft.targetPlanID,
                                      tags: normalizedTags(draft.tags), hasAdultContent: draft.hasAdultContent, blocks: blocks,
                                      publish: publish, commentPermission: draft.commentPermission)
        return Payload(draft: payload, webItemBlockIDs: webItems, formattingLossBlockIDs: formattingLoss,
                       pendingUploadBlockIDs: pendingUploads, pendingLinkCardBlockIDs: pendingLinks)
    }

    /// True when the block holds something the creator entered (empty new blocks are ignored).
    static func hasContent(_ block: DraftBlock) -> Bool {
        switch block.kind {
        case .text, .header: return !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image, .file: return block.remoteMediaID != nil || block.localFileName != nil
        case .url: return block.remoteMediaID != nil || !(block.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .embed:
            return block.remoteMediaID != nil || !(block.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !(block.embedContentID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// http(s) URL with a host (a link card target).
    static func isWebURL(_ string: String) -> Bool {
        guard let comps = URLComponents(string: string), let scheme = comps.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = comps.host else { return false }
        return !host.isEmpty
    }

    // MARK: Styles

    /// Styles to send for a text / header block (imported styles moved onto the edited text) and how many were lost.
    static func sentStyles(of block: DraftBlock) -> (styles: [RemoteTextStyle], lost: Int) {
        guard let imported = block.importedText else { return ([], 0) }
        return rebasedStyles(block.importedStyles, from: imported, to: block.text)
    }

    /// Splits text on line breaks into paragraphs and moves each style onto the paragraphs it covers (UTF-16 offsets).
    static func paragraphs(of text: String, styles: [RemoteTextStyle]) -> [(text: String, styles: [RemoteTextStyle])] {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 1 else { return [(text, styles)] }
        var result: [(text: String, styles: [RemoteTextStyle])] = []
        var start = 0
        for line in lines {
            let length = line.utf16.count
            let end = start + length
            var lineStyles: [RemoteTextStyle] = []
            for style in styles {
                let s = max(style.offset, start)
                let e = min(style.offset + style.length, end)
                guard e > s else { continue }
                lineStyles.append(RemoteTextStyle(type: style.type, offset: s - start, length: e - s, size: style.size))
            }
            result.append((line, lineStyles))
            start = end + 1   // the "\n"
        }
        return result
    }

    /// True when every character of `text` is in the Basic Multilingual Plane (UTF-16 offsets == code point offsets).
    static func isBMPOnly(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value <= 0xFFFF }
    }

    /// Moves style ranges from `old` to `new`. Styles entirely before the edited range are kept, styles entirely after it
    /// are shifted, styles that contain the whole edit grow / shrink with it; any other style is dropped and counted in
    /// `lost`. Offsets are UTF-16 units; text outside the BMP cannot be adjusted safely (the service's offset unit is
    /// unverified for it, docs/API.md §18.4), so all styles are reported lost then.
    static func rebasedStyles(_ styles: [RemoteTextStyle], from old: String, to new: String) -> (styles: [RemoteTextStyle], lost: Int) {
        guard !styles.isEmpty else { return ([], 0) }
        if old == new { return (styles, 0) }
        guard isBMPOnly(old), isBMPOnly(new) else { return ([], styles.count) }
        let o = Array(old.utf16)
        let n = Array(new.utf16)
        let limit = min(o.count, n.count)
        var prefix = 0
        while prefix < limit && o[prefix] == n[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix && o[o.count - 1 - suffix] == n[n.count - 1 - suffix] { suffix += 1 }
        let editStart = prefix
        let editEndOld = o.count - suffix
        let delta = n.count - o.count

        var kept: [RemoteTextStyle] = []
        var lost = 0
        for style in styles {
            let start = style.offset
            let end = style.offset + style.length
            var moved = style
            if end <= editStart {
                // Before the edit: unchanged.
            } else if start >= editEndOld {
                moved.offset = start + delta
            } else if start <= editStart && end >= editEndOld {
                moved.length = style.length + delta
            } else {
                lost += 1
                continue
            }
            guard moved.length > 0, moved.offset >= 0, moved.offset + moved.length <= n.count else {
                lost += 1
                continue
            }
            kept.append(moved)
        }
        return (kept, lost)
    }

    // MARK: Post Edit import

    /// Local block values produced from a FANBOX post block during Post Edit import.
    struct ImportedBlock: Equatable, Sendable {
        var kind: DraftBlockKind
        var text: String = ""
        var remoteMediaID: String?
        var remoteURL: String?
        var originalFileName: String?
        var fileSize: Int?
        var width: Int?
        var height: Int?
        var url: String?
        var embedProvider: String?
        var embedContentID: String?
        /// Paragraph / header: styles and the original text (sent back unchanged when not edited).
        var styles: [RemoteTextStyle] = []
        var importedText: String?
        /// Kept only as a reference to FANBOX content the app cannot show / edit.
        var isLocked = false
        /// Non-nil when this block cannot be written back natively (the whole post then goes to the web editor).
        var unsupportedReason: String?
    }

    /// Never returns nil: a block that cannot be represented is kept as a locked note with `unsupportedReason`, so nothing
    /// disappears from the draft silently.
    static func importedBlock(from block: RemoteBlock) -> ImportedBlock {
        switch block.kind {
        case .paragraph:
            return ImportedBlock(kind: .text, text: block.text, styles: block.styles, importedText: block.text)
        case .header:
            return ImportedBlock(kind: .header, text: block.text, styles: block.styles, importedText: block.text)
        case .image:
            guard let mediaID = block.mediaID else { return unsupported("IDのない画像") }
            let preview = block.displayURL ?? block.thumbnailURL ?? block.originalURL
            return ImportedBlock(kind: .image, remoteMediaID: mediaID, remoteURL: preview,
                                 originalFileName: block.fileName.map { name in
                                     guard let ext = block.fileExtension, !name.lowercased().hasSuffix("." + ext.lowercased()) else { return name }
                                     return "\(name).\(ext)"
                                 },
                                 fileSize: block.fileSize, width: block.width, height: block.height, isLocked: preview == nil)
        case .file, .audio, .video:
            if let mediaID = block.mediaID {
                let name = block.fileName.map { name -> String in
                    guard let ext = block.fileExtension, !name.lowercased().hasSuffix("." + ext.lowercased()) else { return name }
                    return "\(name).\(ext)"
                }
                let link = block.originalURL ?? block.url
                return ImportedBlock(kind: .file, remoteMediaID: mediaID, remoteURL: link, originalFileName: name ?? block.title,
                                     fileSize: block.fileSize, isLocked: link == nil && name == nil)
            }
            if let provider = block.embedProvider, let contentID = block.embedContentID {
                return ImportedBlock(kind: .embed, url: block.url, embedProvider: provider, embedContentID: contentID)
            }
            return unsupported("IDのない添付ファイル")
        case .url:
            if let mediaID = block.mediaID {
                return ImportedBlock(kind: .url, text: block.title ?? "", remoteMediaID: mediaID, url: block.url,
                                     embedProvider: block.embedProvider, embedContentID: block.embedContentID, isLocked: block.url == nil)
            }
            guard let url = block.url else { return unsupported("リンク先の分からないリンクカード") }
            return ImportedBlock(kind: .url, text: block.title ?? "", url: url)
        case .embed:
            if let mediaID = block.mediaID {
                return ImportedBlock(kind: .embed, remoteMediaID: mediaID, url: block.url, embedProvider: block.embedProvider,
                                     embedContentID: block.embedContentID, isLocked: block.embedProvider == nil && block.url == nil)
            }
            guard block.embedProvider != nil || block.url != nil else { return unsupported("内容の分からない埋め込み") }
            return ImportedBlock(kind: .embed, url: block.url, embedProvider: block.embedProvider, embedContentID: block.embedContentID)
        case .unknown:
            let name = block.subtitle.map { "未対応のブロック（\($0)）" } ?? "表示できないブロック"
            var result = unsupported(name)
            if !block.text.isEmpty { result.text = "\(name): \(block.text)" }
            return result
        }
    }

    private static func unsupported(_ reason: String) -> ImportedBlock {
        ImportedBlock(kind: .text, text: "［\(reason)］", isLocked: true, unsupportedReason: reason)
    }
}

extension RemoteError {
    /// Wraps any thrown error for Creator Mode services (never includes request data).
    static func creatorWrapping(_ error: Error) -> RemoteError {
        if let remote = error as? RemoteError { return remote }
        if let partial = error as? RemotePostCreatedPartially { return partial.underlying }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == NSURLErrorCancelled { return .cancelled }
            if ns.code == NSURLErrorNotConnectedToInternet || ns.code == NSURLErrorNetworkConnectionLost { return .offline }
        }
        return .network(code: ns.code, detail: ns.domain)
    }
}

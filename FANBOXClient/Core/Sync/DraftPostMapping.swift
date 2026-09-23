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

    /// Builds the create / update payload.
    /// - Text / 見出し blocks that are only whitespace, and URL / Embed blocks without a target, are omitted.
    /// - Image / File blocks MUST already carry `remoteMediaID` (uploaded or kept from Post Edit); otherwise this throws.
    /// - Publishing requires a title; saving as a FANBOX draft does not.
    static func remotePostDraft(from draft: Draft, publish: Bool) throws -> RemotePostDraft {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if publish && title.isEmpty { throw RemoteError.invalidRequest("タイトルを入力してください") }

        var blocks: [RemoteDraftBlock] = []
        var missingMedia = 0
        for block in draft.orderedBlocks {
            switch block.kind {
            case .text, .header:
                guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                blocks.append(RemoteDraftBlock(kind: block.kind, text: block.text, mediaID: nil, url: nil, embedProvider: nil,
                                               embedContentID: nil))
            case .image, .file:
                guard let mediaID = block.remoteMediaID, !mediaID.isEmpty else {
                    missingMedia += 1
                    continue
                }
                blocks.append(RemoteDraftBlock(kind: block.kind, text: "", mediaID: mediaID, url: nil, embedProvider: nil,
                                               embedContentID: nil))
            case .url:
                let url = (block.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { continue }
                blocks.append(RemoteDraftBlock(kind: .url, text: block.text, mediaID: nil, url: url, embedProvider: nil,
                                               embedContentID: nil))
            case .embed:
                let provider = (block.embedProvider ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let rawURL = (block.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var contentID = (block.embedContentID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if contentID.isEmpty, !rawURL.isEmpty, let known = DraftEmbedProvider(rawValue: provider) {
                    contentID = known.contentID(from: rawURL)
                }
                guard !provider.isEmpty, !contentID.isEmpty else { continue }
                blocks.append(RemoteDraftBlock(kind: .embed, text: "", mediaID: nil, url: rawURL.isEmpty ? nil : rawURL,
                                               embedProvider: provider, embedContentID: contentID))
            }
        }
        if missingMedia > 0 { throw RemoteError.invalidRequest("未アップロードの画像・ファイルがあります（\(missingMedia) 件）") }
        if publish && blocks.isEmpty { throw RemoteError.invalidRequest("本文が空です") }

        return RemotePostDraft(title: title, feeRequired: max(0, draft.feeRequired), planID: draft.targetPlanID,
                               tags: normalizedTags(draft.tags), hasAdultContent: draft.hasAdultContent, blocks: blocks, publish: publish)
    }

    /// Local block values produced from a FANBOX post block during Post Edit import. nil = block is dropped.
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
    }

    static func importedBlock(from block: RemoteBlock) -> ImportedBlock? {
        switch block.kind {
        case .paragraph:
            return ImportedBlock(kind: .text, text: block.text)
        case .header:
            return ImportedBlock(kind: .header, text: block.text)
        case .image:
            guard let mediaID = block.mediaID else { return nil }
            return ImportedBlock(kind: .image, remoteMediaID: mediaID,
                                 remoteURL: block.displayURL ?? block.thumbnailURL ?? block.originalURL,
                                 originalFileName: block.fileName.map { name in
                                     block.fileExtension.map { "\(name).\($0)" } ?? name
                                 },
                                 fileSize: block.fileSize, width: block.width, height: block.height)
        case .file, .audio, .video:
            if let mediaID = block.mediaID {
                let name = block.fileName.map { name in block.fileExtension.map { "\(name).\($0)" } ?? name }
                return ImportedBlock(kind: .file, remoteMediaID: mediaID, remoteURL: block.originalURL ?? block.url,
                                     originalFileName: name ?? block.title, fileSize: block.fileSize)
            }
            if let provider = block.embedProvider, let contentID = block.embedContentID {
                return ImportedBlock(kind: .embed, url: block.url, embedProvider: provider, embedContentID: contentID)
            }
            return nil
        case .url:
            guard let url = block.url else { return nil }
            return ImportedBlock(kind: .url, text: block.title ?? "", url: url)
        case .embed:
            guard block.embedProvider != nil || block.url != nil else { return nil }
            return ImportedBlock(kind: .embed, url: block.url, embedProvider: block.embedProvider, embedContentID: block.embedContentID)
        case .unknown:
            return block.text.isEmpty ? nil : ImportedBlock(kind: .text, text: block.text)
        }
    }
}

extension RemoteError {
    /// Wraps any thrown error for Creator Mode services (never includes request data).
    static func creatorWrapping(_ error: Error) -> RemoteError {
        if let remote = error as? RemoteError { return remote }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == NSURLErrorCancelled { return .cancelled }
            if ns.code == NSURLErrorNotConnectedToInternet || ns.code == NSURLErrorNetworkConnectionLost { return .offline }
        }
        return .network(code: ns.code, detail: ns.domain)
    }
}

import Foundation

/// One block the creator adds in the web editor after a text-first send (SPEC §18 / §20 / §40).
struct DraftWebItem: Identifiable, Equatable, Sendable {
    /// DraftBlock id.
    var id: String
    var kind: DraftBlockKind
    /// 1-based position in the local draft.
    var position: Int
    /// Short label of the nearest block before it that WAS sent ("…の後に追加"). nil = at the top of the body.
    var afterLabel: String?
    /// File name / URL / provider shown in the checklist.
    var title: String
    /// Processed local file (image / file) to export for the web file picker.
    var localFileName: String?
    /// URL (link card / embed) to copy.
    var value: String?

    var kindLabel: String { DraftSendPlanner.kindLabel(kind) }
}

/// What a send will do, computed BEFORE anything is sent (UI confirmation + service-side enforcement).
struct DraftSendPlan: Equatable, Sendable {
    /// Reasons the send cannot happen natively (the web editor is the way forward). Includes `validationError`'s message.
    var blockers: [String] = []
    /// Input the creator can fix in the app (title, tag count, empty body).
    var validationError: RemoteError?
    /// Consequences the creator must accept explicitly (formatting loss, tags / comment permission unknown).
    var warnings: [String] = []
    /// Informational lines for the confirmation (gating change, text-first hand-off, unpublish).
    var notes: [String] = []
    /// Blocks left for the web editor (text-first send), in body order.
    var webItems: [DraftWebItem] = []
    /// Status actually sent: true = published, false = FANBOX draft.
    var sendsPublished: Bool = false
    /// The send takes a published (or possibly published) post down to a draft.
    var unpublishes: Bool = false

    var canSend: Bool { blockers.isEmpty }
}

/// Result of a successful send.
struct DraftSendReceipt: Equatable, Sendable {
    var postID: String
    var sentPublished: Bool
    /// Items to finish in the web editor (empty = nothing left).
    var webItems: [DraftWebItem]

    var needsWebCompletion: Bool { !webItems.isEmpty }
}

enum DraftSendPlanner {
    /// Plans a send. `publish`: the creator's choice (true = publish / keep published, false = FANBOX draft).
    /// `remoteStatus` overrides the draft's recorded FANBOX status (fresh value read just before sending).
    static func plan(draft: Draft, capabilities: DraftCapabilities, publish: Bool,
                     remoteStatus overrideStatus: RemotePostStatus? = nil) -> DraftSendPlan {
        var plan = DraftSendPlan()
        let isExisting = draft.remotePostID != nil
        let status = isExisting ? (overrideStatus ?? draft.remoteStatus) : nil

        if !capabilities.nativeWrites {
            plan.blockers.append("このアカウントの投稿はアプリから送信できません。Webエディタを使ってください。")
        }
        if isExisting, let reason = draft.nativeUpdateBlocker {
            plan.blockers.append(reason)
        } else if status == .scheduled {
            plan.blockers.append(scheduledBlocker)
        }

        var payload: DraftPostMapping.Payload?
        do {
            payload = try DraftPostMapping.payload(from: draft, publish: publish, capabilities: capabilities, allowPendingUploads: true)
        } catch {
            let wrapped = RemoteError.creatorWrapping(error)
            plan.validationError = wrapped
            plan.blockers.append(wrapped.userMessage)
        }
        let webIDs = payload?.webItemBlockIDs ?? []
        plan.webItems = webItems(for: draft, blockIDs: webIDs)

        // Never publish an unfinished post: with items left for the web editor a new post / FANBOX draft stays a draft.
        // A post that is (or may be) live keeps its status: its text is updated first.
        var sendsPublished = publish
        if publish && !plan.webItems.isEmpty && status != .published && status != .unknown { sendsPublished = false }
        plan.sendsPublished = sendsPublished
        plan.unpublishes = isExisting && !sendsPublished && (status == .published || status == .unknown)

        if let payload, !payload.formattingLossBlockIDs.isEmpty {
            plan.warnings.append("編集した段落\(payload.formattingLossBlockIDs.count)件で、太字・リンクなどの書式の一部が失われます。")
        }
        if isExisting && draft.tagsUnverified {
            let count = DraftPostMapping.normalizedTags(draft.tags).count
            plan.warnings.append(count == 0
                ? "FANBOX上のタグを読み取れませんでした。このまま更新するとタグが消える可能性があります。"
                : "FANBOX上のタグを読み取れませんでした。端末内のタグ（\(count)個）で上書きします。")
        }
        if isExisting && capabilities.sendsCommentPermission && draft.commentPermission == nil {
            plan.warnings.append("コメントできる人の設定をFANBOXから読み取れませんでした。既定値（有料なら支援者のみ、無料なら全員）で送信されます。")
        }

        if capabilities.uploadsNeedPost, let payload {
            let uploads = payload.pendingUploadBlockIDs.count
            let links = payload.pendingLinkCardBlockIDs.count
            let steps = [uploads > 0 ? "画像・ファイル\(uploads)件のアップロード" : nil, links > 0 ? "リンクカード\(links)件の登録" : nil]
                .compactMap { $0 }.joined(separator: "と")
            if !steps.isEmpty {
                plan.notes.append(isExisting
                    ? "\(steps)をこの投稿に対して行ってから、本文を保存します。完了した項目は再送しません。"
                    : "先にFANBOXに下書きを作成し、\(steps)を行ってから本文を保存します。途中で失敗しても作成した下書きは残り、再送すると同じ下書きに続きから送信します（完了した項目は再送しません）。")
            }
        }
        let draftType = draft.remotePostType
        if isExisting, capabilities.allowedKinds(in: draftType) != nil {
            plan.notes.append("「\(draftType.creatorLabel)」形式の投稿として保存します（\(draftType == .image ? "画像" : "ファイル")はブロックの順、テキストは段落ごとに空行で区切った本文になります）。")
        }
        if !plan.webItems.isEmpty {
            plan.notes.append("\(summary(of: plan.webItems))はアプリから送信できません。本文を先にFANBOXに保存し、残りはWebエディタで追加します。")
            if publish && !sendsPublished {
                plan.notes.append("未完成のまま公開しないよう、FANBOXには下書きとして保存します。仕上げたらWebエディタで公開してください。")
            } else if sendsPublished && isExisting {
                plan.notes.append("公開中の投稿は本文が先に更新されます。残りの項目はWebエディタで追加するまで表示されません。")
            }
        }
        if isExisting, let old = draft.remoteFeeRequired, old != draft.feeRequired {
            plan.notes.append("公開範囲が変わります: \(feeLabel(old)) → \(feeLabel(draft.feeRequired))")
        }
        if isExisting && status == .archived && sendsPublished {
            plan.notes.append("非公開にした投稿を再び公開します。読者から見えるようになります。")
        }
        if plan.unpublishes {
            plan.notes.append(status == .unknown
                ? "FANBOXで公開中の場合、非公開（下書き）に戻ります。読者からは見えなくなります。"
                : "公開中の投稿を非公開（下書き）に戻します。読者からは見えなくなります。")
        }
        return plan
    }

    static let scheduledBlocker = "予約投稿はアプリから更新できません（予約日時を保てないため）。Webエディタで編集してください。"

    static func feeLabel(_ fee: Int) -> String {
        fee > 0 ? "\(fee)円以上" : "全体公開"
    }

    static func kindLabel(_ kind: DraftBlockKind) -> String {
        switch kind {
        case .text: return "テキスト"
        case .header: return "見出し"
        case .image: return "画像"
        case .file: return "ファイル"
        case .url: return "リンクカード"
        case .embed: return "埋め込み"
        }
    }

    /// "画像2件・リンクカード1件"
    static func summary(of items: [DraftWebItem]) -> String {
        let order: [DraftBlockKind] = [.image, .file, .url, .embed]
        return order.compactMap { kind -> String? in
            let count = items.filter { $0.kind == kind }.count
            return count > 0 ? "\(kindLabel(kind))\(count)件" : nil
        }.joined(separator: "・")
    }

    /// Web items in body order with a position hint (the nearest preceding block that is sent natively).
    static func webItems(for draft: Draft, blockIDs: [String]) -> [DraftWebItem] {
        guard !blockIDs.isEmpty else { return [] }
        let ids = Set(blockIDs)
        var items: [DraftWebItem] = []
        var anchor: String?
        for (index, block) in draft.orderedBlocks.enumerated() {
            if ids.contains(block.id) {
                items.append(DraftWebItem(id: block.id, kind: block.kind, position: index + 1, afterLabel: anchor, title: title(of: block),
                                          localFileName: block.localFileName, value: value(of: block)))
                continue
            }
            if let label = anchorLabel(of: block) { anchor = label }
        }
        return items
    }

    private static func anchorLabel(of block: DraftBlock) -> String? {
        switch block.kind {
        case .text, .header:
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !block.isLockedRemote else { return nil }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return line.count > 24 ? "「\(line.prefix(24))…」" : "「\(line)」"
        case .image, .file:
            guard block.remoteMediaID != nil else { return nil }
            return "\(kindLabel(block.kind))（\(block.originalFileName ?? "FANBOX上")）"
        case .url, .embed:
            guard block.remoteMediaID != nil else { return nil }
            return "\(kindLabel(block.kind))（\(block.url ?? "FANBOX上")）"
        }
    }

    private static func title(of block: DraftBlock) -> String {
        switch block.kind {
        case .image: return block.originalFileName ?? "画像"
        case .file: return block.originalFileName ?? "ファイル"
        case .url: return block.url ?? "リンク"
        case .embed:
            let provider = DraftEmbedProvider.displayName(forKey: block.embedProvider) ?? block.embedProvider ?? "埋め込み"
            return "\(provider): \(block.url ?? block.embedContentID ?? "")"
        case .text, .header: return block.text
        }
    }

    private static func value(of block: DraftBlock) -> String? {
        switch block.kind {
        case .url: return block.url
        case .embed: return block.url ?? block.embedContentID
        default: return nil
        }
    }
}

extension RemotePostStatus {
    /// Creator Mode label of a FANBOX post status.
    var creatorLabel: String {
        switch self {
        case .published: return "公開中"
        case .draft: return "下書き"
        case .scheduled: return "予約投稿"
        case .archived: return "非公開"
        case .unknown: return "状態不明"
        }
    }
}

extension PostType {
    /// Name of the post format in Creator Mode messages.
    var creatorLabel: String {
        switch self {
        case .article: return "記事"
        case .image: return "画像"
        case .file: return "ファイル"
        case .text: return "テキスト"
        case .video: return "動画"
        case .entry: return "旧形式"
        case .unknown: return "不明"
        }
    }
}

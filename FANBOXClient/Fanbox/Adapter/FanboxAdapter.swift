import Foundation

/// Pure DTO → Remote* mapping (SPEC §43: FANBOX changes are absorbed here and in the DTOs).
/// No I/O, no state — every function is unit-tested with hand-written fixtures.
enum FanboxAdapter {
    static let deletedUserName = "退会したユーザー"

    // MARK: - Posts

    static func postType(_ raw: String?) -> PostType {
        guard let raw = raw?.lowercased() else { return .unknown }
        return PostType(rawValue: raw) ?? .unknown
    }

    /// List item → summary. nil when the item has no id (cannot be stored).
    static func postSummary(_ item: FanboxPostListItemDTO, fallbackCreatorID: String? = nil) -> RemotePostSummary? {
        guard let id = item.id else { return nil }
        let creatorID = item.creatorId ?? fallbackCreatorID ?? ""
        let published = item.publishedDatetime ?? item.updatedDatetime ?? .distantPast
        return RemotePostSummary(
            id: id, creatorID: creatorID, creatorName: nonEmpty(item.user?.name) ?? creatorID, creatorIconURL: item.user?.iconUrl,
            pixivUserID: item.user?.userId, title: item.title ?? "", excerpt: item.excerpt ?? "", type: postType(item.type),
            feeRequired: max(0, item.feeRequired ?? 0), coverImageURL: item.cover?.url ?? item.coverImageUrl, publishedAt: published,
            updatedAt: item.updatedDatetime ?? published, tags: item.tags ?? [], likeCount: item.likeCount ?? 0,
            commentCount: item.commentCount ?? 0, isLiked: item.isLiked ?? false, isRestricted: item.isRestricted ?? false,
            hasAdultContent: item.hasAdultContent ?? false)
    }

    /// Maps a page of list items. Pinned posts (`isPinned`, out of date order on creator pages) are moved to the END of
    /// the page so a known pinned post never stops newest-first differential sync before the new posts are seen
    /// (docs/API.md §19.1). Items without an id are dropped; duplicate ids keep the first occurrence.
    static func postSummaries(_ items: [FanboxPostListItemDTO], fallbackCreatorID: String? = nil) -> [RemotePostSummary] {
        let ordered = items.filter { $0.isPinned != true } + items.filter { $0.isPinned == true }
        var seen = Set<String>()
        var result: [RemotePostSummary] = []
        for item in ordered {
            guard let summary = postSummary(item, fallbackCreatorID: fallbackCreatorID), seen.insert(summary.id).inserted else { continue }
            result.append(summary)
        }
        return result
    }

    static func postDetail(_ dto: FanboxPostDetailDTO) -> RemotePostDetail? {
        guard let id = dto.id else { return nil }
        let type = postType(dto.type)
        let restricted = (dto.isRestricted ?? false) || dto.body == nil
        let blocks = restricted ? [] : contentBlocks(body: dto.body, type: type)
        let text = plainText(blocks)
        let creatorID = dto.creatorId ?? ""
        let published = dto.publishedDatetime ?? dto.updatedDatetime ?? .distantPast
        var excerpt = dto.excerpt ?? ""
        if excerpt.isEmpty, !text.isEmpty { excerpt = String(text.prefix(120)) }
        let summary = RemotePostSummary(
            id: id, creatorID: creatorID, creatorName: nonEmpty(dto.user?.name) ?? creatorID, creatorIconURL: dto.user?.iconUrl,
            pixivUserID: dto.user?.userId, title: dto.title ?? "", excerpt: excerpt, type: type, feeRequired: max(0, dto.feeRequired ?? 0),
            coverImageURL: dto.coverImageUrl ?? dto.cover?.url, publishedAt: published, updatedAt: dto.updatedDatetime ?? published,
            tags: dto.tags ?? [], likeCount: dto.likeCount ?? 0, commentCount: dto.commentCount ?? 0, isLiked: dto.isLiked ?? false,
            isRestricted: restricted, hasAdultContent: dto.hasAdultContent ?? false)
        return RemotePostDetail(summary: summary, blocks: blocks, plainText: text, prevPostID: dto.prevPost?.id, nextPostID: dto.nextPost?.id)
    }

    /// Content blocks by post type. Unknown / missing types are inferred from the body's fields.
    static func contentBlocks(body: FanboxPostBodyDTO?, type: PostType, includeReferenceIDs: Bool = false) -> [RemoteBlock] {
        guard let body else { return [] }
        switch type {
        case .article:
            return articleBlocks(body, includeReferenceIDs: includeReferenceIDs)
        case .image:
            return (body.images ?? []).map(imageBlock) + textParagraphs(body.text)
        case .file:
            return (body.files ?? []).map(fileBlock) + textParagraphs(body.text)
        case .video:
            var blocks: [RemoteBlock] = []
            if let video = body.video, let provider = video.serviceProvider, let contentID = video.videoId ?? video.contentId {
                blocks.append(embedBlock(provider: provider, contentID: contentID))
            }
            return blocks + textParagraphs(body.text)
        case .text:
            return textParagraphs(body.text)
        case .entry:
            return entryBlocks(html: body.html ?? body.text ?? "")
        case .unknown:
            if body.blocks != nil { return articleBlocks(body, includeReferenceIDs: includeReferenceIDs) }
            if let html = body.html { return entryBlocks(html: html) }
            var blocks = (body.images ?? []).map(imageBlock) + (body.files ?? []).map(fileBlock)
            if let video = body.video, let provider = video.serviceProvider, let contentID = video.videoId ?? video.contentId {
                blocks.append(embedBlock(provider: provider, contentID: contentID))
            }
            return blocks + textParagraphs(body.text)
        }
    }

    /// Article blocks in order, resolved through imageMap / fileMap / embedMap / urlEmbedMap.
    /// A block whose id is missing from its map becomes an `.unknown` placeholder (never fails the post).
    /// `includeReferenceIDs` (creator editing round-trip): also put embed / url_embed ids in `mediaID`, and keep a block
    /// whose id is missing from its map as a TYPED block carrying only that id (so it can be written back unchanged).
    static func articleBlocks(_ body: FanboxPostBodyDTO, includeReferenceIDs: Bool = false) -> [RemoteBlock] {
        var result: [RemoteBlock] = []
        for block in body.blocks ?? [] {
            switch block.type?.lowercased() {
            case "p", "paragraph":
                result.append(RemoteBlock(kind: .paragraph, text: block.text ?? "", styles: styles(block)))
            case "header", "h":
                result.append(RemoteBlock(kind: .header, text: block.text ?? "", styles: styles(block)))
            case "image":
                if let id = block.imageId, let image = body.imageMap?[id] {
                    result.append(imageBlock(image))
                } else if includeReferenceIDs, let id = block.imageId {
                    result.append(RemoteBlock(kind: .image, mediaID: id))
                } else {
                    result.append(placeholder("画像を表示できません", referenceID: block.imageId))
                }
            case "file":
                if let id = block.fileId, let file = body.fileMap?[id] {
                    result.append(fileBlock(file))
                } else if includeReferenceIDs, let id = block.fileId {
                    result.append(RemoteBlock(kind: .file, mediaID: id))
                } else {
                    result.append(placeholder("ファイルを表示できません", referenceID: block.fileId))
                }
            case "embed":
                if let id = block.embedId, let embed = body.embedMap?[id], let provider = embed.serviceProvider,
                   let contentID = embed.videoId ?? embed.contentId {
                    var b = embedBlock(provider: provider, contentID: contentID)
                    if includeReferenceIDs { b.mediaID = id }
                    result.append(b)
                } else if includeReferenceIDs, let id = block.embedId {
                    result.append(RemoteBlock(kind: .embed, mediaID: id))
                } else {
                    result.append(placeholder("埋め込みを表示できません", referenceID: block.embedId))
                }
            case "url_embed":
                if let id = block.urlEmbedId, let embed = body.urlEmbedMap?[id] {
                    var b = urlEmbedBlock(embed)
                    if includeReferenceIDs { b.mediaID = id }
                    result.append(b)
                } else if includeReferenceIDs, let id = block.urlEmbedId {
                    result.append(RemoteBlock(kind: .url, mediaID: id))
                } else {
                    result.append(placeholder("リンクを表示できません", referenceID: block.urlEmbedId))
                }
            default:
                // Unknown block type: keep any text so nothing is silently lost.
                result.append(RemoteBlock(kind: .unknown, text: block.text ?? "", styles: styles(block), subtitle: block.type))
            }
        }
        return result
    }

    /// Styles plus links. Links are encoded as `RemoteTextStyle(type: "link:<url>")` (RemoteTextStyle has no URL field).
    /// Offsets / lengths are passed through unchanged (UTF-16 code units per docs/API.md §18.4).
    static func styles(_ block: FanboxBlockDTO) -> [RemoteTextStyle] {
        var result: [RemoteTextStyle] = []
        for s in block.styles ?? [] {
            guard let type = s.type, let offset = s.offset, let length = s.length, offset >= 0, length > 0 else { continue }
            result.append(RemoteTextStyle(type: type, offset: offset, length: length, size: s.size))
        }
        for l in block.links ?? [] {
            guard let url = l.url, let offset = l.offset, let length = l.length, offset >= 0, length > 0 else { continue }
            result.append(RemoteTextStyle(type: linkStylePrefix + url, offset: offset, length: length, size: nil))
        }
        return result
    }

    /// Prefix of link styles: `"link:https://..."`.
    static let linkStylePrefix = "link:"

    static func imageBlock(_ image: FanboxImageDTO) -> RemoteBlock {
        // FANBOX offers two sizes: thumbnailUrl (width-1200 sample) and originalUrl. No smaller feed thumbnail exists,
        // so thumbnailURL stays nil and the staged loader starts at the display size.
        RemoteBlock(kind: .image, mediaID: image.id, thumbnailURL: nil, displayURL: image.thumbnailUrl ?? image.originalUrl,
                    originalURL: image.originalUrl ?? image.thumbnailUrl, width: image.width, height: image.height,
                    fileName: image.id.map { id in image.fileExtension.map { "\(id).\($0)" } ?? id }, fileExtension: image.fileExtension)
    }

    static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "ogg"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]

    static func fileKind(forExtension ext: String?) -> PostBlockKind {
        guard let ext = ext?.lowercased() else { return .file }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        return .file
    }

    static func fileBlock(_ file: FanboxFileDTO) -> RemoteBlock {
        // `name` has no extension; the display name is name + "." + extension.
        var displayName = file.name ?? file.id ?? "file"
        if let ext = file.fileExtension, !displayName.lowercased().hasSuffix("." + ext.lowercased()) {
            displayName += "." + ext
        }
        return RemoteBlock(kind: fileKind(forExtension: file.fileExtension), text: "", mediaID: file.id, originalURL: file.url,
                           fileName: displayName, fileExtension: file.fileExtension, fileSize: file.size, url: file.url, title: displayName)
    }

    static func embedBlock(provider: String, contentID: String) -> RemoteBlock {
        RemoteBlock(kind: .embed, url: embedURL(provider: provider, contentID: contentID), embedProvider: provider, embedContentID: contentID,
                    title: providerDisplayName(provider))
    }

    /// Public URL of an embedded / video post item (docs/API.md §18.5). nil for unknown providers.
    static func embedURL(provider: String, contentID: String) -> String? {
        let path = contentID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? contentID
        switch provider.lowercased() {
        case "youtube":
            let q = contentID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? contentID
            return "https://www.youtube.com/watch?v=\(q)"
        case "twitter", "x": return "https://x.com/i/web/status/\(path)"
        case "vimeo": return "https://vimeo.com/\(path)"
        case "soundcloud": return "https://soundcloud.com/\(path)"
        case "google_forms": return "https://docs.google.com/forms/d/e/\(path)/viewform"
        case "fanbox": return "https://www.pixiv.net/fanbox/\(path)"
        case "gist": return "https://gist.github.com/\(path)"
        default: return nil
        }
    }

    static func providerDisplayName(_ provider: String) -> String {
        switch provider.lowercased() {
        case "youtube": return "YouTube"
        case "twitter", "x": return "X"
        case "vimeo": return "Vimeo"
        case "soundcloud": return "SoundCloud"
        case "google_forms": return "Googleフォーム"
        case "fanbox": return "FANBOX"
        case "gist": return "GitHub Gist"
        default: return provider
        }
    }

    /// url_embed → `.url` block. `html` / `html.card` markup is untrusted: only a link is extracted, never rendered.
    static func urlEmbedBlock(_ embed: FanboxURLEmbedDTO) -> RemoteBlock {
        let type = embed.type?.lowercased() ?? "default"
        switch type {
        case "fanbox.post":
            let info = embed.postInfo
            var url: String?
            if let id = info?.id {
                url = info?.creatorId.map { "https://www.fanbox.cc/@\($0)/posts/\(id)" } ?? "https://www.fanbox.cc/posts/\(id)"
            }
            return RemoteBlock(kind: .url, url: url, embedProvider: "fanbox.post", embedContentID: info?.id,
                               title: nonEmpty(info?.title) ?? "FANBOXの投稿", subtitle: info?.user?.name ?? info?.creatorId)
        case "fanbox.creator":
            let profile = embed.profile
            let url = profile?.creatorId.map { "https://www.fanbox.cc/@\($0)" }
            return RemoteBlock(kind: .url, thumbnailURL: profile?.user?.iconUrl, url: url, embedProvider: "fanbox.creator",
                               embedContentID: profile?.creatorId, title: profile?.user?.name ?? profile?.name ?? profile?.creatorId,
                               subtitle: "FANBOXクリエイター")
        case "html", "html.card":
            let link = embed.html.flatMap(firstLink(inHTML:))
            return RemoteBlock(kind: .url, url: link ?? embed.url, embedProvider: type, title: link.flatMap(hostName) ?? "埋め込みリンク",
                               subtitle: type)
        default:
            let url = embed.url
            return RemoteBlock(kind: .url, url: url, embedProvider: type == "default" ? nil : type,
                               title: embed.host ?? url.flatMap(hostName), subtitle: nil)
        }
    }

    static func placeholder(_ text: String, referenceID: String?) -> RemoteBlock {
        RemoteBlock(kind: .unknown, text: text, mediaID: referenceID)
    }

    /// Text body → paragraphs separated by blank lines (single newlines stay inside a paragraph).
    static func textParagraphs(_ text: String?) -> [RemoteBlock] {
        guard let text, !text.isEmpty else { return [] }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var paragraphs: [String] = []
        var current: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }
        return paragraphs.map { RemoteBlock(kind: .paragraph, text: $0) }
    }

    private static let entryImageRegex = try! NSRegularExpression(
        pattern: #"(?:<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>\s*)?<img\b[^>]*?src\s*=\s*["']([^"']+)["'][^>]*>(?:\s*</a>)?"#,
        options: [.caseInsensitive])

    /// Legacy `entry` HTML → text paragraphs and image blocks in document order. The HTML itself is never rendered.
    static func entryBlocks(html: String) -> [RemoteBlock] {
        var blocks: [RemoteBlock] = []
        let ns = html as NSString
        var cursor = 0
        for match in entryImageRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            blocks += textParagraphs(stripHTML(before))
            let href = match.range(at: 1).location != NSNotFound ? ns.substring(with: match.range(at: 1)) : nil
            let src = ns.substring(with: match.range(at: 2))
            let ext = URL(string: href ?? src)?.pathExtension
            blocks.append(RemoteBlock(kind: .image, displayURL: FanboxMetadataParser.unescapeEntities(src),
                                      originalURL: FanboxMetadataParser.unescapeEntities(href ?? src), fileExtension: ext?.isEmpty == false ? ext : nil))
            cursor = match.range.location + match.range.length
        }
        blocks += textParagraphs(stripHTML(ns.substring(from: cursor)))
        return blocks
    }

    private static let tagRegex = try! NSRegularExpression(pattern: #"<[^>]+>"#)
    private static let breakRegex = try! NSRegularExpression(pattern: #"<\s*(br|/p|/div|/h[1-6]|/li)\b[^>]*>"#, options: [.caseInsensitive])
    private static let hrefRegex = try! NSRegularExpression(pattern: #"\b(?:href|src|data-url)\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive])

    static func stripHTML(_ html: String) -> String {
        var s = breakRegex.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length), withTemplate: "\n")
        s = tagRegex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        return FanboxMetadataParser.unescapeEntities(s)
    }

    /// First absolute http(s) link in untrusted markup (iframely `<a href>` / `<iframe src>`).
    static func firstLink(inHTML html: String) -> String? {
        let ns = html as NSString
        for m in hrefRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            var link = FanboxMetadataParser.unescapeEntities(ns.substring(with: m.range(at: 1)))
            if link.hasPrefix("//") { link = "https:" + link }
            if link.hasPrefix("https://") || link.hasPrefix("http://") { return link }
        }
        return nil
    }

    static func hostName(_ url: String) -> String? {
        URLComponents(string: url)?.host
    }

    /// Text of paragraph / header blocks joined by newlines (for search).
    static func plainText(_ blocks: [RemoteBlock]) -> String {
        blocks.filter { $0.kind == .paragraph || $0.kind == .header }.map(\.text).joined(separator: "\n")
    }

    // MARK: - Creators / plans / supports

    static func creator(_ dto: FanboxCreatorDTO) -> RemoteCreator? {
        guard let creatorID = dto.creatorId else { return nil }
        return RemoteCreator(
            creatorID: creatorID, pixivUserID: dto.user?.userId ?? dto.userId, name: nonEmpty(dto.user?.name) ?? nonEmpty(dto.name) ?? creatorID,
            iconURL: dto.user?.iconUrl ?? dto.iconUrl, coverImageURL: dto.coverImageUrl, profileText: dto.description ?? "",
            profileLinks: dto.profileLinks ?? [], hasAdultContent: dto.hasAdultContent ?? false, isFollowed: dto.isFollowed,
            isSupported: dto.isSupported, isStopped: dto.isStopped)
    }

    static func plan(_ dto: FanboxPlanDTO, fallbackCreatorID: String? = nil) -> RemotePlan? {
        guard let id = dto.id, let creatorID = dto.creatorId ?? fallbackCreatorID else { return nil }
        return RemotePlan(planID: id, creatorID: creatorID, title: dto.title ?? "", fee: max(0, dto.fee ?? 0), description: dto.description ?? "",
                          coverImageURL: dto.coverImageUrl, hasAdultContent: dto.hasAdultContent ?? false)
    }

    /// Plans sorted by fee (ascending), as FANBOX shows them.
    static func plans(_ dtos: [FanboxPlanDTO], fallbackCreatorID: String?) -> [RemotePlan] {
        dtos.compactMap { plan($0, fallbackCreatorID: fallbackCreatorID) }.sorted { ($0.fee, $0.planID) < ($1.fee, $1.planID) }
    }

    /// A plan from `plan.listSupporting` → the account's active support. `paymentMethod` stays raw (never interpreted as fact).
    static func support(_ dto: FanboxPlanDTO) -> RemoteSupport? {
        guard let id = dto.id, let creatorID = dto.creatorId else { return nil }
        return RemoteSupport(planID: id, creatorID: creatorID, creatorName: nonEmpty(dto.user?.name) ?? creatorID, creatorIconURL: dto.user?.iconUrl,
                             pixivUserID: dto.user?.userId, planTitle: dto.title ?? "", fee: max(0, dto.fee ?? 0), paymentMethod: dto.paymentMethod,
                             planDescription: dto.description, coverImageURL: dto.coverImageUrl)
    }

    /// Normalized payment method family for display grouping ("card" / "paypal" / "cvs"), or nil when unknown.
    /// The raw string is always kept; this is a guess helper only (VerificationState.inferred).
    static func paymentMethodFamily(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        if raw.contains("card") { return "card" }
        if raw.contains("paypal") { return "paypal" }
        if raw.contains("cvs") { return "cvs" }
        return nil
    }

    // MARK: - Comments

    static func commentParentID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw != "0" else { return nil }
        return raw
    }

    static func comment(_ dto: FanboxCommentDTO, postID: String) -> RemoteComment? {
        guard let id = dto.id else { return nil }
        let replies = (dto.replies ?? []).compactMap { comment($0, postID: postID) }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        return RemoteComment(
            id: id, postID: postID, parentCommentID: commentParentID(dto.parentCommentId), rootCommentID: commentParentID(dto.rootCommentId),
            authorUserID: dto.user?.userId ?? "", authorName: nonEmpty(dto.user?.name) ?? deletedUserName, authorIconURL: dto.user?.iconUrl,
            body: dto.body ?? "", createdAt: dto.createdDatetime ?? .distantPast, likeCount: dto.likeCount ?? 0, isLiked: dto.isLiked ?? false,
            isOwn: dto.isOwn ?? false, replies: replies)
    }

    /// Root threads with nested replies, newest root first (the server order is undocumented).
    static func comments(_ dtos: [FanboxCommentDTO], postID: String) -> [RemoteComment] {
        dtos.compactMap { comment($0, postID: postID) }.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }

    /// Finds the comment just posted by this account (no id is returned by post.addComment; docs/API.md §9.2).
    static func findPostedComment(in comments: [RemoteComment], body: String, parentCommentID: String?, notBefore: Date) -> RemoteComment? {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return comments.flatMap(\.flattened)
            .filter { $0.isOwn && $0.body.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedBody }
            .filter { parentCommentID == nil ? $0.parentCommentID == nil : $0.parentCommentID == parentCommentID }
            .filter { $0.createdAt >= notBefore.addingTimeInterval(-600) }
            .max { $0.createdAt < $1.createdAt }
    }

    // MARK: - Notifications (bell)

    /// docs/API.md §18.8 A. Unknown strings map to `.other` (raw type kept by the caller).
    static func notificationType(rawType: String, isRootComment: Bool?) -> NotificationEventType {
        switch rawType.lowercased() {
        case "on_post_published": return .newPost
        case "post_comment": return isRootComment == false ? .commentReply : .comment
        case "post_comment_reply": return .commentReply
        case "post_comment_like": return .other
        default: return .other
        }
    }

    static func notification(_ dto: FanboxBellItemDTO) -> RemoteNotification? {
        let rawType = dto.type ?? "unknown"
        let type = notificationType(rawType: rawType, isRootComment: dto.isRootComment)
        let createdAt = dto.notifiedDatetime ?? .distantPast
        let post = dto.post
        let postID = post?.id ?? dto.postId
        guard let remoteID = dto.id ?? synthesizedBellID(type: rawType, postID: postID, date: dto.notifiedDatetime) else { return nil }
        let creatorID = post?.creatorId ?? dto.creatorId
        let postTitle = nonEmpty(post?.title) ?? nonEmpty(dto.postTitle)
        let actorName = nonEmpty(dto.userName) ?? nonEmpty(post?.user?.name)
        let actorIcon = dto.userProfileImg ?? post?.user?.iconUrl
        let title: String
        let message: String
        switch rawType.lowercased() {
        case "on_post_published":
            title = nonEmpty(post?.user?.name) ?? creatorID ?? "新着投稿"
            message = postTitle.map { "新しい投稿「\($0)」" } ?? "新しい投稿があります"
        case "post_comment", "post_comment_reply":
            let who = actorName ?? "誰か"
            title = type == .commentReply ? "\(who)さんが返信しました" : "\(who)さんがコメントしました"
            message = dto.postCommentBody ?? postTitle ?? ""
        case "post_comment_like":
            let count = dto.count ?? 1
            title = count > 1 ? "コメントに\(count)件のいいね" : "コメントにいいねがつきました"
            message = dto.postCommentBody ?? ""
        default:
            title = "FANBOXからのお知らせ"
            message = postTitle ?? dto.postCommentBody ?? ""
        }
        return RemoteNotification(
            remoteID: remoteID, type: type, rawType: rawType, createdAt: createdAt, creatorID: creatorID,
            creatorName: nonEmpty(post?.user?.name), postID: postID, postTitle: postTitle,
            // The bell id is NOT verified to be the comment id (docs/API.md §2.11), so commentID stays nil.
            commentID: nil, newsletterID: nil, actorName: actorName, actorIconURL: actorIcon, title: title, message: message,
            isUnread: dto.isUnread, isRestricted: post?.isRestricted)
    }

    static func synthesizedBellID(type: String, postID: String?, date: Date?) -> String? {
        guard let date else { return nil }
        return "bell:\(type):\(postID ?? "-"):\(Int(date.timeIntervalSince1970))"
    }

    // MARK: - Newsletters / payments

    static func newsletter(_ dto: FanboxNewsletterDTO) -> RemoteNewsletter? {
        guard let id = dto.id else { return nil }
        let creatorID = dto.creator?.creatorId ?? ""
        return RemoteNewsletter(id: id, creatorID: creatorID, creatorName: nonEmpty(dto.creator?.user?.name) ?? creatorID,
                                creatorIconURL: dto.creator?.user?.iconUrl, title: nil, body: dto.body ?? "", createdAt: dto.createdAt ?? .distantPast,
                                isRead: dto.isRead ?? false)
    }

    static func payment(_ dto: FanboxPaymentDTO) -> RemotePayment? {
        guard let id = dto.id, let paidAt = dto.paymentDatetime else { return nil }
        // A missing paidAmount is flagged, not turned into a ¥0 payment.
        return RemotePayment(id: id, creatorID: dto.creator?.creatorId, creatorName: nonEmpty(dto.creator?.user?.name),
                             amount: dto.paidAmount ?? 0, paidAt: paidAt, paymentMethod: dto.paymentMethod,
                             isAmountReported: dto.paidAmount != nil)
    }

    /// Payment records newest first.
    static func payments(_ dtos: [FanboxPaymentDTO]) -> [RemotePayment] {
        dtos.compactMap(payment).sorted { ($0.paidAt, $0.id) > ($1.paidAt, $1.id) }
    }

    // MARK: - Session

    /// Page metadata → logged-in user. Throws `.unauthorized` when the page reports no user.
    static func user(_ metadata: FanboxMetadataDTO) throws -> RemoteUser {
        guard let user = metadata.user, let userID = user.userId else { throw RemoteError.unauthorized }
        let creatorID = user.isCreator == false ? nil : nonEmpty(user.creatorId)
        // FANBOX identifies users by their pixiv user id; there is no separate FANBOX user id.
        return RemoteUser(pixivUserID: userID, fanboxUserID: userID, name: nonEmpty(user.name) ?? userID, iconURL: user.iconUrl, creatorID: creatorID)
    }

    // MARK: - Creator side

    static func postStatus(_ raw: String?) -> RemotePostStatus {
        switch raw?.lowercased() {
        case "draft": return .draft
        case "published": return .published
        case "scheduled", "reserved": return .scheduled
        case "archived": return .archived
        default: return .unknown
        }
    }

    static func managedPostSummary(_ dto: FanboxManagedPostDTO, creatorID: String, creatorName: String?, creatorIconURL: String?) -> RemotePostSummary? {
        guard let id = dto.id else { return nil }
        let published = dto.publishedAt ?? dto.updatedAt ?? .distantPast
        let blocks = contentBlocks(body: dto.body, type: postType(dto.type ?? (dto.body?.blocks != nil ? "article" : nil)))
        var summary = RemotePostSummary(
            id: id, creatorID: creatorID, creatorName: nonEmpty(creatorName) ?? creatorID, creatorIconURL: creatorIconURL, title: dto.title ?? "",
            excerpt: String(plainText(blocks).prefix(120)), type: postType(dto.type ?? (dto.body?.blocks != nil ? "article" : nil)),
            feeRequired: max(0, dto.feeRequired ?? 0), coverImageURL: dto.coverImageUrl, publishedAt: published, updatedAt: dto.updatedAt ?? published,
            tags: dto.tags ?? [], isRestricted: false, hasAdultContent: dto.hasAdultContent ?? false)
        // Drafts / scheduled / taken-down posts must not look published (Creator Mode pill, hidden from reader views).
        // Unknown = nil.
        let status = postStatus(dto.status)
        summary.remoteStatus = status == .unknown ? nil : status
        // The managed listing carries no counts or like state; tags / the R-18 flag / the page name only when reported.
        summary.unreported = [.counts, .isLiked]
        if dto.tags == nil { summary.unreported.insert(.tags) }
        if dto.hasAdultContent == nil { summary.unreported.insert(.adultContent) }
        if nonEmpty(creatorName) == nil { summary.unreported.insert(.creatorName) }
        return summary
    }

    /// Managed posts newest first (by the later of updatedAt / publishedAt).
    static func managedPostSummaries(_ dtos: [FanboxManagedPostDTO], creatorID: String, creatorName: String?, creatorIconURL: String?) -> [RemotePostSummary] {
        dtos.compactMap { managedPostSummary($0, creatorID: creatorID, creatorName: creatorName, creatorIconURL: creatorIconURL) }
            .sorted { (max($0.updatedAt, $0.publishedAt), $0.id) > (max($1.updatedAt, $1.publishedAt), $1.id) }
    }

    /// Type of an editable post: the reported `type`, else article when the body has blocks; unknown resolves to article.
    static func editablePostType(_ dto: FanboxManagedPostDTO) -> PostType {
        let type = postType(dto.type ?? (dto.body?.blocks != nil ? "article" : nil))
        return type == .unknown ? .article : type
    }

    static func editablePost(_ dto: FanboxManagedPostDTO) -> RemoteEditablePost? {
        guard let id = dto.id else { return nil }
        // Editable bodies are article-shaped; embed / url_embed ids are kept in mediaID so updatePost can round-trip them.
        let resolvedType = editablePostType(dto)
        let blocks = contentBlocks(body: dto.body, type: resolvedType, includeReferenceIDs: true)
        let status = postStatus(dto.status)
        return RemoteEditablePost(id: id, title: dto.title ?? "", feeRequired: max(0, dto.feeRequired ?? 0), planID: nil, status: status,
                                  blocks: blocks, tags: dto.tags ?? [], hasAdultContent: dto.hasAdultContent ?? false,
                                  publishedAt: status == .draft ? nil : dto.publishedAt, updatedAt: dto.updatedAt,
                                  postType: resolvedType,
                                  commentPermission: dto.commentingPermissionScope.flatMap { CommentPermission(rawValue: $0.lowercased()) },
                                  tagsKnown: dto.tags != nil)
    }

    static func fanState(_ raw: String?) -> FanState {
        switch raw?.lowercased() {
        case "supporter": return .supporting
        case "follower": return .following
        default: return .unknown
        }
    }

    static func fan(_ dto: FanboxFanDTO, plans: [String: RemotePlan]) -> RemoteFan? {
        guard let userID = dto.user?.userId else { return nil }
        let plan = dto.planId.flatMap { plans[$0] }
        return RemoteFan(userID: userID, name: nonEmpty(dto.user?.name) ?? userID, iconURL: dto.user?.iconUrl, planID: dto.planId, planTitle: plan?.title,
                         fee: plan?.fee, supportStartedAt: dto.activatedAt, supportMonths: nil, state: fanState(dto.status))
    }

    /// Supporter count from relationship.listFilterOptions: the explicit `supporter` total if present, else the sum of
    /// per-plan buckets. nil when neither exists (never guessed).
    static func supporterCount(_ options: [FanboxFanFilterOptionDTO]) -> Int? {
        if let total = options.first(where: { $0.type?.lowercased() == "supporter" && $0.planId == nil })?.count { return total }
        let buckets = options.filter { $0.planId != nil }.compactMap(\.count)
        return buckets.isEmpty ? nil : buckets.reduce(0, +)
    }

    /// Sum of support received for `month` ("YYYY-MM") from legacy/manage/pledge/monthly.
    static func earnings(_ body: FanboxPledgeMonthlyBody, month: String) -> Int {
        body.supportTransactions.filter { ($0.targetMonth ?? month) == month }.compactMap(\.paidAmount).reduce(0, +)
    }

    /// Published posts whose publish date falls in `month` (JST).
    static func publishedPostCount(_ posts: [FanboxManagedPostDTO], month: String) -> Int {
        posts.filter { postStatus($0.status) == .published }
            .filter { $0.publishedAt.map { FanboxDateParser.monthKey($0) == month } ?? false }
            .count
    }

    // MARK: - Helpers

    static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

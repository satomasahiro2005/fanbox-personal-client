import Foundation

/// One row of the "閲覧アカウント" menu.
struct PostAccountOption: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var colorHex: String?
    /// nil = unknown (this account never listed the post).
    var canView: Bool?
    var isCached: Bool
    var isBest: Bool

    var statusText: String {
        var parts: [String] = []
        switch canView {
        case true?: parts.append("閲覧可")
        case false?: parts.append("閲覧不可")
        case nil: parts.append("未確認")
        }
        if isCached { parts.append("キャッシュ済") }
        if isBest { parts.append("自動選択") }
        return parts.joined(separator: " · ")
    }
}

/// Pure account-choice rules for Post detail / comments (SPEC §3.2 / §8). The automatic choice itself is
/// `AccountSelector`; this adds the manual override and refresh decisions.
enum PostAccountLogic {
    /// Account to use: the user's manual override while it is still an enabled account, otherwise the automatic best
    /// account, otherwise the first enabled account.
    static func effectiveAccountID(override: String?, best: String?, enabledAccountIDs: [String]) -> String? {
        if let override, enabledAccountIDs.contains(override) { return override }
        if let best, enabledAccountIDs.contains(best) { return best }
        return enabledAccountIDs.first
    }

    /// Whether the post body must be fetched for `selectedAccountID`:
    /// no cached body, cached from another account, or the listing reports a newer version than the cached body.
    /// When the selected account is known NOT to be able to view the post, an existing cached body is kept
    /// (re-fetching would only return a restricted copy).
    static func needsBodyRefresh(hasCachedBody: Bool, cachedAccountID: String?, selectedAccountID: String?,
                                 selectedCanView: Bool? = nil, bodyFetchedAt: Date? = nil, postUpdatedAt: Date? = nil) -> Bool {
        guard hasCachedBody else { return true }
        if selectedCanView == false { return false }
        if let selectedAccountID, let cachedAccountID, cachedAccountID != selectedAccountID { return true }
        if let bodyFetchedAt, let postUpdatedAt, postUpdatedAt > bodyFetchedAt { return true }
        return false
    }

    /// After a fetch in automatic mode the choice moved to `selectedAccountID`: fetch again when that account's body
    /// is not the local one and the account is not known to be restricted.
    static func needsFetchAfterSelectionChange(selectedAccountID: String, cachedAccountID: String?, hasCachedBody: Bool,
                                               selectedCanView: Bool?) -> Bool {
        guard selectedCanView != false else { return false }
        return !hasCachedBody || cachedAccountID != selectedAccountID
    }

    /// A failed body fetch offers the account-aware WebView (SPEC §40 fallback) when FANBOX answered but the answer
    /// could not be used natively: edge / bot block, forbidden, unknown schema, server error, unsupported operation.
    /// Offline, policy blocks, cancellation and plain transport errors would fail in the WebView as well.
    static func offersWebFallback(for error: RemoteError?) -> Bool {
        guard let error else { return false }
        switch error {
        case .offline, .cancelled, .blockedByPolicy, .network: return false
        default: return true
        }
    }

    /// Comment operations (delete, …) that the API refused, does not support or answered unreadably fall back to the
    /// WebView (SPEC §21 "不安定な操作は Account-aware WebView へフォールバックしてよい"). Connectivity problems and
    /// "already gone" do not.
    static func commentOperationOffersWeb(_ error: RemoteError) -> Bool {
        switch error {
        case .offline, .cancelled, .blockedByPolicy, .network, .rateLimited, .notFound: return false
        default: return true
        }
    }

    /// Nobody among my accounts can view the paid body (→ "支援が必要です").
    static func isRestricted(feeRequired: Int, accessAccountIDs: [String], hasBlocks: Bool) -> Bool {
        feeRequired > 0 && accessAccountIDs.isEmpty && !hasBlocks
    }

    /// Menu rows, in account order.
    static func options(accounts: [(id: String, name: String, colorHex: String?)], accesses: [String: Bool],
                        cachedAccountIDs: Set<String>, best: String?) -> [PostAccountOption] {
        accounts.map { a in
            PostAccountOption(id: a.id, name: a.name, colorHex: a.colorHex, canView: accesses[a.id],
                              isCached: cachedAccountIDs.contains(a.id), isBest: a.id == best)
        }
    }

    /// Default account for writing a comment: my creator account for my own posts, else the automatic best account.
    static func defaultCommentAccountID(postCreatorID: String?, isOwnPost: Bool,
                                        accounts: [(id: String, creatorID: String?)], best: String?) -> String? {
        if let postCreatorID, let owner = accounts.first(where: { $0.creatorID == postCreatorID }) {
            return owner.id
        }
        if isOwnPost, let owner = accounts.first(where: { $0.creatorID != nil }) { return owner.id }
        if let best, accounts.contains(where: { $0.id == best }) { return best }
        return accounts.first?.id
    }

    /// Account that may delete a comment, or nil when none of my accounts may:
    /// - my own comment → the account that wrote it (matched by pixiv / fanbox user id, else the account that fetched it);
    /// - any comment on my creator's post → the creator account that owns the post.
    static func deleteAccountID(commentIsOwn: Bool, authorUserID: String, fetchedByAccountID: String,
                                postCreatorID: String?, commentIsOnOwnPost: Bool,
                                accounts: [(id: String, userIDs: [String], creatorID: String?)]) -> String? {
        if let author = accounts.first(where: { $0.userIDs.contains(authorUserID) }) { return author.id }
        if commentIsOwn, accounts.contains(where: { $0.id == fetchedByAccountID }) { return fetchedByAccountID }
        if let postCreatorID, let owner = accounts.first(where: { $0.creatorID == postCreatorID }) { return owner.id }
        if commentIsOnOwnPost, let owner = accounts.first(where: { $0.creatorID != nil }) { return owner.id }
        return nil
    }
}

/// External link resolution for embed / external video blocks (SPEC §6).
enum PostDetailEmbedLink {
    /// Best-effort public URL for an embed. Returns `explicitURL` when present.
    static func url(provider: String?, contentID: String?, explicitURL: String?) -> URL? {
        if let explicitURL, let url = URL(string: explicitURL), url.scheme != nil { return url }
        guard let provider = provider?.lowercased(), let raw = contentID?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let id = raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        switch provider {
        case "youtube": return URL(string: "https://www.youtube.com/watch?v=\(id)")
        case "vimeo": return URL(string: "https://vimeo.com/\(id)")
        case "soundcloud": return URL(string: "https://soundcloud.com/\(id)")
        case "twitter", "x": return URL(string: "https://x.com/i/web/status/\(id)")
        case "gist": return URL(string: "https://gist.github.com/\(id)")
        default: return nil
        }
    }

    static func providerName(_ provider: String?) -> String {
        switch provider?.lowercased() {
        case "youtube"?: return "YouTube"
        case "vimeo"?: return "Vimeo"
        case "soundcloud"?: return "SoundCloud"
        case "twitter"?, "x"?: return "X (Twitter)"
        case "google_forms"?: return "Google フォーム"
        case "gist"?: return "Gist"
        case "fanbox"?: return "FANBOX"
        case let other?: return other
        case nil: return "外部コンテンツ"
        }
    }

    /// FANBOX / pixiv pages open in the account-aware WebView, never plain Safari (SPEC §40).
    static func isFanboxHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "fanbox.cc" || host.hasSuffix(".fanbox.cc") || host == "pixiv.net" || host.hasSuffix(".pixiv.net")
    }
}

/// Groups post blocks for rendering: consecutive images become one gallery (SPEC §6 Image Gallery).
enum PostDetailBlockLayout {
    enum Item: Hashable, Sendable {
        case single(Int)
        /// Indices into the block array, ≥ 2 consecutive images.
        case gallery([Int])
    }

    static func group(_ kinds: [PostBlockKind]) -> [Item] {
        var items: [Item] = []
        var run: [Int] = []
        func flush() {
            if run.count >= 2 { items.append(.gallery(run)) } else if let only = run.first { items.append(.single(only)) }
            run = []
        }
        for (i, kind) in kinds.enumerated() {
            if kind == .image {
                run.append(i)
            } else {
                flush()
                items.append(.single(i))
            }
        }
        flush()
        return items
    }
}

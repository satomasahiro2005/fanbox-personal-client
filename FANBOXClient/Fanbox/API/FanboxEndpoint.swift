import Foundation

/// One FANBOX request description (method, host, path, query, JSON body, CSRF flag, inspector key).
/// Every endpoint documented in docs/API.md has a factory below. Only `FanboxAPIClient` turns these into `HTTPRequest`s;
/// SwiftUI never sees them (SPEC §43).
struct FanboxEndpoint: Sendable, Hashable {
    enum Host: String, Sendable, Hashable {
        /// JSON API.
        case api = "api.fanbox.cc"
        /// Web pages (HTML with the `metadata` meta tag).
        case www = "www.fanbox.cc"
    }

    enum ResponseFormat: Sendable, Hashable {
        case json
        case html
    }

    /// Stable key for Research Mode / API Inspector, e.g. "post.info".
    var key: String
    var method: String
    var host: Host
    /// Path starting with "/", e.g. "/post.info".
    var path: String
    var query: [URLQueryItem]
    /// Verbatim percent-encoded query of a URL returned by FANBOX (`nextUrl`, page URLs). Overrides `query` when set,
    /// so cursor values are sent back byte-for-byte as the server produced them.
    var rawQuery: String?
    var jsonBody: JSONValue?
    var requiresCSRF: Bool
    var responseFormat: ResponseFormat
    /// Documented confidence (docs/API.md), recorded for Research Mode / tests.
    var confidence: Confidence

    enum Confidence: String, Sendable, Hashable {
        case high, medium, low
    }

    init(key: String, method: String = "GET", host: Host = .api, path: String? = nil, query: [URLQueryItem] = [],
         jsonBody: JSONValue? = nil, requiresCSRF: Bool = false, responseFormat: ResponseFormat = .json, confidence: Confidence = .high) {
        self.key = key
        self.method = method
        self.host = host
        self.path = path ?? "/" + key
        self.query = query
        self.jsonBody = jsonBody
        self.requiresCSRF = requiresCSRF
        self.responseFormat = responseFormat
        self.confidence = confidence
    }

    static let apiBase = URL(string: "https://api.fanbox.cc")!
    static let wwwBase = URL(string: "https://www.fanbox.cc")!
    /// Origin / Referer FANBOX expects on API calls (400 without Origin).
    static let webOrigin = "https://www.fanbox.cc"

    var url: URL {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host.rawValue
        comps.path = path
        if let rawQuery, !rawQuery.isEmpty {
            comps.percentEncodedQuery = rawQuery
        } else if !query.isEmpty {
            comps.queryItems = query
            // URLComponents leaves "+" unescaped, which servers decode as a space (breaks ISO-8601 offsets like +09:00).
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return comps.url!
    }

    var isWrite: Bool { method != "GET" }

    // MARK: - Session (www)

    /// www.fanbox.cc homepage: HTML whose `<meta name="metadata">` holds `csrfToken` and `context.user`.
    static func homepageMetadata() -> FanboxEndpoint {
        FanboxEndpoint(key: "www.metadata", host: .www, path: "/", responseFormat: .html)
    }

    // MARK: - Timelines

    static func listHome(limit: Int = 10) -> FanboxEndpoint {
        FanboxEndpoint(key: "post.listHome", query: [.init(name: "limit", value: String(limit))])
    }

    static func listSupporting(limit: Int = 10) -> FanboxEndpoint {
        FanboxEndpoint(key: "post.listSupporting", query: [.init(name: "limit", value: String(limit))])
    }

    static func paginateCreator(creatorID: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "post.paginateCreator", query: [.init(name: "creatorId", value: creatorID)])
    }

    /// First page of a creator's posts when no page URL is known. Pages normally come from `paginateCreator`.
    static func listCreator(creatorID: String, limit: Int = 10) -> FanboxEndpoint {
        FanboxEndpoint(key: "post.listCreator", query: [.init(name: "creatorId", value: creatorID), .init(name: "limit", value: String(limit))])
    }

    static func listTagged(tag: String, creatorID: String?, page: Int? = nil) -> FanboxEndpoint {
        var q: [URLQueryItem] = [.init(name: "tag", value: tag)]
        if let creatorID { q.append(.init(name: "creatorId", value: creatorID)) }
        if let page { q.append(.init(name: "page", value: String(page))) }
        return FanboxEndpoint(key: "post.listTagged", query: q, confidence: .medium)
    }

    // MARK: - Posts

    static func postInfo(postID: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "post.info", query: [.init(name: "postId", value: postID)])
    }

    /// Metadata-only post (no content). Fallback when post.info is blocked.
    static func postGet(postID: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "post.get", query: [.init(name: "postId", value: postID)], confidence: .medium)
    }

    static func likePost(postID: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "post.likePost", method: "POST", jsonBody: ["postId": .string(postID)], requiresCSRF: true)
    }

    // MARK: - Comments

    static func getComments(postID: String, offset: Int = 0, limit: Int = 20) -> FanboxEndpoint {
        FanboxEndpoint(key: "post.getComments", query: [
            .init(name: "postId", value: postID), .init(name: "offset", value: String(offset)), .init(name: "limit", value: String(limit)),
        ])
    }

    /// Root comment: both ids "0" (what the shipping web/app clients send). Reply: root = thread root, parent = replied comment.
    static func addComment(postID: String, body: String, rootCommentID: String?, parentCommentID: String?) -> FanboxEndpoint {
        let root = rootCommentID ?? parentCommentID ?? "0"
        let parent = parentCommentID ?? rootCommentID ?? "0"
        return FanboxEndpoint(key: "post.addComment", method: "POST", jsonBody: [
            "postId": .string(postID), "body": .string(body), "rootCommentId": .string(root), "parentCommentId": .string(parent),
        ], requiresCSRF: true)
    }

    static func deleteComment(commentID: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "post.deleteComment", method: "POST", jsonBody: ["commentId": .string(commentID)], requiresCSRF: true)
    }

    static func likeComment(commentID: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "post.likeComment", method: "POST", jsonBody: ["commentId": .string(commentID)], requiresCSRF: true)
    }

    // MARK: - Creators

    static func creatorGet(creatorID: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "creator.get", query: [.init(name: "creatorId", value: creatorID)])
    }

    static func creatorGet(userID: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "creator.get", query: [.init(name: "userId", value: userID)])
    }

    static func listFollowing() -> FanboxEndpoint { FanboxEndpoint(key: "creator.listFollowing") }

    static func listRecommended(limit: Int = 10) -> FanboxEndpoint {
        FanboxEndpoint(key: "creator.listRecommended", query: [.init(name: "limit", value: String(limit))])
    }

    static func listPixiv() -> FanboxEndpoint { FanboxEndpoint(key: "creator.listPixiv", confidence: .medium) }

    static func creatorSearch(query text: String, page: Int = 0) -> FanboxEndpoint {
        FanboxEndpoint(key: "creator.search", query: [.init(name: "q", value: text), .init(name: "page", value: String(page))])
    }

    static func tagSearch(query text: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "tag.search", query: [.init(name: "q", value: text)], confidence: .medium)
    }

    static func tagFeatured(creatorID: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "tag.getFeatured", query: [.init(name: "creatorId", value: creatorID)], confidence: .medium)
    }

    static func followCreate(creatorUserID: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "follow.create", method: "POST", jsonBody: ["creatorUserId": .string(creatorUserID)], requiresCSRF: true)
    }

    static func followDelete(creatorUserID: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "follow.delete", method: "POST", jsonBody: ["creatorUserId": .string(creatorUserID)], requiresCSRF: true)
    }

    // MARK: - Plans / support / payments

    static func planListSupporting() -> FanboxEndpoint { FanboxEndpoint(key: "plan.listSupporting") }

    static func planListCreator(creatorID: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "plan.listCreator", query: [.init(name: "creatorId", value: creatorID)])
    }

    /// The viewer's support details for one creator (plan, start date, transactions).
    static func supportCreator(creatorID: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "legacy.support.creator", path: "/legacy/support/creator", query: [.init(name: "creatorId", value: creatorID)])
    }

    static func paymentListPaid() -> FanboxEndpoint { FanboxEndpoint(key: "payment.listPaid") }

    static func paymentListUnpaid() -> FanboxEndpoint { FanboxEndpoint(key: "payment.listUnpaid", confidence: .medium) }

    // MARK: - Notifications / newsletters

    /// `skipConvertUnread = true` keeps items unread on FANBOX (listing with 0 marks them read server-side).
    static func bellList(page: Int = 1, skipConvertUnread: Bool = true, commentOnly: Bool = false) -> FanboxEndpoint {
        FanboxEndpoint(key: "bell.list", query: [
            .init(name: "page", value: String(page)),
            .init(name: "skipConvertUnreadNotification", value: skipConvertUnread ? "1" : "0"),
            .init(name: "commentOnly", value: commentOnly ? "1" : "0"),
        ])
    }

    static func bellCountUnread() -> FanboxEndpoint { FanboxEndpoint(key: "bell.countUnread") }

    static func countUnreadMessages() -> FanboxEndpoint { FanboxEndpoint(key: "user.countUnreadMessages") }

    static func newsletterList() -> FanboxEndpoint { FanboxEndpoint(key: "newsletter.list", confidence: .medium) }

    static func newsletterCountUnread() -> FanboxEndpoint { FanboxEndpoint(key: "newsletter.countUnread", confidence: .medium) }

    /// Low confidence (never exercised with a token by any source). Not used by the data source.
    static func newsletterMarkAsReadAll() -> FanboxEndpoint {
        FanboxEndpoint(key: "newsletter.markAsReadAll", method: "POST", jsonBody: [:], requiresCSRF: true, confidence: .low)
    }

    static func notificationGetSettings() -> FanboxEndpoint { FanboxEndpoint(key: "notification.getSettings", confidence: .medium) }

    static func notificationUpdateSettings(type: String, enabled: Bool) -> FanboxEndpoint {
        FanboxEndpoint(key: "notification.updateSettings", method: "POST",
                       jsonBody: ["type": .string(type), "value": .string(enabled ? "1" : "0")], requiresCSRF: true, confidence: .medium)
    }

    // MARK: - Creator side

    static func listManaged() -> FanboxEndpoint { FanboxEndpoint(key: "post.listManaged", confidence: .medium) }

    static func getEditable(postID: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "post.getEditable", query: [.init(name: "postId", value: postID)])
    }

    /// Creates an empty draft; content is then saved with `post.update` (multipart, see `FanboxPostUpdateForm`).
    static func postCreate(type: String = "article") -> FanboxEndpoint {
        FanboxEndpoint(key: "post.create", method: "POST", jsonBody: ["type": .string(type)], requiresCSRF: true, confidence: .medium)
    }

    /// Multipart endpoint; the form is built by `FanboxPostUpdateForm` (CSRF travels in the `tt` field and the header).
    static func postUpdate() -> FanboxEndpoint {
        FanboxEndpoint(key: "post.update", method: "POST", requiresCSRF: true)
    }

    static func postDelete(postID: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "post.delete", method: "POST", jsonBody: ["postId": .string(postID)], requiresCSRF: true, confidence: .medium)
    }

    static func listFans(status: String = "supporter", planID: String? = nil) -> FanboxEndpoint {
        var q: [URLQueryItem] = [.init(name: "status", value: status)]
        if let planID { q.append(.init(name: "planId", value: planID)) }
        return FanboxEndpoint(key: "relationship.listFans", query: q)
    }

    static func listFanFilterOptions() -> FanboxEndpoint { FanboxEndpoint(key: "relationship.listFilterOptions") }

    static func managedSupporter(userID: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "legacy.manage.supporter.user", path: "/legacy/manage/supporter/user",
                       query: [.init(name: "userId", value: userID)], confidence: .medium)
    }

    /// Support payments received in one month ("YYYY-MM").
    static func pledgeMonthly(month: String) -> FanboxEndpoint {
        FanboxEndpoint(key: "legacy.manage.pledge.monthly", path: "/legacy/manage/pledge/monthly",
                       query: [.init(name: "month", value: month)], confidence: .medium)
    }

    static func payoutRequest() -> FanboxEndpoint {
        FanboxEndpoint(key: "legacy.payout_request", path: "/legacy/payout_request", confidence: .medium)
    }

    // MARK: - Cursor URLs

    /// Re-issues a `nextUrl` / page URL returned by FANBOX. Only api.fanbox.cc URLs whose path matches `expectedPath`
    /// are accepted (a cursor must never make the client call an arbitrary host).
    static func followURL(_ string: String, key: String, expectedPath: String) -> FanboxEndpoint? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("//") { s = "https:" + s }
        if !s.contains("://") { s = "https://api.fanbox.cc" + (s.hasPrefix("/") ? "" : "/") + s }
        guard let comps = URLComponents(string: s), comps.scheme == "https", comps.host == Host.api.rawValue,
              comps.path == expectedPath else { return nil }
        var endpoint = FanboxEndpoint(key: key, host: .api, path: comps.path, query: comps.queryItems ?? [])
        endpoint.rawQuery = comps.percentEncodedQuery
        return endpoint
    }
}

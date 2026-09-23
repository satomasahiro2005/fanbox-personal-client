import Foundation
import SwiftData

/// Creator shown as an entity above accounts (SPEC §9).
@Model
final class Creator {
    @Attribute(.unique) var creatorID: String
    var pixivUserID: String?
    var name: String
    var iconURL: String?
    var coverImageURL: String?
    var profileText: String
    var profileLinks: [String]
    var hasAdultContent: Bool
    /// Local account ids that follow this creator.
    var followedByAccountIDs: [String]
    /// Local account ids with an active support (denormalized from `Support`).
    var supportedByAccountIDs: [String]
    /// Denormalized flags so `@Query` predicates can filter cheaply.
    var isFollowed: Bool
    var isSupported: Bool
    var hasKnownPosts: Bool
    /// Non-nil if one of my accounts owns this creator page.
    var ownedByAccountID: String?
    // User metadata (never sent to FANBOX)
    var isFavorite: Bool
    var memo: String
    /// Offline rule: keep the most recent N posts saved (0 = off). SPEC §31 "Creator の最近 N 件".
    var offlineRecentCount: Int
    var latestPostAt: Date?
    var fetchedAt: Date?
    var updatedAt: Date

    init(creatorID: String, name: String, pixivUserID: String? = nil, iconURL: String? = nil, coverImageURL: String? = nil,
         profileText: String = "", profileLinks: [String] = [], hasAdultContent: Bool = false, updatedAt: Date = .now) {
        self.creatorID = creatorID
        self.pixivUserID = pixivUserID
        self.name = name
        self.iconURL = iconURL
        self.coverImageURL = coverImageURL
        self.profileText = profileText
        self.profileLinks = profileLinks
        self.hasAdultContent = hasAdultContent
        self.followedByAccountIDs = []
        self.supportedByAccountIDs = []
        self.isFollowed = false
        self.isSupported = false
        self.hasKnownPosts = false
        self.ownedByAccountID = nil
        self.isFavorite = false
        self.memo = ""
        self.offlineRecentCount = 0
        self.updatedAt = updatedAt
    }
}

@Model
final class Plan {
    @Attribute(.unique) var planID: String
    var creatorID: String
    var title: String
    var fee: Int
    var planDescription: String
    var coverImageURL: String?
    var hasAdultContent: Bool
    var sortOrder: Int
    var updatedAt: Date

    init(planID: String, creatorID: String, title: String, fee: Int, planDescription: String = "", coverImageURL: String? = nil,
         hasAdultContent: Bool = false, sortOrder: Int = 0, updatedAt: Date = .now) {
        self.planID = planID
        self.creatorID = creatorID
        self.title = title
        self.fee = fee
        self.planDescription = planDescription
        self.coverImageURL = coverImageURL
        self.hasAdultContent = hasAdultContent
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
    }
}

/// One post, deduplicated across accounts (SPEC §5). Per-account visibility lives in `PostAccess`.
@Model
final class Post {
    @Attribute(.unique) var postID: String
    var creatorID: String
    var creatorName: String
    var creatorIconURL: String?
    var title: String
    /// Short excerpt from list APIs (feed card "本文冒頭").
    var excerpt: String
    /// Plain text of the full body (filled after detail fetch). Used for local full-text search.
    var bodyText: String
    var typeRaw: String
    var feeRequired: Int
    var coverImageURL: String?
    var publishedAt: Date
    var updatedAt: Date
    var fanboxTags: [String]
    var likeCount: Int
    var commentCount: Int
    var isLiked: Bool
    var hasAdultContent: Bool
    /// Denormalized from PostAccess: account ids that can view the full body.
    var accessAccountIDs: [String]
    /// Account ids that have seen this post in any listing.
    var seenByAccountIDs: [String]
    /// Denormalized feed filter flags (updated by sync).
    var isFromSupportedCreator: Bool
    var isFromFollowedCreator: Bool
    /// True if my own creator account published it.
    var isOwnPost: Bool
    var bodyFetchedAt: Date?
    /// Account used for the currently cached body.
    var detailAccountID: String?
    var prevPostID: String?
    var nextPostID: String?
    // User metadata (never sent to FANBOX)
    var isRead: Bool
    var readAt: Date?
    var isFavorite: Bool
    var isReadLater: Bool
    var memo: String
    var offlineStateRaw: String
    var lastViewedAt: Date?
    var fetchedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \PostBlock.post)
    var blocks: [PostBlock] = []

    init(postID: String, creatorID: String, creatorName: String, title: String, excerpt: String = "", type: PostType = .unknown,
         feeRequired: Int = 0, coverImageURL: String? = nil, publishedAt: Date, updatedAt: Date? = nil, fetchedAt: Date = .now) {
        self.postID = postID
        self.creatorID = creatorID
        self.creatorName = creatorName
        self.creatorIconURL = nil
        self.title = title
        self.excerpt = excerpt
        self.bodyText = ""
        self.typeRaw = type.rawValue
        self.feeRequired = feeRequired
        self.coverImageURL = coverImageURL
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt ?? publishedAt
        self.fanboxTags = []
        self.likeCount = 0
        self.commentCount = 0
        self.isLiked = false
        self.hasAdultContent = false
        self.accessAccountIDs = []
        self.seenByAccountIDs = []
        self.isFromSupportedCreator = false
        self.isFromFollowedCreator = false
        self.isOwnPost = false
        self.isRead = false
        self.isFavorite = false
        self.isReadLater = false
        self.memo = ""
        self.offlineStateRaw = OfflineState.none.rawValue
        self.fetchedAt = fetchedAt
    }

    var type: PostType {
        get { PostType(rawValue: typeRaw) ?? .unknown }
        set { typeRaw = newValue.rawValue }
    }

    var offlineState: OfflineState {
        get { OfflineState(rawValue: offlineStateRaw) ?? .none }
        set { offlineStateRaw = newValue.rawValue }
    }

    var hasCachedBody: Bool { bodyFetchedAt != nil }

    var orderedBlocks: [PostBlock] { blocks.sorted { $0.index < $1.index } }
}

@Model
final class PostBlock {
    /// "\(postID)#\(index)"
    @Attribute(.unique) var key: String
    var postID: String
    var index: Int
    var kindRaw: String
    var text: String
    /// JSON-encoded `[RemoteTextStyle]` (bold / font size ranges), optional.
    var stylesJSON: String?
    /// FANBOX image id / file id.
    var mediaID: String?
    var thumbnailURL: String?
    var displayURL: String?
    var originalURL: String?
    var width: Int?
    var height: Int?
    var fileName: String?
    var fileExtension: String?
    var fileSize: Int?
    /// Link target for url / embed / external video.
    var url: String?
    var embedProvider: String?
    var embedContentID: String?
    var title: String?
    var subtitle: String?
    var post: Post?

    init(postID: String, index: Int, kind: PostBlockKind, text: String = "") {
        self.key = "\(postID)#\(index)"
        self.postID = postID
        self.index = index
        self.kindRaw = kind.rawValue
        self.text = text
    }

    var kind: PostBlockKind {
        get { PostBlockKind(rawValue: kindRaw) ?? .unknown }
        set { kindRaw = newValue.rawValue }
    }
}

/// Per-account view of a post (SPEC §5 `PostAccess`).
@Model
final class PostAccess {
    /// "\(postID)|\(accountID)"
    @Attribute(.unique) var key: String
    var postID: String
    var accountID: String
    var canView: Bool
    var feeRequired: Int
    /// Fee of the plan this account currently supports for the creator (if known).
    var accountPlanFee: Int?
    var bodyCached: Bool
    var fetchedAt: Date
    var lastError: String?

    init(postID: String, accountID: String, canView: Bool, feeRequired: Int, accountPlanFee: Int? = nil, fetchedAt: Date = .now) {
        self.key = PostAccess.key(postID: postID, accountID: accountID)
        self.postID = postID
        self.accountID = accountID
        self.canView = canView
        self.feeRequired = feeRequired
        self.accountPlanFee = accountPlanFee
        self.bodyCached = false
        self.fetchedAt = fetchedAt
    }

    static func key(postID: String, accountID: String) -> String { "\(postID)|\(accountID)" }
}

@Model
final class Comment {
    @Attribute(.unique) var commentID: String
    var postID: String
    var creatorID: String?
    var fetchedByAccountID: String
    var parentCommentID: String?
    var rootCommentID: String?
    var authorUserID: String
    var authorName: String
    var authorIconURL: String?
    var body: String
    var createdAt: Date
    var likeCount: Int
    var isLiked: Bool
    /// Written by one of my accounts.
    var isOwn: Bool
    /// Comment on a post of my own creator account (Creator Mode).
    var isOnOwnPost: Bool
    /// Local read state (Creator Mode 未読).
    var isRead: Bool
    var isDeleted: Bool
    var fetchedAt: Date

    init(commentID: String, postID: String, fetchedByAccountID: String, authorUserID: String, authorName: String, body: String,
         createdAt: Date, parentCommentID: String? = nil, rootCommentID: String? = nil, fetchedAt: Date = .now) {
        self.commentID = commentID
        self.postID = postID
        self.fetchedByAccountID = fetchedByAccountID
        self.authorUserID = authorUserID
        self.authorName = authorName
        self.body = body
        self.createdAt = createdAt
        self.parentCommentID = parentCommentID
        self.rootCommentID = rootCommentID
        self.likeCount = 0
        self.isLiked = false
        self.isOwn = false
        self.isOnOwnPost = false
        self.isRead = false
        self.isDeleted = false
        self.fetchedAt = fetchedAt
    }

    /// Root of the thread this comment belongs to.
    var threadRootID: String { rootCommentID ?? commentID }
}

/// Outgoing comment / reply queue item (SPEC §22).
@Model
final class OutgoingComment {
    @Attribute(.unique) var id: String
    var accountID: String
    var postID: String
    var parentCommentID: String?
    var rootCommentID: String?
    var body: String
    var stateRaw: String
    var originRaw: String
    var createdAt: Date
    var queuedAt: Date?
    var lastAttemptAt: Date?
    var sentAt: Date?
    var attemptCount: Int
    var lastError: String?
    var sentCommentID: String?

    init(id: String = UUID().uuidString, accountID: String, postID: String, parentCommentID: String? = nil, rootCommentID: String? = nil,
         body: String, state: ReplyState = .draft, origin: ReplyOrigin = .inApp, createdAt: Date = .now) {
        self.id = id
        self.accountID = accountID
        self.postID = postID
        self.parentCommentID = parentCommentID
        self.rootCommentID = rootCommentID
        self.body = body
        self.stateRaw = state.rawValue
        self.originRaw = origin.rawValue
        self.createdAt = createdAt
        self.attemptCount = 0
    }

    var state: ReplyState {
        get { ReplyState(rawValue: stateRaw) ?? .draft }
        set { stateRaw = newValue.rawValue }
    }

    var origin: ReplyOrigin {
        get { ReplyOrigin(rawValue: originRaw) ?? .inApp }
        set { originRaw = newValue.rawValue }
    }
}

/// おたより (creator newsletter).
@Model
final class Newsletter {
    @Attribute(.unique) var newsletterID: String
    var creatorID: String
    var creatorName: String
    var creatorIconURL: String?
    var accountIDs: [String]
    var title: String?
    var body: String
    var bodyFetched: Bool
    var createdAt: Date
    var isRead: Bool
    var fetchedAt: Date

    init(newsletterID: String, creatorID: String, creatorName: String, body: String, createdAt: Date, accountIDs: [String] = [],
         fetchedAt: Date = .now) {
        self.newsletterID = newsletterID
        self.creatorID = creatorID
        self.creatorName = creatorName
        self.body = body
        self.bodyFetched = !body.isEmpty
        self.createdAt = createdAt
        self.accountIDs = accountIDs
        self.isRead = false
        self.fetchedAt = fetchedAt
    }
}

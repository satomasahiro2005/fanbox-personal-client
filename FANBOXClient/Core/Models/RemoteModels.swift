import Foundation

// Sendable value types returned by `RemoteDataSource` implementations.
// They are app-domain shapes (NOT FANBOX DTOs). `FanboxAdapter` maps DTO -> Remote*;
// `LocalStore` normalizes Remote* into SwiftData models. SwiftUI never sees DTOs.

struct RemotePage<Item: Sendable>: Sendable {
    var items: [Item]
    /// Opaque cursor for the next (older) page; nil when there is no more data.
    var nextCursor: String?

    init(items: [Item], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// The logged-in user of an account session.
struct RemoteUser: Sendable, Hashable {
    var pixivUserID: String
    var fanboxUserID: String?
    var name: String
    var iconURL: String?
    /// Non-nil if the user owns a creator page.
    var creatorID: String?
}

struct RemoteTextStyle: Sendable, Codable, Hashable {
    /// "bold" / "fontSize" / other raw values.
    var type: String
    var offset: Int
    var length: Int
    var size: Int?
}

struct RemotePostSummary: Sendable, Hashable {
    var id: String
    var creatorID: String
    var creatorName: String
    var creatorIconURL: String?
    var pixivUserID: String?
    var title: String
    var excerpt: String
    var type: PostType
    var feeRequired: Int
    var coverImageURL: String?
    var publishedAt: Date
    var updatedAt: Date
    var tags: [String]
    var likeCount: Int
    var commentCount: Int
    var isLiked: Bool
    /// True when THIS account cannot view the body.
    var isRestricted: Bool
    var hasAdultContent: Bool

    init(id: String, creatorID: String, creatorName: String, creatorIconURL: String? = nil, pixivUserID: String? = nil, title: String,
         excerpt: String = "", type: PostType = .unknown, feeRequired: Int = 0, coverImageURL: String? = nil, publishedAt: Date,
         updatedAt: Date? = nil, tags: [String] = [], likeCount: Int = 0, commentCount: Int = 0, isLiked: Bool = false,
         isRestricted: Bool = false, hasAdultContent: Bool = false) {
        self.id = id
        self.creatorID = creatorID
        self.creatorName = creatorName
        self.creatorIconURL = creatorIconURL
        self.pixivUserID = pixivUserID
        self.title = title
        self.excerpt = excerpt
        self.type = type
        self.feeRequired = feeRequired
        self.coverImageURL = coverImageURL
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt ?? publishedAt
        self.tags = tags
        self.likeCount = likeCount
        self.commentCount = commentCount
        self.isLiked = isLiked
        self.isRestricted = isRestricted
        self.hasAdultContent = hasAdultContent
    }
}

struct RemoteBlock: Sendable, Hashable {
    var kind: PostBlockKind
    var text: String
    var styles: [RemoteTextStyle]
    var mediaID: String?
    var thumbnailURL: String?
    var displayURL: String?
    var originalURL: String?
    var width: Int?
    var height: Int?
    var fileName: String?
    var fileExtension: String?
    var fileSize: Int?
    var url: String?
    var embedProvider: String?
    var embedContentID: String?
    var title: String?
    var subtitle: String?

    init(kind: PostBlockKind, text: String = "", styles: [RemoteTextStyle] = [], mediaID: String? = nil, thumbnailURL: String? = nil,
         displayURL: String? = nil, originalURL: String? = nil, width: Int? = nil, height: Int? = nil, fileName: String? = nil,
         fileExtension: String? = nil, fileSize: Int? = nil, url: String? = nil, embedProvider: String? = nil,
         embedContentID: String? = nil, title: String? = nil, subtitle: String? = nil) {
        self.kind = kind
        self.text = text
        self.styles = styles
        self.mediaID = mediaID
        self.thumbnailURL = thumbnailURL
        self.displayURL = displayURL
        self.originalURL = originalURL
        self.width = width
        self.height = height
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.fileSize = fileSize
        self.url = url
        self.embedProvider = embedProvider
        self.embedContentID = embedContentID
        self.title = title
        self.subtitle = subtitle
    }
}

struct RemotePostDetail: Sendable, Hashable {
    var summary: RemotePostSummary
    /// Empty when `summary.isRestricted`.
    var blocks: [RemoteBlock]
    /// Plain text of all text blocks joined by newlines (for search).
    var plainText: String
    var prevPostID: String?
    var nextPostID: String?
}

struct RemoteCreator: Sendable, Hashable {
    var creatorID: String
    var pixivUserID: String?
    var name: String
    var iconURL: String?
    var coverImageURL: String?
    var profileText: String
    var profileLinks: [String]
    var hasAdultContent: Bool
    /// As seen by the requesting account; nil if unknown.
    var isFollowed: Bool?
    var isSupported: Bool?

    init(creatorID: String, pixivUserID: String? = nil, name: String, iconURL: String? = nil, coverImageURL: String? = nil,
         profileText: String = "", profileLinks: [String] = [], hasAdultContent: Bool = false, isFollowed: Bool? = nil,
         isSupported: Bool? = nil) {
        self.creatorID = creatorID
        self.pixivUserID = pixivUserID
        self.name = name
        self.iconURL = iconURL
        self.coverImageURL = coverImageURL
        self.profileText = profileText
        self.profileLinks = profileLinks
        self.hasAdultContent = hasAdultContent
        self.isFollowed = isFollowed
        self.isSupported = isSupported
    }
}

struct RemotePlan: Sendable, Hashable {
    var planID: String
    var creatorID: String
    var title: String
    var fee: Int
    var description: String
    var coverImageURL: String?
    var hasAdultContent: Bool
}

/// One active support of the requesting account (from the "supporting plans" listing).
struct RemoteSupport: Sendable, Hashable {
    var planID: String
    var creatorID: String
    var creatorName: String
    var creatorIconURL: String?
    var pixivUserID: String?
    var planTitle: String
    var fee: Int
    /// Raw payment method kind reported by FANBOX, if present.
    var paymentMethod: String?
    var planDescription: String?
    var coverImageURL: String?
}

struct RemoteComment: Sendable, Hashable {
    var id: String
    var postID: String
    var parentCommentID: String?
    var rootCommentID: String?
    var authorUserID: String
    var authorName: String
    var authorIconURL: String?
    var body: String
    var createdAt: Date
    var likeCount: Int
    var isLiked: Bool
    var isOwn: Bool
    var replies: [RemoteComment]

    init(id: String, postID: String, parentCommentID: String? = nil, rootCommentID: String? = nil, authorUserID: String,
         authorName: String, authorIconURL: String? = nil, body: String, createdAt: Date, likeCount: Int = 0, isLiked: Bool = false,
         isOwn: Bool = false, replies: [RemoteComment] = []) {
        self.id = id
        self.postID = postID
        self.parentCommentID = parentCommentID
        self.rootCommentID = rootCommentID
        self.authorUserID = authorUserID
        self.authorName = authorName
        self.authorIconURL = authorIconURL
        self.body = body
        self.createdAt = createdAt
        self.likeCount = likeCount
        self.isLiked = isLiked
        self.isOwn = isOwn
        self.replies = replies
    }

    /// Self followed by all nested replies (depth-first).
    var flattened: [RemoteComment] { [self] + replies.flatMap { $0.flattened } }
}

struct RemoteNotification: Sendable, Hashable {
    var remoteID: String
    var type: NotificationEventType
    /// FANBOX raw type string (kept for Research Mode).
    var rawType: String
    var createdAt: Date
    var creatorID: String?
    var creatorName: String?
    var postID: String?
    var postTitle: String?
    var commentID: String?
    var newsletterID: String?
    var actorName: String?
    var actorIconURL: String?
    var title: String
    var message: String
    var isUnread: Bool?
}

struct RemoteNewsletter: Sendable, Hashable {
    var id: String
    var creatorID: String
    var creatorName: String
    var creatorIconURL: String?
    var title: String?
    var body: String
    var createdAt: Date
    var isRead: Bool
}

struct RemotePayment: Sendable, Hashable {
    var id: String
    var creatorID: String?
    var creatorName: String?
    var amount: Int
    var paidAt: Date
    var paymentMethod: String?
}

struct RemoteFan: Sendable, Hashable {
    var userID: String
    var name: String
    var iconURL: String?
    var planID: String?
    var planTitle: String?
    var fee: Int?
    var supportStartedAt: Date?
    var supportMonths: Int?
    var state: FanState
}

/// Each metric is optional; nil = not provided by FANBOX (show as unavailable, never guess).
struct RemoteCreatorDashboard: Sendable, Hashable {
    /// "yyyy-MM"
    var month: String
    var supporterCount: Int?
    var earnings: Int?
    var postCount: Int?
    var commentCount: Int?
}

enum RemotePostStatus: String, Sendable, Codable {
    case draft, published, scheduled, unknown
}

struct RemoteEditablePost: Sendable, Hashable {
    var id: String
    var title: String
    var feeRequired: Int
    var planID: String?
    var status: RemotePostStatus
    var blocks: [RemoteBlock]
    var tags: [String]
    var hasAdultContent: Bool
    var publishedAt: Date?
    var updatedAt: Date?
}

struct RemoteDraftBlock: Sendable, Hashable {
    var kind: DraftBlockKind
    var text: String
    var mediaID: String?
    var url: String?
    var embedProvider: String?
    var embedContentID: String?
}

/// Payload to create / update a post on FANBOX.
struct RemotePostDraft: Sendable, Hashable {
    var title: String
    var feeRequired: Int
    var planID: String?
    var tags: [String]
    var hasAdultContent: Bool
    var blocks: [RemoteDraftBlock]
    /// true = publish, false = save as FANBOX draft.
    var publish: Bool
}

struct RemoteUploadResult: Sendable, Hashable {
    /// FANBOX imageId / fileId.
    var mediaID: String
    var url: String?
}

/// Errors surfaced by remote data sources. Feature code shows cached data + a banner; it never deletes local cache on error.
enum RemoteError: Error, Sendable, Equatable {
    /// Network mode is Offline or there is no connectivity.
    case offline
    /// Session missing / expired — re-login via Web Bridge.
    case unauthorized
    case forbidden
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case decoding(endpoint: String, detail: String)
    case network(code: Int, detail: String)
    /// Not available through the API; caller should fall back to the account-aware WebView.
    case unsupported(operation: String)
    /// Blocked by the current network mode policy (e.g. Extreme blocks automatic media).
    case blockedByPolicy
    case cancelled
    case invalidRequest(String)

    var userMessage: String {
        switch self {
        case .offline: return "オフラインです"
        case .unauthorized: return "ログインが必要です"
        case .forbidden: return "アクセスできません"
        case .notFound: return "見つかりませんでした"
        case .rateLimited: return "しばらく待ってから再試行してください"
        case .server(let status): return "サーバーエラー (\(status))"
        case .decoding: return "応答を解釈できませんでした"
        case .network: return "通信エラー"
        case .unsupported: return "この操作は Web で行ってください"
        case .blockedByPolicy: return "通信モードにより停止中"
        case .cancelled: return "キャンセルされました"
        case .invalidRequest(let detail): return detail
        }
    }

    /// Transient errors that may be retried automatically.
    var isTransient: Bool {
        switch self {
        case .offline, .rateLimited, .network: return true
        case .server(let status): return status >= 500
        default: return false
        }
    }
}

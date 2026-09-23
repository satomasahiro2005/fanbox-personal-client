import Foundation

// Comments, bell notifications, newsletters (おたより) and payment records. See docs/API.md.

/// Comment `{ id, parentCommentId, rootCommentId, body, createdDatetime, likeCount, isLiked, isOwn, user, replies }`.
/// Root comments use "0" for both parent ids. Replies to replies are flattened into the root's `replies`.
struct FanboxCommentDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var id: String?
    var parentCommentId: String?
    var rootCommentId: String?
    var body: String?
    var createdDatetime: Date?
    var likeCount: Int?
    var isLiked: Bool?
    var isOwn: Bool?
    var user: FanboxUserDTO?
    var replies: [FanboxCommentDTO]?

    static let knownFields: Set<String> = [
        "id", "parentCommentId", "rootCommentId", "body", "createdDatetime", "likeCount", "isLiked", "isOwn", "user", "replies",
    ]
    static var schemaChildren: [String: any SchemaDescribed.Type] {
        ["user": FanboxUserDTO.self, "replies[]": FanboxCommentReplySchema.self]
    }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        id = o.nonEmptyString("id")
        parentCommentId = o.nonEmptyString("parentCommentId")
        rootCommentId = o.nonEmptyString("rootCommentId")
        body = o.string("body")
        createdDatetime = o.date("createdDatetime")
        likeCount = o.int("likeCount")
        isLiked = o.bool("isLiked")
        isOwn = o.bool("isOwn")
        user = o.decode("user")
        replies = o.array("replies")
    }
}

/// Schema of a reply (same fields; stops the recursive description at one level).
enum FanboxCommentReplySchema: SchemaDescribed {
    static var knownFields: Set<String> { FanboxCommentDTO.knownFields }
    static var schemaChildren: [String: any SchemaDescribed.Type] { ["user": FanboxUserDTO.self] }
}

/// post.getComments `{ viewMode, commentList: { items, nextUrl } }`; legacy post.listComments `{ items, nextUrl }`.
struct FanboxCommentListBody: FanboxResponseBody {
    var viewMode: String?
    var items: [FanboxCommentDTO]
    var nextUrl: String?

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        viewMode = o.string("viewMode")
        if let list = o.decode("commentList", as: FanboxCommentPageDTO.self) {
            items = list.items
            nextUrl = list.nextUrl
        } else if o.has("items") {
            items = o.array("items") ?? []
            nextUrl = o.nonEmptyString("nextUrl")
        } else if o.has("commentList") {
            // commentList: null ⇒ no comments visible.
            items = []
            nextUrl = nil
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "comment list without commentList (keys: \(o.keys.sorted()))"))
        }
    }

    static var responseSchema: [String: Set<String>] {
        SchemaPaths.merge(["body": ["viewMode", "commentList"], "body.commentList": ["items", "nextUrl"]],
                          FanboxCommentDTO.knownSchema(at: "body.commentList.items[]"))
    }
}

struct FanboxCommentPageDTO: Decodable, Hashable, Sendable {
    var items: [FanboxCommentDTO]
    var nextUrl: String?

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        items = o.array("items") ?? []
        nextUrl = o.nonEmptyString("nextUrl")
    }
}

/// Bell (notification) item. Common: `{ id, type, notifiedDatetime, isUnread }`.
/// on_post_published: `post`; post_comment: `postCommentBody, isRootComment, creatorId, postId, postTitle, userName, userProfileImg`;
/// post_comment_like: `postCommentBody, creatorId, postId, count`.
struct FanboxBellItemDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var id: String?
    var type: String?
    var notifiedDatetime: Date?
    var isUnread: Bool?
    var post: FanboxPostListItemDTO?
    var postCommentBody: String?
    var isRootComment: Bool?
    var creatorId: String?
    var creatorUserId: String?
    var postId: String?
    var postTitle: String?
    var userName: String?
    var userProfileImg: String?
    var count: Int?

    static let knownFields: Set<String> = [
        "id", "type", "notifiedDatetime", "isUnread", "post", "postCommentBody", "isRootComment", "creatorId", "creatorUserId",
        "postId", "postTitle", "userName", "userProfileImg", "count",
    ]
    static var schemaChildren: [String: any SchemaDescribed.Type] { ["post": FanboxPostListItemDTO.self] }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        id = o.nonEmptyString("id")
        type = o.string("type")
        notifiedDatetime = o.date("notifiedDatetime")
        isUnread = o.bool("isUnread")
        post = o.decode("post")
        postCommentBody = o.string("postCommentBody")
        isRootComment = o.bool("isRootComment")
        creatorId = o.nonEmptyString("creatorId")
        creatorUserId = o.nonEmptyString("creatorUserId")
        postId = o.nonEmptyString("postId")
        postTitle = o.string("postTitle")
        userName = o.string("userName")
        userProfileImg = o.nonEmptyString("userProfileImg")
        count = o.int("count")
    }
}

/// bell.list `{ items, nextUrl }`.
struct FanboxBellListBody: FanboxResponseBody {
    var items: [FanboxBellItemDTO]
    var nextUrl: String?

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        guard o.has("items") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "bell.list without items (keys: \(o.keys.sorted()))"))
        }
        items = o.array("items") ?? []
        nextUrl = o.nonEmptyString("nextUrl")
    }

    static var responseSchema: [String: Set<String>] {
        SchemaPaths.merge(["body": ["items", "nextUrl"]], FanboxBellItemDTO.knownSchema(at: "body.items[]"))
    }
}

/// Newsletter creator `{ creatorId, user }`.
struct FanboxNewsletterCreatorDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var creatorId: String?
    var user: FanboxUserDTO?

    static let knownFields: Set<String> = ["creatorId", "user"]
    static var schemaChildren: [String: any SchemaDescribed.Type] { ["user": FanboxUserDTO.self] }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        creatorId = o.nonEmptyString("creatorId")
        user = o.decode("user")
    }
}

/// Newsletter (おたより) `{ id, body, createdAt, creator: { creatorId, user }, isRead }`.
struct FanboxNewsletterDTO: Decodable, Hashable, Sendable, SchemaDescribed, FanboxIdentifiedDTO {
    var id: String?
    var body: String?
    var createdAt: Date?
    var creator: FanboxNewsletterCreatorDTO?
    var isRead: Bool?

    var dtoID: String? { id }

    static let knownFields: Set<String> = ["id", "body", "createdAt", "creator", "isRead"]
    static var schemaChildren: [String: any SchemaDescribed.Type] { ["creator": FanboxNewsletterCreatorDTO.self] }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        id = o.nonEmptyString("id")
        body = o.string("body")
        createdAt = o.date("createdAt")
        creator = o.decode("creator")
        isRead = o.bool("isRead")
    }
}

enum FanboxNewslettersKey: FanboxListWrapperKey {
    /// Currently a bare array; accept a future `{ newsletters: [...] }` / `{ items: [...] }` wrapper.
    static let keys = ["newsletters", "items"]
}

typealias FanboxNewsletterListBody = FanboxWrappedList<FanboxNewsletterDTO, FanboxNewslettersKey>

/// Payment record creator `{ creatorId, user, isActive? }`.
struct FanboxPaymentCreatorDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var creatorId: String?
    var user: FanboxUserDTO?

    static let knownFields: Set<String> = ["creatorId", "user", "isActive"]
    static var schemaChildren: [String: any SchemaDescribed.Type] { ["user": FanboxUserDTO.self] }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        creatorId = o.nonEmptyString("creatorId")
        user = o.decode("user")
    }
}

/// payment.listPaid / listUnpaid element `{ id, paidAmount, paymentDatetime, paymentMethod, creator }`.
struct FanboxPaymentDTO: Decodable, Hashable, Sendable, SchemaDescribed, FanboxIdentifiedDTO {
    var id: String?
    var paidAmount: Int?
    var paymentDatetime: Date?
    var paymentMethod: String?
    var creator: FanboxPaymentCreatorDTO?

    var dtoID: String? { id }

    static let knownFields: Set<String> = ["id", "paidAmount", "paymentDatetime", "paymentMethod", "creator"]
    static var schemaChildren: [String: any SchemaDescribed.Type] { ["creator": FanboxPaymentCreatorDTO.self] }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        id = o.nonEmptyString("id")
        paidAmount = o.int("paidAmount")
        paymentDatetime = o.date("paymentDatetime")
        paymentMethod = o.nonEmptyString("paymentMethod")
        creator = o.decode("creator")
    }
}

enum FanboxPaymentsKey: FanboxListWrapperKey {
    static let keys = ["payments"]
}

/// payment.listPaid: `{ payments: [...] }` (current) or a bare array (older).
typealias FanboxPaymentListBody = FanboxWrappedList<FanboxPaymentDTO, FanboxPaymentsKey>

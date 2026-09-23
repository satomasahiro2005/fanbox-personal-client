import Foundation

// Creator / plan / support DTOs: creator.get, creator.listFollowing, creator.listRecommended, creator.search,
// plan.listSupporting, plan.listCreator, legacy/support/creator. See docs/API.md.

/// profileItems element: `{ id, type: "image", imageUrl, thumbnailUrl }` or `{ id, type: "video", serviceProvider, videoId }`.
struct FanboxProfileItemDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var id: String?
    var type: String?
    var imageUrl: String?
    var thumbnailUrl: String?
    var serviceProvider: String?
    var videoId: String?

    static let knownFields: Set<String> = ["id", "type", "imageUrl", "thumbnailUrl", "serviceProvider", "videoId"]

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        id = o.nonEmptyString("id")
        type = o.string("type")
        imageUrl = o.nonEmptyString("imageUrl")
        thumbnailUrl = o.nonEmptyString("thumbnailUrl")
        serviceProvider = o.nonEmptyString("serviceProvider")
        videoId = o.nonEmptyString("videoId")
    }
}

/// Creator profile (creator.get body, creator list elements, url_embed fanbox.creator profile).
struct FanboxCreatorDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var user: FanboxUserDTO?
    var creatorId: String?
    var description: String?
    var hasAdultContent: Bool?
    var coverImageUrl: String?
    var profileLinks: [String]?
    var profileItems: [FanboxProfileItemDTO]?
    var isFollowed: Bool?
    var isSupported: Bool?
    var isStopped: Bool?
    var isAcceptingRequest: Bool?
    var hasBoothShop: Bool?
    var hasPublishedPost: Bool?
    var category: String?
    /// Flat fields used by some list payloads (`{ creatorId, name, iconUrl, userId }`).
    var name: String?
    var iconUrl: String?
    var userId: String?

    static let knownFields: Set<String> = [
        "user", "creatorId", "description", "hasAdultContent", "coverImageUrl", "profileLinks", "profileItems",
        "isFollowed", "isSupported", "isStopped", "isAcceptingRequest", "hasBoothShop", "hasPublishedPost", "category",
        "name", "iconUrl", "userId",
    ]
    static var schemaChildren: [String: any SchemaDescribed.Type] {
        ["user": FanboxUserDTO.self, "profileItems[]": FanboxProfileItemDTO.self]
    }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        user = o.decode("user")
        creatorId = o.nonEmptyString("creatorId")
        description = o.string("description")
        hasAdultContent = o.bool("hasAdultContent")
        coverImageUrl = o.nonEmptyString("coverImageUrl")
        profileLinks = o.stringArray("profileLinks")
        profileItems = o.array("profileItems")
        isFollowed = o.bool("isFollowed")
        isSupported = o.bool("isSupported")
        isStopped = o.bool("isStopped")
        isAcceptingRequest = o.bool("isAcceptingRequest")
        hasBoothShop = o.bool("hasBoothShop")
        hasPublishedPost = o.bool("hasPublishedPost")
        category = o.nonEmptyString("category")
        name = o.string("name")
        iconUrl = o.nonEmptyString("iconUrl")
        userId = o.nonEmptyString("userId")
    }
}

/// creator.get body. Unwraps `{ creator: ... }` defensively if FANBOX ever wraps it like post.info.
struct FanboxCreatorBody: FanboxResponseBody {
    var creator: FanboxCreatorDTO

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        if o.has("creatorId") || o.has("user") {
            creator = try FanboxCreatorDTO(from: decoder)
        } else if let wrapped = o.decode("creator", as: FanboxCreatorDTO.self) {
            creator = wrapped
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "creator.get without creatorId (keys: \(o.keys.sorted()))"))
        }
    }

    static var responseSchema: [String: Set<String>] { FanboxCreatorDTO.knownSchema(at: "body") }
}

enum FanboxCreatorsKey: FanboxListWrapperKey {
    static let keys = ["creators"]
}

/// creator.listFollowing / listPixiv / listRecommended: `{ creators: [...] }` (since 2026-04) or a bare array.
typealias FanboxCreatorListBody = FanboxWrappedList<FanboxCreatorDTO, FanboxCreatorsKey>

/// creator.search `{ creators, count, nextPage }`.
struct FanboxCreatorSearchBody: FanboxResponseBody {
    var creators: [FanboxCreatorDTO]
    var count: Int?
    var nextPage: Int?

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        creators = o.array("creators") ?? []
        count = o.int("count")
        nextPage = o.int("nextPage")
    }

    static var responseSchema: [String: Set<String>] {
        SchemaPaths.merge(["body": ["creators", "count", "nextPage"]], FanboxCreatorDTO.knownSchema(at: "body.creators[]"))
    }
}

/// Plan `{ id, title, fee, description, coverImageUrl, user, creatorId, hasAdultContent, paymentMethod, perks }`.
/// `paymentMethod` is filled only on plans the viewer pays for (raw string, e.g. "PAYPAL" / "card" / "gmo_card").
struct FanboxPlanDTO: Decodable, Hashable, Sendable, SchemaDescribed, FanboxIdentifiedDTO {
    var id: String?
    var title: String?
    var fee: Int?
    var description: String?
    var coverImageUrl: String?
    var user: FanboxUserDTO?
    var creatorId: String?
    var hasAdultContent: Bool?
    var paymentMethod: String?

    var dtoID: String? { id }

    static let knownFields: Set<String> = [
        "id", "title", "fee", "description", "coverImageUrl", "user", "creatorId", "hasAdultContent", "paymentMethod", "perks",
    ]
    static var schemaChildren: [String: any SchemaDescribed.Type] { ["user": FanboxUserDTO.self] }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        id = o.nonEmptyString("id")
        title = o.string("title")
        fee = o.int("fee")
        description = o.string("description")
        coverImageUrl = o.nonEmptyString("coverImageUrl")
        user = o.decode("user")
        creatorId = o.nonEmptyString("creatorId")
        hasAdultContent = o.bool("hasAdultContent")
        // paymentMethod has been seen as a string; tolerate an object `{ type }` too.
        if let raw = o.nonEmptyString("paymentMethod") {
            paymentMethod = raw
        } else if let obj = o.json("paymentMethod")?.objectValue {
            paymentMethod = (obj["type"] ?? obj["name"])?.stringValue
        } else {
            paymentMethod = nil
        }
    }
}

enum FanboxPlansKey: FanboxListWrapperKey {
    /// `plans` since 2026-07; `supportingPlans` in some older payloads.
    static let keys = ["plans", "supportingPlans"]
}

/// plan.listSupporting / plan.listCreator: `{ plans: [...] }` or a bare array.
typealias FanboxPlanListBody = FanboxWrappedList<FanboxPlanDTO, FanboxPlansKey>

/// Support transaction `{ id, paidAmount, targetMonth "YYYY-MM", transactionDatetime, supporter, paymentMethod? }`.
struct FanboxSupportTransactionDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var id: String?
    var paidAmount: Int?
    var targetMonth: String?
    var transactionDatetime: Date?
    var supporter: FanboxUserDTO?
    var paymentMethod: String?

    static let knownFields: Set<String> = ["id", "paidAmount", "targetMonth", "transactionDatetime", "supporter", "paymentMethod"]
    static var schemaChildren: [String: any SchemaDescribed.Type] { ["supporter": FanboxUserDTO.self] }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        id = o.nonEmptyString("id")
        paidAmount = o.int("paidAmount")
        targetMonth = o.nonEmptyString("targetMonth")
        transactionDatetime = o.date("transactionDatetime")
        supporter = o.decode("supporter")
        paymentMethod = o.nonEmptyString("paymentMethod")
    }
}

/// legacy/support/creator: the viewer's support of one creator.
struct FanboxSupportCreatorBody: FanboxResponseBody {
    var plan: FanboxPlanDTO?
    var supportStartDatetime: Date?
    var supporterCardImageUrl: String?
    var supportTransactions: [FanboxSupportTransactionDTO]

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        plan = o.decode("plan")
        supportStartDatetime = o.date("supportStartDatetime")
        supporterCardImageUrl = o.nonEmptyString("supporterCardImageUrl")
        supportTransactions = o.array("supportTransactions") ?? []
    }

    static var responseSchema: [String: Set<String>] {
        SchemaPaths.merge(["body": ["plan", "supportStartDatetime", "supporterCardImageUrl", "supportTransactions", "supportReservations"]],
                          FanboxPlanDTO.knownSchema(at: "body.plan"),
                          FanboxSupportTransactionDTO.knownSchema(at: "body.supportTransactions[]"))
    }
}

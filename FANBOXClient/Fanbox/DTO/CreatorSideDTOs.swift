import Foundation

// Creator-side (post author) DTOs: post.listManaged, post.getEditable, post.create, relationship.listFans,
// relationship.listFilterOptions, legacy/manage/pledge/monthly, legacy/manage/supporter/user, legacy/payout_request.
// Confidence is medium for most of these (docs/API.md); decoding is tolerant and mapping only uses what is documented.

/// Managed / editable post `{ id, title, status: draft|published, permalink, feeRequired, updatedAt, publishedAt, tags?, body? }`.
/// Note the creator-side date names (`updatedAt` / `publishedAt`) differ from the fan side (`...Datetime`).
struct FanboxManagedPostDTO: Decodable, Hashable, Sendable, SchemaDescribed, FanboxIdentifiedDTO {
    var id: String?
    var title: String?
    var status: String?
    var permalink: String?
    var feeRequired: Int?
    var updatedAt: Date?
    var publishedAt: Date?
    var tags: [String]?
    var type: String?
    var hasAdultContent: Bool?
    var body: FanboxPostBodyDTO?
    var coverImageUrl: String?

    var dtoID: String? { id }

    static let knownFields: Set<String> = [
        "id", "title", "status", "permalink", "feeRequired", "updatedAt", "publishedAt", "tags", "type", "hasAdultContent",
        "body", "coverImageUrl",
    ]
    static var schemaChildren: [String: any SchemaDescribed.Type] { ["body": FanboxPostBodyDTO.self] }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        id = o.nonEmptyString("id")
        title = o.string("title")
        status = o.nonEmptyString("status")
        permalink = o.nonEmptyString("permalink")
        feeRequired = o.int("feeRequired")
        updatedAt = o.date("updatedAt") ?? o.date("updatedDatetime")
        publishedAt = o.date("publishedAt") ?? o.date("publishedDatetime")
        tags = o.stringArray("tags")
        type = o.nonEmptyString("type")
        hasAdultContent = o.bool("hasAdultContent")
        body = o.decode("body")
        coverImageUrl = o.nonEmptyString("coverImageUrl")
    }
}

enum FanboxManagedPostsKey: FanboxListWrapperKey {
    static let keys = ["posts", "items"]
}

/// post.listManaged: bare array (spec) or a wrapped list.
typealias FanboxManagedPostListBody = FanboxWrappedList<FanboxManagedPostDTO, FanboxManagedPostsKey>

/// post.getEditable: `EditablePost` (accepts a `{ post: ... }` wrapper too).
struct FanboxEditablePostBody: FanboxResponseBody {
    var post: FanboxManagedPostDTO

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        if o.has("id") {
            post = try FanboxManagedPostDTO(from: decoder)
        } else if let wrapped = o.decode("post", as: FanboxManagedPostDTO.self) {
            post = wrapped
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "getEditable without id (keys: \(o.keys.sorted()))"))
        }
    }

    static var responseSchema: [String: Set<String>] { FanboxManagedPostDTO.knownSchema(at: "body") }
}

/// post.create `{ postId }`.
struct FanboxPostCreateBody: FanboxResponseBody {
    var postId: String?

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let value = try? single.decode(JSONValue.self) {
            if let obj = value.objectValue {
                postId = (obj["postId"] ?? obj["id"])?.stringValue
            } else {
                postId = value.stringValue
            }
        } else {
            postId = nil
        }
    }

    static var responseSchema: [String: Set<String>] { ["body": ["postId"]] }
}

/// relationship.listFans element `{ status: supporter|follower, user, planId, activatedAt, note }`.
struct FanboxFanDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var status: String?
    var user: FanboxUserDTO?
    var planId: String?
    var activatedAt: Date?
    var note: String?

    static let knownFields: Set<String> = ["status", "user", "planId", "activatedAt", "activedAt", "note"]
    static var schemaChildren: [String: any SchemaDescribed.Type] { ["user": FanboxUserDTO.self] }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        status = o.nonEmptyString("status")
        user = o.decode("user")
        planId = o.nonEmptyString("planId")
        activatedAt = o.date("activatedAt") ?? o.date("activedAt")
        note = o.string("note")
    }
}

enum FanboxFansKey: FanboxListWrapperKey {
    static let keys = ["fans", "items"]
}

/// relationship.listFans: bare array (observed) or a wrapped list.
typealias FanboxFanListBody = FanboxWrappedList<FanboxFanDTO, FanboxFansKey>

/// relationship.listFilterOptions element `{ type: supporter|follower|all, planId, planTitle, count }`.
struct FanboxFanFilterOptionDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var type: String?
    var planId: String?
    var planTitle: String?
    var count: Int?

    static let knownFields: Set<String> = ["type", "planId", "planTitle", "count"]

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        type = o.nonEmptyString("type")
        planId = o.nonEmptyString("planId")
        planTitle = o.string("planTitle")
        count = o.int("count")
    }
}

enum FanboxFilterOptionsKey: FanboxListWrapperKey {
    static let keys = ["filterOptions", "items"]
}

typealias FanboxFanFilterOptionListBody = FanboxWrappedList<FanboxFanFilterOptionDTO, FanboxFilterOptionsKey>

/// legacy/manage/pledge/monthly `{ supportTransactions, nextMonth, previousMonth }`.
struct FanboxPledgeMonthlyBody: FanboxResponseBody {
    var supportTransactions: [FanboxSupportTransactionDTO]
    var nextMonth: String?
    var previousMonth: String?

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        guard o.has("supportTransactions") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "pledge/monthly without supportTransactions (keys: \(o.keys.sorted()))"))
        }
        supportTransactions = o.array("supportTransactions") ?? []
        nextMonth = o.nonEmptyString("nextMonth")
        previousMonth = o.nonEmptyString("previousMonth")
    }

    static var responseSchema: [String: Set<String>] {
        SchemaPaths.merge(["body": ["supportTransactions", "nextMonth", "previousMonth"]],
                          FanboxSupportTransactionDTO.knownSchema(at: "body.supportTransactions[]"))
    }
}

/// legacy/manage/supporter/user `{ user, supportingPlan, supportTransactions }` (newest first).
struct FanboxManagedSupporterBody: FanboxResponseBody {
    var user: FanboxUserDTO?
    var supportingPlan: FanboxPlanDTO?
    var supportTransactions: [FanboxSupportTransactionDTO]

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        user = o.decode("user")
        supportingPlan = o.decode("supportingPlan")
        supportTransactions = o.array("supportTransactions") ?? []
    }

    static var responseSchema: [String: Set<String>] {
        SchemaPaths.merge(["body": ["user", "supportingPlan", "supportTransactions"]],
                          FanboxUserDTO.knownSchema(at: "body.user"),
                          FanboxPlanDTO.knownSchema(at: "body.supportingPlan"),
                          FanboxSupportTransactionDTO.knownSchema(at: "body.supportTransactions[]"))
    }
}

/// legacy/payout_request (single 2023 source; read-only summary, not used for dashboard metrics).
struct FanboxPayoutRequestBody: FanboxResponseBody {
    var currentAmount: Int?
    var calculatedDatetime: Date?
    var nextAutoPayoutDatetime: Date?

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        let max = o.json("maxPayoutRequestAmount")
        currentAmount = max?["amount"]?.intValue
        calculatedDatetime = max?["calculatedDatetime"]?.stringValue.flatMap(FanboxDateParser.parse)
        nextAutoPayoutDatetime = o.date("nextAutoPayoutDatetime")
    }

    static var responseSchema: [String: Set<String>] {
        [
            "body": ["maxPayoutRequestAmount", "monthlyMaxPayoutRequestAmountHistory", "nextAutoPayoutDatetime", "notice"],
            "body.maxPayoutRequestAmount": ["amount", "calculatedDatetime"],
        ]
    }
}

// MARK: - Session metadata (www.fanbox.cc <meta name="metadata">)

/// `context.user` of the page metadata.
struct FanboxMetadataUserDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var userId: String?
    var creatorId: String?
    var name: String?
    var iconUrl: String?
    var isCreator: Bool?
    var isSupporter: Bool?
    var hasUnpaidPayments: Bool?
    var hasAdultContent: Bool?
    var showAdultContent: Bool?
    var planCount: Int?
    var fanboxUserStatus: Int?

    static let knownFields: Set<String> = [
        "userId", "creatorId", "name", "iconUrl", "isCreator", "isSupporter", "hasUnpaidPayments", "hasAdultContent",
        "showAdultContent", "planCount", "fanboxUserStatus", "isMailAddressOutdated", "lang",
    ]

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        userId = o.nonEmptyString("userId")
        creatorId = o.nonEmptyString("creatorId")
        name = o.string("name")
        iconUrl = o.nonEmptyString("iconUrl")
        isCreator = o.bool("isCreator")
        isSupporter = o.bool("isSupporter")
        hasUnpaidPayments = o.bool("hasUnpaidPayments")
        hasAdultContent = o.bool("hasAdultContent")
        showAdultContent = o.bool("showAdultContent")
        planCount = o.int("planCount")
        fanboxUserStatus = o.int("fanboxUserStatus")
    }
}

/// Parsed page metadata JSON `{ apiUrl, csrfToken, context: { user, privacyPolicy }, urlContext? }`.
/// `csrfToken` is a SECRET (SPEC §38): never log it; the API client redacts it before the API Inspector sees the JSON.
struct FanboxMetadataDTO: Decodable, Sendable, SchemaDescribed {
    var csrfToken: String?
    var apiUrl: String?
    var user: FanboxMetadataUserDTO?
    /// Legacy `urlContext.user.isLoggedIn`.
    var isLoggedIn: Bool?

    static let knownFields: Set<String> = ["csrfToken", "apiUrl", "context", "urlContext"]
    static var schemaChildren: [String: any SchemaDescribed.Type] { ["context": FanboxMetadataContextSchema.self] }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        csrfToken = o.nonEmptyString("csrfToken")
        apiUrl = o.nonEmptyString("apiUrl")
        let context = o.json("context")
        if let userJSON = context?["user"], userJSON.objectValue != nil {
            user = try? JSONDecoder().decode(FanboxMetadataUserDTO.self, from: userJSON.encoded())
        }
        isLoggedIn = o.json("urlContext")?["user"]?["isLoggedIn"]?.boolValue
    }

    var isLoggedInUser: Bool { user?.userId != nil || isLoggedIn == true }
}

enum FanboxMetadataContextSchema: SchemaDescribed {
    static let knownFields: Set<String> = ["user", "privacyPolicy"]
    static var schemaChildren: [String: any SchemaDescribed.Type] { ["user": FanboxMetadataUserDTO.self] }
}

import Foundation

// Post DTOs: timeline / creator list items (post.listHome, post.listSupporting, post.listCreator, post.listTagged,
// bell on_post_published, url_embed fanbox.post) and post detail (post.info). See docs/API.md.

/// A post summary as returned by list endpoints. List items carry no `type` and no `body`.
struct FanboxPostListItemDTO: Decodable, Hashable, Sendable, SchemaDescribed, FanboxIdentifiedDTO {
    var id: String?
    var title: String?
    var feeRequired: Int?
    var publishedDatetime: Date?
    var updatedDatetime: Date?
    var tags: [String]?
    var isLiked: Bool?
    var likeCount: Int?
    var isCommentingRestricted: Bool?
    var commentCount: Int?
    var isRestricted: Bool?
    var user: FanboxUserDTO?
    var creatorId: String?
    var hasAdultContent: Bool?
    var cover: FanboxCoverDTO?
    /// Flat cover URL (older list payloads / fanbox.post embeds).
    var coverImageUrl: String?
    var excerpt: String?
    var isPinned: Bool?
    /// Not present on list items today; read when a payload happens to carry it.
    var type: String?

    var dtoID: String? { id }

    static let knownFields: Set<String> = [
        "id", "title", "feeRequired", "publishedDatetime", "updatedDatetime", "tags", "isLiked", "likeCount",
        "isCommentingRestricted", "commentCount", "isRestricted", "user", "creatorId", "hasAdultContent", "cover",
        "coverImageUrl", "excerpt", "isPinned", "type",
    ]
    static var schemaChildren: [String: any SchemaDescribed.Type] {
        ["user": FanboxUserDTO.self, "cover": FanboxCoverDTO.self]
    }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        id = o.nonEmptyString("id")
        title = o.string("title")
        feeRequired = o.int("feeRequired")
        publishedDatetime = o.date("publishedDatetime")
        updatedDatetime = o.date("updatedDatetime")
        tags = o.stringArray("tags")
        isLiked = o.bool("isLiked")
        likeCount = o.int("likeCount")
        isCommentingRestricted = o.bool("isCommentingRestricted")
        commentCount = o.int("commentCount")
        isRestricted = o.bool("isRestricted")
        user = o.decode("user")
        creatorId = o.nonEmptyString("creatorId")
        hasAdultContent = o.bool("hasAdultContent")
        cover = o.decode("cover")
        coverImageUrl = o.nonEmptyString("coverImageUrl")
        excerpt = o.string("excerpt")
        isPinned = o.bool("isPinned")
        type = o.nonEmptyString("type")
    }
}

/// Neighbouring post reference `{ id, title, publishedDatetime }` (post.info prevPost / nextPost).
struct FanboxNeighborPostDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var id: String?
    var title: String?
    var publishedDatetime: Date?

    static let knownFields: Set<String> = ["id", "title", "publishedDatetime"]

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        id = o.nonEmptyString("id")
        title = o.string("title")
        publishedDatetime = o.date("publishedDatetime")
    }
}

/// Image entry `{ id, extension, width, height, originalUrl, thumbnailUrl }` (body.images[] / imageMap values).
struct FanboxImageDTO: Decodable, Hashable, Sendable, SchemaDescribed, FanboxIdentifiedDTO {
    var id: String?
    var fileExtension: String?
    var width: Int?
    var height: Int?
    var originalUrl: String?
    var thumbnailUrl: String?

    var dtoID: String? { id }

    static let knownFields: Set<String> = ["id", "extension", "width", "height", "originalUrl", "thumbnailUrl"]

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        id = o.nonEmptyString("id")
        fileExtension = o.nonEmptyString("extension")
        width = o.int("width")
        height = o.int("height")
        originalUrl = o.nonEmptyString("originalUrl")
        thumbnailUrl = o.nonEmptyString("thumbnailUrl")
    }
}

/// File entry `{ id, name, extension, size, url }`. `name` has no extension.
struct FanboxFileDTO: Decodable, Hashable, Sendable, SchemaDescribed, FanboxIdentifiedDTO {
    var id: String?
    var name: String?
    var fileExtension: String?
    var size: Int?
    var url: String?

    var dtoID: String? { id }

    static let knownFields: Set<String> = ["id", "name", "extension", "size", "url"]

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        id = o.nonEmptyString("id")
        name = o.string("name")
        fileExtension = o.nonEmptyString("extension")
        size = o.int("size")
        url = o.nonEmptyString("url")
    }
}

/// Inline style `{ type: "bold", offset, length }` (offset / length are UTF-16 code units per the research notes).
struct FanboxTextStyleDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var type: String?
    var offset: Int?
    var length: Int?
    var size: Int?

    static let knownFields: Set<String> = ["type", "offset", "length", "size"]

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        type = o.string("type")
        offset = o.int("offset")
        length = o.int("length")
        size = o.int("size")
    }
}

/// Inline link `{ offset, length, url }`.
struct FanboxTextLinkDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var offset: Int?
    var length: Int?
    var url: String?

    static let knownFields: Set<String> = ["offset", "length", "url"]

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        offset = o.int("offset")
        length = o.int("length")
        url = o.nonEmptyString("url")
    }
}

/// Article block `{ type: p|header|image|file|embed|url_embed, text?, styles?, links?, imageId?, fileId?, embedId?, urlEmbedId? }`.
struct FanboxBlockDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var type: String?
    var text: String?
    var styles: [FanboxTextStyleDTO]?
    var links: [FanboxTextLinkDTO]?
    var imageId: String?
    var fileId: String?
    var embedId: String?
    var urlEmbedId: String?

    static let knownFields: Set<String> = ["type", "text", "styles", "links", "imageId", "fileId", "embedId", "urlEmbedId"]
    static var schemaChildren: [String: any SchemaDescribed.Type] {
        ["styles[]": FanboxTextStyleDTO.self, "links[]": FanboxTextLinkDTO.self]
    }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        type = o.string("type")
        text = o.string("text")
        styles = o.array("styles")
        links = o.array("links")
        imageId = o.nonEmptyString("imageId")
        fileId = o.nonEmptyString("fileId")
        embedId = o.nonEmptyString("embedId")
        urlEmbedId = o.nonEmptyString("urlEmbedId")
    }
}

/// embedMap value `{ id, serviceProvider, contentId | videoId }`.
struct FanboxEmbedDTO: Decodable, Hashable, Sendable, SchemaDescribed, FanboxIdentifiedDTO {
    var id: String?
    var serviceProvider: String?
    var contentId: String?
    var videoId: String?

    var dtoID: String? { id }

    static let knownFields: Set<String> = ["id", "serviceProvider", "contentId", "videoId"]

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        id = o.nonEmptyString("id")
        serviceProvider = o.nonEmptyString("serviceProvider")
        contentId = o.nonEmptyString("contentId")
        videoId = o.nonEmptyString("videoId")
    }
}

/// Video post body `{ serviceProvider, videoId }` (some payloads use contentId).
struct FanboxVideoDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var serviceProvider: String?
    var videoId: String?
    var contentId: String?

    static let knownFields: Set<String> = ["serviceProvider", "videoId", "contentId"]

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        serviceProvider = o.nonEmptyString("serviceProvider")
        videoId = o.nonEmptyString("videoId")
        contentId = o.nonEmptyString("contentId")
    }
}

/// urlEmbedMap value: `{ id, type }` plus `url`/`host` (default), `html` (html / html.card),
/// `postInfo` (fanbox.post) or `profile` (fanbox.creator).
struct FanboxURLEmbedDTO: Decodable, Hashable, Sendable, SchemaDescribed, FanboxIdentifiedDTO {
    var id: String?
    var type: String?
    var url: String?
    var host: String?
    var html: String?
    var postInfo: FanboxPostListItemDTO?
    var profile: FanboxCreatorDTO?

    var dtoID: String? { id }

    static let knownFields: Set<String> = ["id", "type", "url", "host", "html", "postInfo", "profile"]
    static var schemaChildren: [String: any SchemaDescribed.Type] {
        ["postInfo": FanboxPostListItemDTO.self, "profile": FanboxCreatorDTO.self]
    }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        id = o.nonEmptyString("id")
        type = o.string("type")
        url = o.nonEmptyString("url")
        host = o.nonEmptyString("host")
        html = o.nonEmptyString("html")
        postInfo = o.decode("postInfo")
        profile = o.decode("profile")
    }
}

/// Post content by type:
/// image `{ text, images }`, file `{ text, files }`, text `{ text }`, video `{ text, video }`, entry `{ html }`,
/// article `{ blocks, imageMap, fileMap, embedMap, urlEmbedMap }` (a missing map is treated as empty).
struct FanboxPostBodyDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var text: String?
    var html: String?
    var images: [FanboxImageDTO]?
    var files: [FanboxFileDTO]?
    var video: FanboxVideoDTO?
    var blocks: [FanboxBlockDTO]?
    var imageMap: [String: FanboxImageDTO]?
    var fileMap: [String: FanboxFileDTO]?
    var embedMap: [String: FanboxEmbedDTO]?
    var urlEmbedMap: [String: FanboxURLEmbedDTO]?

    static let knownFields: Set<String> = [
        "text", "html", "images", "files", "video", "blocks", "imageMap", "fileMap", "embedMap", "urlEmbedMap",
    ]
    static var schemaChildren: [String: any SchemaDescribed.Type] {
        [
            "images[]": FanboxImageDTO.self, "files[]": FanboxFileDTO.self, "video": FanboxVideoDTO.self,
            "blocks[]": FanboxBlockDTO.self, "imageMap{}": FanboxImageDTO.self, "fileMap{}": FanboxFileDTO.self,
            "embedMap{}": FanboxEmbedDTO.self, "urlEmbedMap{}": FanboxURLEmbedDTO.self,
        ]
    }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        text = o.string("text")
        html = o.nonEmptyString("html")
        images = o.array("images")
        files = o.array("files")
        video = o.decode("video")
        blocks = o.array("blocks")
        imageMap = o.map("imageMap")
        fileMap = o.map("fileMap")
        embedMap = o.map("embedMap")
        urlEmbedMap = o.map("urlEmbedMap")
    }
}

/// Full post (post.info `body.post`, legacy `body`).
struct FanboxPostDetailDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var id: String?
    var title: String?
    var feeRequired: Int?
    var publishedDatetime: Date?
    var updatedDatetime: Date?
    var tags: [String]?
    var isLiked: Bool?
    var likeCount: Int?
    var isCommentingRestricted: Bool?
    var commentCount: Int?
    var isRestricted: Bool?
    var user: FanboxUserDTO?
    var creatorId: String?
    var hasAdultContent: Bool?
    var type: String?
    var coverImageUrl: String?
    var cover: FanboxCoverDTO?
    /// nil when restricted.
    var body: FanboxPostBodyDTO?
    var excerpt: String?
    var nextPost: FanboxNeighborPostDTO?
    var prevPost: FanboxNeighborPostDTO?
    var imageForShare: String?
    var isPinned: Bool?

    static let knownFields: Set<String> = [
        "id", "title", "feeRequired", "publishedDatetime", "updatedDatetime", "tags", "isLiked", "likeCount",
        "isCommentingRestricted", "commentCount", "isRestricted", "user", "creatorId", "hasAdultContent", "type",
        "coverImageUrl", "cover", "body", "excerpt", "nextPost", "prevPost", "imageForShare", "isPinned",
        // Legacy fields some older payloads carried; known so they are not reported as new.
        "restrictedFor", "commentList",
    ]
    static var schemaChildren: [String: any SchemaDescribed.Type] {
        [
            "user": FanboxUserDTO.self, "cover": FanboxCoverDTO.self, "body": FanboxPostBodyDTO.self,
            "nextPost": FanboxNeighborPostDTO.self, "prevPost": FanboxNeighborPostDTO.self,
        ]
    }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        id = o.nonEmptyString("id")
        title = o.string("title")
        feeRequired = o.int("feeRequired")
        publishedDatetime = o.date("publishedDatetime")
        updatedDatetime = o.date("updatedDatetime")
        tags = o.stringArray("tags")
        isLiked = o.bool("isLiked")
        likeCount = o.int("likeCount")
        isCommentingRestricted = o.bool("isCommentingRestricted")
        commentCount = o.int("commentCount")
        isRestricted = o.bool("isRestricted")
        user = o.decode("user")
        creatorId = o.nonEmptyString("creatorId")
        hasAdultContent = o.bool("hasAdultContent")
        type = o.nonEmptyString("type")
        coverImageUrl = o.nonEmptyString("coverImageUrl")
        cover = o.decode("cover")
        body = o.decode("body")
        excerpt = o.string("excerpt")
        nextPost = o.decode("nextPost")
        prevPost = o.decode("prevPost")
        imageForShare = o.nonEmptyString("imageForShare")
        isPinned = o.bool("isPinned")
    }
}

// MARK: - Response bodies

/// post.listHome / post.listSupporting / post.listTagged: `{ items, nextUrl [, count] }`.
/// `posts` is also accepted (one client decodes post.listTagged that way).
struct FanboxPostListBody: FanboxResponseBody {
    var items: [FanboxPostListItemDTO]
    var nextUrl: String?
    var count: Int?

    init(items: [FanboxPostListItemDTO], nextUrl: String? = nil, count: Int? = nil) {
        self.items = items
        self.nextUrl = nextUrl
        self.count = count
    }

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            items = LenientObject.decodeElements(&array, as: FanboxPostListItemDTO.self)
            nextUrl = nil
            count = nil
            return
        }
        let o = try LenientObject(decoder)
        guard o.has("items") || o.has("posts") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "post list without items/posts (keys: \(o.keys.sorted()))"))
        }
        items = o.array("items") ?? o.array("posts") ?? []
        nextUrl = o.nonEmptyString("nextUrl")
        count = o.int("count")
    }

    static var responseSchema: [String: Set<String>] {
        SchemaPaths.merge(["body": ["items", "posts", "nextUrl", "count"]],
                          FanboxPostListItemDTO.knownSchema(at: "body.items[]"),
                          FanboxPostListItemDTO.knownSchema(at: "body.posts[]"))
    }
}

enum FanboxPostsKey: FanboxListWrapperKey {
    /// post.listCreator: `posts` since 2026-07; `items` before 2024-08.
    static let keys = ["posts", "items"]
}

/// post.listCreator: `{ posts: [...] }` (current) or a bare array (2024-08 – 2026-07).
typealias FanboxCreatorPostListBody = FanboxWrappedList<FanboxPostListItemDTO, FanboxPostsKey>

/// post.paginateCreator: `{ pageUrls: [String] }` (current) or a bare array of URLs (legacy).
struct FanboxPaginateCreatorBody: FanboxResponseBody {
    var pageUrls: [String]

    init(pageUrls: [String]) {
        self.pageUrls = pageUrls
    }

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            pageUrls = LenientObject.decodeElements(&array, as: JSONValue.self).compactMap(\.stringValue)
            return
        }
        let o = try LenientObject(decoder)
        guard o.has("pageUrls") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "paginateCreator without pageUrls (keys: \(o.keys.sorted()))"))
        }
        pageUrls = o.stringArray("pageUrls") ?? []
    }

    static var responseSchema: [String: Set<String>] { ["body": ["pageUrls"]] }
}

/// post.info: `{ post: PostDetail }` (since 2026-07-13) or the legacy bare `PostDetail`.
struct FanboxPostInfoBody: FanboxResponseBody {
    var post: FanboxPostDetailDTO
    var isWrapped: Bool

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        if o.has("post"), !o.isNull("post"), let wrapped = o.decode("post", as: FanboxPostDetailDTO.self) {
            post = wrapped
            isWrapped = true
        } else if o.has("id") {
            post = try FanboxPostDetailDTO(from: decoder)
            isWrapped = false
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "post.info without post (keys: \(o.keys.sorted()))"))
        }
    }

    static var responseSchema: [String: Set<String>] {
        SchemaPaths.merge(["body": ["post"]], FanboxPostDetailDTO.knownSchema(at: "body.post"))
    }
}

/// tag.search `[ { value, count } ]`.
struct FanboxTagDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var value: String?
    var count: Int?

    static let knownFields: Set<String> = ["value", "count"]

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        value = o.string("value")
        count = o.int("count")
    }
}

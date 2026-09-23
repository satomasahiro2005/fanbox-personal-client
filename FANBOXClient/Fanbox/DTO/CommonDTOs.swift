import Foundation

// Shared FANBOX DTO building blocks. All fields are optional and decoded leniently (SPEC §37).

/// `{ userId, name, iconUrl }` — the pixiv user attached to posts, creators, comments, plans.
struct FanboxUserDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var userId: String?
    var name: String?
    var iconUrl: String?

    static let knownFields: Set<String> = ["userId", "name", "iconUrl"]

    init(userId: String? = nil, name: String? = nil, iconUrl: String? = nil) {
        self.userId = userId
        self.name = name
        self.iconUrl = iconUrl
    }

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        userId = o.nonEmptyString("userId")
        name = o.string("name")
        iconUrl = o.nonEmptyString("iconUrl")
    }
}

/// List-item cover `{ type: "cover_image" | "post_image", url }`.
struct FanboxCoverDTO: Decodable, Hashable, Sendable, SchemaDescribed {
    var type: String?
    var url: String?

    static let knownFields: Set<String> = ["type", "url"]

    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        type = o.string("type")
        url = o.nonEmptyString("url")
    }
}

/// Generic `{ items: [...], nextUrl }` style envelope keys that differ per endpoint.
protocol FanboxListWrapperKey {
    /// Candidate object keys holding the array, in preference order (current shape first, legacy after).
    static var keys: [String] { get }
}

/// A list body that FANBOX has served both as a bare array (`{ body: [...] }`) and wrapped (`{ body: { plans: [...] } }`).
/// An unrecognized object shape throws (so a schema change is never mistaken for "the list is now empty").
struct FanboxWrappedList<Element: Decodable & SchemaDescribed, Key: FanboxListWrapperKey>: FanboxResponseBody {
    var items: [Element]
    /// The key the items were found under; nil for a bare array.
    var wrapperKey: String?

    init(items: [Element], wrapperKey: String? = nil) {
        self.items = items
        self.wrapperKey = wrapperKey
    }

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            items = LenientObject.decodeElements(&array, as: Element.self)
            wrapperKey = nil
            return
        }
        let o = try LenientObject(decoder)
        for key in Key.keys where o.has(key) {
            items = o.array(key, of: Element.self) ?? []
            wrapperKey = key
            return
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                debugDescription: "Expected an array or one of \(Key.keys) (found keys: \(o.keys.sorted()))"))
    }

    static var responseSchema: [String: Set<String>] {
        var schema: [String: Set<String>] = ["body": Set(Key.keys)]
        for key in Key.keys {
            schema = SchemaPaths.merge(schema, Element.knownSchema(at: "body.\(key)[]"))
        }
        return SchemaPaths.merge(schema, Element.knownSchema(at: "body[]"))
    }
}

/// Endpoints whose body is a bare number, or `{ count }` (bell.countUnread, newsletter.countUnread, user.countUnreadMessages).
struct FanboxCountBody: FanboxResponseBody {
    var count: Int?

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let value = try? single.decode(JSONValue.self) {
            if let n = value.intValue, value.objectValue == nil {
                count = n
                return
            }
            if let obj = value.objectValue {
                count = (obj["count"] ?? obj["unreadCount"])?.intValue
                return
            }
        }
        count = nil
    }

    static var responseSchema: [String: Set<String>] { ["body": ["count"]] }
}

/// Body that is ignored (write endpoints whose response content is undocumented).
struct FanboxIgnoredBody: FanboxResponseBody {
    var raw: JSONValue?

    init(from decoder: Decoder) throws {
        raw = try? decoder.singleValueContainer().decode(JSONValue.self)
    }

    static var responseSchema: [String: Set<String>] { [:] }
}

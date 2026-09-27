import Foundation
import SwiftData

/// Unified, deduplicated notification event (SPEC §27).
@Model
final class NotificationEvent {
    /// Dedupe key, e.g. "newPost|<postID>" / "comment|<commentID>". Account-independent for posts, comments and おたより;
    /// per account for support events. See `NotificationEvent.dedupeKey`.
    @Attribute(.unique) var id: String
    var typeRaw: String
    var accountIDs: [String]
    /// FANBOX-side ids per account: "\(accountID):\(remoteID)".
    var remoteIDs: [String]
    var creatorID: String?
    var postID: String?
    var commentID: String?
    var newsletterID: String?
    var actorName: String?
    var actorIconURL: String?
    var title: String
    var message: String
    var timestamp: Date
    var detectedAt: Date
    var prefetchStateRaw: String
    /// readState
    var isRead: Bool
    /// A local iOS notification has been posted for this event.
    var deliveredLocally: Bool
    var priorityRaw: Int

    init(id: String, type: NotificationEventType, accountIDs: [String], title: String, message: String, timestamp: Date,
         creatorID: String? = nil, postID: String? = nil, commentID: String? = nil, newsletterID: String? = nil, detectedAt: Date = .now) {
        self.id = id
        self.typeRaw = type.rawValue
        self.accountIDs = accountIDs
        self.remoteIDs = []
        self.creatorID = creatorID
        self.postID = postID
        self.commentID = commentID
        self.newsletterID = newsletterID
        self.title = title
        self.message = message
        self.timestamp = timestamp
        self.detectedAt = detectedAt
        self.prefetchStateRaw = PrefetchState.pending.rawValue
        self.isRead = false
        self.deliveredLocally = false
        self.priorityRaw = type.priority.rawValue
    }

    var type: NotificationEventType {
        get { NotificationEventType(rawValue: typeRaw) ?? .other }
        set { typeRaw = newValue.rawValue; priorityRaw = newValue.priority.rawValue }
    }

    var prefetchState: PrefetchState {
        get { PrefetchState(rawValue: prefetchStateRaw) ?? .pending }
        set { prefetchStateRaw = newValue.rawValue }
    }

    var priority: NotificationPriority { NotificationPriority(rawValue: priorityRaw) ?? .normal }

    /// Dedupe key. New posts, comments with a known id and おたより get an account-independent key, so the same FANBOX item
    /// received by several accounts becomes one row (comment bells without an id are matched in `upsertNotifications`).
    /// Everything else ends in `fallbackRemoteID`, which callers make per account (a bell id, or `local:<accountID>:…` for
    /// derived support events): one account's support change, stop or payment problem is never merged into another
    /// account's event for the same creator.
    static func dedupeKey(type: NotificationEventType, creatorID: String?, postID: String?, commentID: String?, newsletterID: String?,
                          fallbackRemoteID: String) -> String {
        switch type {
        case .comment, .commentReply:
            if let commentID { return "\(type.rawValue)|\(commentID)" }
        case .newPost:
            if let postID { return "newPost|\(postID)" }
        case .newsletter:
            if let newsletterID { return "newsletter|\(newsletterID)" }
        default:
            break
        }
        return "\(type.rawValue)|\(creatorID ?? "-")|\(postID ?? "-")|\(fallbackRemoteID)"
    }
}

/// A media item referenced by a post (image / file / audio / video) with its staged URLs.
@Model
final class Media {
    @Attribute(.unique) var id: String
    var postID: String?
    var creatorID: String?
    var kindRaw: String
    var thumbnailURL: String?
    var displayURL: String?
    var originalURL: String?
    var fileName: String?
    var fileSize: Int?
    var width: Int?
    var height: Int?

    init(id: String, kind: MediaKind, postID: String? = nil, creatorID: String? = nil) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.postID = postID
        self.creatorID = creatorID
    }

    var kind: MediaKind {
        get { MediaKind(rawValue: kindRaw) ?? .file }
        set { kindRaw = newValue.rawValue }
    }
}

/// A file in the media file cache (SPEC §32).
@Model
final class MediaCacheEntry {
    /// Stable hash of the remote URL + variant.
    @Attribute(.unique) var key: String
    var url: String
    var mediaID: String?
    var postID: String?
    var creatorID: String?
    var variantRaw: String
    var kindRaw: String
    /// Path relative to the media cache root.
    var relativePath: String
    var byteSize: Int
    var isPinned: Bool
    var createdAt: Date
    var lastAccessedAt: Date

    init(key: String, url: String, variant: MediaVariant, kind: MediaKind, relativePath: String, byteSize: Int,
         postID: String? = nil, creatorID: String? = nil, mediaID: String? = nil, isPinned: Bool = false, createdAt: Date = .now) {
        self.key = key
        self.url = url
        self.variantRaw = variant.rawValue
        self.kindRaw = kind.rawValue
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.postID = postID
        self.creatorID = creatorID
        self.mediaID = mediaID
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.lastAccessedAt = createdAt
    }

    var variant: MediaVariant { MediaVariant(rawValue: variantRaw) ?? .original }
    var kind: MediaKind { MediaKind(rawValue: kindRaw) ?? .file }
}

/// User-defined local tag (e.g. #music). Never sent to FANBOX (SPEC §33).
@Model
final class Tag {
    @Attribute(.unique) var name: String
    var colorHex: String?
    var createdAt: Date

    init(name: String, colorHex: String? = nil, createdAt: Date = .now) {
        self.name = Tag.normalize(name)
        self.colorHex = colorHex
        self.createdAt = createdAt
    }

    /// "#Music " -> "music"
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("#") { s.removeFirst() }
        return s.lowercased()
    }
}

@Model
final class PostTag {
    /// "\(postID)|\(tagName)"
    @Attribute(.unique) var key: String
    var postID: String
    var tagName: String
    var createdAt: Date

    init(postID: String, tagName: String, createdAt: Date = .now) {
        let normalized = Tag.normalize(tagName)
        self.key = "\(postID)|\(normalized)"
        self.postID = postID
        self.tagName = normalized
        self.createdAt = createdAt
    }
}

/// Sync bookkeeping per account / resource / scope (SPEC §34).
@Model
final class SyncState {
    /// "\(accountID)|\(resource)|\(scope)"
    @Attribute(.unique) var key: String
    var accountID: String
    var resourceRaw: String
    /// Optional sub-scope, e.g. creatorID for creator posts, postID for comments. "" when none.
    var scope: String
    var lastSuccessfulSync: Date?
    var lastAttemptAt: Date?
    var cursor: String?
    var lastKnownItemID: String?
    var error: String?
    var consecutiveFailures: Int

    init(accountID: String, resource: SyncResource, scope: String = "") {
        self.key = SyncState.key(accountID: accountID, resource: resource, scope: scope)
        self.accountID = accountID
        self.resourceRaw = resource.rawValue
        self.scope = scope
        self.consecutiveFailures = 0
    }

    static func key(accountID: String, resource: SyncResource, scope: String = "") -> String { "\(accountID)|\(resource.rawValue)|\(scope)" }

    var resource: SyncResource { SyncResource(rawValue: resourceRaw) ?? .timeline }
}

/// Research Mode log entry. All text fields MUST already be redacted by `SecretRedactor` (SPEC §38).
@Model
final class ResearchLog {
    @Attribute(.unique) var id: String
    var timestamp: Date
    var kindRaw: String
    var accountID: String?
    var method: String?
    /// Redacted URL or navigation target.
    var endpoint: String
    var statusCode: Int?
    var durationMs: Int?
    var priorityRaw: Int?
    var requestHeaders: String
    var responseHeaders: String
    /// Redacted, truncated body ("Safe Response Body").
    var responseBody: String
    var bytes: Int?
    var errorDescription: String?

    init(id: String = UUID().uuidString, timestamp: Date = .now, kind: ResearchLogKind, accountID: String? = nil, method: String? = nil,
         endpoint: String, statusCode: Int? = nil, durationMs: Int? = nil, priorityRaw: Int? = nil, requestHeaders: String = "",
         responseHeaders: String = "", responseBody: String = "", bytes: Int? = nil, errorDescription: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kindRaw = kind.rawValue
        self.accountID = accountID
        self.method = method
        self.endpoint = endpoint
        self.statusCode = statusCode
        self.durationMs = durationMs
        self.priorityRaw = priorityRaw
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.bytes = bytes
        self.errorDescription = errorDescription
    }

    var kind: ResearchLogKind { ResearchLogKind(rawValue: kindRaw) ?? .note }
}

/// API Inspector: observed JSON schema per endpoint / object path (SPEC §37).
@Model
final class APISchemaSnapshot {
    /// e.g. "post.info" or "post.info:body.body.blocks[]"
    @Attribute(.unique) var endpointKey: String
    /// Fields the DTO knows about.
    var knownFields: [String]
    /// Union of fields ever observed.
    var observedFields: [String]
    /// Observed but unknown to the DTO.
    var newFields: [String]
    /// Known to the DTO but absent in the latest response.
    var missingFields: [String]
    var firstSeenAt: Date
    var lastSeenAt: Date
    var lastChangedAt: Date?
    var sampleCount: Int

    init(endpointKey: String, knownFields: [String], firstSeenAt: Date = .now) {
        self.endpointKey = endpointKey
        self.knownFields = knownFields
        self.observedFields = []
        self.newFields = []
        self.missingFields = []
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = firstSeenAt
        self.sampleCount = 0
    }
}

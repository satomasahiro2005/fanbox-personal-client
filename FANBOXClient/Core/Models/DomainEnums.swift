import Foundation

// Domain enums shared by SwiftData models, services and features.
// SwiftData models store these as `...Raw` strings and expose typed computed accessors.

enum AccountKind: String, Codable, CaseIterable, Sendable {
    /// Real FANBOX / pixiv account backed by an isolated web + API session.
    case fanbox
    /// Local demo account backed by `DemoRemoteDataSource` (no network). Used for previews, tests and UI checks.
    case demo
}

enum SessionState: String, Codable, Sendable {
    case unknown
    case valid
    case expired
    case loggedOut
    case error
}

enum PostType: String, Codable, CaseIterable, Sendable {
    case text, image, file, article, video, entry, unknown
}

enum PostBlockKind: String, Codable, CaseIterable, Sendable {
    case paragraph, header, image, file, audio, video, url, embed, unknown
}

enum OfflineState: String, Codable, CaseIterable, Sendable {
    /// Only lightweight metadata / text cache (normal cache, evictable media).
    case none
    /// Automatically saved because the user viewed it while "auto-save viewed posts" is on.
    case autoSaved
    /// Explicitly saved by the user ("この投稿").
    case saved
    /// Saved by a creator's "最近 N 件" rule: released when it falls out of the newest N or the rule is removed.
    case ruleSaved
}

enum SupportStatus: String, Codable, CaseIterable, Sendable {
    case active
    /// The user (or app) knows the support ended.
    case ended
    /// Support was observed before but is no longer returned by FANBOX. Cause is NOT asserted.
    case missing
    case unknown
}

enum SupportHistoryKind: String, Codable, CaseIterable, Sendable {
    case started, planChanged, ended, disappeared, restored
}

enum ObservedSource: String, Codable, CaseIterable, Sendable {
    case sync, backgroundSync, notification, webBridge, manual, demo
}

enum PaymentProfileType: String, Codable, CaseIterable, Sendable {
    case creditCard, debitCard, paypal, carrierBilling, other
}

enum VerificationState: String, Codable, CaseIterable, Sendable {
    /// Confirmed by the user in the FANBOX / pixiv payment page (via Web Bridge) or reported by FANBOX.
    case verified
    /// Guessed by the app (e.g. from FANBOX paymentMethod kind). MUST be displayed as a guess.
    case inferred
    /// Entered manually by the user without verification.
    case manual
    case unknown
}

enum DraftStatus: String, Codable, CaseIterable, Sendable {
    case local, uploading, readyToPublish, publishing, published, failed
}

enum DraftBlockKind: String, Codable, CaseIterable, Sendable {
    case text, header, image, file, url, embed
}

enum UploadJobState: String, Codable, CaseIterable, Sendable {
    case queued, uploading, paused, failed, completed
}

enum UploadKind: String, Codable, CaseIterable, Sendable {
    case image, file
}

enum ReplyState: String, Codable, CaseIterable, Sendable {
    case draft, queued, sending, sent, failed, needsConfirmation
}

enum ReplyOrigin: String, Codable, Sendable {
    case inApp, notificationAction
}

enum FanState: String, Codable, CaseIterable, Sendable {
    case supporting, following, ended, unknown
}

enum NotificationPriority: Int, Codable, Comparable, Sendable {
    case normal = 1
    case high = 2
    case critical = 3

    static func < (lhs: NotificationPriority, rhs: NotificationPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What to prefetch when a notification event is detected (SPEC §24.2).
enum PrefetchTarget: String, Codable, Sendable {
    case commentThread      // Comment + Thread
    case supportMetadata    // Support Metadata
    case postText           // Title + Body
    case newsletterBody     // Body
    case metadata           // Metadata
    case notificationMetadata
}

enum NotificationEventType: String, Codable, CaseIterable, Sendable {
    case comment
    case commentReply
    case newPost
    case newsletter
    case supportChanged
    case paymentAttention
    case newSupporter
    case other

    /// SPEC §24.2 priority table.
    var priority: NotificationPriority {
        switch self {
        case .comment, .commentReply, .paymentAttention: return .critical
        case .newPost, .newsletter, .supportChanged: return .high
        case .newSupporter, .other: return .normal
        }
    }

    /// SPEC §24.2 prefetch column.
    var prefetchTarget: PrefetchTarget {
        switch self {
        case .comment, .commentReply: return .commentThread
        case .paymentAttention, .supportChanged: return .supportMetadata
        case .newPost: return .postText
        case .newsletter: return .newsletterBody
        case .newSupporter: return .metadata
        case .other: return .notificationMetadata
        }
    }

    var displayName: String {
        switch self {
        case .comment: return "コメント"
        case .commentReply: return "コメント返信"
        case .newPost: return "新着投稿"
        case .newsletter: return "おたより"
        case .supportChanged: return "支援状態変化"
        case .paymentAttention: return "決済要確認"
        case .newSupporter: return "新規支援"
        case .other: return "その他"
        }
    }
}

enum PrefetchState: String, Codable, CaseIterable, Sendable {
    case pending
    case inProgress
    /// Priority 0/1 data (metadata + text) is in the local DB.
    case textReady
    /// Text + small media (avatar/thumbnail) are local.
    case complete
    case failed
    case notNeeded
}

enum MediaKind: String, Codable, CaseIterable, Sendable {
    case image, file, audio, video
}

/// Staged image resolution (SPEC §6: Thumbnail → Display → Original).
enum MediaVariant: String, Codable, CaseIterable, Comparable, Sendable {
    case thumbnail, display, original

    var rank: Int {
        switch self {
        case .thumbnail: return 0
        case .display: return 1
        case .original: return 2
        }
    }

    static func < (lhs: MediaVariant, rhs: MediaVariant) -> Bool { lhs.rank < rhs.rank }
}

enum SyncResource: String, Codable, CaseIterable, Sendable {
    case session
    case timeline
    case supportingTimeline
    case creators
    case supports
    case plans
    case notifications
    case newsletters
    case comments
    case creatorDashboard
    case creatorPosts
    case creatorComments
    case fans
    case payments
}

enum SyncReason: String, Codable, Sendable {
    case appLaunch, foregroundPolling, backgroundRefresh, userRefresh, notification, afterWrite, onDemand
}

enum ResearchLogKind: String, Codable, CaseIterable, Sendable {
    case request, navigation, schema, sync, error, note
}

/// Whether a statistic is a real value, an explicit estimate, or unavailable (SPEC §17).
enum MetricSource: String, Codable, CaseIterable, Sendable {
    case actual, estimated, unavailable
}

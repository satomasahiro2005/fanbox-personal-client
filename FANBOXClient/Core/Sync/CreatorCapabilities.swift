import Foundation

/// What a remote data source can write for Creator Mode posts (SPEC §18 / §20 / §40). Decided up front, so the editor can
/// badge blocks and explain limits BEFORE the creator taps publish, instead of failing at send time.
///
/// - `.full`: everything the native editor offers, uploads not bound to a post (test fakes).
/// - `.demo`: everything, with the same create-first upload flow as FANBOX (demo accounts).
/// - `.fanbox` (defined next to the FANBOX adapter): text / headers, image and file uploads and new link cards natively,
///   all stored into the post (created first when new); new embeds, the R-18 flag and plan ids go to the web editor.
/// - `.textOnly`: text / header blocks natively; media already on the post round-trips by id; new uploads, link cards
///   and embeds are added in the account web editor.
/// - `.webOnly`: native writes switched off; everything goes through the web editor.
struct DraftCapabilities: Sendable, Hashable {
    /// Create / update posts natively at all.
    var nativeWrites: Bool
    /// Upload new images / files.
    var uploadsMedia: Bool
    /// Add new URL (link card) blocks.
    var createsLinkCards: Bool
    /// Add new embed blocks.
    var createsEmbeds: Bool
    /// The R-18 flag is sent.
    var sendsAdultFlag: Bool
    /// A plan id is sent (otherwise gating is by minimum fee only).
    var sendsPlanID: Bool
    /// The comment permission is sent on every update (so an unknown current value may be changed).
    var sendsCommentPermission: Bool
    /// Non-article posts (image / file / text / video types) can be updated with a block body.
    var updatesNonArticlePosts: Bool
    /// Uploads and new link cards are stored INTO an existing post (FANBOX `post.addImage` / `post.addFile` /
    /// `post.addUrlEmbed` take a `postId`): a new post is created first (`createEmptyPost`) and its id persisted, then
    /// media is uploaded and link cards registered, then the content is saved by id.
    var uploadsNeedPost: Bool = false
    /// Image- and file-type posts are saved with their own body shape (`{text, images}` / `{text, files}`): they can be
    /// updated natively but only hold image (file) blocks and plain text.
    var mediaPostBodies: Bool = false
    /// Client-side limits of the service's uploader (checked before anything is sent). nil = no known limits.
    var mediaLimits: DraftMediaLimits? = nil

    static let full = DraftCapabilities(nativeWrites: true, uploadsMedia: true, createsLinkCards: true, createsEmbeds: true,
                                        sendsAdultFlag: true, sendsPlanID: true, sendsCommentPermission: false,
                                        updatesNonArticlePosts: true)
    /// Demo accounts: every block natively, with FANBOX's create-first flow (uploads and link cards bound to the post).
    static let demo = DraftCapabilities(nativeWrites: true, uploadsMedia: true, createsLinkCards: true, createsEmbeds: true,
                                        sendsAdultFlag: true, sendsPlanID: true, sendsCommentPermission: false,
                                        updatesNonArticlePosts: true, uploadsNeedPost: true)
    static let textOnly = DraftCapabilities(nativeWrites: true, uploadsMedia: false, createsLinkCards: false, createsEmbeds: false,
                                            sendsAdultFlag: false, sendsPlanID: false, sendsCommentPermission: true,
                                            updatesNonArticlePosts: false)
    static let webOnly = DraftCapabilities(nativeWrites: false, uploadsMedia: false, createsLinkCards: false, createsEmbeds: false,
                                           sendsAdultFlag: false, sendsPlanID: false, sendsCommentPermission: false,
                                           updatesNonArticlePosts: false)

    /// True when a NEW block of this kind (no `remoteMediaID` yet) can be sent natively.
    func sendsNew(_ kind: DraftBlockKind) -> Bool {
        guard nativeWrites else { return false }
        switch kind {
        case .text, .header: return true
        case .image, .file: return uploadsMedia
        case .url: return createsLinkCards
        case .embed: return createsEmbeds
        }
    }

    /// True when an existing post of this type can be updated natively without changing its type.
    func updates(_ type: PostType) -> Bool {
        guard nativeWrites else { return false }
        switch type {
        case .article, .unknown: return true
        case .image, .file: return updatesNonArticlePosts || mediaPostBodies
        case .text, .video, .entry: return updatesNonArticlePosts
        }
    }

    /// Block kinds an image- / file-type post can hold when it is saved with its own body shape (nil = any kind).
    func allowedKinds(in type: PostType) -> Set<DraftBlockKind>? {
        guard mediaPostBodies, !updatesNonArticlePosts else { return nil }
        switch type {
        case .image: return [.image, .text]
        case .file: return [.file, .text]
        default: return nil
        }
    }
}

/// Upload limits of a service's own uploader, checked before a draft is sent so an oversized or unsupported file is
/// reported in the plan instead of after a post was created.
struct DraftMediaLimits: Sendable, Hashable {
    var maxImageBytes: Int
    var maxFileBytes: Int
    /// Lower-case extensions without the dot.
    var imageExtensions: Set<String>
    var fileExtensions: Set<String>

    /// Why the file cannot be uploaded (nil = acceptable). `fileName` is the display name, `size` in bytes when known.
    func problem(kind: UploadKind, fileName: String, size: Int?) -> String? {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let allowed = kind == .image ? imageExtensions : fileExtensions
        let label = kind == .image ? "画像" : "ファイル"
        if !allowed.contains(ext) {
            return "「\(fileName)」はアップロードできない\(label)形式です（対応: \(allowed.sorted().joined(separator: ", "))）"
        }
        let limit = kind == .image ? maxImageBytes : maxFileBytes
        if let size, size > limit {
            return "「\(fileName)」は大きすぎます（\(label)は \(limit / 1_000_000) MB まで）"
        }
        return nil
    }
}

extension RemoteDataSource {
    /// Default for data sources that implement every write (demo / fakes). `FanboxRemoteDataSource` narrows it.
    var draftCapabilities: DraftCapabilities { .full }
}

/// Who may comment on a post (SPEC §21). Raw values are the service's scope names.
enum CommentPermission: String, Sendable, Hashable, CaseIterable {
    case everyone
    case supporters
    /// "none" (named so it never reads as `Optional.none`).
    case disabled = "none"

    var label: String {
        switch self {
        case .everyone: return "全員"
        case .supporters: return "支援者のみ"
        case .disabled: return "コメント不可"
        }
    }

    /// Value used when the post's own setting is unknown (paid posts: supporters only; free posts: everyone), mirroring
    /// the only documented client that sends it (docs/API.md §14.4).
    static func `default`(feeRequired: Int) -> CommentPermission {
        feeRequired > 0 ? .supporters : .everyone
    }
}

/// A create that made an (empty) post on the service but could not save its content. The id is returned so the caller
/// persists it and the next attempt UPDATES that post instead of creating another one (no orphan / duplicate drafts).
struct RemotePostCreatedPartially: Error, Sendable, Equatable {
    var postID: String
    var underlying: RemoteError
}

/// Freshness policy for Creator Mode reads (docs/API.md §1.8 / §16.1, SPEC §3.7). Screens refresh on appear with
/// `.onDemand`, launch refresh uses `.appLaunch`; both are skipped while the last successful sync is younger than the
/// resource's minimum interval. Pull-to-refresh, after-write and notification-triggered syncs always run.
enum CreatorReadPolicy {
    static func minimumInterval(for resource: SyncResource, scope: String) -> TimeInterval? {
        switch resource {
        // .fans is throttled inside SyncEngine (fansAutomaticInterval / fansOnDemandInterval), not here.
        case .creatorDashboard: return 10 * 60
        case .creatorComments: return 10 * 60
        case .creatorPosts: return scope.isEmpty ? 5 * 60 : nil   // only my own managed list
        default: return nil
        }
    }

    static func bypassesThrottle(_ reason: SyncReason) -> Bool {
        switch reason {
        case .userRefresh, .afterWrite, .notification: return true
        case .appLaunch, .foregroundPolling, .backgroundRefresh, .onDemand: return false
        }
    }

    /// True when the sync can be skipped because the local copy is fresh enough.
    static func isFresh(_ resource: SyncResource, scope: String, reason: SyncReason, lastSuccess: Date?, now: Date = .now) -> Bool {
        guard !bypassesThrottle(reason), let interval = minimumInterval(for: resource, scope: scope), let lastSuccess else { return false }
        let age = now.timeIntervalSince(lastSuccess)
        return age >= 0 && age < interval
    }
}

/// Reconciliation after an account web session closes (SPEC §40).
enum CreatorWebReconcile {
    /// The managed post list is re-synced after the web post editor / post management was used (posts may have been
    /// created, finished, published or deleted there).
    static func needsManagedPostsResync(_ request: WebSessionRequest) -> Bool {
        switch request.destination {
        case .managePostEditor, .managePosts: return true
        default: return false
        }
    }
}

/// "yyyy-MM" month keys of Creator Mode. The service bills and counts in JST, so the key is computed in Asia/Tokyo on every
/// device (a device outside JST would otherwise look up the wrong month near a month boundary).
enum CreatorMonth {
    static let timeZone = TimeZone(identifier: "Asia/Tokyo") ?? TimeZone(secondsFromGMT: 9 * 3600)!

    static func key(_ date: Date = .now) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}

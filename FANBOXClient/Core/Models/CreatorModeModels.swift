import Foundation
import SwiftData

/// Local post draft (SPEC §19). Created and edited fully offline.
@Model
final class Draft {
    @Attribute(.unique) var id: String
    var accountID: String
    var creatorID: String?
    /// Non-nil when this draft edits an existing FANBOX post (Post Edit).
    var remotePostID: String?
    var title: String
    var targetPlanID: String?
    var feeRequired: Int
    var tags: [String]
    var hasAdultContent: Bool
    var statusRaw: String
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date
    var publishedAt: Date?
    /// FANBOX-side status of `remotePostID` ("published" / "draft" / "scheduled" / "unknown"), as last seen (import, pre-send
    /// check or a successful send). nil = new post, or a draft imported before this field existed (treated as "maybe published").
    var remoteStatusRaw: String?
    /// Fee (minimum support) the FANBOX post had when imported / last sent. Used to warn about gating changes.
    var remoteFeeRequired: Int?
    /// FANBOX `updatedAt` the local copy is based on. A newer remote value means the post changed elsewhere (e.g. the web
    /// editor) and a native update would overwrite that change, so the update is refused.
    var remoteUpdatedAt: Date?
    /// Comment permission read from FANBOX (`CommentPermission` raw value). nil = unknown.
    var commentPermissionRaw: String?
    /// Why this post cannot be updated natively (non-article post, scheduled post, unsupported blocks). nil = no blocker.
    var nativeUpdateBlocker: String?
    /// True when FANBOX did not report the post's tags on import (an update might clear them).
    var tagsUnverified: Bool = false
    /// Set after a text-first send that left media / link cards / embeds to be added in the web editor.
    var webHandoffAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \DraftBlock.draft)
    var blocks: [DraftBlock] = []

    init(id: String = UUID().uuidString, accountID: String, creatorID: String? = nil, remotePostID: String? = nil, title: String = "",
         targetPlanID: String? = nil, feeRequired: Int = 0, createdAt: Date = .now) {
        self.id = id
        self.accountID = accountID
        self.creatorID = creatorID
        self.remotePostID = remotePostID
        self.title = title
        self.targetPlanID = targetPlanID
        self.feeRequired = feeRequired
        self.tags = []
        self.hasAdultContent = false
        self.statusRaw = DraftStatus.local.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var status: DraftStatus {
        get { DraftStatus(rawValue: statusRaw) ?? .local }
        set { statusRaw = newValue.rawValue }
    }

    /// FANBOX-side status. nil for a new post. A linked post whose status was never recorded reads as `.unknown`.
    var remoteStatus: RemotePostStatus? {
        guard remotePostID != nil else { return nil }
        return remoteStatusRaw.flatMap(RemotePostStatus.init(rawValue:)) ?? .unknown
    }

    var commentPermission: CommentPermission? {
        get { commentPermissionRaw.flatMap(CommentPermission.init(rawValue:)) }
        set { commentPermissionRaw = newValue?.rawValue }
    }

    var orderedBlocks: [DraftBlock] { blocks.sorted { $0.order < $1.order } }
}

@Model
final class DraftBlock {
    @Attribute(.unique) var id: String
    var draftID: String
    var order: Int
    var kindRaw: String
    var text: String
    /// File name inside the app's draft media directory (see `DraftMediaStore`).
    var localFileName: String?
    var originalFileName: String?
    var mimeType: String?
    var fileSize: Int?
    var width: Int?
    var height: Int?
    /// FANBOX image id / file id once uploaded.
    var remoteMediaID: String?
    var remoteURL: String?
    var url: String?
    var embedProvider: String?
    var embedContentID: String?
    /// Post Edit: text of the FANBOX block when imported / last sent (nil = block created locally). Lets an unchanged
    /// paragraph (including an empty spacing paragraph) be sent back exactly as it was.
    var importedText: String?
    /// Post Edit: JSON `[RemoteTextStyle]` (bold / font size / links) of the FANBOX block, offsets relative to `importedText`.
    var stylesJSON: String?
    /// Post Edit: block that references FANBOX content the app cannot show or edit (e.g. a link card whose target is
    /// unknown). It is sent back unchanged by its `remoteMediaID`.
    var isLockedRemote: Bool = false
    var draft: Draft?

    init(id: String = UUID().uuidString, draftID: String, order: Int, kind: DraftBlockKind, text: String = "") {
        self.id = id
        self.draftID = draftID
        self.order = order
        self.kindRaw = kind.rawValue
        self.text = text
    }

    var kind: DraftBlockKind {
        get { DraftBlockKind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }

    /// Imported text styles (empty when none / not imported).
    var importedStyles: [RemoteTextStyle] {
        get {
            guard let stylesJSON, let data = stylesJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([RemoteTextStyle].self, from: data)) ?? []
        }
        set {
            if newValue.isEmpty {
                stylesJSON = nil
            } else if let data = try? JSONEncoder().encode(newValue) {
                stylesJSON = String(data: data, encoding: .utf8)
            }
        }
    }
}

/// Media upload job (SPEC §20).
@Model
final class UploadJob {
    @Attribute(.unique) var id: String
    var draftID: String
    var draftBlockID: String
    var accountID: String
    var fileName: String
    var localFileName: String
    var kindRaw: String
    var stateRaw: String
    var progress: Double
    var bytesTotal: Int
    var order: Int
    var remoteMediaID: String?
    var remoteURL: String?
    var attemptCount: Int
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, draftID: String, draftBlockID: String, accountID: String, fileName: String, localFileName: String,
         kind: UploadKind, bytesTotal: Int = 0, order: Int = 0, createdAt: Date = .now) {
        self.id = id
        self.draftID = draftID
        self.draftBlockID = draftBlockID
        self.accountID = accountID
        self.fileName = fileName
        self.localFileName = localFileName
        self.kindRaw = kind.rawValue
        self.stateRaw = UploadJobState.queued.rawValue
        self.progress = 0
        self.bytesTotal = bytesTotal
        self.order = order
        self.attemptCount = 0
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var state: UploadJobState {
        get { UploadJobState(rawValue: stateRaw) ?? .queued }
        set { stateRaw = newValue.rawValue }
    }

    var kind: UploadKind {
        get { UploadKind(rawValue: kindRaw) ?? .file }
        set { kindRaw = newValue.rawValue }
    }
}

/// Fan / supporter of my creator account (SPEC §23).
@Model
final class Fan {
    /// "\(accountID)|\(userID)"
    @Attribute(.unique) var key: String
    /// Creator account (local account id).
    var accountID: String
    var userID: String
    var name: String
    var iconURL: String?
    var planID: String?
    var planTitle: String?
    var fee: Int?
    var supportStartedAt: Date?
    var supportMonths: Int?
    var stateRaw: String
    /// Local note, never sent to FANBOX.
    var note: String
    var updatedAt: Date

    init(accountID: String, userID: String, name: String, state: FanState = .unknown, updatedAt: Date = .now) {
        self.key = "\(accountID)|\(userID)"
        self.accountID = accountID
        self.userID = userID
        self.name = name
        self.stateRaw = state.rawValue
        self.note = ""
        self.updatedAt = updatedAt
    }

    var state: FanState {
        get { FanState(rawValue: stateRaw) ?? .unknown }
        set { stateRaw = newValue.rawValue }
    }
}

/// Creator dashboard numbers. Each metric carries its source: actual / estimated / unavailable (SPEC §17).
@Model
final class CreatorDashboardSnapshot {
    /// "\(accountID)|\(month)" where month = "yyyy-MM"
    @Attribute(.unique) var key: String
    var accountID: String
    var month: String
    var supporterCount: Int?
    var supporterCountSourceRaw: String
    var earnings: Int?
    var earningsSourceRaw: String
    var postCount: Int?
    var postCountSourceRaw: String
    var commentCount: Int?
    var commentCountSourceRaw: String
    var fetchedAt: Date

    init(accountID: String, month: String, fetchedAt: Date = .now) {
        self.key = "\(accountID)|\(month)"
        self.accountID = accountID
        self.month = month
        self.supporterCountSourceRaw = MetricSource.unavailable.rawValue
        self.earningsSourceRaw = MetricSource.unavailable.rawValue
        self.postCountSourceRaw = MetricSource.unavailable.rawValue
        self.commentCountSourceRaw = MetricSource.unavailable.rawValue
        self.fetchedAt = fetchedAt
    }

    var supporterCountSource: MetricSource { MetricSource(rawValue: supporterCountSourceRaw) ?? .unavailable }
    var earningsSource: MetricSource { MetricSource(rawValue: earningsSourceRaw) ?? .unavailable }
    var postCountSource: MetricSource { MetricSource(rawValue: postCountSourceRaw) ?? .unavailable }
    var commentCountSource: MetricSource { MetricSource(rawValue: commentCountSourceRaw) ?? .unavailable }
}

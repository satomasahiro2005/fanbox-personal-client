import Foundation
import SwiftData

/// A FANBOX / pixiv account managed by the app (SPEC §7).
/// Secrets (cookies, CSRF token, session) are NEVER stored here — see `CredentialStore` (Keychain)
/// and the per-account `WKWebsiteDataStore` identified by `webProfileID`.
@Model
final class Account {
    @Attribute(.unique) var id: String
    var kindRaw: String
    var displayName: String
    var pixivUserID: String?
    var fanboxUserID: String?
    var avatarURL: String?
    /// UUID string used as `WKWebsiteDataStore(forIdentifier:)` identifier. One store per account.
    var webProfileID: String
    /// Non-nil when this account owns a FANBOX creator page (SPEC: `creatorAccount`).
    var creatorID: String?
    var enabled: Bool
    var isMain: Bool
    var sortOrder: Int
    var sessionStateRaw: String
    var sessionCheckedAt: Date?
    var lastSyncAt: Date?
    var createdAt: Date
    /// Small color label to tell accounts apart in lists (hex, e.g. "#8B5CF6").
    var colorHex: String?
    /// Observed flag from FANBOX (page metadata `hasUnpaidPayments` / unpaid payment list). nil = never observed.
    /// Used only to show "決済状態を確認できません" — never to assert that a payment failed (SPEC §15).
    var hasUnpaidPayments: Bool?
    var unpaidPaymentsCheckedAt: Date?

    init(
        id: String = UUID().uuidString,
        kind: AccountKind = .fanbox,
        displayName: String,
        pixivUserID: String? = nil,
        fanboxUserID: String? = nil,
        avatarURL: String? = nil,
        webProfileID: String = UUID().uuidString,
        creatorID: String? = nil,
        enabled: Bool = true,
        isMain: Bool = false,
        sortOrder: Int = 0,
        sessionState: SessionState = .unknown,
        colorHex: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.displayName = displayName
        self.pixivUserID = pixivUserID
        self.fanboxUserID = fanboxUserID
        self.avatarURL = avatarURL
        self.webProfileID = webProfileID
        self.creatorID = creatorID
        self.enabled = enabled
        self.isMain = isMain
        self.sortOrder = sortOrder
        self.sessionStateRaw = sessionState.rawValue
        self.colorHex = colorHex
        self.createdAt = createdAt
    }

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .fanbox }
        set { kindRaw = newValue.rawValue }
    }

    var sessionState: SessionState {
        get { SessionState(rawValue: sessionStateRaw) ?? .unknown }
        set { sessionStateRaw = newValue.rawValue }
    }

    /// SPEC §7 `creatorAccount`.
    var creatorAccount: Bool { creatorID != nil }

    var context: AccountContext {
        AccountContext(accountID: id, kind: kind, pixivUserID: pixivUserID, fanboxUserID: fanboxUserID, creatorID: creatorID)
    }
}

/// Sendable snapshot of an account, passed to actors / remote data sources.
struct AccountContext: Sendable, Hashable {
    var accountID: String
    var kind: AccountKind
    var pixivUserID: String?
    var fanboxUserID: String?
    var creatorID: String?
}

import Foundation
import SwiftUI
import SwiftData

/// Plain snapshot of the fields an inbox row needs (keeps formatting pure / testable).
struct NotificationRowInput: Sendable, Equatable {
    var type: NotificationEventType
    var actorName: String?
    /// Resolved from the local `Creator` table when known.
    var creatorName: String?
    var title: String
    var message: String
    var timestamp: Date
    var prefetchState: PrefetchState
    var isRead: Bool
    var accountIDs: [String]
}

extension NotificationRowInput {
    @MainActor
    init(event: NotificationEvent, creatorName: String?) {
        self.init(type: event.type, actorName: event.actorName, creatorName: creatorName, title: event.title, message: event.message,
                  timestamp: event.timestamp, prefetchState: event.prefetchState, isRead: event.isRead, accountIDs: event.accountIDs)
    }
}

/// Prefetch indicator shown on an inbox row (SPEC §25 / §26: the user can tell a notification opens instantly).
struct NotificationPrefetchBadge: Equatable, Sendable {
    enum Tone: Sendable { case ready, working, problem }
    var text: String
    var systemImage: String
    var tone: Tone

    var tint: Color {
        switch tone {
        case .ready: return .green
        case .working: return .secondary
        case .problem: return .orange
        }
    }
}

/// Text for one inbox row (SPEC §27):
///
///     ● user123がコメントしました
///       Creator Account
///       1分前
struct NotificationRowText: Equatable, Sendable {
    var headline: String
    /// Secondary lines (post title, comment body …), deduplicated, never repeating the headline.
    var details: [String]
    var relativeTime: String
    var badge: NotificationPrefetchBadge?
}

enum NotificationRowFormatter {
    static func format(_ input: NotificationRowInput, now: Date = .now, calendar: Calendar = .current) -> NotificationRowText {
        let headline = headline(for: input)
        return NotificationRowText(headline: headline, details: details(for: input, headline: headline),
                                   relativeTime: relativeTime(input.timestamp, now: now, calendar: calendar),
                                   badge: prefetchBadge(for: input.prefetchState, type: input.type))
    }

    /// "user123がコメントしました" / "Creator Aが投稿しました" / "Creator Bからおたより".
    static func headline(for input: NotificationRowInput) -> String {
        let actor = clean(input.actorName)
        let creator = clean(input.creatorName)
        let title = clean(input.title)
        switch input.type {
        case .comment:
            if let actor { return "\(actor)がコメントしました" }
        case .commentReply:
            if let actor { return "\(actor)が返信しました" }
        case .newPost:
            if let name = creator ?? actor { return "\(name)が投稿しました" }
        case .newsletter:
            if let name = creator ?? actor { return "\(name)からおたより" }
        case .newSupporter:
            if let actor { return "\(actor)が支援を開始しました" }
        case .supportChanged, .paymentAttention, .other:
            break
        }
        return title ?? fallbackHeadline(for: input.type)
    }

    static func fallbackHeadline(for type: NotificationEventType) -> String {
        switch type {
        case .comment: return "新しいコメントがあります"
        case .commentReply: return "コメントに返信がありました"
        case .newPost: return "新着投稿があります"
        case .newsletter: return "おたよりが届きました"
        case .supportChanged: return "支援状態が変わりました"
        case .paymentAttention: return "決済の確認が必要です"
        case .newSupporter: return "新しい支援がありました"
        case .other: return "FANBOXからのお知らせ"
        }
    }

    /// Title + message below the headline, deduplicated (the headline may already be the title).
    static func details(for input: NotificationRowInput, headline: String) -> [String] {
        var result: [String] = []
        for candidate in [clean(input.title), clean(input.message)].compactMap({ $0 }) {
            let line = NewsletterExcerpt.make(candidate, limit: 120)
            guard line != headline, !result.contains(line) else { continue }
            result.append(line)
        }
        return result
    }

    /// "たった今" / "1分前" / "3時間前" / "2日前" / "9月1日" / "2025年9月1日".
    static func relativeTime(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "たった今" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)分前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)時間前" }
        let days = hours / 24
        if days < 7 { return "\(days)日前" }
        let d = calendar.dateComponents([.year, .month, .day], from: date)
        let nowYear = calendar.component(.year, from: now)
        if d.year == nowYear { return "\(d.month ?? 0)月\(d.day ?? 0)日" }
        return "\(d.year ?? 0)年\(d.month ?? 0)月\(d.day ?? 0)日"
    }

    /// textReady / complete ⇒ "本文取得済" so the user knows the notification opens instantly.
    static func prefetchBadge(for state: PrefetchState, type: NotificationEventType) -> NotificationPrefetchBadge? {
        switch state {
        case .textReady, .complete:
            let text: String
            switch type.prefetchTarget {
            case .commentThread: text = "コメント取得済"
            case .supportMetadata, .metadata, .notificationMetadata: text = "取得済"
            case .postText, .newsletterBody: text = "本文取得済"
            }
            return NotificationPrefetchBadge(text: text, systemImage: "checkmark.circle.fill", tone: .ready)
        case .inProgress:
            return NotificationPrefetchBadge(text: "取得中", systemImage: "arrow.down.circle", tone: .working)
        case .failed:
            return NotificationPrefetchBadge(text: "未取得", systemImage: "exclamationmark.circle", tone: .problem)
        case .pending, .notNeeded:
            return nil
        }
    }

    static func systemImage(for type: NotificationEventType) -> String {
        switch type {
        case .comment: return "bubble.left.fill"
        case .commentReply: return "arrowshape.turn.up.left.fill"
        case .newPost: return "doc.richtext.fill"
        case .newsletter: return "envelope.fill"
        case .supportChanged: return "yensign.circle.fill"
        case .paymentAttention: return "exclamationmark.triangle.fill"
        case .newSupporter: return "person.crop.circle.badge.plus"
        case .other: return "bell.fill"
        }
    }

    static func tint(for type: NotificationEventType) -> Color {
        switch type {
        case .comment, .commentReply: return .blue
        case .newPost: return .purple
        case .newsletter: return .teal
        case .supportChanged: return .pink
        case .paymentAttention: return .orange
        case .newSupporter: return .green
        case .other: return .gray
        }
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// Inbox filter (type chips + account filter + unread toggle). Pure and testable.
struct NotificationInboxFilter: Equatable, Sendable {
    /// nil = all types.
    var type: NotificationEventType? = nil
    /// nil = all accounts.
    var accountID: String? = nil
    var unreadOnly: Bool = false
    /// Set by the inbox from the enabled accounts: an item shows only when one of its receiving accounts is enabled, so
    /// items of disabled accounts (and items left without any account after a removal) are hidden. nil = no restriction.
    var enabledAccountIDs: Set<String>? = nil

    /// A filter the user chose (the enabled-account restriction is not a user choice).
    var isActive: Bool { type != nil || accountID != nil || unreadOnly }

    func matches(type eventType: NotificationEventType, accountIDs: [String], isRead: Bool) -> Bool {
        if let enabledAccountIDs, !accountIDs.contains(where: enabledAccountIDs.contains) { return false }
        if let type, type != eventType { return false }
        if let accountID, !accountIDs.contains(accountID) { return false }
        if unreadOnly && isRead { return false }
        return true
    }

    @MainActor
    func matches(_ event: NotificationEvent) -> Bool {
        matches(type: event.type, accountIDs: event.accountIDs, isRead: event.isRead)
    }

    /// Type chips: "すべて" + every `NotificationEventType.displayName`, in SPEC §24.1 order.
    static var typeChips: [NotificationTypeChip] {
        [NotificationTypeChip(type: nil)] + NotificationEventType.allCases.map { NotificationTypeChip(type: $0) }
    }
}

/// One type filter chip ("すべて" when `type` is nil).
struct NotificationTypeChip: Identifiable, Hashable, Sendable {
    var type: NotificationEventType?

    var id: String { type?.rawValue ?? "all" }
    var title: String { type?.displayName ?? "すべて" }
}

/// Newsletter / notification text excerpt: whitespace collapsed to single spaces, truncated with "…".
enum NewsletterExcerpt {
    static func make(_ body: String, limit: Int = 80) -> String {
        let collapsed = body
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard limit > 0 else { return "" }
        guard collapsed.count > limit else { return collapsed }
        let cut = collapsed.prefix(limit).trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }

    /// Row excerpt for a newsletter: body excerpt, or a placeholder when the body is not fetched yet.
    static func rowText(body: String, bodyFetched: Bool, limit: Int = 80) -> String {
        let excerpt = make(body, limit: limit)
        if !excerpt.isEmpty { return excerpt }
        return bodyFetched ? "(本文なし)" : "本文は未取得です"
    }
}

/// Local read-state mutations used by the inbox / newsletter screens (local metadata only; never sent to FANBOX).
/// An おたより and its inbox event always share one read state (both inbox segments show the same thing).
@MainActor
enum NotificationReadActions {
    /// Marks the newsletter and any inbox event pointing at it as read. Returns true when something changed.
    @discardableResult
    static func markNewsletterRead(newsletterID: String, store: LocalStore) -> Bool {
        setNewsletterRead(newsletterID: newsletterID, read: true, store: store)
    }

    /// Sets the read state of a newsletter and of every inbox event pointing at it. Returns true when something changed.
    @discardableResult
    static func setNewsletterRead(newsletterID: String, read: Bool, store: LocalStore) -> Bool {
        var changed = false
        if let newsletter = store.newsletter(id: newsletterID), newsletter.isRead != read {
            newsletter.isRead = read
            changed = true
        }
        let id = newsletterID
        let events = store.fetch(FetchDescriptor<NotificationEvent>(predicate: #Predicate { $0.newsletterID == id }))
        for event in events where event.isRead != read {
            event.isRead = read
            changed = true
        }
        if changed { store.save() }
        return changed
    }

    /// Sets an event's read state (swipe action); an おたより event carries its newsletter along.
    static func setEventRead(_ event: NotificationEvent, read: Bool, store: LocalStore) {
        if let newsletterID = event.newsletterID {
            setNewsletterRead(newsletterID: newsletterID, read: read, store: store)
        }
        if event.isRead != read {
            event.isRead = read
            store.save()
        }
    }

    /// "すべて既読" for the events matching `filter`. Returns the number of events changed.
    @discardableResult
    static func markAllRead(_ events: [NotificationEvent], filter: NotificationInboxFilter, store: LocalStore) -> Int {
        var count = 0
        var newsletterIDs: [String] = []
        for event in events where !event.isRead && filter.matches(event) {
            event.isRead = true
            count += 1
            if let id = event.newsletterID { newsletterIDs.append(id) }
        }
        for id in newsletterIDs { setNewsletterRead(newsletterID: id, read: true, store: store) }
        if count > 0 { store.save() }
        return count
    }

    /// "すべて既読" for newsletters matching `filter` (type filter is ignored for newsletters); their events follow.
    @discardableResult
    static func markAllRead(_ newsletters: [Newsletter], filter: NotificationInboxFilter, store: LocalStore) -> Int {
        var newsletterFilter = filter
        newsletterFilter.type = nil
        var ids: [String] = []
        for newsletter in newsletters where !newsletter.isRead
            && newsletterFilter.matches(type: .newsletter, accountIDs: newsletter.accountIDs, isRead: newsletter.isRead) {
            ids.append(newsletter.newsletterID)
        }
        for id in ids { setNewsletterRead(newsletterID: id, read: true, store: store) }
        return ids.count
    }
}

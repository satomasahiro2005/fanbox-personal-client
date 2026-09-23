import Foundation
import SwiftData

/// Home feed filter chips (SPEC §5): すべて / 支援中 / フォロー中 / 未読 / お気に入り.
enum HomeFeedFilterKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all, supporting, following, unread, favorite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "すべて"
        case .supporting: return "支援中"
        case .following: return "フォロー中"
        case .unread: return "未読"
        case .favorite: return "お気に入り"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.stack"
        case .supporting: return "yensign.circle"
        case .following: return "person.crop.circle.badge.checkmark"
        case .unread: return "circle.fill"
        case .favorite: return "star"
        }
    }

    /// Stable id for UI tests: "homeFilter.<name>".
    var accessibilityID: String { "homeFilter.\(rawValue)" }
}

/// Value snapshot of the post fields the feed filter looks at. Keeps `HomeFeedFilter` pure and testable
/// without a SwiftData container.
struct HomeFeedEntry: Hashable, Sendable {
    var postID: String
    var publishedAt: Date
    var isFromSupportedCreator: Bool
    var isFromFollowedCreator: Bool
    var isRead: Bool
    var isFavorite: Bool
    var accessAccountIDs: [String]
    var seenByAccountIDs: [String]

    init(postID: String, publishedAt: Date = .distantPast, isFromSupportedCreator: Bool = false, isFromFollowedCreator: Bool = false,
         isRead: Bool = false, isFavorite: Bool = false, accessAccountIDs: [String] = [], seenByAccountIDs: [String] = []) {
        self.postID = postID
        self.publishedAt = publishedAt
        self.isFromSupportedCreator = isFromSupportedCreator
        self.isFromFollowedCreator = isFromFollowedCreator
        self.isRead = isRead
        self.isFavorite = isFavorite
        self.accessAccountIDs = accessAccountIDs
        self.seenByAccountIDs = seenByAccountIDs
    }
}

extension HomeFeedEntry {
    init(_ post: Post) {
        self.init(postID: post.postID, publishedAt: post.publishedAt, isFromSupportedCreator: post.isFromSupportedCreator,
                  isFromFollowedCreator: post.isFromFollowedCreator, isRead: post.isRead, isFavorite: post.isFavorite,
                  accessAccountIDs: post.accessAccountIDs, seenByAccountIDs: post.seenByAccountIDs)
    }
}

/// Pure filter for the unified timeline (SPEC §5). Combines a chip (`kind`) with an optional account filter.
/// Posts are already deduplicated by `postID` in the DB; `apply` still guarantees each postID appears once.
struct HomeFeedFilter: Hashable, Sendable {
    var kind: HomeFeedFilterKind = .all
    /// nil = all accounts. Otherwise only posts that this account has seen in a listing or can view.
    var accountID: String?

    init(kind: HomeFeedFilterKind = .all, accountID: String? = nil) {
        self.kind = kind
        self.accountID = accountID
    }

    func matches(_ entry: HomeFeedEntry) -> Bool {
        switch kind {
        case .all: break
        case .supporting: guard entry.isFromSupportedCreator else { return false }
        case .following: guard entry.isFromFollowedCreator else { return false }
        case .unread: guard !entry.isRead else { return false }
        case .favorite: guard entry.isFavorite else { return false }
        }
        if let accountID {
            return entry.seenByAccountIDs.contains(accountID) || entry.accessAccountIDs.contains(accountID)
        }
        return true
    }

    /// Filters, dedupes by postID (first occurrence wins) and keeps the input order.
    func apply(_ entries: [HomeFeedEntry]) -> [HomeFeedEntry] {
        var seen = Set<String>()
        return entries.filter { entry in
            guard matches(entry), seen.insert(entry.postID).inserted else { return false }
            return true
        }
    }

    /// Same as `apply` for SwiftData posts.
    func apply(_ posts: [Post]) -> [Post] {
        var seen = Set<String>()
        return posts.filter { post in
            guard matches(HomeFeedEntry(post)), seen.insert(post.postID).inserted else { return false }
            return true
        }
    }

    /// Sorts newest first (ties broken by postID for a stable order).
    static func newestFirst(_ entries: [HomeFeedEntry]) -> [HomeFeedEntry] {
        entries.sorted { a, b in
            if a.publishedAt != b.publishedAt { return a.publishedAt > b.publishedAt }
            return a.postID > b.postID
        }
    }

    /// Fetch descriptor that pre-filters the chip in SQLite (Bool fields only — arrays are filtered in memory),
    /// newest first. `limit` bounds the working set for very large local libraries.
    func descriptor(limit: Int?) -> FetchDescriptor<Post> {
        let sort = [SortDescriptor(\Post.publishedAt, order: .reverse)]
        var d: FetchDescriptor<Post>
        switch kind {
        case .all:
            d = FetchDescriptor<Post>(sortBy: sort)
        case .supporting:
            d = FetchDescriptor<Post>(predicate: #Predicate { $0.isFromSupportedCreator }, sortBy: sort)
        case .following:
            d = FetchDescriptor<Post>(predicate: #Predicate { $0.isFromFollowedCreator }, sortBy: sort)
        case .unread:
            d = FetchDescriptor<Post>(predicate: #Predicate { !$0.isRead }, sortBy: sort)
        case .favorite:
            d = FetchDescriptor<Post>(predicate: #Predicate { $0.isFavorite }, sortBy: sort)
        }
        d.fetchLimit = limit
        return d
    }
}

/// "対象 Plan" label for a post card / detail header.
enum HomePlanLabel {
    /// "全体公開" for free posts, otherwise "¥500〜" (plus the matching plan title when known).
    /// The matching plan is the cheapest plan whose fee covers `feeRequired`.
    static func text(feeRequired: Int, plans: [Plan] = []) -> String {
        guard feeRequired > 0 else { return "全体公開" }
        let fee = Formatters.yen(feeRequired) + "〜"
        if let title = planTitle(feeRequired: feeRequired, plans: plans.map { ($0.fee, $0.title) }) {
            return "\(fee) \(title)"
        }
        return fee
    }

    /// Pure lookup on (fee, title) pairs.
    static func planTitle(feeRequired: Int, plans: [(fee: Int, title: String)]) -> String? {
        guard feeRequired > 0 else { return nil }
        return plans.filter { $0.fee >= feeRequired && !$0.title.isEmpty }
            .min { $0.fee < $1.fee }?.title
    }
}

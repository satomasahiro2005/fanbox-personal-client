import Foundation

/// Plain snapshot of the creator fields the list filter / search / sort need.
/// Keeps `CreatorListFilter` pure and testable without SwiftData.
struct CreatorFilterFacts: Sendable, Equatable {
    var creatorID: String
    var name: String
    var memo: String = ""
    var profileText: String = ""
    var isSupported: Bool = false
    var isFollowed: Bool = false
    var hasPosts: Bool = false
    var isFavorite: Bool = false
    var isOwnCreator: Bool = false
    var latestPostAt: Date? = nil
    /// Sum of active support amounts (JPY / month) across my accounts.
    var monthlySupportTotal: Int = 0
    /// Supported, followed or owned only by disabled accounts: hidden from the list (every chip, すべて included).
    var isOnlyRelatedToDisabledAccounts: Bool = false
}

extension CreatorFilterFacts {
    /// Builds facts from the SwiftData row plus cross-table knowledge. Only enabled accounts count: relations of a
    /// disabled account stay stored but are ignored, and a creator related to disabled accounts only is hidden.
    /// - Parameters:
    ///   - activeSupportTotals: creatorID → sum of ACTIVE `Support.amount` of enabled accounts
    ///     (see `CreatorSupportSummary.totalsByCreator`).
    ///   - ownCreatorIDs: `Account.creatorID` of my enabled accounts (a creator page I own counts even if sync hasn't set
    ///     `ownedByAccountID`).
    ///   - enabledAccountIDs: ids of the enabled accounts.
    ///   - localLatestPostAt: creatorID → newest local `Post.publishedAt` (fallback when `latestPostAt` is not denormalized yet).
    @MainActor
    init(creator: Creator, activeSupportTotals: [String: Int], ownCreatorIDs: Set<String>, enabledAccountIDs: Set<String>,
         localLatestPostAt: [String: Date] = [:]) {
        let total = activeSupportTotals[creator.creatorID]
        let latest = [creator.latestPostAt, localLatestPostAt[creator.creatorID]].compactMap { $0 }.max()
        let supported = creator.supportedByAccountIDs.contains(where: enabledAccountIDs.contains) || total != nil
        let followed = creator.followedByAccountIDs.contains(where: enabledAccountIDs.contains)
        let owned = creator.ownedByAccountID.map(enabledAccountIDs.contains) == true || ownCreatorIDs.contains(creator.creatorID)
        let hasRelation = !creator.supportedByAccountIDs.isEmpty || !creator.followedByAccountIDs.isEmpty
            || creator.ownedByAccountID != nil
        self.init(
            creatorID: creator.creatorID,
            name: creator.name,
            memo: creator.memo,
            profileText: creator.profileText,
            isSupported: supported,
            isFollowed: followed,
            hasPosts: creator.hasKnownPosts || latest != nil,
            isFavorite: creator.isFavorite,
            isOwnCreator: owned,
            latestPostAt: latest,
            monthlySupportTotal: total ?? 0,
            isOnlyRelatedToDisabledAccounts: hasRelation && !supported && !followed && !owned
        )
    }

    /// True when the creator's stored relations (support, follow, ownership) exist and all belong to accounts outside
    /// `enabledAccountIDs`. For lists that hide such creators without building the full facts (offline creator picker).
    @MainActor
    static func isOnlyRelatedToDisabledAccounts(_ creator: Creator, enabledAccountIDs: Set<String>) -> Bool {
        let related = creator.supportedByAccountIDs + creator.followedByAccountIDs + [creator.ownedByAccountID].compactMap { $0 }
        return !related.isEmpty && !related.contains(where: enabledAccountIDs.contains)
    }
}

/// Creator list filter chips (SPEC §9 "Creator 一覧フィルター").
enum CreatorListFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case supporting
    case following
    case hasPosts
    case favorite
    case ownCreatorAccount

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "すべて"
        case .supporting: return "支援中"
        case .following: return "フォロー中"
        case .hasPosts: return "投稿あり"
        case .favorite: return "お気に入り"
        case .ownCreatorAccount: return "自分のCreator Account"
        }
    }

    var systemImage: String? {
        switch self {
        case .all: return nil
        case .supporting: return "yensign.circle"
        case .following: return "person.badge.plus"
        case .hasPosts: return "doc.richtext"
        case .favorite: return "star"
        case .ownCreatorAccount: return "paintbrush.pointed"
        }
    }

    func matches(_ facts: CreatorFilterFacts) -> Bool {
        if facts.isOnlyRelatedToDisabledAccounts { return false }
        switch self {
        case .all: return true
        case .supporting: return facts.isSupported
        case .following: return facts.isFollowed
        case .hasPosts: return facts.hasPosts
        case .favorite: return facts.isFavorite
        case .ownCreatorAccount: return facts.isOwnCreator
        }
    }
}

/// Sort order of the creator list.
enum CreatorListSort: String, CaseIterable, Identifiable, Sendable {
    /// Favorites first, then newest post, then name.
    case recommended
    case latestPost
    case name
    case supportAmount

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommended: return "おすすめ順"
        case .latestPost: return "最新投稿順"
        case .name: return "名前順"
        case .supportAmount: return "支援額順"
        }
    }

    /// Strict ordering; ties fall back to name then creatorID so the order is stable.
    func areInIncreasingOrder(_ a: CreatorFilterFacts, _ b: CreatorFilterFacts) -> Bool {
        switch self {
        case .recommended:
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            if let r = Self.compareDatesDescending(a.latestPostAt, b.latestPostAt) { return r }
        case .latestPost:
            if let r = Self.compareDatesDescending(a.latestPostAt, b.latestPostAt) { return r }
        case .name:
            break
        case .supportAmount:
            if a.monthlySupportTotal != b.monthlySupportTotal { return a.monthlySupportTotal > b.monthlySupportTotal }
        }
        let byName = a.name.localizedStandardCompare(b.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return a.creatorID < b.creatorID
    }

    /// nil when equal. Dates present sort before missing dates.
    private static func compareDatesDescending(_ a: Date?, _ b: Date?) -> Bool? {
        switch (a, b) {
        case let (x?, y?): return x == y ? nil : x > y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return nil
        }
    }
}

/// Local creator search (SPEC §33: 完全ローカル検索 / Memo).
enum CreatorSearch {
    /// All whitespace-separated tokens must appear in name, creatorID, memo or profile text.
    /// Case-, diacritic- and width-insensitive (全角/半角).
    static func matches(_ facts: CreatorFilterFacts, query: String) -> Bool {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return true }
        let haystacks = [facts.name, facts.creatorID, facts.memo, facts.profileText]
        return tokens.allSatisfy { token in
            haystacks.contains { $0.range(of: token, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
        }
    }

    static func tokenize(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map(String.init).map { token in
            // "@creator" searches creatorID too.
            token.hasPrefix("@") && token.count > 1 ? String(token.dropFirst()) : token
        }
    }
}

extension CreatorListFilter {
    /// Filter + search + sort in one pass. Returns facts in display order.
    static func apply(_ items: [CreatorFilterFacts], filter: CreatorListFilter, query: String,
                      sort: CreatorListSort = .recommended) -> [CreatorFilterFacts] {
        items
            .filter { filter.matches($0) && CreatorSearch.matches($0, query: query) }
            .sorted(by: sort.areInIncreasingOrder)
    }

    /// Number of creators per chip (for chip badges), ignoring the search query.
    static func counts(_ items: [CreatorFilterFacts]) -> [CreatorListFilter: Int] {
        var result: [CreatorListFilter: Int] = [:]
        for filter in CreatorListFilter.allCases {
            result[filter] = items.lazy.filter(filter.matches).count
        }
        return result
    }
}

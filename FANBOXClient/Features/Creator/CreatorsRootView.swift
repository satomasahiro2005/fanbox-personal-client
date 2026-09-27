import SwiftUI
import SwiftData

/// クリエイター tab (SPEC §9): creators as entities above accounts, rendered from the local DB (SPEC §3.1).
struct CreatorsRootView: View {
    @Environment(AppEnvironment.self) private var env

    @Query(sort: \Creator.name) private var creators: [Creator]
    @Query(filter: #Predicate<Support> { $0.statusRaw == "active" }) private var activeSupports: [Support]
    @Query(FetchDescriptorFactory.enabledAccounts()) private var accounts: [Account]

    @State private var filter: CreatorListFilter = .all
    @State private var sort: CreatorListSort = .recommended
    @State private var query = ""
    /// creatorID → newest local post date (fallback for creators whose `latestPostAt` is not denormalized yet).
    @State private var localLatestPostAt: [String: Date] = [:]

    var body: some View {
        let model = CreatorsListModel(creators: creators, activeSupports: activeSupports, accounts: accounts,
                                      localLatestPostAt: localLatestPostAt)
        let rows = CreatorListFilter.apply(model.facts, filter: filter, query: query, sort: sort)
        let counts = CreatorListFilter.counts(model.facts)

        List {
            if let error = env.coordinator.lastError {
                Section {
                    SyncStatusBanner(error: error, lastSync: env.coordinator.lastRefreshAt)
                        .listRowSeparator(.hidden)
                }
            }
            Section {
                ForEach(rows, id: \.creatorID) { facts in
                    if let creator = model.creatorsByID[facts.creatorID] {
                        NavigationLink(value: AppRoute.creator(creatorID: facts.creatorID)) {
                            CreatorListRow(creator: creator, facts: facts,
                                           supportingAccounts: model.supportingAccounts(creatorID: facts.creatorID))
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                toggleFavorite(creator)
                            } label: {
                                Label(creator.isFavorite ? "お気に入り解除" : "お気に入り",
                                      systemImage: creator.isFavorite ? "star.slash" : "star")
                            }
                            .tint(.yellow)
                        }
                        .contextMenu {
                            Button {
                                toggleFavorite(creator)
                            } label: {
                                Label(creator.isFavorite ? "お気に入り解除" : "お気に入りに追加",
                                      systemImage: creator.isFavorite ? "star.slash" : "star")
                            }
                        }
                        .accessibilityIdentifier("creatorRow.\(facts.creatorID)")
                    }
                }
            } header: {
                // Plain-style section headers stay pinned, so the chips remain reachable while scrolling.
                filterBar(counts: counts)
                    .listRowInsets(EdgeInsets())
                    .textCase(nil)
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("creatorsList")
        .overlay {
            if creators.isEmpty {
                EmptyStateView(title: "クリエイターがいません", systemImage: "person.2",
                               message: "アカウントを追加して同期すると、支援中・フォロー中のクリエイターが表示されます")
            } else if rows.isEmpty {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    EmptyStateView(title: "該当するクリエイターがいません", systemImage: filter.systemImage ?? "line.3.horizontal.decrease.circle",
                                   message: "「\(filter.title)」に一致するクリエイターはいません")
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query, prompt: "クリエイター・メモを検索")
        .refreshable {
            await env.coordinator.refreshNow()
            reloadLocalPostDates()
        }
        .navigationTitle("クリエイター")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("並び順", selection: $sort) {
                        ForEach(CreatorListSort.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("並び順")
                .accessibilityIdentifier("creatorsSortMenu")
            }
        }
        .task { reloadLocalPostDates() }
    }

    private func filterBar(counts: [CreatorListFilter: Int]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CreatorListFilter.allCases) { f in
                    CreatorsFilterChip(title: f.title, systemImage: f.systemImage, count: f == .all ? nil : counts[f],
                                       isSelected: filter == f) {
                        withAnimation(.snappy) { filter = f }
                    }
                    .accessibilityIdentifier("creatorFilter.\(f.rawValue)")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func toggleFavorite(_ creator: Creator) {
        creator.isFavorite.toggle()
        env.store.save()
    }

    /// Newest local post date per creator. Cheap (two properties only) and never touches the network.
    private func reloadLocalPostDates() {
        var descriptor = FetchDescriptor<Post>(predicate: ReaderPostQueries.visible, sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        descriptor.propertiesToFetch = [\.creatorID, \.publishedAt]
        descriptor.fetchLimit = 5000
        var result: [String: Date] = [:]
        for post in env.store.fetch(descriptor) where result[post.creatorID] == nil {
            result[post.creatorID] = post.publishedAt
        }
        if result != localLatestPostAt { localLatestPostAt = result }
    }
}

/// Derived, per-render lookup tables for the creator list.
@MainActor
struct CreatorsListModel {
    let facts: [CreatorFilterFacts]
    let creatorsByID: [String: Creator]
    private let accountsByID: [String: Account]
    private let supportingAccountIDs: [String: [String]]

    /// `accounts`: the enabled accounts. Supports, relations and totals of disabled accounts are left out.
    init(creators: [Creator], activeSupports: [Support], accounts: [Account], localLatestPostAt: [String: Date]) {
        let inputs = activeSupports.map(CreatorSupportInput.init)
        let known = Set(accounts.map(\.id))
        let totals = CreatorSupportSummary.totalsByCreator(inputs, knownAccountIDs: known)
        let ownCreatorIDs = Set(accounts.compactMap(\.creatorID))
        facts = creators.map {
            CreatorFilterFacts(creator: $0, activeSupportTotals: totals, ownCreatorIDs: ownCreatorIDs, enabledAccountIDs: known,
                               localLatestPostAt: localLatestPostAt)
        }
        creatorsByID = Dictionary(creators.map { ($0.creatorID, $0) }, uniquingKeysWith: { first, _ in first })
        accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        supportingAccountIDs = CreatorSupportSummary.accountsByCreator(inputs.filter { known.contains($0.accountID) },
                                                                       accountOrder: accounts.map(\.id))
    }

    func supportingAccounts(creatorID: String) -> [Account] {
        (supportingAccountIDs[creatorID] ?? []).compactMap { accountsByID[$0] }
    }
}

/// Row: avatar, name, support summary ("¥6,500 / 月" + per-account badges), following badge, latest post date.
struct CreatorListRow: View {
    let creator: Creator
    let facts: CreatorFilterFacts
    let supportingAccounts: [Account]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AvatarView(url: creator.iconURL, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(creator.name.isEmpty ? creator.creatorID : creator.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if creator.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("お気に入り")
                    }
                }
                if facts.monthlySupportTotal > 0 || !supportingAccounts.isEmpty {
                    HStack(spacing: 8) {
                        Text(CreatorSupportSummary.monthlyText(facts.monthlySupportTotal))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.primary)
                        CreatorAccountDots(accounts: supportingAccounts)
                    }
                }
                HStack(spacing: 6) {
                    if facts.isOwnCreator {
                        PillLabel(text: "自分", systemImage: "paintbrush.pointed", tint: .purple)
                    }
                    if facts.isSupported {
                        PillLabel(text: "支援中", tint: .pink)
                    }
                    if facts.isFollowed {
                        PillLabel(text: "フォロー中", tint: .teal)
                    }
                    if let latest = facts.latestPostAt {
                        Text("最新投稿\(Formatters.shortDate(latest))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}


import SwiftUI
import SwiftData

/// ホーム / 統合フィード (SPEC §5). Renders from the local DB immediately (SPEC §3.1); pull-to-refresh asks the
/// coordinator for a differential sync and never blocks the list.
struct HomeRootView: View {
    @Environment(AppEnvironment.self) private var env
    /// Per-device UI conveniences (not data): the last chosen chip / account filter.
    @AppStorage("home.filterKind") private var kindRaw = HomeFeedFilterKind.all.rawValue
    @AppStorage("home.accountFilter") private var accountFilterRaw = ""
    @State private var limit = HomeRootView.pageSize

    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)]) private var allAccounts: [Account]

    static let pageSize = 300

    private var accounts: [Account] { allAccounts.filter(\.enabled) }

    private var kind: HomeFeedFilterKind { HomeFeedFilterKind(rawValue: kindRaw) ?? .all }

    /// The stored account filter, ignored when that account no longer exists / is disabled.
    private var accountFilterID: String? {
        guard !accountFilterRaw.isEmpty, accounts.contains(where: { $0.id == accountFilterRaw }) else { return nil }
        return accountFilterRaw
    }

    private var filter: HomeFeedFilter { HomeFeedFilter(kind: kind, accountID: accountFilterID) }

    var body: some View {
        HomeFeedList(filter: filter, limit: limit, hasAccounts: !accounts.isEmpty) {
            limit += HomeRootView.pageSize
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .navigationTitle("ホーム")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { accountFilterMenu }
        }
        .onChange(of: filter) { _, _ in limit = HomeRootView.pageSize }
    }

    // MARK: Header (chips + status)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HomeFeedFilterKind.allCases) { k in
                        HomeFilterChip(title: k.title, systemImage: k == .all ? nil : k.systemImage, isSelected: k == kind) {
                            kindRaw = k.rawValue
                        }
                        .accessibilityIdentifier(k.accessibilityID)
                    }
                }
                .padding(.horizontal)
            }
            statusLine
            SyncStatusBanner(error: env.coordinator.lastError, lastSync: env.coordinator.lastRefreshAt)
                .padding(.horizontal)
            AccountReloginBanner()
                .padding(.horizontal)
        }
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var statusLine: some View {
        let offline = env.networkMode.effectiveMode == .offline
        let refreshing = env.coordinator.isRefreshing
        if offline || refreshing || accountFilterID != nil {
            HStack(spacing: 6) {
                if let id = accountFilterID {
                    AccountBadge(accountID: id)
                    Button {
                        accountFilterRaw = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("アカウントの絞り込みを解除")
                }
                Spacer(minLength: 0)
                if refreshing {
                    ProgressView().controlSize(.mini)
                    Text("同期中…").font(.caption2).foregroundStyle(.secondary)
                }
                if offline {
                    PillLabel(text: "Offline", systemImage: "wifi.slash", tint: .orange)
                        .accessibilityIdentifier("homeOfflinePill")
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: Account filter

    private var accountFilterMenu: some View {
        Menu {
            Picker("アカウント", selection: $accountFilterRaw) {
                Text("すべてのアカウント").tag("")
                ForEach(accounts) { account in
                    Text(account.displayName).tag(account.id)
                }
            }
        } label: {
            Image(systemName: accountFilterID == nil ? "person.2.circle" : "person.2.circle.fill")
        }
        .accessibilityLabel("アカウントで絞り込み")
        .accessibilityIdentifier("homeAccountFilter")
        .disabled(accounts.count < 2 && accountFilterID == nil)
    }
}

/// The feed list. Re-created with a new `@Query` whenever the filter / page size changes.
private struct HomeFeedList: View {
    let filter: HomeFeedFilter
    let limit: Int
    let hasAccounts: Bool
    let loadMore: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Query private var posts: [Post]
    @Query(sort: \Plan.fee) private var plans: [Plan]

    init(filter: HomeFeedFilter, limit: Int, hasAccounts: Bool, loadMore: @escaping () -> Void) {
        self.filter = filter
        self.limit = limit
        self.hasAccounts = hasAccounts
        self.loadMore = loadMore
        _posts = Query(filter.descriptor(limit: limit))
    }

    var body: some View {
        let visible = filter.apply(posts)
        let plansByCreator = Dictionary(grouping: plans, by: \.creatorID)
        List {
            ForEach(visible) { post in
                NavigationLink(value: AppRoute.post(postID: post.postID)) {
                    PostCardView(post: post, plans: plansByCreator[post.creatorID] ?? [])
                }
                .accessibilityIdentifier("homePost.\(post.postID)")
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        HomePostUserActions.setRead(post, !post.isRead, store: env.store)
                    } label: {
                        Label(post.isRead ? "未読にする" : "既読にする",
                              systemImage: post.isRead ? "envelope.badge" : "envelope.open")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        HomePostUserActions.toggleFavorite(post, store: env.store)
                    } label: {
                        Label(post.isFavorite ? "お気に入り解除" : "お気に入り", systemImage: post.isFavorite ? "star.slash" : "star")
                    }
                    .tint(.yellow)
                    Button {
                        HomePostUserActions.toggleReadLater(post, store: env.store)
                    } label: {
                        Label(post.isReadLater ? "あとで読む解除" : "あとで読む",
                              systemImage: post.isReadLater ? "bookmark.slash" : "bookmark")
                    }
                    .tint(.orange)
                }
            }
            if posts.count >= limit {
                Button("さらに表示") { loadMore() }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("homeLoadMore")
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("homeFeedList")
        .overlay {
            if visible.isEmpty { emptyState }
        }
        .refreshable {
            await env.coordinator.refreshNow()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !hasAccounts {
            ContentUnavailableView {
                Label("アカウントがありません", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("設定 → アカウント から FANBOX アカウントを追加すると、ここに投稿が表示されます。")
            } actions: {
                Button("設定を開く") { env.router.isSettingsPresented = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("homeOpenSettings")
            }
        } else if filter.kind == .all && filter.accountID == nil {
            ContentUnavailableView {
                Label("まだ投稿がありません", systemImage: "tray")
            } description: {
                Text("下に引っ張って更新してください。表示されない場合は 設定 → アカウント でログイン状態を確認してください。")
            } actions: {
                Button("設定を開く") { env.router.isSettingsPresented = true }
                    .accessibilityIdentifier("homeOpenSettings")
            }
        } else {
            EmptyStateView(title: "該当する投稿がありません", systemImage: "line.3.horizontal.decrease.circle",
                           message: "フィルターを変更してください")
        }
    }
}

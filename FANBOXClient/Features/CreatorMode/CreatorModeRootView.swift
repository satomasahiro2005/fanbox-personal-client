import SwiftData
import SwiftUI

/// SPEC §16 Creator Mode: Dashboard / Posts / Drafts / New Post / Comments / Fans / Plans.
/// Renders from SwiftData immediately; refreshes run in `.task` / `.refreshable` and never block the UI.
struct CreatorModeRootView: View {
    var body: some View {
        CreatorAccountScope { account, creators in
            CreatorModeAccountView(account: account, creatorAccounts: creators)
        }
        .navigationTitle("Creator")
    }
}

/// Error surfaced when "編集" (Post Edit import) fails.
struct CreatorPostEditFailure: Identifiable {
    let id = UUID()
    var postID: String
    var error: RemoteError
}

private struct CreatorModeAccountView: View {
    @Environment(AppEnvironment.self) private var env
    let account: Account
    let creatorAccounts: [Account]
    private let accountID: String
    private let creatorID: String

    @Query private var posts: [Post]
    @Query private var drafts: [Draft]
    @Query private var snapshots: [CreatorDashboardSnapshot]
    @Query private var ownPostComments: [Comment]
    @Query private var fans: [Fan]
    @Query private var plans: [Plan]
    @Query private var syncStates: [SyncState]

    @AppStorage(CreatorModeKeys.selectedAccountID) private var selectedID: String = ""
    @State private var syncError: RemoteError?
    @State private var importingPostID: String?
    @State private var editFailure: CreatorPostEditFailure?
    @State private var draftPendingDeletion: Draft?
    /// `.task` runs again every time the screen reappears; only the first appearance refreshes (plus pull-to-refresh).
    @State private var didInitialLoad = false

    init(account: Account, creatorAccounts: [Account]) {
        self.account = account
        self.creatorAccounts = creatorAccounts
        let accountID = account.id
        let creatorID = account.creatorID ?? ""
        self.accountID = accountID
        self.creatorID = creatorID
        _posts = Query(filter: #Predicate<Post> { $0.creatorID == creatorID }, sort: [SortDescriptor(\.publishedAt, order: .reverse)])
        _drafts = Query(filter: #Predicate<Draft> { $0.accountID == accountID }, sort: [SortDescriptor(\.updatedAt, order: .reverse)])
        _snapshots = Query(filter: #Predicate<CreatorDashboardSnapshot> { $0.accountID == accountID },
                           sort: [SortDescriptor(\.month, order: .reverse)])
        _ownPostComments = Query(filter: #Predicate<Comment> { $0.isOnOwnPost && !$0.isRemoved })
        _fans = Query(filter: #Predicate<Fan> { $0.accountID == accountID })
        _plans = Query(filter: #Predicate<Plan> { $0.creatorID == creatorID }, sort: [SortDescriptor(\.fee)])
        _syncStates = Query(filter: #Predicate<SyncState> { $0.accountID == accountID })
    }

    /// My posts on FANBOX (posts deleted there are hidden, their local metadata is kept).
    private var visiblePosts: [Post] { posts.filter { !$0.isRemovedFromFanbox } }

    private var currentMonth: String { CreatorFormatting.monthKey() }
    private var currentSnapshot: CreatorDashboardSnapshot? { snapshots.first { $0.month == currentMonth } }

    private var myComments: [Comment] {
        let postIDs = Set(posts.map(\.postID))
        return ownPostComments.filter { $0.fetchedByAccountID == accountID || $0.creatorID == creatorID || postIDs.contains($0.postID) }
    }

    private var unreadCommentCount: Int { myComments.filter { !$0.isRead && !$0.isOwn }.count }

    private var lastSync: Date? {
        let creatorResources = Set([SyncResource.creatorDashboard, .creatorPosts, .creatorComments, .fans].map(\.rawValue))
        return syncStates.filter { creatorResources.contains($0.resourceRaw) }.compactMap(\.lastSuccessfulSync).max()
    }

    var body: some View {
        List {
            if creatorAccounts.count > 1 {
                Section {
                    Picker("アカウント", selection: Binding(get: { accountID }, set: { selectedID = $0 })) {
                        ForEach(creatorAccounts) { a in
                            Text(a.displayName).tag(a.id)
                        }
                    }
                    .accessibilityIdentifier("creatorAccountPicker")
                }
            }

            if syncError != nil {
                Section {
                    SyncStatusBanner(error: syncError, lastSync: lastSync)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
            }

            dashboardSection
            newPostSection
            draftsSection
            postsSection
            manageSection
            webSection
        }
        .accessibilityIdentifier("creatorModeList")
        .task(id: accountID) {
            guard !didInitialLoad else { return }
            didInitialLoad = true
            await refresh(reason: .onDemand)
        }
        .refreshable { await refresh(reason: .userRefresh) }
        .overlay {
            if importingPostID != nil {
                ProgressView("編集用データを取得中…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("編集を開始できませんでした", isPresented: Binding(get: { editFailure != nil }, set: { if !$0 { editFailure = nil } }),
               presenting: editFailure) { failure in
            Button("Web エディタで開く") {
                env.web.openWeb(account: accountID, destination: .managePostEditor(postID: failure.postID),
                                purpose: .fallback(reason: failure.error.userMessage))
            }
            Button("閉じる", role: .cancel) {}
        } message: { failure in
            Text(failure.error.userMessage)
        }
        .confirmationDialog("この下書きを削除しますか？", isPresented: Binding(get: { draftPendingDeletion != nil },
                                                                   set: { if !$0 { draftPendingDeletion = nil } }),
                            titleVisibility: .visible, presenting: draftPendingDeletion) { draft in
            Button("削除", role: .destructive) { env.drafts.deleteDraft(draftID: draft.id) }
        } message: { _ in
            Text("ローカルの下書きと添付メディアを削除します。FANBOX 上の投稿は削除されません。")
        }
    }

    // MARK: Sections

    private var dashboardSection: some View {
        Section {
            let s = currentSnapshot
            CreatorMetricRow(title: "支援者",
                             display: CreatorFormatting.metric(s?.supporterCount, source: s?.supporterCountSource ?? .unavailable) { "\($0) 人" },
                             identifier: "creatorMetricSupporters")
            CreatorMetricRow(title: "支援額",
                             display: CreatorFormatting.metric(s?.earnings, source: s?.earningsSource ?? .unavailable) { Formatters.yen($0) },
                             identifier: "creatorMetricEarnings")
            CreatorMetricRow(title: "投稿",
                             display: CreatorFormatting.metric(s?.postCount, source: s?.postCountSource ?? .unavailable),
                             identifier: "creatorMetricPosts")
            CreatorMetricRow(title: "コメント",
                             display: CreatorFormatting.metric(s?.commentCount, source: s?.commentCountSource ?? .unavailable),
                             identifier: "creatorMetricComments")
        } header: {
            Text("今月（\(CreatorFormatting.monthTitle(currentMonth))）")
        } footer: {
            if let s = currentSnapshot {
                Text("取得: \(Formatters.shortDate(s.fetchedAt)) \(Formatters.time(s.fetchedAt))・取得できない統計は表示しません")
            } else {
                Text("まだ取得していません。取得できない統計は推定せず「取得不可」と表示します。")
            }
        }
    }

    private var newPostSection: some View {
        Section {
            Button {
                let draft = env.drafts.createDraft(accountID: accountID)
                env.router.open(.draft(draftID: draft.id))
            } label: {
                Label("新規投稿", systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("creatorNewPostButton")
        } footer: {
            Text("下書きは端末内に自動保存され、オフラインでも作成・編集できます。")
        }
    }

    private var draftsSection: some View {
        Section {
            if drafts.isEmpty {
                Text("ローカル下書きはありません").foregroundStyle(.secondary)
            }
            ForEach(drafts) { draft in
                NavigationLink(value: AppRoute.draft(draftID: draft.id)) {
                    CreatorDraftRow(draft: draft)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("削除", role: .destructive) { draftPendingDeletion = draft }
                }
                .accessibilityIdentifier("creatorDraftRow")
            }
        } header: {
            Text("下書き（\(drafts.count)）")
        }
    }

    private var postsSection: some View {
        Section {
            let visible = visiblePosts
            if visible.isEmpty {
                Text("取得済みの投稿はありません").foregroundStyle(.secondary)
            }
            ForEach(visible.prefix(10)) { post in
                postRow(post)
            }
            if visible.count > 10 {
                NavigationLink {
                    CreatorManagedPostsView(accountID: accountID, creatorID: creatorID)
                } label: {
                    Text("すべての投稿（\(visible.count)）")
                }
                .accessibilityIdentifier("creatorAllPostsLink")
            }
        } header: {
            Text("投稿")
        }
    }

    private func postRow(_ post: Post) -> some View {
        HStack(spacing: 8) {
            NavigationLink(value: AppRoute.post(postID: post.postID)) {
                CreatorManagedPostRow(post: post)
            }
            Button("編集") { startEditing(post) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(importingPostID != nil)
                .accessibilityIdentifier("creatorEditPostButton")
        }
        .swipeActions(edge: .trailing) {
            Button("編集") { startEditing(post) }.tint(.accentColor)
        }
        .contextMenu {
            Button { startEditing(post) } label: { Label("編集", systemImage: "pencil") }
            Button {
                env.web.openWeb(account: accountID, destination: .managePostEditor(postID: post.postID), purpose: .browse)
            } label: { Label("Web エディタで開く", systemImage: "safari") }
        }
    }

    private var manageSection: some View {
        Section {
            NavigationLink(value: AppRoute.creatorComments) {
                HStack {
                    Label("コメント", systemImage: "bubble.left.and.bubble.right")
                    Spacer()
                    CreatorCountBadge(count: unreadCommentCount)
                }
            }
            .accessibilityIdentifier("creatorCommentsLink")
            NavigationLink(value: AppRoute.fans) {
                HStack {
                    Label("ファン", systemImage: "person.3")
                    Spacer()
                    if !fans.isEmpty {
                        Text("\(fans.filter { $0.state == .supporting }.count) 人支援中").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("creatorFansLink")
            NavigationLink(value: AppRoute.plans(creatorID: creatorID)) {
                HStack {
                    Label("プラン", systemImage: "list.bullet.rectangle")
                    Spacer()
                    if !plans.isEmpty {
                        Text("\(plans.count) 件").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("creatorPlansLink")
        } header: {
            Text("管理")
        }
    }

    private var webSection: some View {
        Section {
            Button {
                env.web.openWeb(account: accountID, destination: .managePosts, purpose: .browse)
            } label: {
                Label("Web で投稿管理", systemImage: "safari")
            }
            .accessibilityIdentifier("creatorWebManagePosts")
            Button {
                env.web.openWeb(account: accountID, destination: .manageDashboard, purpose: .browse)
            } label: {
                Label("Web でダッシュボード", systemImage: "chart.bar")
            }
        } footer: {
            Text("ネイティブで扱えない操作は、このアカウントのログイン状態を保った Web 画面で行えます。")
        }
    }

    // MARK: Actions

    /// Screen-appear refreshes use `.onDemand` and are bounded by `CreatorReadPolicy` (fans ≈ daily, dashboard / comments
    /// 10 min, posts 5 min); pull-to-refresh always fetches. Plans feed the editor's 公開範囲 picker.
    private func refresh(reason: SyncReason) async {
        async let dashboard = env.sync.sync(.creatorDashboard, accountID: accountID, reason: reason)
        async let managed = env.sync.sync(.creatorPosts, accountID: accountID, reason: reason)
        async let comments = env.sync.sync(.creatorComments, accountID: accountID, reason: reason)
        async let fanList = env.sync.sync(.fans, accountID: accountID, reason: reason)
        async let planList = env.sync.sync(.plans, accountID: accountID, scope: creatorID, reason: reason)
        let outcomes = await [dashboard, managed, comments, fanList, planList]
        syncError = outcomes.compactMap(\.error).first
    }

    private func startEditing(_ post: Post) {
        guard importingPostID == nil else { return }
        importingPostID = post.postID
        Task {
            defer { importingPostID = nil }
            do {
                let draft = try await env.drafts.importRemotePost(postID: post.postID, accountID: accountID)
                env.router.open(.draft(draftID: draft.id))
            } catch {
                editFailure = CreatorPostEditFailure(postID: post.postID, error: RemoteError.creatorWrapping(error))
            }
        }
    }
}

// MARK: - Rows

struct CreatorDraftRow: View {
    let draft: Draft

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(draft.title.isEmpty ? "（無題）" : draft.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if draft.remotePostID != nil {
                    PillLabel(text: "投稿の編集", systemImage: "pencil", tint: .purple)
                }
            }
            HStack(spacing: 6) {
                PillLabel(text: draft.status.creatorLabel, tint: draft.status.creatorTint)
                if let remote = draft.remoteStatus, remote != .unknown {
                    PillLabel(text: "FANBOX: \(remote.creatorLabel)", tint: remote.creatorTint)
                }
                if draft.webHandoffAt != nil {
                    PillLabel(text: "Web で仕上げ", systemImage: "safari", tint: .orange)
                }
                let images = draft.blocks.filter { $0.kind == .image }.count
                if images > 0 {
                    Label("\(images)", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                }
                Text("更新 \(Formatters.relative(draft.updatedAt))").font(.caption).foregroundStyle(.secondary)
            }
            if let error = draft.lastError, draft.status == .failed {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
    }
}

struct CreatorManagedPostRow: View {
    let post: Post

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(post.title.isEmpty ? "（無題）" : post.title)
                .font(.body.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                if let status = post.managedStatus {
                    PillLabel(text: status.creatorLabel, tint: status.creatorTint)
                        .accessibilityIdentifier("creatorPostStatus")
                }
                Text(Formatters.shortDate(post.publishedAt)).font(.caption).foregroundStyle(.secondary)
                PillLabel(text: post.feeRequired == 0 ? "全体公開" : Formatters.yen(post.feeRequired), tint: .purple)
                if post.commentCount > 0 {
                    Label("\(post.commentCount)", systemImage: "bubble.left").font(.caption).foregroundStyle(.secondary)
                }
                if post.likeCount > 0 {
                    Label("\(post.likeCount)", systemImage: "heart").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Full list of my creator posts (local DB, newest first).
struct CreatorManagedPostsView: View {
    @Environment(AppEnvironment.self) private var env
    let accountID: String
    @Query private var posts: [Post]
    @State private var query = ""
    @State private var importing = false
    @State private var editFailure: CreatorPostEditFailure?

    init(accountID: String, creatorID: String) {
        self.accountID = accountID
        _posts = Query(filter: #Predicate<Post> { $0.creatorID == creatorID }, sort: [SortDescriptor(\.publishedAt, order: .reverse)])
    }

    private var filtered: [Post] {
        let visible = posts.filter { !$0.isRemovedFromFanbox }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return visible }
        return visible.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List(filtered) { post in
            NavigationLink(value: AppRoute.post(postID: post.postID)) {
                CreatorManagedPostRow(post: post)
            }
            .swipeActions(edge: .trailing) {
                Button("編集") { edit(post) }.tint(.accentColor)
            }
        }
        .searchable(text: $query, prompt: "タイトルで検索")
        .navigationTitle("投稿")
        .overlay {
            if importing { ProgressView() }
        }
        .alert("編集を開始できませんでした", isPresented: Binding(get: { editFailure != nil }, set: { if !$0 { editFailure = nil } }),
               presenting: editFailure) { failure in
            Button("Web エディタで開く") {
                env.web.openWeb(account: accountID, destination: .managePostEditor(postID: failure.postID),
                                purpose: .fallback(reason: failure.error.userMessage))
            }
            Button("閉じる", role: .cancel) {}
        } message: { failure in
            Text(failure.error.userMessage)
        }
    }

    private func edit(_ post: Post) {
        importing = true
        Task {
            defer { importing = false }
            do {
                let draft = try await env.drafts.importRemotePost(postID: post.postID, accountID: accountID)
                env.router.open(.draft(draftID: draft.id))
            } catch {
                editFailure = CreatorPostEditFailure(postID: post.postID, error: RemoteError.creatorWrapping(error))
            }
        }
    }
}

import SwiftUI
import SwiftData

/// 投稿詳細 (SPEC §6). Renders the locally cached post immediately and never waits for the network (SPEC §3.1 / §26).
/// The viewing account is chosen automatically (SPEC §8) and can always be overridden from the toolbar (SPEC §3.2).
struct PostDetailView: View {
    let postID: String

    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL

    @Query private var posts: [Post]
    @Query private var blocks: [PostBlock]
    @Query private var accesses: [PostAccess]
    @Query private var comments: [Comment]
    @Query private var localTags: [PostTag]
    @Query private var plans: [Plan]
    @Query(FetchDescriptorFactory.enabledAccounts()) private var accounts: [Account]

    /// Account currently used for this post (automatic or manual).
    @State private var selectedAccountID: String?
    /// Manual override from the "閲覧アカウント" menu (nil = automatic).
    @State private var accountOverride: String?
    @State private var didStart = false
    @State private var isRefreshing = false
    /// A refresh was requested while another was running (e.g. account switched mid-fetch) → run once more afterwards.
    @State private var refreshAgain: Bool?
    @State private var refreshError: RemoteError?
    @State private var viewerStart: PostDetailImageViewerStart?
    /// Restricted post → payment flow sheet (SPEC §14).
    @State private var paymentRequest: PaymentFlowRequest?
    @State private var showTagMemo = false
    @State private var pendingLike: Bool?
    @State private var alertMessage: String?
    @State private var confirmClearCache = false
    /// The automatic choice already triggered its one extra fetch (see `refresh`).
    @State private var didRefetchForSelection = false
    /// The user set 既読 / 未読 by hand on this screen: never overwritten automatically.
    @State private var userChangedReadState = false
    /// "Creator を開く": pushed on whichever NavigationStack hosts this screen (tab or the notification sheet).
    @State private var showCreator = false

    init(postID: String) {
        self.postID = postID
        _posts = Query(filter: #Predicate<Post> { $0.postID == postID })
        _blocks = Query(filter: #Predicate<PostBlock> { $0.postID == postID }, sort: \PostBlock.index)
        _accesses = Query(filter: #Predicate<PostAccess> { $0.postID == postID })
        _comments = Query(filter: #Predicate<Comment> { $0.postID == postID && !$0.isRemoved },
                          sort: \Comment.createdAt, order: .reverse)
        _localTags = Query(filter: #Predicate<PostTag> { $0.postID == postID }, sort: \PostTag.tagName)
        _plans = Query(sort: \Plan.fee)
    }

    private var post: Post? { posts.first }
    private var enabledAccountIDs: Set<String> { Set(accounts.map(\.id)) }
    private var creatorPlans: [Plan] {
        guard let creatorID = post?.creatorID else { return [] }
        return plans.filter { $0.creatorID == creatorID }
    }

    var body: some View {
        Group {
            if let post {
                content(post)
            } else if isRefreshing || !didStart {
                ProgressView("読み込み中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("postDetailLoading")
            } else {
                missingState
            }
        }
        .navigationTitle(post?.title ?? "投稿")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await start() }
        .environment(\.openURL, OpenURLAction { url in
            if PostDetailEmbedLink.isFanboxHost(url), let account = browserAccountID {
                env.web.openWeb(account: account, destination: .url(url))
                return .handled
            }
            return .systemAction
        })
        .fullScreenCover(item: $viewerStart) { start in
            ImageViewer(items: imageItems, startIndex: start.index, postID: postID, accountID: selectedAccountID)
        }
        .navigationDestination(isPresented: $showCreator) {
            if let creatorID = post?.creatorID {
                CreatorDetailView(creatorID: creatorID)
            }
        }
        .paymentFlowSheet($paymentRequest)
        .sheet(isPresented: $showTagMemo) {
            TagMemoEditorView(postID: postID)
        }
        .confirmationDialog("この投稿のキャッシュ (画像・添付) を削除しますか？", isPresented: $confirmClearCache, titleVisibility: .visible) {
            Button("Cache 削除", role: .destructive) { env.media.clearCache(postID: postID) }
        } message: {
            Text("本文とタイトルは残ります。")
        }
        .alert("操作できませんでした", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Content

    private func content(_ post: Post) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                SyncStatusBanner(error: refreshError, lastSync: post.bodyFetchedAt ?? post.fetchedAt)
                PostDetailHeader(post: post, plans: creatorPlans, enabledAccountIDs: enabledAccountIDs,
                                 localTags: localTags.map(\.tagName)) {
                    showTagMemo = true
                }
                accountHint(post)
                bodySection(post)
                PostDetailFooter(post: post, isLiked: pendingLike ?? post.isLiked, likeCount: displayedLikeCount(post),
                                 isLikeBusy: pendingLike != nil) {
                    toggleLike(post)
                }
                PostDetailCommentPreview(postID: postID, comments: Array(comments.prefix(3)),
                                   totalCount: max(post.commentCount, comments.count))
                prevNextLinks(post)
            }
            .padding()
        }
        .refreshable { await refresh(force: true) }
        .accessibilityIdentifier("postDetailScroll")
    }

    @ViewBuilder
    private func bodySection(_ post: Post) -> some View {
        if !blocks.isEmpty {
            if blocks.allSatisfy({ $0.kind != .image }), post.coverImageURL != nil {
                RemoteImageView(thumbnailURL: post.coverImageURL, displayURL: post.coverImageURL, maxVariant: .display, postID: postID,
                                creatorID: post.creatorID, accountID: selectedAccountID, contentMode: .fill)
                    // FANBOX covers are ~1200×630; a fixed ratio keeps the layout stable while the image loads.
                    .aspectRatio(1200.0 / 630.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            PostDetailBlocksView(blocks: blocks, context: renderContext(post))
        } else if PostAccountLogic.isRestricted(feeRequired: post.feeRequired, accessAccountIDs: post.accessAccountIDs,
                                                enabledAccountIDs: enabledAccountIDs, hasBlocks: false) {
            PostDetailRestrictedView(excerpt: post.excerpt, feeRequired: post.feeRequired,
                               planTitle: HomePlanLabel.planTitle(feeRequired: post.feeRequired,
                                                                  plans: creatorPlans.map { ($0.fee, $0.title) })) {
                paymentRequest = PaymentFlowRequest(creatorID: post.creatorID, planID: matchingPlanID(post))
            }
        } else if !post.bodyText.isEmpty && post.hasCachedBody {
            Text(post.bodyText).textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if !post.excerpt.isEmpty {
                    Text(post.excerpt).foregroundStyle(.secondary)
                }
                if isRefreshing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("本文を取得中…").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else if post.hasCachedBody {
                    Text("本文はありません").font(.subheadline).foregroundStyle(.secondary)
                } else if PostAccountLogic.offersWebFallback(for: refreshError), let account = browserAccountID {
                    PostDetailWebFallbackCard(error: refreshError, accountID: account) {
                        env.web.openWeb(account: account, destination: .post(creatorID: post.creatorID, postID: postID),
                                        purpose: .fallback(reason: "本文を取得できませんでした"))
                    } retry: {
                        Task { await refresh(force: true) }
                    }
                } else {
                    Text("本文はまだ取得されていません").font(.subheadline).foregroundStyle(.secondary)
                    if SessionEdgeBlockNotice.applies(to: refreshError), let account = browserAccountID {
                        // post.info blocked at the edge (docs/API.md §1.7): the account-aware WebView still works.
                        SessionEdgeBlockNotice {
                            env.web.openWeb(account: account, destination: .post(creatorID: post.creatorID, postID: postID))
                        }
                    }
                    Button("本文を取得") { Task { await refresh(force: true) } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("postFetchBodyButton")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Selected account cannot view, but another one can → offer a one-tap switch (SPEC §3.2 / §8).
    @ViewBuilder
    private func accountHint(_ post: Post) -> some View {
        let selectedCanView = accesses.first { $0.accountID == selectedAccountID }?.canView
        if let selected = selectedAccountID, selectedCanView == false,
           let viewer = post.accessAccountIDs.first(where: { id in id != selected && accounts.contains { $0.id == id } }) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                VStack(alignment: .leading, spacing: 2) {
                    Text("選択中のアカウントでは閲覧できません").font(.subheadline)
                    AccountBadge(accountID: viewer)
                }
                Spacer()
                Button("切り替え") { switchAccount(to: viewer) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("postSwitchToViewableAccount")
            }
            .padding(10)
            .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func prevNextLinks(_ post: Post) -> some View {
        if post.prevPostID != nil || post.nextPostID != nil {
            HStack {
                if let prev = post.prevPostID {
                    NavigationLink(value: AppRoute.post(postID: prev)) {
                        Label("前の投稿", systemImage: "chevron.left")
                    }
                }
                Spacer()
                if let next = post.nextPostID {
                    NavigationLink(value: AppRoute.post(postID: next)) {
                        HStack(spacing: 4) {
                            Text("次の投稿")
                            Image(systemName: "chevron.right")
                        }
                    }
                }
            }
            .font(.subheadline)
            .padding(.top, 8)
        }
    }

    private var missingState: some View {
        VStack(spacing: 12) {
            SyncStatusBanner(error: refreshError, lastSync: nil)
            ContentUnavailableView {
                Label("投稿を表示できません", systemImage: "doc.questionmark")
            } description: {
                Text(refreshError?.userMessage ?? "この投稿はまだ端末に保存されていません。")
            } actions: {
                Button("再試行") { Task { await refresh(force: true) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("postRetryButton")
                if PostAccountLogic.offersWebFallback(for: refreshError), let account = browserAccountID,
                   let creatorID = knownCreatorIDForMissingPost {
                    Button("Web で開く") {
                        env.web.openWeb(account: account, destination: .post(creatorID: creatorID, postID: postID),
                                        purpose: .fallback(reason: "投稿を取得できませんでした"))
                    }
                    .accessibilityIdentifier("postOpenWebFallback")
                }
            }
        }
        .padding()
    }

    /// Creator of a post that is not local yet, when a notification mentioned it (needed for the web URL).
    private var knownCreatorIDForMissingPost: String? {
        let id: String? = postID
        var descriptor = FetchDescriptor<NotificationEvent>(predicate: #Predicate { $0.postID == id && $0.creatorID != nil })
        descriptor.fetchLimit = 1
        return env.store.fetch(descriptor).first?.creatorID
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let post {
                Menu {
                    accountMenuItems
                } label: {
                    Label("閲覧アカウント", systemImage: accountOverride == nil ? "person.crop.circle" : "person.crop.circle.fill")
                }
                .accessibilityIdentifier("postAccountMenu")

                Menu {
                    actionMenuItems(post)
                } label: {
                    Label("操作", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("postActionsMenu")
            }
        }
    }

    @ViewBuilder
    private var accountMenuItems: some View {
        let options = accountOptions
        Section("閲覧アカウント") {
            Button {
                switchAccount(to: nil)
            } label: {
                if accountOverride == nil {
                    Label("自動選択", systemImage: "checkmark")
                } else {
                    Text("自動選択")
                }
            }
            ForEach(options) { option in
                Button {
                    switchAccount(to: option.id)
                } label: {
                    Label {
                        Text(option.name)
                        Text(option.statusText)
                    } icon: {
                        Image(systemName: option.id == selectedAccountID ? "checkmark"
                              : option.canView == true ? "eye" : option.canView == false ? "eye.slash" : "questionmark.circle")
                    }
                }
                .accessibilityIdentifier("postAccountOption.\(option.id)")
            }
        }
    }

    @ViewBuilder
    private func actionMenuItems(_ post: Post) -> some View {
        Section {
            Button {
                userChangedReadState = true
                HomePostUserActions.setRead(post, !post.isRead, store: env.store)
            } label: {
                Label(post.isRead ? "未読にする" : "既読にする", systemImage: post.isRead ? "envelope.badge" : "envelope.open")
            }
            Button {
                HomePostUserActions.toggleFavorite(post, store: env.store)
            } label: {
                Label(post.isFavorite ? "お気に入り解除" : "お気に入り", systemImage: post.isFavorite ? "star.slash" : "star")
            }
            Button {
                HomePostUserActions.toggleReadLater(post, store: env.store)
            } label: {
                Label(post.isReadLater ? "あとで読む解除" : "あとで読む", systemImage: post.isReadLater ? "bookmark.slash" : "bookmark")
            }
            Button {
                showTagMemo = true
            } label: {
                Label("タグ・メモ", systemImage: "tag")
            }
        }
        Section {
            if post.offlineState != .saved {
                Button {
                    Task {
                        let summary = await env.offline.save(postID: postID)
                        if let failure = summary.failureReason { alertMessage = failure.message }
                    }
                } label: {
                    Label(env.offline.activeSaves.contains(postID) ? "Offline 保存中…" : "Offline 保存", systemImage: "arrow.down.circle")
                }
                .disabled(env.offline.activeSaves.contains(postID))
            }
            if post.offlineState != .none {
                Button {
                    env.offline.remove(postID: postID)
                } label: {
                    Label("Offline 解除", systemImage: "xmark.circle")
                }
            }
            Button(role: .destructive) {
                confirmClearCache = true
            } label: {
                Label("Cache 削除", systemImage: "trash")
            }
        }
        Section {
            Button {
                if let account = browserAccountID {
                    env.web.openWeb(account: account, destination: .post(creatorID: post.creatorID, postID: postID))
                }
            } label: {
                Label("Browser で開く", systemImage: "safari")
            }
            .disabled(browserAccountID == nil)
            Menu {
                accountMenuItems
            } label: {
                Label("Account 切り替え", systemImage: "person.2.circle")
            }
            Button {
                showCreator = true
            } label: {
                Label("Creator を開く", systemImage: "person.crop.square")
            }
            ShareLink(item: WebDestination.post(creatorID: post.creatorID, postID: postID).url, subject: Text(post.title)) {
                Label("共有", systemImage: "square.and.arrow.up")
            }
        }
    }

    // MARK: - Derived values

    private var browserAccountID: String? { selectedAccountID ?? env.store.mainAccount()?.id }

    private var accountOptions: [PostAccountOption] {
        let accessMap = Dictionary(accesses.map { ($0.accountID, $0.canView) }, uniquingKeysWith: { a, _ in a })
        var cached = Set(accesses.filter(\.bodyCached).map(\.accountID))
        if let post, post.hasCachedBody, let id = post.detailAccountID { cached.insert(id) }
        let best = AccountSelector.bestAccount(postID: postID, store: env.store)
        return PostAccountLogic.options(accounts: accounts.map { ($0.id, $0.displayName, $0.colorHex) }, accesses: accessMap,
                                        cachedAccountIDs: cached, best: best)
    }

    private var imageBlocks: [PostBlock] { blocks.filter { $0.kind == .image } }

    private var imageItems: [ImageViewerItem] {
        imageBlocks.map(ImageViewerItem.init(block:))
    }

    private func renderContext(_ post: Post) -> PostDetailRenderContext {
        PostDetailRenderContext(
            postID: postID,
            creatorID: post.creatorID,
            accountID: selectedAccountID,
            openImage: { key in
                if let index = imageBlocks.firstIndex(where: { $0.key == key }) {
                    viewerStart = PostDetailImageViewerStart(index: index)
                }
            },
            openLink: { url in openLink(url) },
            openInBrowser: {
                if let account = browserAccountID {
                    env.web.openWeb(account: account, destination: .post(creatorID: post.creatorID, postID: postID))
                }
            }
        )
    }

    private func matchingPlanID(_ post: Post) -> String? {
        creatorPlans.filter { $0.fee >= post.feeRequired }.min { $0.fee < $1.fee }?.planID
    }

    private func displayedLikeCount(_ post: Post) -> Int {
        guard let pendingLike, pendingLike != post.isLiked else { return post.likeCount }
        return max(0, post.likeCount + (pendingLike ? 1 : -1))
    }

    // MARK: - Actions

    private func openLink(_ url: URL) {
        if PostDetailEmbedLink.isFanboxHost(url), let account = browserAccountID {
            env.web.openWeb(account: account, destination: .url(url))
        } else {
            openURL(url)
        }
    }

    private func toggleLike(_ post: Post) {
        guard pendingLike == nil else { return }
        let target = !post.isLiked
        pendingLike = target
        Task {
            let error = await RequestContext.$priority.withValue(.interactiveWrite) {
                await env.sync.setLike(postID: postID, liked: target)
            }
            pendingLike = nil
            if let error { alertMessage = error.userMessage }
        }
    }

    private func switchAccount(to id: String?) {
        accountOverride = id
        resolveSelectedAccount()
        Task { await refresh(force: false) }
    }

    private func resolveSelectedAccount() {
        let enabled = env.store.accounts().map(\.id)
        let best = AccountSelector.bestAccount(postID: postID, store: env.store)
        selectedAccountID = PostAccountLogic.effectiveAccountID(override: accountOverride, best: best, enabledAccountIDs: enabled)
    }

    /// First appearance: pick the account, mark read, fetch only what is missing — text first: the body, then the
    /// comment preview, and only then (detached) the auto-save media. Re-appearing (e.g. back from comments) only
    /// refreshes the history timestamp, so a manual 未読 survives navigation.
    private func start() async {
        guard !didStart else {
            touchLastViewed()
            return
        }
        resolveSelectedAccount()
        didStart = true
        markViewed()
        await refresh(force: false)
        markViewed()        // the post may only exist locally after the refresh
        await prefetchCommentsIfNeeded()
        // Media never gates text (SPEC §3.3 / §46): the auto-save download runs on its own.
        let offline = env.offline
        let id = postID
        Task { await offline.postViewed(postID: id) }
    }

    /// Fetches the body when needed (or when forced by pull-to-refresh / retry). Never deletes cached content.
    /// Automatic mode passes no account so the engine walks every account that may read the post (SPEC §8); a manual
    /// choice is fetched with exactly that account.
    private func refresh(force: Bool) async {
        guard !isRefreshing else {
            refreshAgain = (refreshAgain ?? false) || force
            return
        }
        let local = env.store.post(id: postID)
        let selectedCanView = env.store.postAccesses(postID: postID).first { $0.accountID == selectedAccountID }?.canView
        let needed: Bool
        if let local {
            needed = force || PostAccountLogic.needsBodyRefresh(hasCachedBody: local.hasCachedBody, cachedAccountID: local.detailAccountID,
                                                                selectedAccountID: selectedAccountID, selectedCanView: selectedCanView,
                                                                bodyFetchedAt: local.bodyFetchedAt, postUpdatedAt: local.updatedAt)
        } else {
            needed = true
        }
        guard needed else { return }
        isRefreshing = true
        let override = accountOverride
        let error = await RequestContext.$priority.withValue(.interactiveRead) {
            await env.sync.refreshPost(postID: postID, accountID: override, priority: .interactiveRead)
        }
        isRefreshing = false
        refreshError = error
        if accountOverride == nil {
            // A fresh body / access info may change the automatic choice.
            let before = selectedAccountID
            resolveSelectedAccount()
            // Safety net: the choice moved to an account whose body is not local yet (and that may read it) → fetch once
            // more, so the screen never shows a paywall next to a selected account that could read the post.
            if refreshAgain == nil, !didRefetchForSelection, let now = selectedAccountID, now != before,
               PostAccountLogic.needsFetchAfterSelectionChange(
                   selectedAccountID: now, cachedAccountID: env.store.post(id: postID)?.detailAccountID,
                   hasCachedBody: env.store.post(id: postID)?.hasCachedBody ?? false,
                   selectedCanView: env.store.postAccesses(postID: postID).first { $0.accountID == now }?.canView) {
                didRefetchForSelection = true
                refreshAgain = false
            }
        }
        if let again = refreshAgain {
            refreshAgain = nil
            await refresh(force: again)
        }
    }

    /// Comments are small and high priority (SPEC §46): fetch them once when the post says there are some but none are local.
    private func prefetchCommentsIfNeeded() async {
        guard let local = env.store.post(id: postID), local.commentCount > 0, env.store.comments(postID: postID).isEmpty else { return }
        let override = accountOverride
        _ = await RequestContext.$priority.withValue(.interactiveRead) {
            await env.sync.refreshComments(postID: postID, accountID: override, priority: .interactiveRead)
        }
    }

    /// First view: mark read (unless the user chose 既読 / 未読 here) and record the history timestamp.
    private func markViewed() {
        guard let local = env.store.post(id: postID) else { return }
        if !local.isRead, !userChangedReadState {
            local.isRead = true
            local.readAt = .now
        }
        local.lastViewedAt = .now
        env.store.save()
    }

    private func touchLastViewed() {
        guard let local = env.store.post(id: postID) else { return }
        local.lastViewedAt = .now
        env.store.save()
    }
}

/// Identifiable wrapper for the full-screen image viewer.
struct PostDetailImageViewerStart: Identifiable, Hashable {
    let index: Int
    var id: Int { index }
}


import SwiftUI
import SwiftData

/// コメントスレッド (SPEC §21 / §22 / §26). Cached comments render first; the refresh runs in the background.
/// Replies go through `ReplyQueue` (interactiveWrite, works offline) and appear inline with their queue state.
struct CommentThreadView: View {
    let postID: String
    let focusCommentID: String?

    @Environment(AppEnvironment.self) private var env
    @Query private var comments: [Comment]
    @Query private var outgoing: [OutgoingComment]
    @Query private var posts: [Post]
    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)]) private var allAccounts: [Account]

    @State private var draftText = ""
    @State private var replyTargetID: String?
    @State private var composerAccountID: String?
    @State private var isRefreshing = false
    @State private var didStart = false
    @State private var refreshError: RemoteError?
    @State private var didInitialScroll = false
    @State private var scrollRequest: String?
    @State private var pendingDelete: Comment?
    @State private var alertMessage: String?
    /// Queued `.draft` item currently loaded in the composer (hidden from the list while edited).
    @State private var editingDraftID: String?
    @State private var didPreselectReply = false
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(postID: String, focusCommentID: String?) {
        self.postID = postID
        self.focusCommentID = focusCommentID
        _comments = Query(filter: #Predicate<Comment> { $0.postID == postID }, sort: \Comment.createdAt)
        _outgoing = Query(filter: #Predicate<OutgoingComment> { $0.postID == postID }, sort: \OutgoingComment.createdAt)
        _posts = Query(filter: #Predicate<Post> { $0.postID == postID })
    }

    private var post: Post? { posts.first }
    private var accounts: [Account] { allAccounts.filter(\.enabled) }

    /// Deleted comments are kept only as placeholders for their replies.
    private var visibleComments: [Comment] {
        let parentIDs = Set(comments.flatMap { [$0.parentCommentID, $0.rootCommentID].compactMap { $0 } })
        return comments.filter { !$0.isRemoved || parentIDs.contains($0.commentID) }
    }

    private var visibleOutgoing: [OutgoingComment] {
        let known = Set(comments.map(\.commentID))
        let ids = Set(CommentThreadBuilder.visiblePending(outgoing.map { ($0.id, $0.state, $0.sentCommentID) }, knownCommentIDs: known))
        return outgoing.filter { ids.contains($0.id) && $0.id != editingDraftID }
    }

    private var threads: [CommentThread] {
        CommentThreadBuilder.build(visibleComments.map(CommentThreadNode.init) + visibleOutgoing.map(CommentThreadNode.init))
    }

    var body: some View {
        let threads = self.threads
        let commentsByID = Dictionary(comments.map { ($0.commentID, $0) }, uniquingKeysWith: { a, _ in a })
        let outgoingByID = Dictionary(outgoing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rowIDs = threads.flatMap { $0.nodes.map(\.id) }

        ScrollViewReader { proxy in
            List {
                if let post {
                    Text(post.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .listRowSeparator(.hidden)
                }
                ForEach(threads) { thread in
                    if thread.isOrphan {
                        Text("元のコメントは表示できません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden, edges: .bottom)
                    }
                    ForEach(thread.nodes) { node in
                        let isReply = node.id != thread.root.id || thread.isOrphan
                        if node.isPending, let item = outgoingByID[node.id] {
                            HomeOutgoingCommentRow(item: item, isReply: isReply,
                                               replyToName: node.parentID.flatMap { commentsByID[$0]?.authorName },
                                               edit: { editDraft(item) })
                                .id(node.id)
                        } else if let comment = commentsByID[node.id] {
                            commentRow(comment, isReply: isReply, parent: comment.parentCommentID.flatMap { commentsByID[$0] },
                                       rootID: thread.root.id)
                                .id(node.id)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("commentList")
            .overlay {
                if threads.isEmpty {
                    if isRefreshing || !didStart {
                        ProgressView("コメントを読み込み中…")
                    } else {
                        EmptyStateView(title: "コメントはまだありません", systemImage: "bubble.left.and.bubble.right",
                                       message: "最初のコメントを書いてみましょう")
                    }
                }
            }
            .refreshable { await refresh() }
            .safeAreaInset(edge: .top, spacing: 0) {
                if refreshError != nil {
                    SyncStatusBanner(error: refreshError, lastSync: comments.map(\.fetchedAt).max())
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .background(.bar)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer(commentsByID: commentsByID) }
            .onChange(of: rowIDs, initial: true) { _, ids in
                scrollInitially(ids: ids, proxy: proxy)
                scrollToRequested(ids: ids, proxy: proxy)
            }
            .onChange(of: scrollRequest) { _, _ in
                scrollToRequested(ids: rowIDs, proxy: proxy)
            }
        }
        .navigationTitle("コメント")
        .navigationBarTitleDisplayMode(.inline)
        .task { await start() }
        .onDisappear { persistDraft(clearComposer: true) }
        .onChange(of: scenePhase) { _, phase in
            // Keep the text safe if the app is suspended / killed while typing.
            if phase != .active { persistDraft(clearComposer: false) }
        }
        .confirmationDialog("このコメントを削除しますか？", isPresented: Binding(get: { pendingDelete != nil },
                                                                           set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                if let comment = pendingDelete { delete(comment) }
                pendingDelete = nil
            }
        }
        .alert("操作できませんでした", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Rows

    private func commentRow(_ comment: Comment, isReply: Bool, parent: Comment?, rootID: String) -> some View {
        let deleteAccount = deleteAccountID(for: comment)
        let isFocused = comment.commentID == focusCommentID
        return HomeCommentRow(comment: comment, isReply: isReply,
                          replyToName: (parent != nil && parent?.commentID != rootID) ? parent?.authorName : nil,
                          isMine: isMine(comment),
                          reply: {
                              replyTargetID = comment.commentID
                              composerFocused = true
                          })
            .listRowBackground(isFocused ? Color.accentColor.opacity(0.14) : Color.clear)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if deleteAccount != nil && !comment.isRemoved {
                    Button(role: .destructive) {
                        pendingDelete = comment
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                }
            }
            .accessibilityIdentifier(isFocused ? "commentRow.focused" : "commentRow.\(comment.commentID)")
    }

    // MARK: - Composer

    private func composer(commentsByID: [String: Comment]) -> some View {
        let target = replyTargetID.flatMap { commentsByID[$0] }
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let offline = env.networkMode.effectiveMode == .offline
        return VStack(alignment: .leading, spacing: 6) {
            if let target {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left").foregroundStyle(.secondary)
                    Text("\(target.authorName) に返信").font(.caption.weight(.semibold))
                    Text(target.body).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button {
                        replyTargetID = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返信をやめる")
                    .accessibilityIdentifier("commentCancelReply")
                }
            }
            if offline {
                Label("オフラインです。送信待ちとして保存し、接続が戻ったら送信します。", systemImage: "wifi.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            HStack(alignment: .bottom, spacing: 8) {
                accountPicker
                TextField(target == nil ? "コメントを入力" : "返信を入力", text: $draftText, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("commentComposer")
                Button {
                    send(target: target)
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.body.weight(.semibold))
                        .padding(9)
                        .foregroundStyle(.white)
                        .background(trimmed.isEmpty || composerAccountID == nil ? Color.gray : Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty || composerAccountID == nil)
                .accessibilityLabel(offline ? "送信待ちに保存" : "送信")
                .accessibilityIdentifier("commentSendButton")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var accountPicker: some View {
        Menu {
            Picker("投稿するアカウント", selection: Binding(get: { composerAccountID ?? "" }, set: { composerAccountID = $0 })) {
                ForEach(accounts) { account in
                    Text(account.displayName).tag(account.id)
                }
            }
        } label: {
            Group {
                if let id = composerAccountID {
                    AccountBadge(accountID: id, showsName: false)
                        .padding(10)
                } else {
                    Image(systemName: "person.crop.circle.badge.questionmark").padding(6)
                }
            }
            .background(Color.secondary.opacity(0.12), in: Circle())
        }
        .accessibilityLabel("投稿するアカウント")
        .accessibilityIdentifier("commentAccountPicker")
    }

    // MARK: - Actions

    private func send(target: Comment?) {
        let body = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let accountID = composerAccountID else { return }
        let parentID = target?.commentID
        let rootID = target.map { $0.rootCommentID ?? $0.commentID }
        // SPEC §3.3: the reply must feel instant — clear the composer first; the queue persists and sends (interactiveWrite).
        draftText = ""
        replyTargetID = nil
        if let editing = editingDraftID {
            editingDraftID = nil
            env.replies.cancel(id: editing)
        }
        let id = env.replies.submit(postID: postID, body: body, parentCommentID: parentID, rootCommentID: rootID, accountID: accountID)
        if !id.isEmpty { scrollRequest = id }
    }

    /// Loads a queued draft into the composer. The draft row stays in the queue (hidden while edited) until it is sent,
    /// replaced or cleared, so an app kill never loses the text.
    private func editDraft(_ item: OutgoingComment) {
        if editingDraftID != item.id { persistDraft(clearComposer: true) }
        draftText = item.body
        replyTargetID = item.parentCommentID
        if accounts.contains(where: { $0.id == item.accountID }) { composerAccountID = item.accountID }
        editingDraftID = item.id
        composerFocused = true
    }

    /// Keeps unsent composer text as a local draft (SPEC §22 "通信不能時でも返信文を作成できる").
    private func persistDraft(clearComposer: Bool) {
        let body = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = editingDraftID.flatMap { id in outgoing.first { $0.id == id } }
        let target = replyTargetID.flatMap { id in comments.first { $0.commentID == id } }
        let unchanged = existing.map { $0.body == body && $0.parentCommentID == target?.commentID && $0.accountID == composerAccountID }
            ?? false
        if !unchanged {
            if let editing = editingDraftID {
                env.replies.cancel(id: editing)
                editingDraftID = nil
            }
            if !body.isEmpty, let accountID = composerAccountID {
                let id = env.replies.saveDraft(postID: postID, body: body, parentCommentID: target?.commentID,
                                               rootCommentID: target.map { $0.rootCommentID ?? $0.commentID }, accountID: accountID)
                editingDraftID = id.isEmpty ? nil : id
            }
        }
        if clearComposer {
            draftText = ""
            replyTargetID = nil
            editingDraftID = nil
        }
    }

    private func delete(_ comment: Comment) {
        guard let accountID = deleteAccountID(for: comment) else { return }
        let commentID = comment.commentID
        Task {
            let error = await RequestContext.$priority.withValue(.interactiveWrite) {
                await env.sync.deleteComment(commentID: commentID, postID: postID, accountID: accountID)
            }
            if let error { alertMessage = error.userMessage }
        }
    }

    private func start() async {
        if composerAccountID == nil { composerAccountID = defaultAccountID() }
        restoreDraftIfNeeded()
        preselectFocusedReplyTarget()
        guard !didStart else { return }
        didStart = true
        await refresh()
        preselectFocusedReplyTarget()
        markOwnPostCommentsRead()
    }

    /// Opened for a specific comment (notification / preview tap): prepare a reply to it so "通知から即コメント返信"
    /// is one tap on the text field (SPEC §3.3 / §46). The keyboard is not raised automatically.
    private func preselectFocusedReplyTarget() {
        guard !didPreselectReply, replyTargetID == nil, draftText.isEmpty, let focus = focusCommentID,
              let comment = comments.first(where: { $0.commentID == focus }) else { return }
        didPreselectReply = true
        guard !comment.isRemoved, !isMine(comment) else { return }
        replyTargetID = focus
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let owner = ownerAccountID()
        let error = await RequestContext.$priority.withValue(.interactiveRead) {
            await env.sync.refreshComments(postID: postID, accountID: owner, priority: .interactiveRead)
        }
        isRefreshing = false
        refreshError = error
    }

    /// Restores the newest in-app draft into the empty composer.
    private func restoreDraftIfNeeded() {
        guard draftText.isEmpty, editingDraftID == nil,
              let draft = outgoing.filter({ $0.state == .draft && $0.origin == .inApp }).max(by: { $0.createdAt < $1.createdAt })
        else { return }
        editDraft(draft)
        composerFocused = false
    }

    /// Scrolls to a just-submitted item once it shows up in the list.
    private func scrollToRequested(ids: [String], proxy: ScrollViewProxy) {
        guard let id = scrollRequest, ids.contains(id) else { return }
        scrollRequest = nil
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
    }

    private func scrollInitially(ids: [String], proxy: ScrollViewProxy) {
        guard !didInitialScroll, !ids.isEmpty else { return }
        if let focus = focusCommentID {
            guard ids.contains(focus) else { return }   // wait until the focused comment is local
            didInitialScroll = true
            DispatchQueue.main.async { proxy.scrollTo(focus, anchor: .center) }
        } else if let last = ids.last {
            didInitialScroll = true
            DispatchQueue.main.async { proxy.scrollTo(last, anchor: .bottom) }
        }
    }

    private func markOwnPostCommentsRead() {
        var changed = false
        for comment in comments where comment.isOnOwnPost && !comment.isRead {
            comment.isRead = true
            changed = true
        }
        if changed { env.store.save() }
    }

    // MARK: - Account helpers

    private func ownerAccountID() -> String? {
        guard let creatorID = post?.creatorID else { return nil }
        return accounts.first { $0.creatorID == creatorID }?.id
    }

    private func defaultAccountID() -> String? {
        PostAccountLogic.defaultCommentAccountID(postCreatorID: post?.creatorID, isOwnPost: post?.isOwnPost ?? false,
                                                 accounts: accounts.map { ($0.id, $0.creatorID) },
                                                 best: AccountSelector.bestAccount(postID: postID, store: env.store))
    }

    private var accountUserIDs: [(id: String, userIDs: [String], creatorID: String?)] {
        accounts.map { ($0.id, [$0.pixivUserID, $0.fanboxUserID].compactMap { $0 }, $0.creatorID) }
    }

    private func isMine(_ comment: Comment) -> Bool {
        comment.isOwn || accountUserIDs.contains { $0.userIDs.contains(comment.authorUserID) }
    }

    private func deleteAccountID(for comment: Comment) -> String? {
        PostAccountLogic.deleteAccountID(commentIsOwn: comment.isOwn, authorUserID: comment.authorUserID,
                                         fetchedByAccountID: comment.fetchedByAccountID, postCreatorID: post?.creatorID,
                                         commentIsOnOwnPost: comment.isOnOwnPost || (post?.isOwnPost ?? false),
                                         accounts: accountUserIDs)
    }
}

/// One confirmed comment.
struct HomeCommentRow: View {
    let comment: Comment
    let isReply: Bool
    var replyToName: String?
    var isMine: Bool
    let reply: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isReply {
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 2).padding(.leading, 14)
            }
            AvatarView(url: comment.authorIconURL, size: isReply ? 24 : 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.authorName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if isMine { PillLabel(text: "自分", tint: .accentColor) }
                    Spacer(minLength: 4)
                    Text(HomeDateText.format(comment.createdAt)).font(.caption2).foregroundStyle(.secondary)
                }
                if let replyToName {
                    Text("↪︎ \(replyToName)").font(.caption).foregroundStyle(.secondary)
                }
                if comment.isRemoved {
                    Text("このコメントは削除されました").font(.body).italic().foregroundStyle(.secondary)
                } else {
                    Text(comment.body).font(.body).textSelection(.enabled)
                }
                HStack(spacing: 14) {
                    if !comment.isRemoved {
                        Button(action: reply) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrowshape.turn.up.left").imageScale(.small)
                                Text("返信")
                            }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("\(comment.authorName) に返信")
                        .accessibilityIdentifier("commentReply.\(comment.commentID)")
                    }
                    if comment.likeCount > 0 || comment.isLiked {
                        HStack(spacing: 3) {
                            Image(systemName: comment.isLiked ? "heart.fill" : "heart").imageScale(.small)
                            Text("\(comment.likeCount)")
                        }
                        .foregroundStyle(comment.isLiked ? Color.pink : Color.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A local outgoing comment with its queue state (SPEC §22).
struct HomeOutgoingCommentRow: View {
    let item: OutgoingComment
    let isReply: Bool
    var replyToName: String?
    let edit: () -> Void

    @Environment(AppEnvironment.self) private var env

    private var tint: Color {
        switch item.state {
        case .draft: return .secondary
        case .queued, .sending: return .blue
        case .sent: return .green
        case .failed: return .red
        case .needsConfirmation: return .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isReply {
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 2).padding(.leading, 14)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    AccountBadge(accountID: item.accountID)
                    Spacer(minLength: 4)
                    if item.state == .sending { ProgressView().controlSize(.mini) }
                    PillLabel(text: ReplyStateLabel.text(item.state), systemImage: ReplyStateLabel.systemImage(item.state), tint: tint)
                        .accessibilityIdentifier("pendingCommentState")
                }
                if let replyToName {
                    Text("↪︎ \(replyToName)").font(.caption).foregroundStyle(.secondary)
                }
                Text(item.body).font(.body).foregroundStyle(item.state == .sent ? .secondary : .primary)
                if item.state == .failed || item.state == .needsConfirmation, let error = item.lastError, !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                actions
            }
        }
        .padding(8)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("pendingComment.\(item.id)")
    }

    @ViewBuilder
    private var actions: some View {
        let id = item.id
        switch item.state {
        case .failed:
            HStack(spacing: 12) {
                Button("再送") { Task { await env.replies.retry(id: id) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("pendingCommentRetry")
                Button("破棄", role: .destructive) { env.replies.cancel(id: id) }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
        case .needsConfirmation:
            HStack(spacing: 12) {
                Button("送信する") { Task { await env.replies.confirmAndSend(id: id) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pendingCommentConfirm")
                Button("破棄", role: .destructive) { env.replies.cancel(id: id) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("pendingCommentDiscard")
            }
            .font(.caption)
        case .draft:
            HStack(spacing: 12) {
                Button("編集", action: edit)
                    .buttonStyle(.bordered)
                Button("破棄", role: .destructive) { env.replies.cancel(id: id) }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
        case .queued:
            Button("取り消し", role: .destructive) { env.replies.cancel(id: id) }
                .buttonStyle(.borderless)
                .font(.caption)
        case .sending, .sent:
            EmptyView()
        }
    }
}

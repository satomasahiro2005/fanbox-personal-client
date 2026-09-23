import SwiftData
import SwiftUI

/// SPEC §21 Creator Mode comments: 未読 / 全件 / 投稿別 + Thread 表示 (shared `CommentThreadView`), quick reply, delete.
struct CreatorCommentsView: View {
    var body: some View {
        CreatorAccountScope { account, creators in
            CreatorCommentsList(account: account, creatorAccounts: creators)
        }
        .navigationTitle("コメント")
    }
}

enum CreatorCommentSegment: String, CaseIterable, Identifiable {
    case unread, all, byPost
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unread: return "未読"
        case .all: return "全件"
        case .byPost: return "投稿別"
        }
    }
}

/// Pure grouping helpers (unit-tested).
enum CreatorCommentGrouping {
    struct Group: Identifiable, Equatable {
        var postID: String
        var title: String
        var commentIDs: [String]
        var unreadCount: Int
        var latestAt: Date
        var id: String { postID }
    }

    /// Groups comments by post (newest activity first); comments inside a group newest first.
    static func byPost(_ comments: [Comment], titles: [String: String]) -> [Group] {
        Dictionary(grouping: comments, by: \.postID).map { postID, items in
            let sorted = items.sorted { $0.createdAt > $1.createdAt }
            return Group(postID: postID, title: titles[postID].flatMap { $0.isEmpty ? nil : $0 } ?? "投稿 \(postID)",
                         commentIDs: sorted.map(\.commentID), unreadCount: items.filter { !$0.isRead && !$0.isOwn }.count,
                         latestAt: sorted.first?.createdAt ?? .distantPast)
        }
        .sorted { $0.latestAt > $1.latestAt }
    }
}

private struct CreatorCommentsList: View {
    @Environment(AppEnvironment.self) private var env
    let account: Account
    let creatorAccounts: [Account]
    private let accountID: String
    private let creatorID: String

    @Query private var comments: [Comment]
    @Query private var posts: [Post]
    @Query private var pendingReplies: [OutgoingComment]
    @Query private var syncStates: [SyncState]

    @State private var segment: CreatorCommentSegment = .unread
    @State private var replyTarget: Comment?
    @State private var deleteTarget: Comment?
    @State private var errorMessage: String?
    /// Post to open in the account-aware WebView after a failed native delete (SPEC §21 / §40).
    @State private var webFallbackPost: (postID: String, creatorID: String)?
    @State private var syncError: RemoteError?

    init(account: Account, creatorAccounts: [Account]) {
        self.account = account
        self.creatorAccounts = creatorAccounts
        let accountID = account.id
        let creatorID = account.creatorID ?? ""
        self.accountID = accountID
        self.creatorID = creatorID
        _comments = Query(filter: #Predicate<Comment> { $0.isOnOwnPost && !$0.isRemoved }, sort: [SortDescriptor(\.createdAt, order: .reverse)])
        _posts = Query(filter: #Predicate<Post> { $0.creatorID == creatorID })
        _pendingReplies = Query(filter: #Predicate<OutgoingComment> { $0.accountID == accountID })
        let resource = SyncResource.creatorComments.rawValue
        _syncStates = Query(filter: #Predicate<SyncState> { $0.accountID == accountID && $0.resourceRaw == resource })
    }

    private var postTitles: [String: String] {
        Dictionary(posts.map { ($0.postID, $0.title) }, uniquingKeysWith: { a, _ in a })
    }

    private var myComments: [Comment] {
        let postIDs = Set(posts.map(\.postID))
        return comments.filter { $0.fetchedByAccountID == accountID || $0.creatorID == creatorID || postIDs.contains($0.postID) }
    }

    private var unread: [Comment] { myComments.filter { !$0.isRead && !$0.isOwn } }

    private var waitingReplies: Int {
        let waiting: Set<ReplyState> = [.queued, .sending, .failed, .needsConfirmation]
        return pendingReplies.filter { waiting.contains($0.state) }.count
    }

    var body: some View {
        let mine = myComments
        let unreadComments = unread
        List {
            Section {
                Picker("表示", selection: $segment) {
                    ForEach(CreatorCommentSegment.allCases) { s in
                        Text(s == .unread && !unreadComments.isEmpty ? "未読 (\(unreadComments.count))" : s.title).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("creatorCommentSegment")
                if syncError != nil {
                    SyncStatusBanner(error: syncError, lastSync: syncStates.first?.lastSuccessfulSync)
                }
                if waitingReplies > 0 {
                    Label("送信待ちの返信 \(waitingReplies) 件", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            switch segment {
            case .unread:
                if unreadComments.isEmpty {
                    Text("未読のコメントはありません").foregroundStyle(.secondary)
                }
                ForEach(unreadComments) { row($0, showsPost: true) }
            case .all:
                if mine.isEmpty {
                    Text("コメントはまだありません").foregroundStyle(.secondary)
                }
                ForEach(mine) { row($0, showsPost: true) }
            case .byPost:
                let byID = Dictionary(mine.map { ($0.commentID, $0) }, uniquingKeysWith: { a, _ in a })
                ForEach(CreatorCommentGrouping.byPost(mine, titles: postTitles)) { group in
                    Section {
                        ForEach(group.commentIDs.compactMap { byID[$0] }) { row($0, showsPost: false) }
                    } header: {
                        HStack {
                            Text(group.title).lineLimit(1)
                            Spacer()
                            CreatorCountBadge(count: group.unreadCount)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("creatorCommentsList")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CreatorAccountMenu(accounts: creatorAccounts, selected: account)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("すべて既読") { markAllRead() }
                    .disabled(unreadComments.isEmpty)
                    .accessibilityIdentifier("creatorCommentsMarkAllRead")
            }
        }
        .task(id: accountID) { await refresh(reason: .onDemand) }
        .refreshable { await refresh(reason: .userRefresh) }
        .sheet(item: $replyTarget) { comment in
            NavigationStack {
                CreatorQuickReplySheet(comment: comment, accountID: accountID, postTitle: postTitles[comment.postID])
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("このコメントを削除しますか？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible, presenting: deleteTarget) { comment in
            Button("削除", role: .destructive) { delete(comment) }
        } message: { comment in
            Text("\(comment.authorName): \(comment.body)")
        }
        .alert("エラー", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 {
            errorMessage = nil
            webFallbackPost = nil
        } })) {
            if let target = webFallbackPost {
                Button("Web で開く") {
                    env.web.openWeb(account: accountID, destination: .post(creatorID: target.creatorID, postID: target.postID),
                                    purpose: .fallback(reason: "コメントの削除"))
                }
                .accessibilityIdentifier("creatorCommentsOpenWeb")
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func row(_ comment: Comment, showsPost: Bool) -> some View {
        Button {
            comment.isRead = true
            env.router.open(.comments(postID: comment.postID, focusCommentID: comment.commentID))
        } label: {
            CreatorCommentRow(comment: comment, postTitle: showsPost ? postTitles[comment.postID] : nil)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button(comment.isRead ? "未読にする" : "既読にする") { comment.isRead.toggle() }
                .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("削除", role: .destructive) { deleteTarget = comment }
            if !comment.isOwn {
                Button("返信") { replyTarget = comment }.tint(.accentColor)
            }
        }
        .contextMenu {
            if !comment.isOwn {
                Button { replyTarget = comment } label: { Label("返信", systemImage: "arrowshape.turn.up.left") }
            }
            Button { comment.isRead.toggle() } label: {
                Label(comment.isRead ? "未読にする" : "既読にする", systemImage: comment.isRead ? "envelope.badge" : "envelope.open")
            }
            Button(role: .destructive) { deleteTarget = comment } label: { Label("削除", systemImage: "trash") }
        }
        .accessibilityIdentifier("creatorCommentRow")
    }

    private func markAllRead() {
        for comment in unread { comment.isRead = true }
        env.store.save()
    }

    private func delete(_ comment: Comment) {
        let commentID = comment.commentID
        let postID = comment.postID
        let creatorID = comment.creatorID ?? env.store.post(id: postID)?.creatorID
        Task {
            if let error = await env.sync.deleteComment(commentID: commentID, postID: postID, accountID: accountID) {
                // Unsupported / refused by the API (e.g. deleting another user's comment on my post): the web UI of this
                // creator account is the fallback.
                if PostAccountLogic.commentOperationOffersWeb(error), let creatorID {
                    webFallbackPost = (postID, creatorID)
                    errorMessage = "アプリから削除できませんでした（\(error.userMessage)）。Web で開いて、このアカウントで操作できます。"
                } else {
                    errorMessage = "削除できませんでした: \(error.userMessage)"
                }
            }
        }
    }

    private func refresh(reason: SyncReason) async {
        let outcome = await env.sync.sync(.creatorComments, accountID: accountID, reason: reason)
        syncError = outcome.error
    }
}

struct CreatorCommentRow: View {
    let comment: Comment
    var postTitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: comment.authorIconURL, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if !comment.isRead && !comment.isOwn {
                        Circle().fill(.tint).frame(width: 8, height: 8)
                            .accessibilityLabel("未読")
                    }
                    Text(comment.authorName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if comment.isOwn { PillLabel(text: "自分", tint: .purple) }
                    if comment.parentCommentID != nil { PillLabel(text: "返信", tint: .secondary) }
                    Spacer()
                    Text(Formatters.relative(comment.createdAt)).font(.caption).foregroundStyle(.secondary)
                }
                Text(comment.body)
                    .font(.body)
                    .lineLimit(4)
                    .foregroundStyle(.primary)
                if let postTitle {
                    Label(postTitle.isEmpty ? "（無題の投稿）" : postTitle, systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Quick reply from Creator Mode. Goes through the offline-capable reply queue (SPEC §22) as the creator account.
struct CreatorQuickReplySheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let comment: Comment
    let accountID: String
    var postTitle: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(comment.authorName).font(.subheadline.weight(.semibold))
                    Text(comment.body).font(.callout).foregroundStyle(.secondary)
                    if let postTitle { Text(postTitle).font(.caption).foregroundStyle(.tertiary) }
                }
            }
            Section {
                TextField("返信を入力", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focused)
                    .accessibilityIdentifier("creatorReplyField")
                AccountBadge(accountID: accountID)
            } footer: {
                Text("オフラインでも送信キューに保存され、接続後に送信されます。")
            }
        }
        .navigationTitle("返信")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("キャンセル") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("送信") { submit() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("creatorReplySendButton")
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        env.replies.submit(postID: comment.postID, body: body, parentCommentID: comment.commentID,
                           rootCommentID: comment.threadRootID, accountID: accountID)
        comment.isRead = true
        env.store.save()
        dismiss()
    }
}

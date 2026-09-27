import SwiftData
import SwiftUI

/// 送信キュー (SPEC §22): every reply that has not been sent yet, across posts and accounts.
/// Replies that need a decision (送信結果を確認できない / 長時間待機 / 失敗) are listed first with their actions, so a reply
/// written from a notification never silently stays unsent. Reachable from the app-level banner and the inbox.
struct ReplyQueueView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @Query private var items: [OutgoingComment]
    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)]) private var accounts: [Account]
    @State private var busyIDs: Set<String> = []

    init() {
        let states = [ReplyState.draft, .queued, .sending, .needsConfirmation, .failed].map(\.rawValue)
        _items = Query(filter: #Predicate<OutgoingComment> { states.contains($0.stateRaw) }, sort: [SortDescriptor(\.createdAt)])
    }

    var body: some View {
        let attention = items.filter { $0.state == .needsConfirmation || $0.state == .failed }
        let waiting = items.filter { $0.state == .queued || $0.state == .sending }
        let drafts = items.filter { $0.state == .draft }
        List {
            if !attention.isEmpty {
                Section {
                    ForEach(attention, id: \.id) { row($0) }
                } header: {
                    Text("確認が必要")
                }
            }
            if !waiting.isEmpty {
                Section("送信待ち") {
                    ForEach(waiting, id: \.id) { row($0) }
                }
            }
            if !drafts.isEmpty {
                Section("下書き") {
                    ForEach(drafts, id: \.id) { row($0) }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                EmptyStateView(title: "送信待ちの返信はありません", systemImage: "paperplane", message: "返信はすべて送信済みです")
            }
        }
        .navigationTitle("送信キュー")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("replyQueueList")
    }

    private func row(_ item: OutgoingComment) -> some View {
        let accountName = accounts.first { $0.id == item.accountID }?.displayName ?? "不明なアカウント"
        let postTitle = env.store.post(id: item.postID).map { $0.title.isEmpty ? "無題の投稿" : $0.title } ?? "投稿\(item.postID)"
        let busy = busyIDs.contains(item.id) || item.state == .sending
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(postTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                PillLabel(text: ReplyStateLabel.text(item.state), tint: tint(item.state))
            }
            Text("\(accountName)\(item.parentCommentID == nil ? " ・ コメント" : " ・ 返信")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(item.body)
                .font(.callout)
                .lineLimit(4)
            if let error = item.lastError, !error.isEmpty, item.state != .draft {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                switch item.state {
                case .needsConfirmation:
                    Button("送信する") { run(item.id) { await env.replies.confirmAndSend(id: item.id) } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("replyQueueConfirm.\(item.id)")
                case .failed:
                    Button("再試行") { run(item.id) { await env.replies.retry(id: item.id) } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("replyQueueRetry.\(item.id)")
                default:
                    EmptyView()
                }
                Button("スレッドを開く") { openThread(item) }
                    .buttonStyle(.bordered)
                if item.state != .sending {
                    Button("取り消す", role: .destructive) { env.replies.cancel(id: item.id) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("replyQueueCancel.\(item.id)")
                }
            }
            .font(.footnote)
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }

    private func tint(_ state: ReplyState) -> Color {
        switch state {
        case .failed: return .red
        case .needsConfirmation: return .orange
        case .queued, .sending: return .blue
        case .draft, .sent: return .secondary
        }
    }

    private func run(_ id: String, _ action: @escaping @MainActor () async -> Void) {
        busyIDs.insert(id)
        Task {
            await action()
            busyIDs.remove(id)
        }
    }

    private func openThread(_ item: OutgoingComment) {
        let route = AppRoute.comments(postID: item.postID, focusCommentID: item.parentCommentID)
        dismiss()
        env.router.openFromNotification(route)
    }
}

import SwiftData
import SwiftUI

/// Account management (SPEC §7): list / add via login / demo / main / enable / reorder / remove / session state.
struct AccountsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)]) private var allAccounts: [Account]
    @State private var pendingDeletionID: String?
    @State private var isValidatingAll = false

    /// Login placeholders are not real accounts yet.
    private var accounts: [Account] { allAccounts.filter { !AccountService.isPlaceholder($0) } }

    var body: some View {
        List {
            Section {
                if accounts.isEmpty {
                    EmptyStateView(title: "アカウントがありません", systemImage: "person.crop.circle.badge.plus",
                                   message: "「アカウントを追加」からpixiv / FANBOXにログインしてください。")
                }
                ForEach(accounts) { account in
                    NavigationLink {
                        AccountDetailView(accountID: account.id)
                    } label: {
                        AccountSettingsRow(account: account, isValidating: env.accounts.validatingAccountIDs.contains(account.id)) { enabled in
                            env.accounts.setEnabled(accountID: account.id, enabled)
                        }
                    }
                    .accessibilityIdentifier("accountRow_\(account.displayName)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeletionID = account.id
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if !account.isMain {
                            Button {
                                env.accounts.setMain(accountID: account.id)
                            } label: {
                                Label("メイン", systemImage: "star.fill")
                            }
                            .tint(.yellow)
                        }
                    }
                    .contextMenu {
                        if !account.isMain {
                            Button("メインアカウントにする", systemImage: "star") { env.accounts.setMain(accountID: account.id) }
                        }
                        Button(account.enabled ? "無効にする" : "有効にする", systemImage: account.enabled ? "pause.circle" : "play.circle") {
                            env.accounts.setEnabled(accountID: account.id, !account.enabled)
                        }
                        if account.kind == .fanbox {
                            Button("セッションを確認", systemImage: "checkmark.shield") {
                                Task { await env.accounts.validateSession(accountID: account.id) }
                            }
                        }
                        Button("削除", systemImage: "trash", role: .destructive) { pendingDeletionID = account.id }
                    }
                }
                .onMove { source, destination in
                    env.accounts.move(accounts.map(\.id), fromOffsets: source, toOffset: destination)
                }
            } header: {
                Text("アカウント")
            }
            .accessibilityIdentifier("accountsList")

            Section {
                NavigationLink {
                    AddAccountView()
                } label: {
                    Label("アカウントを追加", systemImage: "person.badge.plus")
                }
                .accessibilityIdentifier("addAccountButton")

                Button {
                    env.accounts.addDemoAccount(name: env.accounts.nextDemoName())
                } label: {
                    Label("デモアカウントを追加", systemImage: "wand.and.stars")
                }
                .accessibilityIdentifier("addDemoAccountButton")
            }

            if accounts.contains(where: { $0.kind == .fanbox && $0.enabled }) {
                Section {
                    Button {
                        Task {
                            isValidatingAll = true
                            await env.accounts.validateAllSessions()
                            isValidatingAll = false
                        }
                    } label: {
                        HStack {
                            Label("すべてのセッションを確認", systemImage: "checkmark.shield")
                            if isValidatingAll {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isValidatingAll)
                    .accessibilityIdentifier("validateAllSessionsButton")
                }
            }
        }
        .navigationTitle("アカウント")
        .toolbar {
            if accounts.count > 1 {
                EditButton()
            }
        }
        .confirmationDialog("アカウントを削除しますか？", isPresented: deletionBinding, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                if let id = pendingDeletionID {
                    Task { await env.accounts.remove(accountID: id) }
                }
                pendingDeletionID = nil
            }
            Button("キャンセル", role: .cancel) { pendingDeletionID = nil }
        } message: {
            Text(deletionMessage)
        }
        .task {
            await env.accounts.cleanupAbandonedPlaceholders()
            await env.webSessions.purgePendingRemovals()
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { pendingDeletionID != nil }, set: { if !$0 { pendingDeletionID = nil } })
    }

    private var deletionMessage: String {
        let name = accounts.first { $0.id == pendingDeletionID }?.displayName ?? "このアカウント"
        return "「\(name)」のセッション（Keychain）、Webデータ、支援・同期情報が削除されます。取得済みの投稿本文やコメントは残ります。"
    }
}

/// One account in the settings list: color, name, pixiv id, badges, last sync, enabled toggle.
struct AccountSettingsRow: View {
    let account: Account
    var isValidating = false
    var onToggleEnabled: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            AccountAvatarBadge(account: account, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(account.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if account.isMain {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("メイン")
                    }
                }
                if let pixiv = account.pixivUserID, account.kind == .fanbox {
                    Text("pixiv ID: \(pixiv)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    AccountSessionPill(state: account.sessionState, kind: account.kind)
                    if account.creatorAccount {
                        PillLabel(text: "クリエイター", systemImage: "paintbrush.pointed", tint: .purple)
                    }
                    if isValidating { ProgressView().controlSize(.mini) }
                }
                Text(lastSyncText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Toggle("有効", isOn: Binding(get: { account.enabled }, set: { onToggleEnabled($0) }))
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("\(account.displayName)を有効にする")
        }
        .opacity(account.enabled ? 1 : 0.55)
        .padding(.vertical, 2)
    }

    private var lastSyncText: String {
        guard let date = account.lastSyncAt else { return "未同期" }
        return "最終同期: \(Formatters.relative(date))"
    }
}

/// Avatar with the account color ring (falls back to a colored initial).
struct AccountAvatarBadge: View {
    let account: Account
    var size: CGFloat = 36

    var body: some View {
        let color = Color(hex: account.colorHex, fallback: .gray)
        ZStack {
            Circle().fill(color.opacity(0.2))
            if let url = account.avatarURL {
                AvatarView(url: url, size: size - 4)
            } else {
                Text(String(account.displayName.prefix(1)))
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(color, lineWidth: 2.5))
        .accessibilityHidden(true)
    }
}

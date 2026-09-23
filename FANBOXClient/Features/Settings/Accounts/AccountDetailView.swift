import SwiftData
import SwiftUI

/// One account: profile, session state / check / re-login, web, color, creator page, logout, remove.
struct AccountDetailView: View {
    let accountID: String
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [Account]
    @State private var confirmRemove = false
    @State private var confirmLogout = false
    @State private var lastCheckResult: SessionCheckResult?

    init(accountID: String) {
        self.accountID = accountID
        _accounts = Query(filter: #Predicate<Account> { $0.id == accountID })
    }

    var body: some View {
        Group {
            if let account = accounts.first {
                form(account)
            } else {
                EmptyStateView(title: "アカウントが見つかりません", systemImage: "person.crop.circle.badge.xmark")
            }
        }
        .navigationTitle(accounts.first?.displayName ?? "アカウント")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func form(_ account: Account) -> some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AccountAvatarBadge(account: account, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(account.displayName).font(.title3.weight(.bold))
                            if account.isMain {
                                Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("メイン")
                            }
                        }
                        HStack(spacing: 4) {
                            AccountSessionPill(state: account.sessionState, kind: account.kind)
                            if account.creatorAccount {
                                PillLabel(text: "クリエイター", systemImage: "paintbrush.pointed", tint: .purple)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                if account.kind == .fanbox {
                    LabeledContent("pixiv ID", value: account.pixivUserID ?? "—")
                    if let fanboxUserID = account.fanboxUserID {
                        LabeledContent("FANBOX ユーザー ID", value: fanboxUserID)
                    }
                } else {
                    LabeledContent("種類", value: "デモ（通信なし）")
                }
                LabeledContent("追加日", value: Formatters.shortDate(account.createdAt))
                LabeledContent("最終同期", value: account.lastSyncAt.map { Formatters.relative($0) } ?? "未同期")
            } header: {
                Text("プロフィール")
            }

            if account.kind == .fanbox {
                sessionSection(account)
            }

            Section {
                Toggle("有効", isOn: Binding(get: { account.enabled },
                                           set: { env.accounts.setEnabled(accountID: account.id, $0) }))
                    .accessibilityIdentifier("accountEnabledToggle")
                Button {
                    env.accounts.setMain(accountID: account.id)
                } label: {
                    Label(account.isMain ? "メインアカウントです" : "メインアカウントにする", systemImage: account.isMain ? "star.fill" : "star")
                }
                .disabled(account.isMain)
                .accessibilityIdentifier("setMainAccountButton")
                AccountColorPicker(selectedHex: account.colorHex) { hex in
                    env.accounts.setColor(accountID: account.id, hex: hex)
                }
            } header: {
                Text("表示")
            } footer: {
                Text("無効にしたアカウントは同期・通知・自動アカウント選択の対象外になります。")
            }

            creatorSection(account)

            if account.kind == .fanbox {
                Section {
                    LabeledContent("Web ストア", value: String(account.webProfileID.prefix(8)) + "…")
                    Button(role: .destructive) {
                        confirmLogout = true
                    } label: {
                        Label("ログアウト（セッションと Web データを消去）", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityIdentifier("logoutAccountButton")
                } header: {
                    Text("セキュリティ")
                } footer: {
                    Text("Cookie はこのアカウント専用の WebKit ストアに、API セッションは Keychain に保存されています。どちらも他のアカウントとは共有されません。")
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Label("このアカウントを削除", systemImage: "trash")
                }
                .accessibilityIdentifier("removeAccountButton")
            }
        }
        .confirmationDialog("アカウントを削除しますか？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                let id = account.id
                dismiss()
                Task { await env.accounts.remove(accountID: id) }
            }
        } message: {
            Text("セッション（Keychain）、Web データ、支援・同期情報が削除されます。取得済みの投稿本文やコメントは残ります。")
        }
        .confirmationDialog("ログアウトしますか？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("ログアウト", role: .destructive) {
                let id = account.id
                Task { await env.accounts.logout(accountID: id) }
            }
        } message: {
            Text("このアカウントのセッションと Web データを削除します。アカウントとキャッシュは残り、「Web で再ログイン」で復帰できます。")
        }
    }

    private func sessionSection(_ account: Account) -> some View {
        let isValidating = env.accounts.validatingAccountIDs.contains(account.id)
        return Section {
            LabeledContent("状態") {
                AccountSessionPill(state: account.sessionState, kind: account.kind)
            }
            LabeledContent("最終確認", value: account.sessionCheckedAt.map { Formatters.relative($0) } ?? "未確認")
            Button {
                Task {
                    lastCheckResult = nil
                    lastCheckResult = await env.accounts.checkSession(accountID: account.id)
                }
            } label: {
                HStack {
                    Label("セッションを確認", systemImage: "checkmark.shield")
                    if isValidating {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isValidating)
            .accessibilityIdentifier("validateSessionButton")
            if let lastCheckResult, !isValidating {
                Text(checkMessage(lastCheckResult))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                env.web.openWeb(account: account.id, destination: .login, purpose: .login)
            } label: {
                Label("Web で再ログイン", systemImage: "person.badge.key")
            }
            .accessibilityIdentifier("reloginButton")
            Button {
                env.web.openWeb(account: account.id, destination: .home, purpose: .browse)
            } label: {
                Label("Web で FANBOX を開く", systemImage: "safari")
            }
            .accessibilityIdentifier("openWebButton")
        } header: {
            Text("セッション")
        } footer: {
            if account.sessionState == .expired || account.sessionState == .loggedOut {
                Text("ログインの有効期限が切れています。「Web で再ログイン」から同じ pixiv アカウントでログインしてください。")
            }
        }
    }

    @ViewBuilder
    private func creatorSection(_ account: Account) -> some View {
        if let creatorID = account.creatorID {
            AccountCreatorSection(accountID: account.id, creatorID: creatorID, isDemo: account.kind == .demo)
        } else if account.kind == .fanbox {
            Section("クリエイターページ") {
                Text("このアカウントはクリエイターページを所有していません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func checkMessage(_ result: SessionCheckResult) -> String {
        switch result {
        case .updated(.valid): return "セッションは有効です。"
        case .updated(.expired): return "ログインの有効期限が切れています。"
        case .updated(.loggedOut): return "ログアウトしています。"
        case .updated(.error): return "セッションを確認できませんでした（エラー）。"
        case .updated(.unknown): return "状態は不明です。"
        case .unchanged(let reason): return "確認できませんでした（\(reason)）。状態は変更していません。"
        }
    }
}

/// Owned creator page info (reads the Creator row reactively).
private struct AccountCreatorSection: View {
    let accountID: String
    let creatorID: String
    let isDemo: Bool
    @Environment(AppEnvironment.self) private var env
    @Query private var creators: [Creator]

    init(accountID: String, creatorID: String, isDemo: Bool) {
        self.accountID = accountID
        self.creatorID = creatorID
        self.isDemo = isDemo
        _creators = Query(filter: #Predicate<Creator> { $0.creatorID == creatorID })
    }

    var body: some View {
        Section {
            LabeledContent("クリエイター ID", value: creatorID)
            if let creator = creators.first {
                LabeledContent("名前", value: creator.name)
            }
            if !isDemo {
                Button {
                    env.web.openWeb(account: accountID, destination: .creator(creatorID: creatorID), purpose: .browse)
                } label: {
                    Label("クリエイターページを Web で開く", systemImage: "person.crop.square")
                }
                Button {
                    env.web.openWeb(account: accountID, destination: .manageDashboard, purpose: .browse)
                } label: {
                    Label("クリエイター管理画面を Web で開く", systemImage: "chart.bar")
                }
            }
        } header: {
            Text("クリエイターページ")
        } footer: {
            Text("このアカウントは Creator Mode で使用されます。")
        }
    }
}

/// Palette swatches for the account label color.
struct AccountColorPicker: View {
    let selectedHex: String?
    let onSelect: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 36), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("カラー")
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(AccountColorPalette.entries) { entry in
                    let isSelected = selectedHex?.uppercased() == entry.hex.uppercased()
                    Button {
                        onSelect(entry.hex)
                    } label: {
                        Circle()
                            .fill(Color(hex: entry.hex))
                            .frame(width: 30, height: 30)
                            .overlay {
                                if isSelected {
                                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                                }
                            }
                            .overlay(Circle().stroke(Color.primary.opacity(isSelected ? 0.5 : 0), lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.name)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("accountColorPicker")
    }
}

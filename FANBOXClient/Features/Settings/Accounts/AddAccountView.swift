import SwiftData
import SwiftUI

/// Add an account by logging in inside a fresh, isolated WebKit store (SPEC §7.1).
struct AddAccountView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var pendingAccountID: String?
    @State private var addedAccountName: String?

    var body: some View {
        List {
            Section {
                AddAccountInfoRow(systemImage: "lock.rectangle.stack", tint: .purple,
                                  title: "アカウントごとに独立した Web ストア",
                                  detail: "新しいアカウント専用の Cookie / セッション保存領域を作成してログインします。他のアカウントと混ざることはありません。")
                AddAccountInfoRow(systemImage: "person.badge.key", tint: .teal,
                                  title: "ログインは pixiv の画面で",
                                  detail: "ID・パスワードは pixiv / FANBOX の画面に直接入力します。パスワードはこのアプリに保存されません。")
                AddAccountInfoRow(systemImage: "key.viewfinder", tint: .orange,
                                  title: "セッションは Keychain に保存",
                                  detail: "ログイン後のセッション情報は端末の Keychain にのみ保存され、ログや画面には表示されません。")
                AddAccountInfoRow(systemImage: "checkmark.circle", tint: .green,
                                  title: "自動で追加",
                                  detail: "ログインが確認できると画面が閉じ、アカウントが追加されます。既に追加済みのアカウントは追加できません。")
            } header: {
                Text("しくみ")
            }

            Section {
                Button {
                    startLogin()
                } label: {
                    Label("pixiv / FANBOX にログイン", systemImage: "arrow.right.circle.fill")
                        .font(.body.weight(.semibold))
                }
                .disabled(env.web.presented != nil)
                .accessibilityIdentifier("startLoginButton")
            } footer: {
                Text("ログイン画面を閉じると、作成途中のアカウントと Web データは削除されます。")
            }

            if let addedAccountName {
                Section {
                    Label("「\(addedAccountName)」を追加しました", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("accountAddedLabel")
                    Button("アカウント一覧に戻る") { dismiss() }
                }
            }

            Section {
                Button {
                    let account = env.accounts.addDemoAccount(name: env.accounts.nextDemoName())
                    addedAccountName = account.displayName
                } label: {
                    Label("デモアカウントを追加", systemImage: "wand.and.stars")
                }
                .accessibilityIdentifier("addDemoAccountFromAddButton")
            } footer: {
                Text("デモアカウントは通信を行わず、端末内のサンプルデータのみを表示します。")
            }
        }
        .navigationTitle("アカウントを追加")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: env.web.presented?.id) { _, newValue in
            guard newValue == nil else { return }
            finishIfNeeded()
        }
        .onChange(of: env.accounts.loginInProgressAccountID) { _, _ in
            finishIfNeeded()
        }
    }

    private func startLogin() {
        addedAccountName = nil
        let account = env.accounts.beginLogin()
        pendingAccountID = account.id
        env.web.openWeb(account: account.id, destination: .login, purpose: .login)
    }

    /// After the login web session closes: report success, or forget the (already cleaned up) placeholder.
    private func finishIfNeeded() {
        guard let id = pendingAccountID else { return }
        if let account = env.store.account(id: id), !AccountService.isPlaceholder(account) {
            addedAccountName = account.displayName
            pendingAccountID = nil
        } else if env.web.presented == nil && env.accounts.loginInProgressAccountID != id {
            pendingAccountID = nil
        }
    }
}

private struct AddAccountInfoRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

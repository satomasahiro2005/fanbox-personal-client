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
                Button {
                    startLogin()
                } label: {
                    Label("pixiv / FANBOXにログイン", systemImage: "arrow.right.circle.fill")
                        .font(.body.weight(.semibold))
                }
                .disabled(env.web.presented != nil)
                .accessibilityIdentifier("startLoginButton")
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

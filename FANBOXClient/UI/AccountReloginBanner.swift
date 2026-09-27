import SwiftData
import SwiftUI

/// "再ログインが必要なアカウント" banner (SPEC §7 / §44): lists enabled FANBOX accounts whose session expired, or that were
/// stopped because their session belonged to another pixiv user, with a one-tap re-login in the account-aware WebView.
/// Home and the notification inbox show it so the fix does not require a trip through Settings. Renders nothing when
/// every account is fine.
struct AccountReloginBanner: View {
    @Environment(AppEnvironment.self) private var env
    @Query(FetchDescriptorFactory.enabledAccounts()) private var accounts: [Account]

    /// Accounts needing a re-login (the session state is a computed property: filtered in memory).
    static func needsRelogin(_ account: Account) -> Bool {
        account.kind == .fanbox && !AccountService.isPlaceholder(account)
            && (account.sessionState == .expired || account.sessionState == .error)
    }

    private var affected: [Account] { accounts.filter(Self.needsRelogin) }

    var body: some View {
        let affected = affected
        if !affected.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(affected.count == 1 ? "「\(affected[0].displayName)」の再ログインが必要です" : "再ログインが必要なアカウントがあります",
                      systemImage: "person.badge.key.fill")
                    .font(.subheadline.bold())
                Text(message(affected))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(affected) { account in
                            Button {
                                env.web.openWeb(account: account.id, destination: .login, purpose: .login)
                            } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(Color(hex: account.colorHex)).frame(width: 8, height: 8)
                                    Text(affected.count == 1 ? "Webで再ログイン" : account.displayName)
                                        .lineLimit(1)
                                }
                                .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)
                            .accessibilityLabel("\(account.displayName)に再ログイン")
                            .accessibilityIdentifier("reloginBannerButton_\(account.displayName)")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("accountReloginBanner")
        }
    }

    private func message(_ affected: [Account]) -> String {
        let mismatched = affected.contains { $0.sessionState == .error }
        if mismatched {
            return "別のpixivアカウントのセッションを検出したため、同期を止めています。正しいアカウントでログインし直してください。"
        }
        return "ログインの有効期限が切れたため、このアカウントの自動同期を止めています。キャッシュ済みのデータはそのまま表示できます。"
    }
}

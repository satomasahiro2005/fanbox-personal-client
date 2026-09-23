import SwiftUI

/// Presents `WebBridge.presented` as a full-screen account-aware web session.
struct WebBridgePresenter: ViewModifier {
    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        @Bindable var web = env.web
        content
            .fullScreenCover(item: $web.presented, onDismiss: { env.web.onDismiss.map { _ in } }) { request in
                AccountWebSessionView(request: request)
            }
    }
}

/// Account-aware web screen: shows WHICH account is active (prevents wrong-account operations).
struct AccountWebSessionView: View {
    let request: WebSessionRequest
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    AccountBadge(accountID: request.accountID)
                    Text("として表示中").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
                Text(request.destination.url.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(request.destination.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { env.web.dismiss() }
                }
            }
        }
    }
}

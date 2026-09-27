import SwiftUI

/// Shown where native content could not be fetched because FANBOX's edge blocked the request (`RemoteError.edgeBlocked`,
/// docs/API.md §1.7): explains that the session is fine and offers the account-aware WebView (SPEC §40 fallback).
struct SessionEdgeBlockNotice: View {
    var message = "FANBOX側で一時的にブロックされたため、アプリ内で本文を取得できませんでした。ログイン状態には影響ありません。"
    let openWeb: () -> Void

    /// Whether `error` is the edge block this notice explains.
    static func applies(to error: RemoteError?) -> Bool {
        if case .edgeBlocked? = error { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("FANBOX側で一時的にブロックされています", systemImage: "shield.lefthalf.filled.slash")
                .font(.subheadline.bold())
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openWeb()
            } label: {
                Label("Webで開く", systemImage: "safari")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("edgeBlockOpenWebButton")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("edgeBlockNotice")
    }
}

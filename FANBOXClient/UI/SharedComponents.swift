import SwiftUI
import SwiftData

enum Formatters {
    /// "¥6,500"
    static func yen(_ amount: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "ja_JP")
        return "¥" + (f.string(from: NSNumber(value: amount)) ?? "\(amount)")
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day())
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

extension Color {
    /// "#RRGGBB" → Color
    init(hex: String?, fallback: Color = .accentColor) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let v = UInt32(hex.dropFirst(), radix: 16) else {
            self = fallback
            return
        }
        self = Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Colored dot + account name.
struct AccountBadge: View {
    let accountID: String
    var showsName: Bool = true
    @Query private var accounts: [Account]

    init(accountID: String, showsName: Bool = true) {
        self.accountID = accountID
        self.showsName = showsName
        _accounts = Query(filter: #Predicate<Account> { $0.id == accountID })
    }

    var body: some View {
        let account = accounts.first
        HStack(spacing: 4) {
            Circle()
                .fill(Color(hex: account?.colorHex))
                .frame(width: 8, height: 8)
            if showsName {
                Text(account?.displayName ?? "不明なアカウント")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Row of account badges ("Account A / Account C").
struct AccountBadgeRow: View {
    let accountIDs: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(accountIDs, id: \.self) { AccountBadge(accountID: $0) }
        }
    }
}

/// SPEC §44 standard error banner: "同期できませんでした / キャッシュ済みデータを表示しています / 最後の同期: 01:32".
struct SyncStatusBanner: View {
    let error: RemoteError?
    let lastSync: Date?

    var body: some View {
        if let error {
            VStack(alignment: .leading, spacing: 2) {
                Text("同期できませんでした").font(.subheadline.bold())
                Text("キャッシュ済みデータを表示しています").font(.caption)
                if let lastSync {
                    Text("最後の同期: \(Formatters.time(lastSync))").font(.caption).foregroundStyle(.secondary)
                }
                if case .unauthorized = error {
                    Text("ログインの有効期限が切れている可能性があります").font(.caption2).foregroundStyle(.secondary)
                }
                if case .edgeBlocked = error {
                    Text("FANBOX側で一時的にブロックされています（ログイン状態には影響ありません）").font(.caption2).foregroundStyle(.secondary)
                }
                if case .rateLimited = error {
                    Text("リクエストが多すぎるため、しばらく通信を控えています").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("syncErrorBanner")
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var message: String? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        }
    }
}

/// Small pill label (e.g. "Offline", "¥500", "estimated").
struct PillLabel: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Bell button with unread badge; opens the notification inbox. Counts events of enabled accounts only.
struct NotificationBellButton: View {
    @Environment(AppRouter.self) private var router
    @Query(filter: #Predicate<NotificationEvent> { !$0.isRead }) private var unreadEvents: [NotificationEvent]
    @Query(FetchDescriptorFactory.enabledAccounts()) private var accounts: [Account]

    var body: some View {
        let enabled = Set(accounts.map(\.id))
        let unread = unreadEvents.filter { $0.accountIDs.contains(where: enabled.contains) }
        Button {
            router.isNotificationInboxPresented = true
        } label: {
            Image(systemName: unread.isEmpty ? "bell" : "bell.badge")
        }
        .accessibilityLabel(unread.isEmpty ? "通知" : "通知 未読\(unread.count)件")
        .accessibilityIdentifier("notificationBell")
    }
}

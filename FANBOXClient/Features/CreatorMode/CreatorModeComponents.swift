import SwiftData
import SwiftUI

enum CreatorModeKeys {
    /// Creator account selected in Creator Mode (shared by root / comments / fans).
    static let selectedAccountID = "creatorMode.selectedAccountID"
}

// MARK: - Pure formatting (unit-tested)

/// How a dashboard metric is shown (SPEC §17: never show estimates or missing numbers as plain values).
enum CreatorMetricDisplay: Equatable {
    case value(String)
    case estimated(String)
    case unavailable
}

enum CreatorFormatting {
    static func metric(_ value: Int?, source: MetricSource, format: (Int) -> String = { "\($0)" }) -> CreatorMetricDisplay {
        guard let value else { return .unavailable }
        switch source {
        case .actual: return .value(format(value))
        case .estimated: return .estimated(format(value))
        case .unavailable: return .unavailable
        }
    }

    /// "2024/01〜・20ヶ月" (SPEC §23 Support Period).
    static func supportPeriod(startedAt: Date?, months: Int?, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        var start: String?
        if let startedAt {
            var cal = calendar
            cal.timeZone = TimeZone.current
            let c = cal.dateComponents([.year, .month], from: startedAt)
            start = String(format: "%04d/%02d〜", c.year ?? 0, c.month ?? 0)
        }
        let length = months.map { "\($0)ヶ月" }
        switch (start, length) {
        case let (s?, l?): return "\(s)・\(l)"
        case let (s?, nil): return s
        case let (nil, l?): return l
        default: return "期間不明"
        }
    }

    /// "yyyy-MM" of the current month in JST, the month the dashboard snapshot is stored under (`CreatorMonth`).
    static func monthKey(_ date: Date = .now) -> String {
        CreatorMonth.key(date)
    }

    /// "2026年9月" from "2026-09".
    static func monthTitle(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) else { return key }
        return "\(y)年\(m)月"
    }

    /// Upload queue line (SPEC §20 example): "✓" / "Uploading 42%" / "Waiting" / "一時停止" / "失敗".
    static func uploadStatus(state: UploadJobState, progress: Double) -> String {
        switch state {
        case .completed: return "✓"
        case .uploading: return "Uploading \(Int((min(max(progress, 0), 1) * 100).rounded(.down)))%"
        case .queued: return "Waiting"
        case .paused: return "一時停止"
        case .failed: return "失敗"
        }
    }
}

extension DraftStatus {
    var creatorLabel: String {
        switch self {
        case .local: return "ローカル"
        case .uploading: return "アップロード中"
        case .readyToPublish: return "FANBOX下書き保存済み"
        case .publishing: return "送信中"
        case .published: return "公開済み"
        case .failed: return "送信失敗"
        }
    }

    var creatorTint: Color {
        switch self {
        case .local: return .secondary
        case .uploading, .publishing: return .blue
        case .readyToPublish: return .teal
        case .published: return .green
        case .failed: return .red
        }
    }
}

extension RemotePostStatus {
    var creatorTint: Color {
        switch self {
        case .published: return .green
        case .draft: return .teal
        case .scheduled: return .orange
        case .archived: return .gray
        case .unknown: return .secondary
        }
    }
}

extension Post {
    /// FANBOX status of my own managed post (nil = not reported / reader post).
    var managedStatus: RemotePostStatus? { remoteStatusRaw.flatMap(RemotePostStatus.init(rawValue:)) }
    /// Deleted on FANBOX (missing from a complete managed listing).
    var isRemovedFromFanbox: Bool { remoteStatusRaw == LocalStore.removedManagedStatus }
}

extension FanState {
    var creatorLabel: String {
        switch self {
        case .supporting: return "支援中"
        case .following: return "フォロー中"
        case .ended: return "支援終了"
        case .unknown: return "不明"
        }
    }

    var creatorTint: Color {
        switch self {
        case .supporting: return .green
        case .following: return .blue
        case .ended: return .secondary
        case .unknown: return .orange
        }
    }
}

// MARK: - Account scope

/// Resolves the Creator Mode account (enabled account with a creator page), shows the explanatory empty state when
/// there is none, and passes the selected account + all creator accounts to `content`.
struct CreatorAccountScope<Content: View>: View {
    @Query(FetchDescriptorFactory.enabledAccounts()) private var accounts: [Account]
    @AppStorage(CreatorModeKeys.selectedAccountID) private var selectedID: String = ""
    @ViewBuilder var content: (Account, [Account]) -> Content

    var body: some View {
        let creators = accounts.filter { $0.creatorID != nil }
        if let account = creators.first(where: { $0.id == selectedID }) ?? creators.first {
            content(account, creators)
                .id(account.id)
        } else {
            CreatorNoAccountView()
        }
    }
}

/// Shown when no local account owns a creator page.
struct CreatorNoAccountView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ContentUnavailableView {
            Label("Creatorアカウントがありません", systemImage: "paintbrush.pointed")
        } description: {
            Text("Creator ModeはFANBOXのクリエイターページを持つアカウントで利用できます。\nアカウント設定でクリエイターアカウントを追加またはログインしてください。")
        } actions: {
            Button("アカウント設定を開く") {
                env.router.isSettingsPresented = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("creatorModeOpenAccountSettings")
        }
        .accessibilityIdentifier("creatorModeNoAccount")
    }
}

/// Toolbar menu to switch creator accounts (only when several exist).
struct CreatorAccountMenu: View {
    let accounts: [Account]
    let selected: Account
    @AppStorage(CreatorModeKeys.selectedAccountID) private var selectedID: String = ""

    var body: some View {
        if accounts.count > 1 {
            Menu {
                ForEach(accounts) { account in
                    Button {
                        selectedID = account.id
                    } label: {
                        if account.id == selected.id {
                            Label(account.displayName, systemImage: "checkmark")
                        } else {
                            Text(account.displayName)
                        }
                    }
                }
            } label: {
                AccountBadge(accountID: selected.id)
            }
            .accessibilityLabel("Creatorアカウントを切り替え")
            .accessibilityIdentifier("creatorAccountMenu")
        }
    }
}

// MARK: - Dashboard metric

struct CreatorMetricRow: View {
    let title: String
    let display: CreatorMetricDisplay
    var identifier: String = ""

    var body: some View {
        LabeledContent(title) {
            switch display {
            case .value(let text):
                Text(text).monospacedDigit().foregroundStyle(.primary)
            case .estimated(let text):
                HStack(spacing: 6) {
                    Text("約\(text)").monospacedDigit()
                    PillLabel(text: "estimated", tint: .orange)
                }
            case .unavailable:
                Text("取得不可").foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

/// Small count capsule (unread badge).
struct CreatorCountBadge: View {
    let count: Int
    var tint: Color = .red

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.bold())
                .monospacedDigit()
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(.white)
                .background(tint, in: Capsule())
        }
    }
}

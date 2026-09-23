import SwiftData
import SwiftUI

/// Research Mode "Demo tools" (SPEC §45 新着投稿通知 / おたより通知 / コメント通知 in the simulator).
///
/// Demo fixtures are imported silently by the first sync and later syncs return the same fixtures, so nothing "new"
/// ever arrives on its own. These actions add one new item to the demo world and then run one regular foreground polling
/// tick, so the real path — detection → prefetch (post text / comment thread / newsletter body) → local iOS notification →
/// tap routing — can be exercised end to end without FANBOX.
@MainActor
enum ResearchDemoTools {
    enum Action: String, CaseIterable, Identifiable, Sendable {
        case newPost
        case comment
        case newsletter

        var id: String { rawValue }

        var title: String {
            switch self {
            case .newPost: return "新着投稿を発生させる"
            case .comment: return "コメントを発生させる（Demo Creator 宛）"
            case .newsletter: return "おたよりを発生させる"
            }
        }

        var systemImage: String {
            switch self {
            case .newPost: return "doc.badge.plus"
            case .comment: return "text.bubble"
            case .newsletter: return "envelope.badge"
            }
        }
    }

    struct Outcome: Equatable, Sendable {
        var message: String
        /// NotificationEvents created by the polling tick.
        var createdEvents: Int
    }

    /// The world behind the app's demo data source.
    static func world(of remote: RemoteDataSourceProvider) -> DemoWorld {
        (remote as? DefaultRemoteDataSourceProvider)?.demo.world ?? .shared
    }

    /// 1. Makes sure every enabled demo account had its first `.notifications` sync (that one imports silently).
    /// 2. Adds the item to the demo world.
    /// 3. Runs `poll` — in the app `SyncCoordinator.pollOnce()`, the same tick foreground polling runs.
    static func run(_ action: Action, world: DemoWorld, store: LocalStore, engine: SyncEngine,
                    poll: @MainActor () async -> Void) async -> Outcome {
        let demoAccounts = store.accounts().filter { $0.kind == .demo }
        guard !demoAccounts.isEmpty else {
            return Outcome(message: "有効なデモアカウントがありません。", createdEvents: 0)
        }
        guard engine.canReachNetwork else {
            return Outcome(message: "オフラインのため実行しませんでした（デモでも通信モードに従います）。", createdEvents: 0)
        }
        if action == .comment, !demoAccounts.contains(where: { $0.creatorID == DemoFixtures.selfCreatorID }) {
            return Outcome(message: "コメント通知の受け手（Demo Creator アカウント）がありません。", createdEvents: 0)
        }
        for account in demoAccounts {
            let key = SyncState.key(accountID: account.id, resource: .notifications)
            if store.first(#Predicate<SyncState> { $0.key == key })?.lastSuccessfulSync == nil {
                await engine.sync(.notifications, accountID: account.id, reason: .userRefresh)
            }
        }
        let before = eventCount(store)
        let label: String
        switch action {
        case .newPost:
            label = "新着投稿 \(await world.simulateIncomingPost(creatorID: DemoWorld.simulationCreatorID))"
        case .comment:
            guard let id = await world.simulateIncomingComment() else {
                return Outcome(message: "コメント先のデモ投稿が見つかりません。", createdEvents: 0)
            }
            label = "コメント \(id)"
        case .newsletter:
            label = "おたより \(await world.simulateIncomingNewsletter())"
        }
        await poll()
        let created = max(0, eventCount(store) - before)
        return Outcome(message: "\(label) を追加してポーリングしました。新しい通知イベント: \(created) 件", createdEvents: created)
    }

    private static func eventCount(_ store: LocalStore) -> Int {
        (try? store.context.fetchCount(FetchDescriptor<NotificationEvent>())) ?? 0
    }
}

#if DEBUG
/// Debug-only Research Mode section; shown only while an enabled demo account exists.
struct ResearchDemoToolsSection: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)]) private var accounts: [Account]
    @State private var running: ResearchDemoTools.Action?
    @State private var lastOutcome: String?

    var body: some View {
        if accounts.contains(where: { $0.kind == .demo && $0.enabled }) {
            Section {
                ForEach(ResearchDemoTools.Action.allCases) { action in
                    Button {
                        run(action)
                    } label: {
                        HStack {
                            Label(action.title, systemImage: action.systemImage)
                            Spacer()
                            if running == action { ProgressView() }
                        }
                    }
                    .disabled(running != nil)
                    .accessibilityIdentifier("researchDemo_\(action.rawValue)")
                }
                if let lastOutcome {
                    Text(lastOutcome)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("researchDemoOutcome")
                }
            } header: {
                Text("デモツール（DEBUG）")
            } footer: {
                Text("デモアカウントのデータに 1 件追加してから、通常のポーリングを 1 回実行します（通知の取得 → 本文の先読み → ローカル通知）。"
                     + "実アカウントがある場合は、その通知確認も通常どおり行われます。"
                     + (env.settings.localNotificationsEnabled ? "" : "\nローカル通知がオフのため、iOS の通知は表示されません。"))
            }
        }
    }

    private func run(_ action: ResearchDemoTools.Action) {
        running = action
        Task {
            let outcome = await ResearchDemoTools.run(action, world: ResearchDemoTools.world(of: env.remote), store: env.store,
                                                      engine: env.sync, poll: { await env.coordinator.pollOnce() })
            lastOutcome = outcome.message
            running = nil
        }
    }
}
#endif

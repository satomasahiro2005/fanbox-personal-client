import SwiftData
import SwiftUI

/// What is known about an account's stored credential — presence only, never values (SPEC §38).
struct CredentialPresence: Equatable, Sendable {
    var hasCredential = false
    var hasSessionCookie = false
    var cookieCount = 0
    var hasCSRFToken = false
    var hasUserAgent = false
    var capturedAt: Date?

    init() {}

    init(_ credential: SessionCredential?) {
        guard let credential else { return }
        hasCredential = true
        hasSessionCookie = credential.hasSessionCookie
        cookieCount = credential.cookies.count
        hasCSRFToken = credential.csrfToken?.isEmpty == false
        hasUserAgent = credential.userAgent?.isEmpty == false
        capturedAt = credential.capturedAt
    }
}

/// Account State (SPEC §36): session / sync bookkeeping per account. Cookie and credential VALUES are never shown.
struct ResearchAccountStateView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)]) private var accounts: [Account]
    @Query(sort: [SortDescriptor(\SyncState.resourceRaw), SortDescriptor(\SyncState.scope)]) private var syncStates: [SyncState]
    @State private var credentials: [String: CredentialPresence] = [:]

    var body: some View {
        let statesByAccount = Dictionary(grouping: syncStates, by: \.accountID)
        List {
            if accounts.isEmpty {
                EmptyStateView(title: "アカウントがありません", systemImage: "person.crop.circle.badge.questionmark")
            }
            ForEach(accounts) { account in
                Section {
                    LabeledContent("Kind", value: account.kind.rawValue)
                    LabeledContent("Enabled / Main", value: "\(SystemStatusText.yesNo(account.enabled)) / \(SystemStatusText.yesNo(account.isMain))")
                    LabeledContent("Creator Account", value: account.creatorID.map { ResearchLogFormatter.safe($0) } ?? "—")
                    LabeledContent("Session", value: SystemStatusText.sessionState(account.sessionState))
                    LabeledContent("sessionCheckedAt", value: SystemStatusText.date(account.sessionCheckedAt))
                    LabeledContent("lastSyncAt", value: SystemStatusText.date(account.lastSyncAt))
                    LabeledContent("Web Data Store", value: "分離 (\(account.webProfileID.prefix(8))…)")
                    let presence = credentials[account.id] ?? CredentialPresence()
                    LabeledContent("Keychain Credential", value: SystemStatusText.presence(presence.hasCredential))
                    if presence.hasCredential {
                        LabeledContent("FANBOXSESSID", value: SystemStatusText.presence(presence.hasSessionCookie) + "（値は非表示）")
                        LabeledContent("Cookies", value: "\(presence.cookieCount) 件（値は非表示）")
                        LabeledContent("CSRF Token", value: SystemStatusText.presence(presence.hasCSRFToken) + "（値は非表示）")
                        LabeledContent("User-Agent", value: SystemStatusText.presence(presence.hasUserAgent))
                        LabeledContent("capturedAt", value: SystemStatusText.date(presence.capturedAt))
                    }
                    let states = statesByAccount[account.id] ?? []
                    if states.isEmpty {
                        Text("SyncState なし").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(states) { state in
                        SyncStateRow(state: state)
                    }
                } header: {
                    HStack {
                        AccountBadge(accountID: account.id)
                        if account.kind == .demo { PillLabel(text: "demo") }
                    }
                    .textCase(nil)
                }
            }
        }
        .navigationTitle("Account State")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("researchAccountState")
        .task(id: accounts.map(\.id)) { await loadCredentials() }
        .refreshable { await loadCredentials() }
    }

    private func loadCredentials() async {
        var result: [String: CredentialPresence] = [:]
        for account in accounts {
            result[account.id] = CredentialPresence(await env.credentials.credential(for: account.id))
        }
        credentials = result
    }
}

private struct SyncStateRow: View {
    let state: SyncState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(state.resourceRaw).font(.callout.monospaced().bold())
                if !state.scope.isEmpty {
                    Text(ResearchLogFormatter.safe(state.scope)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if state.consecutiveFailures > 0 {
                    PillLabel(text: "失敗 \(state.consecutiveFailures)", tint: .red)
                }
            }
            Group {
                Text("lastSuccessfulSync: \(SystemStatusText.date(state.lastSuccessfulSync))")
                Text("lastAttemptAt: \(SystemStatusText.date(state.lastAttemptAt))")
                Text("cursor: \(SystemStatusText.presence(state.cursor?.isEmpty == false)) / lastKnownItemID: \(state.lastKnownItemID.map { ResearchLogFormatter.safe($0) } ?? "—")")
                if let error = state.error, !error.isEmpty {
                    Text("error: \(ResearchLogFormatter.safe(error))").foregroundStyle(.red)
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Support State (SPEC §36): raw `Support` rows as stored, for tracing support / payment state transitions.
struct ResearchSupportStateView: View {
    @Query(sort: [SortDescriptor(\Support.creatorName), SortDescriptor(\Support.accountID)]) private var supports: [Support]
    @Query private var assignments: [SupportPaymentAssignment]
    @State private var attentionOnly = false

    var body: some View {
        let assignmentByKey = Dictionary(assignments.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let visible = attentionOnly ? supports.filter { $0.needsAttention || $0.status != .active } : supports
        List {
            Section {
                Toggle("要確認・非 active のみ", isOn: $attentionOnly)
            } footer: {
                Text("FANBOX から観測した値をそのまま表示します。原因（決済失敗など）は推定しません。")
            }
            if visible.isEmpty {
                EmptyStateView(title: "支援の記録がありません", systemImage: "yensign.circle")
            }
            ForEach(visible) { support in
                Section {
                    LabeledContent("status", value: support.statusRaw)
                    LabeledContent("amount", value: "\(support.amount) (\(Formatters.yen(support.amount)))")
                    LabeledContent("planID", value: support.planID.map { ResearchLogFormatter.safe($0) } ?? "nil")
                    LabeledContent("planTitle", value: support.planTitle)
                    LabeledContent("reportedPaymentMethod", value: support.reportedPaymentMethod.map { ResearchLogFormatter.safe($0) } ?? "nil")
                    LabeledContent("firstObservedAt", value: SystemStatusText.date(support.firstObservedAt))
                    LabeledContent("lastObservedAt", value: SystemStatusText.date(support.lastObservedAt))
                    LabeledContent("missingSince", value: SystemStatusText.date(support.missingSince))
                    LabeledContent("needsAttention", value: support.needsAttention ? "true" : "false")
                    LabeledContent("attentionReason", value: support.attentionReason.map { ResearchLogFormatter.safe($0) } ?? "nil")
                    LabeledContent("acknowledgedAt", value: SystemStatusText.date(support.acknowledgedAt))
                    if let assignment = assignmentByKey[support.key] {
                        LabeledContent("assignment.verificationState", value: assignment.verificationStateRaw)
                        LabeledContent("assignment.paymentProfile", value: assignment.paymentProfileID == nil ? "nil" : "設定あり")
                        LabeledContent("assignment.lastVerifiedAt", value: SystemStatusText.date(assignment.lastVerifiedAt))
                    }
                } header: {
                    HStack {
                        Text(support.creatorName).textCase(nil)
                        AccountBadge(accountID: support.accountID)
                        if support.needsAttention { PillLabel(text: "要確認", tint: .orange) }
                    }
                }
                .font(.callout)
            }
        }
        .navigationTitle("Support State")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("researchSupportState")
    }
}

/// Scheduler (SPEC §29): in-flight requests per priority + current network policy + queue state.
struct ResearchSchedulerView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var inFlight: [RequestPriority: Int] = [:]
    @State private var policy = NetworkPolicySnapshot.default
    @State private var updatedAt: Date?

    var body: some View {
        List {
            Section {
                ForEach(RequestPriority.allCases.sorted(by: >), id: \.self) { priority in
                    LabeledContent("\(priority.displayName) (\(priority.rawValue))") {
                        Text("\(inFlight[priority] ?? 0)").monospacedDigit()
                            .foregroundStyle((inFlight[priority] ?? 0) > 0 ? Color.accentColor : Color.secondary)
                    }
                }
            } header: {
                Text("実行中のリクエスト")
            } footer: {
                if let updatedAt { Text("更新: \(updatedAt.formatted(.dateTime.hour().minute().second()))（1 秒ごと）") }
            }

            Section("通信ポリシー") {
                LabeledContent("mode", value: policy.mode.displayName)
                LabeledContent("pathSatisfied", value: SystemStatusText.yesNo(policy.pathSatisfied))
                LabeledContent("isOnWiFi", value: SystemStatusText.yesNo(policy.isOnWiFi))
                LabeledContent("isConstrained", value: SystemStatusText.yesNo(policy.isConstrained))
                LabeledContent("isExpensive", value: SystemStatusText.yesNo(policy.isExpensive))
                LabeledContent("mediaPrefetchWiFiOnly", value: SystemStatusText.yesNo(policy.mediaPrefetchWiFiOnly))
                LabeledContent("extremeShowsThumbnails", value: SystemStatusText.yesNo(policy.extremeShowsThumbnails))
            }

            Section("同期 / キュー") {
                LabeledContent("SyncEngine.isSyncing", value: SystemStatusText.yesNo(env.sync.isSyncing))
                LabeledContent("SyncEngine.lastSuccessAt", value: SystemStatusText.date(env.sync.lastSuccessAt))
                LabeledContent("SyncEngine.lastError", value: env.sync.lastError.map { ResearchLogFormatter.safe(String(describing: $0)) } ?? "—")
                LabeledContent("Coordinator.isRefreshing", value: SystemStatusText.yesNo(env.coordinator.isRefreshing))
                LabeledContent("Coordinator.lastRefreshAt", value: SystemStatusText.date(env.coordinator.lastRefreshAt))
                LabeledContent("ReplyQueue.pendingCount", value: "\(env.replies.pendingCount)")
                LabeledContent("UploadQueue.isRunning", value: SystemStatusText.yesNo(env.uploads.isRunning))
            }
        }
        .navigationTitle("Scheduler")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("researchScheduler")
        .task {
            while !Task.isCancelled {
                inFlight = await env.scheduler.snapshot()
                policy = env.networkMode.policy
                updatedAt = .now
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

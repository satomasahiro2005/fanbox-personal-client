import SwiftUI
import SwiftData

/// Tab 「支援」 (SPEC §10.3 dashboard, §15 要確認, §10.1 / §10.2 groupings).
/// Renders from SwiftData immediately; pull-to-refresh re-syncs supports + payments of all enabled accounts.
struct SupportRootView: View {
    enum Grouping: String, Hashable { case creator, account }

    @Environment(AppEnvironment.self) private var env
    @Query(sort: \Support.creatorName) private var supports: [Support]
    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)]) private var accounts: [Account]
    @Query(sort: \PaymentRecord.paidAt, order: .reverse) private var payments: [PaymentRecord]
    @Query private var assignments: [SupportPaymentAssignment]
    @Query private var syncStates: [SyncState]

    @State private var grouping: Grouping = .creator
    @State private var refreshError: RemoteError?
    @State private var flowRequest: PaymentFlowRequest?

    init() {
        let raw = SyncResource.supports.rawValue
        _syncStates = Query(filter: #Predicate<SyncState> { $0.resourceRaw == raw && $0.scope == "" })
    }

    var body: some View {
        let known = Set(accounts.map(\.id))
        let snapshots = supports.filter { known.contains($0.accountID) }.map(SupportSnapshot.init)
        let paymentSnapshots = payments.filter { known.contains($0.accountID) }.map(PaymentSnapshot.init)
        let now = Date.now
        let unpaidAccountIDs = SupportAnalyzer.paymentStateAttentionAccountIDs(accounts.map(AccountPaymentState.init))
        let unpaidAccounts = accounts.filter { unpaidAccountIDs.contains($0.id) }
        let summary = SupportAnalyzer.summarize(supports: snapshots, payments: paymentSnapshots, now: now,
                                                paymentStateAttentionAccountIDs: unpaidAccountIDs)
        let attention = SupportAnalyzer.attentionItems(snapshots)
        let order = accounts.map(\.id)
        let assignmentSnapshots = assignments.map(AssignmentSnapshot.init)
        let status = SupportSyncStatus(states: syncStates, accountIDs: known)

        List {
            if let error = status.bannerError(local: refreshError) {
                Section {
                    SyncStatusBanner(error: error, lastSync: status.lastSync)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }

            Section {
                SupportDashboardCard(summary: summary, monthLabel: SupportAnalyzer.monthLabel(now), lastSync: status.lastSync)
            } footer: {
                Text(SupportText.dashboardFootnote)
                    .accessibilityIdentifier("supportDashboardFootnote")
            }

            if !attention.isEmpty || !unpaidAccounts.isEmpty {
                Section {
                    ForEach(unpaidAccounts) { account in
                        PaymentStateAttentionCard(account: account)
                    }
                    ForEach(attention) { item in
                        if let support = supports.first(where: { $0.key == item.id }) {
                            SupportAttentionCard(support: support) {
                                flowRequest = PaymentFlowRequest(creatorID: support.creatorID, planID: support.planID, accountID: support.accountID)
                            }
                        }
                    }
                } header: {
                    Label("要確認 \(attention.count + unpaidAccounts.count)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("supportAttentionHeader")
                } footer: {
                    Text("アプリが観測した事実のみを表示しています。原因は FANBOX / pixiv の画面で確認してください。")
                }
            }

            Section {
                Picker("表示", selection: $grouping) {
                    Text("Creator 別").tag(Grouping.creator)
                    Text("Account 別").tag(Grouping.account)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("supportGroupingPicker")

                switch grouping {
                case .creator:
                    let groups = SupportAnalyzer.byCreator(supports: snapshots, assignments: assignmentSnapshots, accountOrder: order)
                    if groups.isEmpty {
                        emptyRow
                    }
                    ForEach(groups) { group in
                        NavigationLink(value: AppRoute.supportCreator(creatorID: group.creatorID)) {
                            SupportCreatorGroupRow(group: group)
                        }
                        .accessibilityIdentifier("supportCreatorRow-\(group.creatorID)")
                    }
                case .account:
                    let groups = SupportAnalyzer.byAccount(supports: snapshots, assignments: assignmentSnapshots, accountOrder: order)
                    if groups.isEmpty {
                        emptyRow
                    }
                    ForEach(groups) { group in
                        NavigationLink(value: AppRoute.supportAccount(accountID: group.accountID)) {
                            SupportAccountGroupRow(group: group)
                        }
                        .accessibilityIdentifier("supportAccountRow-\(group.accountID)")
                    }
                }
            } header: {
                Text("支援中")
            }

            Section {
                NavigationLink(value: AppRoute.supportHistory) {
                    Label("支援履歴", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("supportHistoryLink")
                NavigationLink(value: AppRoute.paymentProfiles) {
                    Label("Payment Profile", systemImage: "creditcard")
                }
                .accessibilityIdentifier("paymentProfilesLink")
            }
        }
        .accessibilityIdentifier("supportRootList")
        .navigationTitle("支援")
        .refreshable { await refreshAll(priority: .interactiveRead, reason: .userRefresh) }
        .task {
            let ids = accounts.filter(\.enabled).map(\.id)
            guard !ids.isEmpty, SupportSync.isStale(states: syncStates, accountIDs: ids) else { return }
            await refreshAll(priority: .backgroundSync, reason: .onDemand)
        }
        .paymentFlowSheet($flowRequest)
    }

    private var emptyRow: some View {
        Text("支援中のクリエイターはありません")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("supportEmpty")
    }

    private func refreshAll(priority: RequestPriority, reason: SyncReason) async {
        let ids = accounts.filter(\.enabled).map(\.id)
        guard !ids.isEmpty else { return }
        refreshError = await SupportSync.refresh(env: env, accountIDs: ids, includePayments: true, priority: priority, reason: reason)
    }
}

// MARK: - Dashboard card (SPEC §10.3)

struct SupportDashboardCard: View {
    let summary: SupportDashboardSummary
    let monthLabel: String
    var lastSync: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(monthLabel)
                    .font(.title2.bold())
                    .accessibilityIdentifier("supportDashboardMonth")
                Spacer()
                if summary.attentionCount > 0 {
                    PillLabel(text: "要確認 \(summary.attentionCount)", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
            }
            SupportMoneyRow(title: "定常月額", value: summary.recurringMonthly, caption: "支援中プランの月額合計",
                            identifier: "supportRecurringMonthly")
            SupportMoneyRow(title: "今月実請求", value: summary.actualThisMonth, caption: SupportText.actualCaption(summary),
                            identifier: "supportActualThisMonth")
            SupportMoneyRow(title: "来月予定", value: summary.nextMonthPlanned, caption: SupportText.nextMonthCaption(summary),
                            identifier: "supportNextMonthPlanned")
            Divider()
            HStack(spacing: 24) {
                stat("Creators", summary.creatorCount, identifier: "supportCreatorCount")
                stat("Accounts", summary.accountCount, identifier: "supportAccountCount")
                Spacer()
                if let lastSync {
                    Text("最後の同期: \(Formatters.time(lastSync))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("supportDashboard")
    }

    private func stat(_ title: String, _ value: Int, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)").font(.title3.monospacedDigit().weight(.semibold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - 要確認 card (SPEC §15)

/// Recovery card. Shows OBSERVED FACTS only — never asserts that a payment failed.
struct SupportAttentionCard: View {
    let support: Support
    var onResupport: () -> Void

    @Environment(AppEnvironment.self) private var env
    @State private var isChecking = false
    @State private var checkFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AvatarView(url: support.creatorIconURL, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(support.creatorName).font(.headline)
                    AccountBadge(accountID: support.accountID)
                }
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                GridRow {
                    Text("以前:").foregroundStyle(.secondary)
                    Text(SupportText.previousText(amount: support.amount)).monospacedDigit()
                }
                GridRow {
                    Text("現在:").foregroundStyle(.secondary)
                    Text(SupportText.currentText(status: support.status, amount: support.amount))
                        .fontWeight(.semibold)
                }
            }
            .font(.subheadline)

            Label(SupportText.observedFact(status: support.status, attentionReason: support.attentionReason), systemImage: "eye")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let since = support.missingSince {
                Text("観測日時: \(Formatters.shortDate(since)) \(Formatters.time(since))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if checkFailed {
                Text("状態を確認できませんでした。キャッシュ済みデータを表示しています")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button {
                    Task { await checkState() }
                } label: {
                    if isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("状態を確認", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isChecking)
                .accessibilityIdentifier("attentionCheck")
                Button {
                    onResupport()
                } label: {
                    Label("再支援", systemImage: "heart")
                }
                .accessibilityIdentifier("attentionResupport")
            }
            HStack {
                Button {
                    env.web.openWeb(account: support.accountID, destination: .supportingPlans, purpose: .payment)
                } label: {
                    Label("Web で開く", systemImage: "safari")
                }
                .accessibilityIdentifier("attentionOpenWeb")
                Button {
                    SupportMutations.acknowledge(support, store: env.store)
                } label: {
                    Label("確認済みにする", systemImage: "checkmark")
                }
                .accessibilityIdentifier("attentionAcknowledge")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.vertical, 4)
        .accessibilityIdentifier("attentionCard-\(support.key)")
    }

    private func checkState() async {
        isChecking = true
        defer { isChecking = false }
        let error = await SupportSync.refresh(env: env, accountIDs: [support.accountID], includePayments: false,
                                              priority: .interactiveRead, reason: .userRefresh)
        checkFailed = error != nil
    }
}

// MARK: - 決済状態を確認できません (SPEC §15)

/// Account-level observation: FANBOX reported unpaid payments for the account (`Account.hasUnpaidPayments`, set by sync).
/// States the observation only — never that a payment failed. Stays while FANBOX keeps reporting it.
struct PaymentStateAttentionCard: View {
    let account: Account

    @Environment(AppEnvironment.self) private var env
    @State private var isChecking = false
    @State private var checkFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AccountBadge(accountID: account.id)
                Spacer()
            }
            Label(SupportText.paymentStateUnknown, systemImage: "eye")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("paymentStateUnknownFact")
            Text(SupportText.paymentStateUnknownDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let checked = account.unpaidPaymentsCheckedAt {
                Text("観測日時: \(Formatters.shortDate(checked)) \(Formatters.time(checked))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if checkFailed {
                Text("状態を確認できませんでした。キャッシュ済みデータを表示しています")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button {
                    Task { await checkState() }
                } label: {
                    if isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("状態を確認", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isChecking)
                .accessibilityIdentifier("paymentStateCheck")
                Menu {
                    Button {
                        env.web.openWeb(account: account.id, destination: .paymentHistory, purpose: .payment)
                    } label: {
                        Label("お支払い履歴", systemImage: "list.bullet.rectangle")
                    }
                    Button {
                        env.web.openWeb(account: account.id, destination: .paymentSettings, purpose: .payment)
                    } label: {
                        Label("お支払い方法", systemImage: "creditcard")
                    }
                } label: {
                    Label("Web で開く", systemImage: "safari")
                }
                .accessibilityIdentifier("paymentStateOpenWeb")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.vertical, 4)
        .accessibilityIdentifier("paymentStateCard-\(account.id)")
    }

    private func checkState() async {
        isChecking = true
        defer { isChecking = false }
        let error = await SupportSync.refresh(env: env, accountIDs: [account.id], includePayments: true,
                                              priority: .interactiveRead, reason: .userRefresh)
        checkFailed = error != nil
    }
}

// MARK: - Group rows

struct SupportCreatorGroupRow: View {
    let group: CreatorSupportGroup

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(url: group.creatorIconURL, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.creatorName).font(.body.weight(.medium)).lineLimit(1)
                AccountBadgeRow(accountIDs: group.activeAccountIDs)
            }
            Spacer()
            Text(SupportText.monthly(group.total))
                .font(.subheadline.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }
}

struct SupportAccountGroupRow: View {
    let group: AccountSupportGroup

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                AccountBadge(accountID: group.accountID)
                Text("\(group.activeCreatorCount) クリエイター")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(SupportText.monthly(group.total))
                .font(.subheadline.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }
}

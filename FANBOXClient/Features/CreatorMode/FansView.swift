import SwiftData
import SwiftUI

/// SPEC §23 Fan 管理: User / Plan / Support Period / Current State, name search and plan filter. Notes stay local.
struct FansView: View {
    var body: some View {
        CreatorAccountScope { account, creators in
            CreatorFansList(account: account, creatorAccounts: creators)
        }
        .navigationTitle("ファン")
    }
}

/// Plan filter of the fan list.
enum CreatorFanPlanFilter: Hashable {
    case all
    case plan(String)
    /// Fans without a plan (followers / unknown).
    case noPlan
}

/// Pure filtering (unit-tested).
enum CreatorFanFiltering {
    static func filter(_ fans: [Fan], query: String, plan: CreatorFanPlanFilter, state: FanState?) -> [Fan] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return fans.filter { fan in
            if !q.isEmpty && !(fan.name.localizedCaseInsensitiveContains(q) || fan.note.localizedCaseInsensitiveContains(q)) { return false }
            switch plan {
            case .all: break
            case .plan(let id): if fan.planID != id { return false }
            case .noPlan: if fan.planID != nil { return false }
            }
            if let state, fan.state != state { return false }
            return true
        }
        .sorted { a, b in
            let ra = rank(a.state), rb = rank(b.state)
            if ra != rb { return ra < rb }
            if (a.fee ?? 0) != (b.fee ?? 0) { return (a.fee ?? 0) > (b.fee ?? 0) }
            return (a.supportStartedAt ?? .distantFuture) < (b.supportStartedAt ?? .distantFuture)
        }
    }

    private static func rank(_ state: FanState) -> Int {
        switch state {
        case .supporting: return 0
        case .following: return 1
        case .unknown: return 2
        case .ended: return 3
        }
    }
}

private struct CreatorFanPlanOption: Identifiable, Hashable {
    var id: String
    var title: String
    var fee: Int?
}

private struct CreatorFansList: View {
    @Environment(AppEnvironment.self) private var env
    let account: Account
    let creatorAccounts: [Account]
    private let accountID: String

    @Query private var fans: [Fan]
    @Query private var plans: [Plan]
    @Query private var syncStates: [SyncState]

    @State private var query = ""
    /// Refresh only on the first appearance (returning from a pushed screen does not refetch; pull-to-refresh does).
    @State private var didInitialLoad = false
    @State private var planFilter: CreatorFanPlanFilter = .all
    @State private var stateFilter: FanState?
    @State private var syncError: RemoteError?

    init(account: Account, creatorAccounts: [Account]) {
        self.account = account
        self.creatorAccounts = creatorAccounts
        let accountID = account.id
        let creatorID = account.creatorID ?? ""
        self.accountID = accountID
        _fans = Query(filter: #Predicate<Fan> { $0.accountID == accountID }, sort: [SortDescriptor(\.name)])
        _plans = Query(filter: #Predicate<Plan> { $0.creatorID == creatorID }, sort: [SortDescriptor(\.fee)])
        let resource = SyncResource.fans.rawValue
        _syncStates = Query(filter: #Predicate<SyncState> { $0.accountID == accountID && $0.resourceRaw == resource })
    }

    /// Plans known locally plus plans only seen on fan rows.
    private var planOptions: [CreatorFanPlanOption] {
        var options = plans.map { CreatorFanPlanOption(id: $0.planID, title: $0.title, fee: $0.fee) }
        var known = Set(options.map(\.id))
        for fan in fans {
            guard let id = fan.planID, !known.contains(id) else { continue }
            known.insert(id)
            options.append(CreatorFanPlanOption(id: id, title: fan.planTitle ?? "プラン \(id)", fee: fan.fee))
        }
        return options.sorted { ($0.fee ?? 0) < ($1.fee ?? 0) }
    }

    private var filterLabel: String {
        switch planFilter {
        case .all: return "すべてのプラン"
        case .noPlan: return "プランなし"
        case .plan(let id): return planOptions.first { $0.id == id }?.title ?? "プラン"
        }
    }

    var body: some View {
        let visible = CreatorFanFiltering.filter(fans, query: query, plan: planFilter, state: stateFilter)
        List {
            Section {
                if syncError != nil {
                    SyncStatusBanner(error: syncError, lastSync: syncStates.first?.lastSuccessfulSync)
                }
                HStack {
                    Text("支援中 \(fans.filter { $0.state == .supporting }.count) 人")
                    Spacer()
                    Text("取得済み \(fans.count) 人").foregroundStyle(.secondary)
                }
                .font(.subheadline)
                if planFilter != .all || stateFilter != nil {
                    HStack {
                        PillLabel(text: filterLabel, systemImage: "line.3.horizontal.decrease", tint: .purple)
                        if let stateFilter { PillLabel(text: stateFilter.creatorLabel, tint: stateFilter.creatorTint) }
                        Spacer()
                        Button("解除") {
                            planFilter = .all
                            stateFilter = nil
                        }
                        .font(.caption)
                    }
                }
            } footer: {
                Text("FANBOX から取得できる範囲の情報です。メモは端末内だけに保存されます。")
            }

            Section {
                if visible.isEmpty {
                    Text(fans.isEmpty ? "ファン情報はまだ取得されていません" : "該当するファンはいません")
                        .foregroundStyle(.secondary)
                }
                ForEach(visible) { fan in
                    NavigationLink {
                        CreatorFanDetailView(fan: fan)
                    } label: {
                        CreatorFanRow(fan: fan)
                    }
                    .accessibilityIdentifier("creatorFanRow")
                }
            }
        }
        .searchable(text: $query, prompt: "名前・メモで検索")
        .accessibilityIdentifier("creatorFansList")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CreatorAccountMenu(accounts: creatorAccounts, selected: account)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("プラン", selection: $planFilter) {
                        Text("すべてのプラン").tag(CreatorFanPlanFilter.all)
                        ForEach(planOptions) { option in
                            Text(option.fee.map { "\(option.title)（\(Formatters.yen($0))）" } ?? option.title)
                                .tag(CreatorFanPlanFilter.plan(option.id))
                        }
                        Text("プランなし").tag(CreatorFanPlanFilter.noPlan)
                    }
                    Picker("状態", selection: $stateFilter) {
                        Text("すべての状態").tag(FanState?.none)
                        ForEach([FanState.supporting, .following, .ended, .unknown], id: \.self) { state in
                            Text(state.creatorLabel).tag(Optional(state))
                        }
                    }
                } label: {
                    Label("フィルター", systemImage: planFilter == .all && stateFilter == nil
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("creatorFanFilterMenu")
            }
        }
        .task(id: accountID) {
            guard !didInitialLoad else { return }
            didInitialLoad = true
            await refresh(reason: .onDemand)
        }
        .refreshable { await refresh(reason: .userRefresh) }
    }

    private func refresh(reason: SyncReason) async {
        let outcome = await env.sync.sync(.fans, accountID: accountID, reason: reason)
        syncError = outcome.error
    }
}

struct CreatorFanRow: View {
    let fan: Fan

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(url: fan.iconURL, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(fan.name).font(.body.weight(.medium)).lineLimit(1)
                    PillLabel(text: fan.state.creatorLabel, tint: fan.state.creatorTint)
                }
                HStack(spacing: 6) {
                    if let title = fan.planTitle {
                        Text(fan.fee.map { "\(title)・\(Formatters.yen($0))" } ?? title)
                    } else {
                        Text("プランなし")
                    }
                    Text(CreatorFormatting.supportPeriod(startedAt: fan.supportStartedAt, months: fan.supportMonths))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if !fan.note.isEmpty {
                    Label(fan.note, systemImage: "note.text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct CreatorFanDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var fan: Fan

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AvatarView(url: fan.iconURL, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fan.name).font(.headline)
                        PillLabel(text: fan.state.creatorLabel, tint: fan.state.creatorTint)
                    }
                }
            }
            Section("支援") {
                LabeledContent("プラン", value: fan.planTitle ?? "プランなし")
                LabeledContent("月額", value: fan.fee.map { Formatters.yen($0) } ?? "—")
                LabeledContent("支援期間", value: CreatorFormatting.supportPeriod(startedAt: fan.supportStartedAt, months: fan.supportMonths))
                LabeledContent("状態", value: fan.state.creatorLabel)
            }
            Section {
                TextField("メモ", text: $fan.note, axis: .vertical)
                    .lineLimit(3...10)
                    .accessibilityIdentifier("creatorFanNoteField")
            } header: {
                Text("メモ")
            } footer: {
                Text("メモは端末内だけに保存され、FANBOX には送信されません。")
            }
        }
        .navigationTitle(fan.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { env.store.save() }
    }
}

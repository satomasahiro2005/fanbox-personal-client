import SwiftUI
import SwiftData

/// SPEC §11: support changes observed by the app, newest first, filterable by account / creator. Enabled accounts only.
struct SupportHistoryView: View {
    @Query(sort: \SupportHistory.timestamp, order: .reverse) private var history: [SupportHistory]
    @Query(FetchDescriptorFactory.enabledAccounts()) private var accounts: [Account]

    @State private var accountFilter: String?
    @State private var creatorFilter: String?

    init(accountID: String? = nil, creatorID: String? = nil) {
        _accountFilter = State(initialValue: accountID)
        _creatorFilter = State(initialValue: creatorID)
    }

    var body: some View {
        let enabled = Set(accounts.map(\.id))
        let rows = history.filter { enabled.contains($0.accountID) }
        let creators = SupportHistoryFilter.creators(in: rows.map { ($0.creatorID, $0.creatorName) })
        let filtered = rows.filter { SupportHistoryFilter.matches(accountID: $0.accountID, creatorID: $0.creatorID,
                                                                  accountFilter: accountFilter, creatorFilter: creatorFilter) }
        List {
            if accountFilter != nil || creatorFilter != nil {
                Section {
                    HStack(spacing: 8) {
                        if let accountFilter {
                            AccountBadge(accountID: accountFilter)
                        }
                        if let creatorFilter {
                            PillLabel(text: creators.first { $0.id == creatorFilter }?.name ?? creatorFilter, systemImage: "person")
                        }
                        Spacer()
                        Button("解除") {
                            accountFilter = nil
                            creatorFilter = nil
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("supportHistoryClearFilter")
                    }
                }
            }
            if filtered.isEmpty {
                EmptyStateView(title: "支援履歴はありません", systemImage: "clock.arrow.circlepath",
                               message: "アプリが観測した支援状態の変化がここに記録されます")
                    .listRowBackground(Color.clear)
            } else {
                ForEach(filtered) { entry in
                    SupportHistoryRow(entry: entry)
                        .accessibilityIdentifier("supportHistoryRow-\(entry.id)")
                }
            }
        }
        .accessibilityIdentifier("supportHistoryList")
        .navigationTitle("支援履歴")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("アカウント", selection: $accountFilter) {
                        Text("すべてのアカウント").tag(String?.none)
                        ForEach(accounts) { a in
                            Text(a.displayName).tag(Optional(a.id))
                        }
                    }
                    Picker("クリエイター", selection: $creatorFilter) {
                        Text("すべてのクリエイター").tag(String?.none)
                        ForEach(creators) { c in
                            Text(c.name).tag(Optional(c.id))
                        }
                    }
                } label: {
                    Image(systemName: accountFilter != nil || creatorFilter != nil
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("絞り込み")
                .accessibilityIdentifier("supportHistoryFilter")
            }
        }
    }
}

/// Pure filtering helpers for the history screen.
enum SupportHistoryFilter {
    struct CreatorOption: Identifiable, Hashable {
        var id: String
        var name: String
    }

    static func matches(accountID: String, creatorID: String, accountFilter: String?, creatorFilter: String?) -> Bool {
        (accountFilter == nil || accountFilter == accountID) && (creatorFilter == nil || creatorFilter == creatorID)
    }

    /// Distinct creators (first name seen wins), sorted by name.
    static func creators(in pairs: [(String, String)]) -> [CreatorOption] {
        var seen: [String: String] = [:]
        for (id, name) in pairs where seen[id] == nil { seen[id] = name }
        return seen.map { CreatorOption(id: $0.key, name: $0.value) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}

/// "2026/9/1 · Creator A · Account B · ¥500 → ¥1,000 · 同期で観測"
struct SupportHistoryRow: View {
    let entry: SupportHistory
    var showsCreator: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: SupportText.historySymbol(entry.kind))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(Formatters.shortDate(entry.timestamp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    PillLabel(text: SupportText.observedSourceLabel(entry.observedSource))
                }
                if showsCreator {
                    Text(entry.creatorName).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                AccountBadge(accountID: entry.accountID)
                Text(SupportText.historyText(entry))
                    .font(.body.monospacedDigit())
                if entry.kind == .planChanged, let old = entry.oldPlan, let new = entry.newPlan, !old.isEmpty, !new.isEmpty, old != new {
                    Text("\(old) → \(new)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch entry.kind {
        case .started, .restored: return .green
        case .planChanged: return .blue
        case .ended: return .secondary
        case .disappeared: return .orange
        }
    }
}

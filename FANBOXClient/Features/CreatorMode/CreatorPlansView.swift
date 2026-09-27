import SwiftData
import SwiftUI

/// Creator Mode plans: own plans with fee / description and supporter counts from locally known fans.
struct CreatorPlansView: View {
    @Environment(AppEnvironment.self) private var env
    let creatorID: String

    @Query private var plans: [Plan]
    @Query(FetchDescriptorFactory.enabledAccounts()) private var accounts: [Account]
    @Query private var fans: [Fan]
    @State private var syncError: RemoteError?
    @State private var expandedPlanIDs: Set<String> = []
    /// Refresh only on the first appearance (pull-to-refresh always fetches).
    @State private var didInitialLoad = false

    init(creatorID: String) {
        self.creatorID = creatorID
        _plans = Query(filter: #Predicate<Plan> { $0.creatorID == creatorID }, sort: [SortDescriptor(\.fee), SortDescriptor(\.sortOrder)])
        _fans = Query()
    }

    /// The enabled local account that owns this creator page.
    private var ownerAccount: Account? { accounts.first { $0.creatorID == creatorID } }

    private var ownerFans: [Fan] {
        guard let id = ownerAccount?.id else { return [] }
        return fans.filter { $0.accountID == id }
    }

    var body: some View {
        let supporters = CreatorPlanCounting.supporterCounts(ownerFans)
        List {
            if syncError != nil {
                Section { SyncStatusBanner(error: syncError, lastSync: nil) }
            }
            Section {
                if plans.isEmpty {
                    Text("プラン情報はまだ取得されていません").foregroundStyle(.secondary)
                }
                ForEach(plans) { plan in
                    planRow(plan, supporterCount: ownerFans.isEmpty ? nil : supporters[plan.planID, default: 0])
                }
            }
            Section {
                Button {
                    if let account = ownerAccount {
                        env.web.openWeb(account: account.id, destination: .managePlans, purpose: .browse)
                    }
                } label: {
                    Label("Webでプラン管理", systemImage: "safari")
                }
                .disabled(ownerAccount == nil)
                .accessibilityIdentifier("creatorWebManagePlans")
            }
        }
        .navigationTitle("プラン")
        .accessibilityIdentifier("creatorPlansList")
        .task {
            guard !didInitialLoad else { return }
            didInitialLoad = true
            await refresh(reason: .onDemand)
        }
        .refreshable { await refresh(reason: .userRefresh) }
    }

    private func planRow(_ plan: Plan, supporterCount: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(plan.title).font(.headline)
                if plan.hasAdultContent { PillLabel(text: "R-18", tint: .red) }
                Spacer()
                Text(Formatters.yen(plan.fee)).font(.headline).monospacedDigit()
                Text("/ 月").font(.caption).foregroundStyle(.secondary)
            }
            if let coverURL = plan.coverImageURL {
                RemoteImageView(thumbnailURL: coverURL, displayURL: coverURL, maxVariant: .display, creatorID: creatorID,
                                accountID: ownerAccount?.id)
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if !plan.planDescription.isEmpty {
                let expanded = expandedPlanIDs.contains(plan.planID)
                Text(plan.planDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 3)
                    .onTapGesture {
                        if expanded { expandedPlanIDs.remove(plan.planID) } else { expandedPlanIDs.insert(plan.planID) }
                    }
            }
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                if let supporterCount {
                    Text("支援者\(supporterCount)人")
                } else {
                    Text("支援者数: 未取得")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("creatorPlanRow")
    }

    private func refresh(reason: SyncReason) async {
        guard let accountID = ownerAccount?.id else { return }
        async let planOutcome = env.sync.sync(.plans, accountID: accountID, scope: creatorID, reason: reason)
        async let fanOutcome = env.sync.sync(.fans, accountID: accountID, reason: reason)
        let outcomes = await [planOutcome, fanOutcome]
        syncError = outcomes.compactMap(\.error).first
    }
}

/// Pure counting helper (unit-tested).
enum CreatorPlanCounting {
    /// Supporting fans per planID.
    static func supporterCounts(_ fans: [Fan]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for fan in fans where fan.state == .supporting {
            guard let planID = fan.planID else { continue }
            counts[planID, default: 0] += 1
        }
        return counts
    }
}

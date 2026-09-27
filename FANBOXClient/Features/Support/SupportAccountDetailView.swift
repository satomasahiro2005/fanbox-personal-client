import SwiftUI
import SwiftData

/// SPEC §10.2: one account — its default card, supported creators, amounts and 合計, and the observed payments;
/// payment settings / history via the account-aware web.
struct SupportAccountDetailView: View {
    let accountID: String

    @Environment(AppEnvironment.self) private var env
    @Query private var accountRows: [Account]
    @Query private var supports: [Support]
    @Query private var payments: [PaymentRecord]
    @Query private var assignments: [SupportPaymentAssignment]
    @Query(sort: [SortDescriptor(\PaymentProfile.sortOrder), SortDescriptor(\PaymentProfile.createdAt)]) private var profiles: [PaymentProfile]
    @Query private var syncStates: [SyncState]

    @State private var refreshError: RemoteError?

    init(accountID: String) {
        self.accountID = accountID
        _accountRows = Query(filter: #Predicate<Account> { $0.id == accountID })
        _supports = Query(filter: #Predicate<Support> { $0.accountID == accountID }, sort: \Support.creatorName)
        _payments = Query(filter: #Predicate<PaymentRecord> { $0.accountID == accountID }, sort: \PaymentRecord.paidAt, order: .reverse)
        _assignments = Query(filter: #Predicate<SupportPaymentAssignment> { $0.accountID == accountID })
        let raw = SyncResource.supports.rawValue
        _syncStates = Query(filter: #Predicate<SyncState> { $0.accountID == accountID && $0.resourceRaw == raw && $0.scope == "" })
    }

    var body: some View {
        let account = accountRows.first
        let group = SupportAnalyzer.byAccount(supports: supports.map(SupportSnapshot.init), assignments: assignments.map(AssignmentSnapshot.init),
                                              accountOrder: [accountID], includeInactive: true).first
        let paymentSnapshots = payments.map(PaymentSnapshot.init)
        let now = Date.now
        let status = SupportSyncStatus(states: syncStates)
        let paymentContext = SupportPaymentContext(profiles: profiles.map(PaymentProfileSnapshot.init),
                                                   defaults: account.map { [AccountPaymentDefault($0)] } ?? [],
                                                   payments: paymentSnapshots, now: now)

        List {
            if let error = status.bannerError(local: refreshError) {
                Section {
                    SyncStatusBanner(error: error, lastSync: status.lastSync)
                }
            }

            if let account {
                Section {
                    Picker("このアカウントのカード", selection: Binding(
                        get: { account.defaultPaymentProfileID },
                        set: { SupportMutations.setAccountDefault(store: env.store, accountID: accountID, profileID: $0) }
                    )) {
                        Text("なし").tag(String?.none)
                        ForEach(profiles) { p in
                            Text(PaymentProfileSnapshot(p).shortLabel).tag(Optional(p.id))
                        }
                    }
                    .accessibilityIdentifier("supportAccountDefaultProfile")
                    if account.defaultPaymentProfileID != nil {
                        Toggle("Webで確認した", isOn: Binding(
                            get: { account.defaultPaymentVerifiedAt != nil },
                            set: { SupportMutations.setAccountDefault(store: env.store, accountID: accountID,
                                                                      profileID: account.defaultPaymentProfileID, verified: $0) }
                        ))
                        .accessibilityIdentifier("supportAccountDefaultVerified")
                    }
                    if profiles.isEmpty {
                        NavigationLink(value: AppRoute.paymentProfiles) {
                            Label("Payment Profileを追加", systemImage: "plus")
                        }
                    }
                }
            }

            Section {
                HStack {
                    AccountBadge(accountID: accountID)
                    Spacer()
                    if let account, !account.enabled {
                        PillLabel(text: "無効", systemImage: "pause.circle", tint: .secondary)
                    }
                    if let account, account.sessionState == .expired || account.sessionState == .loggedOut {
                        PillLabel(text: "要ログイン", systemImage: "person.crop.circle.badge.exclamationmark", tint: .orange)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("合計")
                    Spacer()
                    Text(SupportText.monthly(group?.total ?? 0))
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .accessibilityIdentifier("supportAccountTotal")
                }
                Text("\(group?.activeCreatorCount ?? 0) クリエイターを支援中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let stopping = group?.lines.filter { $0.support.scheduledStop() != nil } ?? []
                if !stopping.isEmpty {
                    Text("うち停止予定 \(Formatters.yen(stopping.reduce(0) { $0 + $1.support.amount }))（来月予定には含みません）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let account, account.enabled, account.hasUnpaidPayments == true {
                Section {
                    PaymentStateAttentionCard(account: account)
                } header: {
                    Label("要確認", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                if let group, !group.lines.isEmpty {
                    ForEach(group.lines) { line in
                        NavigationLink(value: AppRoute.supportCreator(creatorID: line.support.creatorID)) {
                            SupportAccountLineRow(line: line, payment: paymentContext.summary(for: line))
                        }
                        .accessibilityIdentifier("supportAccountLine-\(line.support.creatorID)")
                    }
                } else {
                    Text("このアカウントで支援中のクリエイターはありません")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("クリエイター")
            }

            Section {
                Button {
                    env.web.openWeb(account: accountID, destination: .paymentSettings, purpose: .payment)
                } label: {
                    Label("お支払い方法を Web で確認", systemImage: "creditcard")
                }
                .accessibilityIdentifier("supportAccountPaymentSettings")
                Button {
                    env.web.openWeb(account: accountID, destination: .paymentHistory, purpose: .browse)
                } label: {
                    Label("お支払い履歴", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("supportAccountPaymentHistory")
                Button {
                    env.web.openWeb(account: accountID, destination: .supportingPlans, purpose: .payment)
                } label: {
                    Label("支援中のプラン", systemImage: "heart.text.square")
                }
            } header: {
                Text("FANBOX / pixiv で確認")
            }

            if paymentSnapshots.isEmpty {
                Section {
                    Text("お支払いデータなし（まだ取得されていません）")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("supportAccountNoPayments")
                } header: {
                    Text("お支払い")
                }
            } else {
                PaymentMonthSection(title: "今月のお支払い", records: recordsIn(SupportAnalyzer.monthRange(containing: now)))
                PaymentMonthSection(title: "先月のお支払い", records: recordsIn(SupportAnalyzer.previousMonthRange(before: now)))
                Section {
                    NavigationLink(value: AppRoute.paymentRecords(accountID: accountID)) {
                        Label("すべてのお支払い", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("supportAccountAllPayments")
                }
            }
        }
        .navigationTitle(account?.displayName ?? "アカウント")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            refreshError = await SupportSync.refresh(env: env, accountIDs: [accountID], includePayments: true)
        }
    }

    private func recordsIn(_ range: Range<Date>?) -> [PaymentRecord] {
        guard let range else { return [] }
        return payments.filter { range.contains($0.paidAt) }
    }
}

/// Every observed payment of one account (all months, newest first), one section per billing month (JST).
struct SupportPaymentRecordsView: View {
    let accountID: String

    @Environment(AppEnvironment.self) private var env
    @Query private var accountRows: [Account]
    @Query private var payments: [PaymentRecord]

    @State private var refreshError: RemoteError?

    init(accountID: String) {
        self.accountID = accountID
        _accountRows = Query(filter: #Predicate<Account> { $0.id == accountID })
        _payments = Query(filter: #Predicate<PaymentRecord> { $0.accountID == accountID }, sort: \PaymentRecord.paidAt, order: .reverse)
    }

    var body: some View {
        let byMonth = Dictionary(grouping: payments) { SupportAnalyzer.monthKey($0.paidAt) }
        let monthKeys = byMonth.keys.sorted(by: >)

        List {
            if let refreshError {
                Section {
                    SyncStatusBanner(error: refreshError, lastSync: nil)
                }
            }
            if monthKeys.isEmpty {
                Text("お支払いデータなし（まだ取得されていません）")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(monthKeys, id: \.self) { key in
                let records = byMonth[key] ?? []
                PaymentMonthSection(title: records.first.map { Self.monthTitle($0.paidAt) } ?? key, records: records)
            }
        }
        .accessibilityIdentifier("supportPaymentRecordsList")
        .navigationTitle(accountRows.first.map { "\($0.displayName)のお支払い" } ?? "お支払い")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            refreshError = await SupportSync.refresh(env: env, accountIDs: [accountID], includePayments: true)
        }
    }

    /// "2026年9月" (JST billing month).
    static func monthTitle(_ date: Date, calendar: Calendar = SupportBilling.calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return "\(c.year ?? 0)年\(c.month ?? 0)月"
    }
}

/// One billing month of payment records with its total. Records without a reported amount are listed but never summed.
struct PaymentMonthSection: View {
    let title: String
    let records: [PaymentRecord]

    var body: some View {
        Section {
            if records.isEmpty {
                Text("この月のお支払いは観測されていません")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records, id: \.key) { record in
                    PaymentRecordRow(record: record)
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if !records.isEmpty {
                    // Records without a reported amount are listed but never summed as ¥0.
                    Text(Formatters.yen(records.filter { $0.amountUnknown != true }.reduce(0) { $0 + $1.amount })).monospacedDigit()
                }
            }
        } footer: {
            let unknown = records.filter { $0.amountUnknown == true }.count
            if unknown > 0 {
                Text("金額不明のお支払い \(unknown) 件は合計に含みません")
            }
        }
    }
}

struct SupportAccountLineRow: View {
    let line: SupportLine
    let payment: SupportPaymentSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(line.support.creatorName).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                Text(Formatters.yen(line.support.amount))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(line.support.isActive ? .primary : .secondary)
                    .strikethrough(!line.support.isActive)
            }
            HStack(spacing: 6) {
                if !line.support.planTitle.isEmpty {
                    Text(line.support.planTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                SupportStatusPill(status: line.support.status)
                if let stop = line.support.scheduledStop() {
                    StopScheduledPill(source: stop)
                }
                Spacer()
            }
            SupportPaymentLine(summary: payment)
        }
    }
}

struct PaymentRecordRow: View {
    let record: PaymentRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.creatorName ?? "不明なクリエイター").lineLimit(1)
                HStack(spacing: 6) {
                    Text(Formatters.shortDate(record.paidAt))
                    if let method = SupportText.paymentMethodLabel(record.reportedPaymentMethod) {
                        Text(method)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if record.amountUnknown == true {
                Text("金額不明").foregroundStyle(.secondary)
            } else {
                Text(Formatters.yen(record.amount)).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

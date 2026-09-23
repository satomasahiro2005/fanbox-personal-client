import SwiftUI
import SwiftData

/// SPEC §10.2: one account — supported creators, amounts and 合計; payment settings / history via the account-aware web.
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

        List {
            if let error = status.bannerError(local: refreshError) {
                Section {
                    SyncStatusBanner(error: error, lastSync: status.lastSync)
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
            }

            Section {
                if let group, !group.lines.isEmpty {
                    ForEach(group.lines) { line in
                        NavigationLink(value: AppRoute.supportCreator(creatorID: line.support.creatorID)) {
                            SupportAccountLineRow(line: line,
                                                  profile: line.assignment?.paymentProfileID.flatMap { pid in profiles.first { $0.id == pid } })
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
            } footer: {
                Text("このアカウントでログインした画面が開きます。カード情報はアプリに保存されません。")
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
                paymentSection(title: "今月のお支払い",
                               records: recordsIn(SupportAnalyzer.monthRange(containing: now)))
                paymentSection(title: "先月のお支払い",
                               records: recordsIn(previousMonthRange(now)))
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

    private func previousMonthRange(_ now: Date) -> Range<Date>? {
        guard let current = SupportAnalyzer.monthRange(containing: now),
              let previous = Calendar.current.date(byAdding: .month, value: -1, to: current.lowerBound) else { return nil }
        return SupportAnalyzer.monthRange(containing: previous)
    }

    @ViewBuilder
    private func paymentSection(title: String, records: [PaymentRecord]) -> some View {
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
                    Text(Formatters.yen(records.reduce(0) { $0 + $1.amount })).monospacedDigit()
                }
            }
        }
    }
}

struct SupportAccountLineRow: View {
    let line: SupportLine
    let profile: PaymentProfile?

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
                Spacer()
                if let profile, let a = line.assignment, a.paymentProfileID != nil {
                    Text(profile.nickname).font(.caption2).foregroundStyle(.secondary)
                    VerificationLabel(state: a.verificationState)
                }
            }
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
                    if let method = record.reportedPaymentMethod, !method.isEmpty {
                        Text("支払い種別: \(method)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Formatters.yen(record.amount)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

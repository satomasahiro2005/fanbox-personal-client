import SwiftUI
import SwiftData

/// SPEC §10.1: one creator — 合計月額 and, per account, plan / fee / payment profile with its verification state.
struct SupportCreatorDetailView: View {
    let creatorID: String

    @Environment(AppEnvironment.self) private var env
    @Query private var supports: [Support]
    @Query private var assignments: [SupportPaymentAssignment]
    @Query(sort: [SortDescriptor(\PaymentProfile.sortOrder), SortDescriptor(\PaymentProfile.createdAt)]) private var profiles: [PaymentProfile]
    @Query private var history: [SupportHistory]
    @Query private var creators: [Creator]
    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)]) private var accounts: [Account]

    @State private var editRequest: AssignmentEditRequest?
    @State private var flowRequest: PaymentFlowRequest?
    @State private var pendingWeb: PendingWebOpen?
    @State private var refreshError: RemoteError?

    init(creatorID: String) {
        self.creatorID = creatorID
        _supports = Query(filter: #Predicate<Support> { $0.creatorID == creatorID })
        _assignments = Query(filter: #Predicate<SupportPaymentAssignment> { $0.creatorID == creatorID })
        var historyDescriptor = FetchDescriptor<SupportHistory>(predicate: #Predicate { $0.creatorID == creatorID },
                                                                sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        historyDescriptor.fetchLimit = 30
        _history = Query(historyDescriptor)
        _creators = Query(filter: #Predicate<Creator> { $0.creatorID == creatorID })
    }

    var body: some View {
        let known = Set(accounts.map(\.id))
        let snapshots = supports.filter { known.contains($0.accountID) }.map(SupportSnapshot.init)
        let group = SupportAnalyzer.byCreator(supports: snapshots, assignments: assignments.map(AssignmentSnapshot.init),
                                              accountOrder: accounts.map(\.id), includeInactive: true).first
        let creator = creators.first
        let name = creator?.name ?? group?.creatorName ?? creatorID
        let profileTuples = profiles.map { (id: $0.id, type: $0.type) }

        List {
            if let refreshError {
                Section {
                    SyncStatusBanner(error: refreshError, lastSync: nil)
                }
            }

            Section {
                HStack(spacing: 12) {
                    AvatarView(url: creator?.iconURL ?? group?.creatorIconURL, size: 44)
                    Text(name).font(.title3.bold()).lineLimit(2)
                    Spacer()
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("合計月額")
                    Spacer()
                    Text(Formatters.yen(group?.total ?? 0))
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .accessibilityIdentifier("supportCreatorTotal")
                }
            }

            Section {
                if let group, !group.lines.isEmpty {
                    ForEach(group.lines) { line in
                        Button {
                            editRequest = AssignmentEditRequest(accountID: line.support.accountID, creatorID: creatorID,
                                                                planID: line.support.planID)
                        } label: {
                            SupportCreatorLineRow(
                                line: line,
                                profile: line.assignment?.paymentProfileID.flatMap { pid in profiles.first { $0.id == pid } },
                                inferredProfile: inferredProfile(for: line, tuples: profileTuples)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("supportCreatorLine-\(line.support.accountID)")
                    }
                } else {
                    Text("このクリエイターを支援しているアカウントはありません")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("アカウント別")
            } footer: {
                Text("タップして支払い方法（Payment Profile）を設定します。「推定」「手動設定」は FANBOX 上で確認された情報ではありません。")
            }

            Section {
                Button {
                    flowRequest = PaymentFlowRequest(creatorID: creatorID, planID: nil, accountID: nil)
                } label: {
                    Label("プラン変更 / 再支援", systemImage: "heart.circle")
                }
                .accessibilityIdentifier("supportCreatorPaymentFlow")
                NavigationLink(value: AppRoute.creator(creatorID: creatorID)) {
                    Label("クリエイターページ", systemImage: "person.crop.circle")
                }
            }

            Section {
                if history.isEmpty {
                    Text("まだ観測された変更はありません")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(history) { entry in
                        SupportHistoryRow(entry: entry, showsCreator: false)
                    }
                }
                NavigationLink(value: AppRoute.supportHistory) {
                    Text("すべての支援履歴")
                }
            } header: {
                Text("支援履歴")
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            let ids = accounts.filter(\.enabled).map(\.id)
            refreshError = await SupportSync.refresh(env: env, accountIDs: ids, includePayments: false)
        }
        .sheet(item: $editRequest, onDismiss: openPending) { request in
            AssignmentEditorSheet(request: request) { pending in
                pendingWeb = pending
                editRequest = nil
            }
        }
        .sheet(item: $flowRequest, onDismiss: openPending) { request in
            PaymentFlowView(creatorID: request.creatorID, planID: request.planID, preselectedAccountID: request.accountID) { pending in
                pendingWeb = pending
                flowRequest = nil
            }
        }
    }

    private func openPending() {
        SupportSync.open(pendingWeb, env: env)
        pendingWeb = nil
    }

    /// Display-only guess when the user has not assigned a profile (shown as "推定（未確認）").
    private func inferredProfile(for line: SupportLine, tuples: [(id: String, type: PaymentProfileType)]) -> PaymentProfile? {
        guard line.assignment?.paymentProfileID == nil,
              let id = SupportAnalyzer.inferredProfileID(reportedPaymentMethod: line.support.reportedPaymentMethod, profiles: tuples)
        else { return nil }
        return profiles.first { $0.id == id }
    }
}

/// Account line of the creator detail: plan title & fee, status and payment assignment.
struct SupportCreatorLineRow: View {
    let line: SupportLine
    let profile: PaymentProfile?
    var inferredProfile: PaymentProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                AccountBadge(accountID: line.support.accountID)
                Spacer()
                SupportStatusPill(status: line.support.status)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(line.support.planTitle.isEmpty ? "プラン" : line.support.planTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                Text(SupportText.monthly(line.support.amount))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(line.support.isActive ? .primary : .secondary)
                    .strikethrough(!line.support.isActive)
            }
            AssignmentSummaryView(assignment: line.assignment, profile: profile, inferredProfile: inferredProfile,
                                  reportedPaymentMethod: line.support.reportedPaymentMethod)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Assignment editor (SPEC §13)

/// Chooses which Payment Profile the user believes pays this support, and how sure they are.
/// "Web で確認した" ⇒ `.verified` with `lastVerifiedAt = now`; otherwise `.manual`.
struct AssignmentEditorSheet: View {
    enum Confirmation: Hashable { case manual, verifiedInWeb }

    let request: AssignmentEditRequest
    /// Called with the web session to open once this sheet is dismissed.
    var onOpenWeb: (PendingWebOpen) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\PaymentProfile.sortOrder), SortDescriptor(\PaymentProfile.createdAt)]) private var profiles: [PaymentProfile]
    @Query private var supports: [Support]

    @State private var selectedProfileID: String?
    @State private var confirmation: Confirmation = .manual
    @State private var loaded = false
    @State private var original: AssignmentSnapshot?
    @State private var isAddingProfile = false

    init(request: AssignmentEditRequest, onOpenWeb: @escaping (PendingWebOpen) -> Void) {
        self.request = request
        self.onOpenWeb = onOpenWeb
        let key = Support.key(accountID: request.accountID, creatorID: request.creatorID)
        _supports = Query(filter: #Predicate<Support> { $0.key == key })
    }

    var body: some View {
        let support = supports.first
        NavigationStack {
            Form {
                Section {
                    AccountBadge(accountID: request.accountID)
                    if let support {
                        LabeledContent(support.creatorName) {
                            Text(SupportText.monthly(support.amount)).monospacedDigit()
                        }
                        if !support.planTitle.isEmpty {
                            Text(support.planTitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let original {
                        HStack {
                            Text("現在の状態").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            VerificationLabel(state: original.verificationState, lastVerifiedAt: original.lastVerifiedAt)
                        }
                    }
                }

                Section {
                    Picker("Payment Profile", selection: $selectedProfileID) {
                        Text("未設定").tag(String?.none)
                        ForEach(profiles) { p in
                            Text("\(p.nickname)  \(p.displayDetail)").tag(Optional(p.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("assignmentProfilePicker")
                    Button {
                        isAddingProfile = true
                    } label: {
                        Label("Payment Profile を追加", systemImage: "plus")
                    }
                } header: {
                    Text("支払い方法（Payment Profile）")
                }

                if selectedProfileID != nil {
                    Section {
                        Picker("確認状態", selection: $confirmation) {
                            Text("手動設定").tag(Confirmation.manual)
                            Text("Web で確認した").tag(Confirmation.verifiedInWeb)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("assignmentConfirmationPicker")
                    } header: {
                        Text("確認状態")
                    } footer: {
                        Text("「Web で確認した」は FANBOX / pixiv のお支払い方法画面で実際に確認した場合のみ選んでください。確認日時が記録されます。")
                    }
                }

                Section {
                    Button {
                        saveIfChanged(forcing: .manual)
                        onOpenWeb(PendingWebOpen(accountID: request.accountID, destination: .paymentSettings, purpose: .payment))
                    } label: {
                        Label("このアカウントのお支払い方法を Web で確認", systemImage: "safari")
                    }
                    .accessibilityIdentifier("assignmentOpenPaymentSettings")
                } footer: {
                    Text("選択中の内容は「手動設定」として保存してから開きます。確認後、この画面で「Web で確認した」を選んでください。カード情報はアプリに保存されません。")
                }
            }
            .navigationTitle("支払い方法の割り当て")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveIfChanged(forcing: nil)
                        dismiss()
                    }
                    .accessibilityIdentifier("assignmentSave")
                }
            }
            .sheet(isPresented: $isAddingProfile) {
                PaymentProfileEditorView(draft: PaymentProfileDraft()) { profile in
                    selectedProfileID = profile.id
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let existing = SupportMutations.assignment(store: env.store, accountID: request.accountID, creatorID: request.creatorID) {
            let snapshot = AssignmentSnapshot(existing)
            original = snapshot
            selectedProfileID = snapshot.paymentProfileID
            confirmation = snapshot.verificationState == .verified ? .verifiedInWeb : .manual
        }
    }

    /// Writes only when something changed, so re-saving never refreshes `lastVerifiedAt` without a new check.
    private func saveIfChanged(forcing forced: VerificationState?) {
        let state: VerificationState
        if let forced, selectedProfileID != original?.paymentProfileID || original?.verificationState != .verified {
            state = forced
        } else {
            state = confirmation == .verifiedInWeb ? .verified : .manual
        }
        let effective: VerificationState = selectedProfileID == nil ? .unknown : state
        if let original, original.paymentProfileID == selectedProfileID, original.verificationState == effective {
            return
        }
        if original == nil && selectedProfileID == nil { return }
        SupportMutations.setAssignment(store: env.store, accountID: request.accountID, creatorID: request.creatorID,
                                       planID: request.planID, profileID: selectedProfileID, state: effective)
    }
}

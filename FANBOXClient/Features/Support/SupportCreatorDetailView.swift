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
    @Query private var payments: [PaymentRecord]
    @Query(FetchDescriptorFactory.enabledAccounts()) private var accounts: [Account]

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
        _payments = Query(filter: #Predicate<PaymentRecord> { $0.creatorID == creatorID })
    }

    var body: some View {
        let known = Set(accounts.map(\.id))
        let snapshots = supports.filter { known.contains($0.accountID) }.map(SupportSnapshot.init)
        let group = SupportAnalyzer.byCreator(supports: snapshots, assignments: assignments.map(AssignmentSnapshot.init),
                                              accountOrder: accounts.map(\.id), includeInactive: true).first
        let visibleHistory = history.filter { known.contains($0.accountID) }
        let creator = creators.first
        let name = creator?.name ?? group?.creatorName ?? creatorID
        let paymentContext = SupportPaymentContext(profiles: profiles, accounts: accounts,
                                                   payments: payments.filter { known.contains($0.accountID) })

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
                let stopping = group?.lines.filter { $0.support.scheduledStop() != nil } ?? []
                if !stopping.isEmpty {
                    Text("うち停止予定 \(Formatters.yen(stopping.reduce(0) { $0 + $1.support.amount }))（来月予定には含みません）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("supportCreatorStopping")
                }
            }

            Section {
                if let group, !group.lines.isEmpty {
                    ForEach(group.lines) { line in
                        Button {
                            editRequest = AssignmentEditRequest(accountID: line.support.accountID, creatorID: creatorID,
                                                                planID: line.support.planID)
                        } label: {
                            SupportCreatorLineRow(line: line, payment: paymentContext.summary(for: line))
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
                Text("タップして支払い方法（Payment Profile）や停止予定を設定します。「推定（未確認）」「手動設定」「停止予定（自分で記録）」は FANBOX 上で確認された情報ではありません。")
            }

            Section {
                Button {
                    flowRequest = PaymentFlowRequest(creatorID: creatorID)
                } label: {
                    Label("支援を追加 / プラン変更", systemImage: "heart.circle")
                }
                .accessibilityIdentifier("supportCreatorPaymentFlow")
                NavigationLink(value: AppRoute.creator(creatorID: creatorID)) {
                    Label("クリエイターページ", systemImage: "person.crop.circle")
                }
            }

            Section {
                if visibleHistory.isEmpty {
                    Text("まだ観測された変更はありません")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleHistory) { entry in
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
            let ids = accounts.map(\.id)
            refreshError = await SupportSync.refresh(env: env, accountIDs: ids, includePayments: true)
        }
        .sheet(item: $editRequest, onDismiss: openPending) { request in
            AssignmentEditorSheet(request: request) { pending in
                pendingWeb = pending
                editRequest = nil
            }
        }
        .paymentFlowSheet($flowRequest)
    }

    private func openPending() {
        SupportSync.open(pendingWeb, env: env)
        pendingWeb = nil
    }
}

/// Account line of the creator detail: plan title & fee, status, and the payment line (card, 前回, 次回).
struct SupportCreatorLineRow: View {
    let line: SupportLine
    let payment: SupportPaymentSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                AccountBadge(accountID: line.support.accountID)
                Spacer()
                if let stop = line.support.scheduledStop() {
                    StopScheduledPill(source: stop)
                }
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
            SupportPaymentLine(summary: payment)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Assignment editor (SPEC §13)

/// Chooses which Payment Profile the user believes pays this support, and how sure they are.
/// "Webで確認した" ⇒ `.verified` with `lastVerifiedAt = now`; otherwise `.manual`. No profile of its own
/// (アカウントの既定に従う) ⇒ the support inherits the account default when rendered.
struct AssignmentEditorSheet: View {
    enum Confirmation: Hashable { case manual, verifiedInWeb }

    let request: AssignmentEditRequest
    /// Called with the web session to open once this sheet is dismissed.
    var onOpenWeb: (PendingWebOpen) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\PaymentProfile.sortOrder), SortDescriptor(\PaymentProfile.createdAt)]) private var profiles: [PaymentProfile]
    @Query private var supports: [Support]
    @Query private var accountRows: [Account]

    @State private var selectedProfileID: String?
    @State private var confirmation: Confirmation = .manual
    @State private var loaded = false
    @State private var original: AssignmentSnapshot?
    @State private var isAddingProfile = false
    /// User-entered "停止予定" of the current billing month (SPEC §10.3 来月予定).
    @State private var stopMarked = false
    @State private var originalStopMarked = false

    init(request: AssignmentEditRequest, onOpenWeb: @escaping (PendingWebOpen) -> Void) {
        self.request = request
        self.onOpenWeb = onOpenWeb
        let key = Support.key(accountID: request.accountID, creatorID: request.creatorID)
        _supports = Query(filter: #Predicate<Support> { $0.key == key })
        let accountID = request.accountID
        _accountRows = Query(filter: #Predicate<Account> { $0.id == accountID })
    }

    var body: some View {
        let support = supports.first
        // Named only when the support line would show it (PaymentResolution skips a default FANBOX's type contradicts).
        let accountDefault = accountRows.first?.defaultPaymentProfileID.flatMap { id in profiles.first { $0.id == id } }
            .flatMap { PaymentResolution.contradicts($0.type, reportedPaymentMethod: support?.reportedPaymentMethod) ? nil : $0 }
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
                        Text(accountDefault.map { "アカウントの既定に従う（\(PaymentProfileSnapshot($0).shortLabel)）" } ?? "アカウントの既定に従う")
                            .tag(String?.none)
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
                        Label("Payment Profileを追加", systemImage: "plus")
                    }
                } header: {
                    Text("支払い方法（Payment Profile）")
                }

                if selectedProfileID != nil {
                    Section {
                        Picker("確認状態", selection: $confirmation) {
                            Text("手動設定").tag(Confirmation.manual)
                            Text("Webで確認した").tag(Confirmation.verifiedInWeb)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("assignmentConfirmationPicker")
                    } header: {
                        Text("確認状態")
                    } footer: {
                        Text("「Webで確認した」はFANBOX / pixivのお支払い方法画面で実際に確認した場合のみ選んでください。確認日時が記録されます。")
                    }
                }

                if let support, support.isActive {
                    Section {
                        if SupportSnapshot(support).scheduledStop() == .observed {
                            Label("FANBOX で停止予定を観測しました。来月予定には含みません。", systemImage: "calendar.badge.minus")
                                .font(.footnote)
                                .accessibilityIdentifier("assignmentObservedStop")
                        }
                        Toggle("停止予定として記録（自分で記録）", isOn: $stopMarked)
                            .accessibilityIdentifier("assignmentStopToggle")
                    } header: {
                        Text("来月の予定")
                    } footer: {
                        Text("FANBOX で支援を停止した場合などに記録します。自分で記録した内容で、FANBOX 上で確認された情報ではありません。今月（日本時間）の間だけ有効で、来月予定の合計から除外します。")
                    }
                }

                Section {
                    Button {
                        saveIfChanged(forcing: .manual)
                        saveStopMarkIfChanged()
                        onOpenWeb(PendingWebOpen(accountID: request.accountID, destination: .creatorPlans(creatorID: request.creatorID),
                                                 purpose: .payment))
                    } label: {
                        Label("このクリエイターのプランをWebで確認", systemImage: "safari")
                    }
                    .accessibilityIdentifier("assignmentOpenCreatorPlans")
                }
            }
            .navigationTitle("支払い方法・停止予定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveIfChanged(forcing: nil)
                        saveStopMarkIfChanged()
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
        if let support = supports.first {
            stopMarked = SupportMutations.hasEffectiveUserStopMark(support)
            originalStopMarked = stopMarked
        }
        if let existing = SupportMutations.assignment(store: env.store, accountID: request.accountID, creatorID: request.creatorID) {
            let snapshot = AssignmentSnapshot(existing)
            original = snapshot
            selectedProfileID = snapshot.paymentProfileID
            confirmation = snapshot.verificationState == .verified ? .verifiedInWeb : .manual
        }
    }

    private func saveStopMarkIfChanged() {
        guard stopMarked != originalStopMarked, let support = supports.first else { return }
        SupportMutations.setUserStopMark(support, marked: stopMarked, store: env.store)
        originalStopMarked = stopMarked
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

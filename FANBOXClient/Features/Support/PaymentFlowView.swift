import SwiftUI
import SwiftData

/// SPEC §14 payment web bridge: Plan 選択 → Account 選択 → Payment Profile 選択 → account-aware WebView → 状態再同期.
/// Card entry / payment is NEVER implemented natively; the FANBOX / pixiv page does it in the chosen account's session.
/// Present as a sheet. Hosts that can open the web only after the sheet is dismissed pass `onHandoff`.
struct PaymentFlowView: View {
    enum Step: Int, CaseIterable, Hashable {
        case plan, account, profile, confirm

        var title: String {
            switch self {
            case .plan: return "プラン"
            case .account: return "アカウント"
            case .profile: return "支払い方法"
            case .confirm: return "FANBOX へ"
            }
        }
    }

    let creatorID: String
    var planID: String? = nil
    var preselectedAccountID: String? = nil
    /// Receives the web session to open after the host dismissed this sheet. When nil the flow dismisses itself and
    /// opens the account-aware web right after.
    var onHandoff: ((PendingWebOpen) -> Void)? = nil

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query private var plans: [Plan]
    @Query private var supports: [Support]
    @Query private var creators: [Creator]
    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)]) private var accounts: [Account]
    @Query(sort: [SortDescriptor(\PaymentProfile.sortOrder), SortDescriptor(\PaymentProfile.createdAt)]) private var profiles: [PaymentProfile]

    @State private var step: Step = .plan
    @State private var selectedPlanID: String?
    @State private var selectedAccountID: String?
    @State private var selectedProfileID: String?
    @State private var isLoadingPlans = false
    @State private var planLoadError: RemoteError?
    @State private var didSetUp = false
    @State private var isAddingProfile = false

    init(creatorID: String, planID: String? = nil, preselectedAccountID: String? = nil, onHandoff: ((PendingWebOpen) -> Void)? = nil) {
        self.creatorID = creatorID
        self.planID = planID
        self.preselectedAccountID = preselectedAccountID
        self.onHandoff = onHandoff
        _plans = Query(filter: #Predicate<Plan> { $0.creatorID == creatorID }, sort: \Plan.fee)
        _supports = Query(filter: #Predicate<Support> { $0.creatorID == creatorID })
        _creators = Query(filter: #Predicate<Creator> { $0.creatorID == creatorID })
    }

    private var creatorName: String {
        creators.first?.name ?? supports.first?.creatorName ?? creatorID
    }

    private var enabledAccounts: [Account] { accounts.filter(\.enabled) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PaymentFlowStepIndicator(current: step)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                Group {
                    switch step {
                    case .plan: planStep
                    case .account: accountStep
                    case .profile: profileStep
                    case .confirm: confirmStep
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .safeAreaInset(edge: .bottom) { navigationBar }
            .navigationTitle("支援 / プラン変更")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .accessibilityIdentifier("paymentFlowCancel")
                }
            }
            .task { await setUp() }
            .onChange(of: selectedAccountID) { _, newValue in
                preselectProfile(for: newValue)
            }
            .sheet(isPresented: $isAddingProfile) {
                PaymentProfileEditorView(draft: PaymentProfileDraft()) { profile in
                    selectedProfileID = profile.id
                }
            }
        }
        .accessibilityIdentifier("paymentFlow")
    }

    // MARK: Step 1 — Plan

    private var planStep: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    AvatarView(url: creators.first?.iconURL ?? supports.first?.creatorIconURL, size: 36)
                    Text(creatorName).font(.headline)
                }
            }
            Section {
                if plans.isEmpty {
                    if isLoadingPlans {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("プランを取得中…").foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(planLoadError == nil ? "プラン情報がありません" : "プランを取得できませんでした")
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("再取得") { Task { await loadPlans() } }
                                Button("プランを選ばずに進む") { step = .account }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                ForEach(plans, id: \.planID) { plan in
                    Button {
                        selectedPlanID = plan.planID
                    } label: {
                        PlanChoiceRow(plan: plan, isSelected: selectedPlanID == plan.planID,
                                      supportingAccountIDs: supports.filter { $0.isActive && $0.planID == plan.planID }.map(\.accountID))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("paymentFlowPlan-\(plan.planID)")
                }
            } header: {
                Text("1. プランを選択")
            } footer: {
                Text("最後に同期したプラン情報です。最新の内容は FANBOX の画面で確認できます。")
            }
        }
    }

    // MARK: Step 2 — Account

    private var accountStep: some View {
        List {
            Section {
                ForEach(enabledAccounts) { account in
                    let support = supports.first { $0.accountID == account.id }
                    let isOwn = account.creatorID == creatorID
                    Button {
                        selectedAccountID = account.id
                    } label: {
                        AccountChoiceRow(account: account, support: support, isSelected: selectedAccountID == account.id, isOwnCreator: isOwn)
                    }
                    .buttonStyle(.plain)
                    .disabled(isOwn)
                    .accessibilityIdentifier("paymentFlowAccount-\(account.id)")
                }
                if enabledAccounts.isEmpty {
                    Text("有効なアカウントがありません").foregroundStyle(.secondary)
                }
            } header: {
                Text("2. アカウントを選択")
            } footer: {
                Text("選択したアカウントでログインした FANBOX の画面で手続きします。")
            }

            if let accountID = selectedAccountID, let current = supports.first(where: { $0.accountID == accountID && $0.isActive }) {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("このアカウントは既に支援中です")
                                .fontWeight(.semibold)
                            Text("現在: \(current.planTitle.isEmpty ? "プラン" : current.planTitle) \(SupportText.monthly(current.amount))")
                            if let selectedPlanID, current.planID == selectedPlanID {
                                Text("選択したプランと同じプランです。")
                            } else {
                                Text("手続きするとプラン変更になる場合があります。")
                            }
                        }
                        .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .accessibilityIdentifier("paymentFlowAlreadySupporting")
                }
            }
        }
    }

    // MARK: Step 3 — Payment profile

    private var profileStep: some View {
        List {
            Section {
                Button {
                    selectedProfileID = nil
                } label: {
                    choiceRow(title: "指定しない", detail: nil, isSelected: selectedProfileID == nil)
                }
                .buttonStyle(.plain)
                ForEach(profiles) { profile in
                    Button {
                        selectedProfileID = profile.id
                    } label: {
                        choiceRow(title: profile.nickname, detail: profile.displayDetail, isSelected: selectedProfileID == profile.id)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("paymentFlowProfile-\(profile.nickname)")
                }
                Button {
                    isAddingProfile = true
                } label: {
                    Label("Payment Profile を追加", systemImage: "plus")
                }
            } header: {
                Text("3. Payment Profile（任意）")
            } footer: {
                Text("\(SupportText.paymentChoiceNote)。ここで選んだ内容は自分用の記録（手動設定）で、FANBOX 上で確認された情報ではありません。")
            }
        }
    }

    // MARK: Step 4 — Confirm & hand off

    private var confirmStep: some View {
        List {
            Section {
                LabeledContent("クリエイター", value: creatorName)
                LabeledContent("プラン") {
                    Text(selectedPlanText).multilineTextAlignment(.trailing)
                }
                LabeledContent("アカウント") {
                    if let selectedAccountID {
                        AccountBadge(accountID: selectedAccountID)
                    } else {
                        Text("未選択").foregroundStyle(.red)
                    }
                }
                LabeledContent("Payment Profile") {
                    Text(profiles.first { $0.id == selectedProfileID }?.nickname ?? "指定しない")
                }
            } header: {
                Text("確認")
            }

            Section {
                Label("決済はアプリ内では行いません。選択したアカウントの FANBOX / pixiv の画面が開きます。", systemImage: "lock.shield")
                Label(SupportText.paymentChoiceNote, systemImage: "creditcard")
                Label("画面を閉じると支援状態を再同期します。", systemImage: "arrow.clockwise")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Section {
                Button {
                    handOff()
                } label: {
                    Label("FANBOX で手続きへ", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedAccountID == nil)
                .accessibilityIdentifier("paymentFlowHandoff")
            }
            .listRowBackground(Color.clear)
        }
    }

    private var selectedPlanText: String {
        guard let selectedPlanID else { return "FANBOX の画面で選択" }
        if let plan = plans.first(where: { $0.planID == selectedPlanID }) {
            return "\(plan.title) \(SupportText.monthly(plan.fee))"
        }
        if let support = supports.first(where: { $0.planID == selectedPlanID }) {
            return "\(support.planTitle) \(SupportText.monthly(support.amount))"
        }
        return "選択したプラン"
    }

    // MARK: Bottom navigation

    private var navigationBar: some View {
        HStack {
            if let previous = Step(rawValue: step.rawValue - 1) {
                Button {
                    step = previous
                } label: {
                    Label("戻る", systemImage: "chevron.left")
                }
                .accessibilityIdentifier("paymentFlowBack")
            }
            Spacer()
            if let next = Step(rawValue: step.rawValue + 1) {
                Button {
                    step = next
                } label: {
                    Label("次へ", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
                .accessibilityIdentifier("paymentFlowNext")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canAdvance: Bool {
        switch step {
        case .plan: return selectedPlanID != nil
        case .account: return selectedAccountID != nil
        case .profile: return true
        case .confirm: return false
        }
    }

    private func choiceRow(title: String, detail: String?, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
    }

    // MARK: Actions

    private func setUp() async {
        if !didSetUp {
            didSetUp = true
            selectedPlanID = planID
            if let preselectedAccountID {
                selectedAccountID = preselectedAccountID
            } else if enabledAccounts.count == 1 {
                selectedAccountID = enabledAccounts.first?.id
            }
            preselectProfile(for: selectedAccountID)
            if planID == nil {
                step = .plan
            } else {
                step = preselectedAccountID == nil ? .account : .profile
            }
        }
        if plans.isEmpty {
            await loadPlans()
        }
    }

    /// Local plans first; only when none are cached ask SyncEngine for this creator's plans.
    private func loadPlans() async {
        guard !isLoadingPlans else { return }
        guard let accountID = selectedAccountID ?? preselectedAccountID ?? env.store.mainAccount()?.id ?? enabledAccounts.first?.id else {
            return
        }
        isLoadingPlans = true
        defer { isLoadingPlans = false }
        let outcome = await RequestContext.$priority.withValue(.interactiveRead) {
            await env.sync.sync(.plans, accountID: accountID, scope: creatorID, reason: .onDemand)
        }
        planLoadError = outcome.error
    }

    private func preselectProfile(for accountID: String?) {
        guard let accountID,
              let existing = SupportMutations.assignment(store: env.store, accountID: accountID, creatorID: creatorID),
              let profileID = existing.paymentProfileID,
              profiles.contains(where: { $0.id == profileID }) else { return }
        selectedProfileID = profileID
    }

    private func handOff() {
        guard let accountID = selectedAccountID else { return }
        SupportMutations.recordPaymentIntent(store: env.store, accountID: accountID, creatorID: creatorID,
                                             planID: selectedPlanID, profileID: selectedProfileID)
        let destination: WebDestination = selectedPlanID.map { .plan(creatorID: creatorID, planID: $0) } ?? .creatorPlans(creatorID: creatorID)
        let pending = PendingWebOpen(accountID: accountID, destination: destination, purpose: .payment)
        if let onHandoff {
            onHandoff(pending)
        } else {
            // The web cover is presented from the root; give this sheet time to go away first.
            let env = self.env
            dismiss()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                SupportSync.open(pending, env: env)
            }
        }
    }
}

// MARK: - Rows

struct PaymentFlowStepIndicator: View {
    let current: PaymentFlowView.Step

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PaymentFlowView.Step.allCases, id: \.self) { step in
                VStack(spacing: 3) {
                    Capsule()
                        .fill(step.rawValue <= current.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                    Text(step.title)
                        .font(.caption2)
                        .foregroundStyle(step == current ? .primary : .secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ステップ \(current.rawValue + 1) / \(PaymentFlowView.Step.allCases.count): \(current.title)")
    }
}

struct PlanChoiceRow: View {
    let plan: Plan
    let isSelected: Bool
    let supportingAccountIDs: [String]

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.title).font(.body.weight(.medium))
                Text(SupportText.monthly(plan.fee)).font(.subheadline.monospacedDigit())
                if !plan.planDescription.isEmpty {
                    Text(plan.planDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !supportingAccountIDs.isEmpty {
                    HStack(spacing: 4) {
                        Text("支援中:").font(.caption2).foregroundStyle(.secondary)
                        AccountBadgeRow(accountIDs: supportingAccountIDs)
                    }
                }
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
    }
}

struct AccountChoiceRow: View {
    let account: Account
    let support: Support?
    let isSelected: Bool
    let isOwnCreator: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                AccountBadge(accountID: account.id)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(support?.isActive == true ? .orange : .secondary)
                if account.sessionState == .expired || account.sessionState == .loggedOut {
                    Text("ログインが必要な可能性があります").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .opacity(isOwnCreator ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    private var statusText: String {
        if isOwnCreator { return "自分のクリエイターページです" }
        guard let support else { return "未支援" }
        switch support.status {
        case .active:
            return "支援中: \(support.planTitle.isEmpty ? "プラン" : support.planTitle) \(SupportText.monthly(support.amount))"
        case .missing:
            return "支援中一覧から消えました（以前: \(SupportText.monthly(support.amount))）"
        case .ended:
            return "支援終了"
        case .unknown:
            return "支援状態を確認できません"
        }
    }
}

import SwiftUI
import SwiftData

/// SPEC §12: logical payment profiles ("楽天カード / Visa •••• 1234"). Never card numbers, CVC, PIN or expiry.
struct PaymentProfilesView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: [SortDescriptor(\PaymentProfile.sortOrder), SortDescriptor(\PaymentProfile.createdAt)]) private var profiles: [PaymentProfile]
    @Query private var assignments: [SupportPaymentAssignment]
    @Query private var supports: [Support]

    @State private var editing: ProfileEditRequest?
    @State private var pendingDelete: PaymentProfile?

    init() {}

    var body: some View {
        let activeKeys = Set(supports.filter(\.isActive).map(\.key))
        let usage = PaymentProfileUsage.counts(assignments: assignments.map(AssignmentSnapshot.init), activeSupportKeys: activeKeys)

        List {
            Section {
                Label(SupportText.storagePolicyNote, systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("paymentProfilePolicyNote")
            }

            Section {
                if profiles.isEmpty {
                    Text("Payment Profile はまだありません")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(profiles) { profile in
                    Button {
                        editing = ProfileEditRequest(draft: PaymentProfileDraft(profile))
                    } label: {
                        PaymentProfileRow(profile: profile, usageCount: usage[profile.id] ?? 0)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("paymentProfileRow-\(profile.nickname)")
                }
                .onDelete { offsets in
                    if let index = offsets.first, profiles.indices.contains(index) {
                        pendingDelete = profiles[index]
                    }
                }
                .onMove { source, destination in
                    var ordered = profiles
                    ordered.move(fromOffsets: source, toOffset: destination)
                    SupportMutations.reorderProfiles(ordered, store: env.store)
                }
            } header: {
                Text("Payment Profile")
            } footer: {
                Text("支援ごとの割り当ては「支援」→ クリエイターから設定します。")
            }
        }
        .accessibilityIdentifier("paymentProfilesList")
        .navigationTitle("Payment Profile")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !profiles.isEmpty {
                    EditButton()
                }
                Button {
                    editing = ProfileEditRequest(draft: PaymentProfileDraft())
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Payment Profile を追加")
                .accessibilityIdentifier("addPaymentProfile")
            }
        }
        .sheet(item: $editing) { request in
            PaymentProfileEditorView(draft: request.draft)
        }
        .confirmationDialog(
            "「\(pendingDelete?.nickname ?? "")」を削除しますか？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { profile in
            Button("削除", role: .destructive) {
                SupportMutations.deleteProfile(id: profile.id, store: env.store)
                pendingDelete = nil
            }
            .accessibilityIdentifier("confirmDeletePaymentProfile")
            Button("キャンセル", role: .cancel) { pendingDelete = nil }
        } message: { profile in
            let count = assignments.filter { $0.paymentProfileID == profile.id }.count
            if count > 0 {
                Text("\(count) 件の支援の割り当てが解除され、「不明」になります。")
            } else {
                Text("この Payment Profile を削除します。")
            }
        }
    }
}

struct ProfileEditRequest: Identifiable {
    let id = UUID()
    var draft: PaymentProfileDraft
}

struct PaymentProfileRow: View {
    let profile: PaymentProfile
    let usageCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.nickname).font(.body.weight(.medium))
                Text(profile.displayDetail).font(.caption).foregroundStyle(.secondary)
                if !profile.memo.isEmpty {
                    Text(profile.memo).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(usageCount > 0 ? "\(usageCount) 件の支援" : "未使用")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("paymentProfileUsage")
        }
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch profile.type {
        case .creditCard, .debitCard: return "creditcard"
        case .paypal: return "p.circle"
        case .carrierBilling: return "iphone"
        case .other: return "wallet.pass"
        }
    }
}

// MARK: - Editor

/// Add / edit form. Values stay in memory until they pass `PaymentProfileValidator` (SPEC §12 / §39).
struct PaymentProfileEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var draft: PaymentProfileDraft
    /// "" = not set, otherwise one of `SupportText.brands`.
    @State private var brandChoice: String
    @State private var customBrand: String
    @State private var nicknameTouched = false
    var onSaved: ((PaymentProfile) -> Void)?

    init(draft: PaymentProfileDraft, onSaved: ((PaymentProfile) -> Void)? = nil) {
        _draft = State(initialValue: draft)
        let brand = draft.brand ?? ""
        if brand.isEmpty {
            _brandChoice = State(initialValue: "")
            _customBrand = State(initialValue: "")
        } else if SupportText.brands.contains(brand) {
            _brandChoice = State(initialValue: brand)
            _customBrand = State(initialValue: "")
        } else {
            _brandChoice = State(initialValue: "その他")
            _customBrand = State(initialValue: brand)
        }
        _nicknameTouched = State(initialValue: draft.id != nil)
        self.onSaved = onSaved
    }

    var body: some View {
        let candidate = currentDraft
        let issues = candidate.issues
        let shownIssues = issues.filter { $0 != .nicknameRequired || nicknameTouched }

        NavigationStack {
            Form {
                Section {
                    Label(SupportText.storagePolicyNote, systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("名前（例: 楽天カード）", text: $draft.nickname)
                        .onChange(of: draft.nickname) { nicknameTouched = true }
                        .accessibilityIdentifier("paymentProfileNickname")
                    Picker("種類", selection: $draft.type) {
                        ForEach(PaymentProfileType.allCases, id: \.self) { type in
                            Text(SupportText.profileTypeLabel(type)).tag(type)
                        }
                    }
                    .accessibilityIdentifier("paymentProfileType")
                }

                if SupportText.isCardType(draft.type) {
                    Section {
                        Picker("ブランド", selection: $brandChoice) {
                            Text("未設定").tag("")
                            ForEach(SupportText.brands, id: \.self) { brand in
                                Text(brand).tag(brand)
                            }
                        }
                        .accessibilityIdentifier("paymentProfileBrand")
                        if brandChoice == "その他" {
                            TextField("ブランド名（任意）", text: $customBrand)
                                .accessibilityIdentifier("paymentProfileCustomBrand")
                        }
                        TextField("下4桁（任意）", text: $draft.last4)
                            .keyboardType(.numberPad)
                            .textContentType(nil)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("paymentProfileLast4")
                    } header: {
                        Text("カード")
                    } footer: {
                        Text("識別用に下4桁だけを保存できます。カード番号全体は入力しないでください。")
                    }
                }

                Section {
                    TextField("メモ（例: 引き落とし口座、用途など）", text: $draft.memo, axis: .vertical)
                        .lineLimit(2...5)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("paymentProfileMemo")
                } header: {
                    Text("メモ")
                } footer: {
                    Text("暗証番号・セキュリティコード・有効期限は書かないでください。")
                }

                if !shownIssues.isEmpty {
                    Section {
                        ForEach(Array(shownIssues.enumerated()), id: \.offset) { _, issue in
                            Label(issue.message, systemImage: "exclamationmark.octagon")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .accessibilityIdentifier("paymentProfileIssues")
                }
            }
            .navigationTitle(draft.id == nil ? "Payment Profile を追加" : "Payment Profile を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!issues.isEmpty)
                        .accessibilityIdentifier("savePaymentProfile")
                }
            }
        }
    }

    /// The draft as it would be stored (brand resolved from the picker).
    private var currentDraft: PaymentProfileDraft {
        var d = draft
        switch brandChoice {
        case "": d.brand = nil
        case "その他":
            let custom = customBrand.trimmingCharacters(in: .whitespacesAndNewlines)
            d.brand = custom.isEmpty ? "その他" : custom
        default: d.brand = brandChoice
        }
        return d
    }

    private func save() {
        nicknameTouched = true
        switch SupportMutations.saveProfile(currentDraft, store: env.store) {
        case .success(let profile):
            onSaved?(profile)
            dismiss()
        case .failure:
            break // issues are already listed in the form; nothing was written
        }
    }
}

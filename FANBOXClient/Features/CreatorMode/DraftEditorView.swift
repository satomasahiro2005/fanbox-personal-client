import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Native post editor (SPEC §18 / §19 / §20). Every edit autosaves locally (debounced) and works fully offline.
struct DraftEditorView: View {
    let draftID: String
    @Query private var drafts: [Draft]

    init(draftID: String) {
        self.draftID = draftID
        _drafts = Query(filter: #Predicate<Draft> { $0.id == draftID })
    }

    var body: some View {
        if let draft = drafts.first {
            DraftEditorContent(draft: draft)
        } else {
            EmptyStateView(title: "下書きが見つかりません", systemImage: "doc.questionmark", message: "削除された可能性があります。")
                .navigationTitle("下書き")
        }
    }
}

private enum DraftEditorMode: String, CaseIterable, Identifiable {
    case edit, preview
    var id: String { rawValue }
    var title: String { self == .edit ? "編集" : "プレビュー" }
}

/// Outcome of a send, shown as an alert.
private struct DraftSendResult: Identifiable {
    let id = UUID()
    var published: Bool
    var error: RemoteError?
    /// Specific reason recorded on the draft (e.g. the blocker or conflict explanation).
    var detail: String?

    var title: String {
        if error == nil { return published ? "公開しました" : "FANBOX に下書き保存しました" }
        return "送信できませんでした"
    }

    var message: String {
        guard let error else { return "ローカルの下書きはそのまま残っています。" }
        let reason = detail ?? error.userMessage
        if case .unsupported = error, detail == nil {
            return "この操作はアプリから行えません。下書きは端末内に残っています。Web エディタで続けてください。"
        }
        return "\(reason)\n下書きは端末内に残っています。"
    }

    /// The account web editor is offered for every failure except connectivity (it needs the network too).
    var offersWeb: Bool {
        guard let error else { return false }
        switch error {
        case .offline, .cancelled: return false
        default: return true
        }
    }
}

/// A send waiting for the creator's confirmation.
private struct PendingSend: Identifiable {
    let id = UUID()
    var publish: Bool
    var plan: DraftSendPlan
    var title: String
    var confirmLabel: String
}

/// A send that cannot happen natively.
private struct BlockedSend: Identifiable {
    let id = UUID()
    var message: String
    var offersWeb: Bool
}

/// 公開範囲 picker value. FANBOX gates by minimum fee; a fee without a matching local plan stays selectable as itself.
private enum DraftPlanChoice: Hashable {
    case everyone
    case plan(String)
    case fee(Int)
}

private struct DraftEditorContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Bindable var draft: Draft
    @Query private var plans: [Plan]
    @Query private var jobs: [UploadJob]

    @State private var mode: DraftEditorMode = .edit
    @State private var editMode: EditMode = .inactive
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var pendingSend: PendingSend?
    @State private var blockedSend: BlockedSend?
    @State private var sendResult: DraftSendResult?
    @State private var importMessage: String?
    @State private var newTag = ""
    @State private var blockPendingDeletion: DraftBlock?
    @State private var showHandoff = false
    @State private var handoffChecked: Set<String> = []
    @State private var awaitingWebReturn = false
    @State private var askWebCompletion = false
    @State private var plansRequested = false

    init(draft: Draft) {
        self.draft = draft
        let creatorID = draft.creatorID ?? ""
        let draftID = draft.id
        _plans = Query(filter: #Predicate<Plan> { $0.creatorID == creatorID }, sort: [SortDescriptor(\.fee), SortDescriptor(\.sortOrder)])
        _jobs = Query(filter: #Predicate<UploadJob> { $0.draftID == draftID }, sort: [SortDescriptor(\.order)])
    }

    private var isPublishing: Bool { env.drafts.isPublishing(draft.id) }
    private var capabilities: DraftCapabilities { env.drafts.capabilities(accountID: draft.accountID) }
    private var isExisting: Bool { draft.remotePostID != nil }
    /// FANBOX post is (or may be) live: the primary action updates it and keeps it published.
    private var isLiveOrUnknown: Bool { draft.remoteStatus == .published || draft.remoteStatus == .unknown }

    /// Plan of the primary action with what is known locally (badges, banners).
    private var livePlan: DraftSendPlan {
        DraftSendPlanner.plan(draft: draft, capabilities: capabilities, publish: isExisting ? isLiveOrUnknown : true)
    }

    private var planTitle: String {
        if let id = draft.targetPlanID, let plan = plans.first(where: { $0.planID == id }) {
            return "\(plan.title)（\(Formatters.yen(plan.fee))〜）"
        }
        if draft.feeRequired > 0 { return "\(Formatters.yen(draft.feeRequired)) 以上" }
        return "全体公開"
    }

    private var hasMedia: Bool { draft.blocks.contains { $0.kind == .image || $0.kind == .file } }

    var body: some View {
        Group {
            switch mode {
            case .edit: editor
            case .preview: DraftPreviewView(draft: draft, planTitle: planTitle)
            }
        }
        .navigationTitle(isExisting ? "投稿の編集" : "新規投稿")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .disabled(isPublishing)
        .overlay {
            if isPublishing {
                ProgressView(draft.status == .uploading ? "アップロード中…" : "送信中…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems, maxSelectionCount: 20, selectionBehavior: .ordered,
                      matching: .images, preferredItemEncoding: .current)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            let batch = items
            pickerItems = []
            Task { await importImages(batch) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await importFiles(urls) }
            case .failure: importMessage = "ファイルを読み込めませんでした"
            }
        }
        .confirmationDialog(pendingSend?.title ?? "", isPresented: Binding(get: { pendingSend != nil }, set: { if !$0 { pendingSend = nil } }),
                            titleVisibility: .visible, presenting: pendingSend) { pending in
            Button(pending.confirmLabel, role: pending.plan.unpublishes ? .destructive : nil) {
                send(publish: pending.publish, acceptWarnings: true, allowUnpublish: pending.plan.unpublishes)
            }
            .accessibilityIdentifier("draftConfirmPublishButton")
            if !pending.plan.warnings.isEmpty {
                Button("Web エディタで編集") { openWeb(reason: "書式などを保ったまま編集") }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { pending in
            Text(confirmationMessage(pending))
        }
        .alert("アプリから送信できません", isPresented: Binding(get: { blockedSend != nil }, set: { if !$0 { blockedSend = nil } }),
               presenting: blockedSend) { blocked in
            if blocked.offersWeb { openWebButton(reason: blocked.message) }
            Button("OK", role: .cancel) {}
        } message: { blocked in
            Text(blocked.message)
        }
        .alert(sendResult?.title ?? "", isPresented: Binding(get: { sendResult != nil }, set: { if !$0 { sendResult = nil } }),
               presenting: sendResult) { result in
            if result.offersWeb { openWebButton(reason: result.detail ?? result.error?.userMessage ?? "") }
            Button("OK", role: .cancel) {}
        } message: { result in
            Text(result.message)
        }
        .alert("読み込み", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
        .confirmationDialog("このブロックを削除しますか？", isPresented: Binding(get: { blockPendingDeletion != nil },
                                                                     set: { if !$0 { blockPendingDeletion = nil } }),
                            titleVisibility: .visible, presenting: blockPendingDeletion) { block in
            Button("削除", role: .destructive) { env.drafts.deleteBlock(block) }
        }
        .confirmationDialog("Web エディタでの作業は完了しましたか？", isPresented: $askWebCompletion, titleVisibility: .visible) {
            webCompletionButtons
            Button("まだ", role: .cancel) {}
        } message: {
            Text(isExisting
                 ? "完了した場合、FANBOX 上の投稿が最新です。ローカル下書きから再送すると Web での変更を上書きしてしまうため、再送はできなくなります。"
                 : "Web で投稿を作成した場合、この下書きは不要です。アプリから送信すると別の投稿が作られます。")
        }
        .sheet(isPresented: $showHandoff) {
            NavigationStack {
                DraftWebHandoffView(draft: draft, items: livePlan.webItems, checked: $handoffChecked,
                                    openWeb: { openWeb(reason: "残りの項目を Web エディタで追加") },
                                    complete: { completion in completeOnWeb(completion) })
            }
        }
        .onChange(of: env.web.presented == nil) { _, closed in
            guard closed, awaitingWebReturn else { return }
            awaitingWebReturn = false
            // The hand-off sheet has its own completion buttons.
            if !showHandoff { askWebCompletion = true }
        }
        .task {
            // The 公開範囲 picker needs the plans; fetch once when none are known yet.
            guard plans.isEmpty, !plansRequested, let creatorID = draft.creatorID else { return }
            plansRequested = true
            await env.sync.sync(.plans, accountID: draft.accountID, scope: creatorID, reason: .onDemand)
        }
        .onDisappear { env.drafts.saveNow() }
    }

    // MARK: Editor

    private var editor: some View {
        let plan = livePlan
        let webIDs = Set(plan.webItems.map(\.id))
        return List {
            statusSection(plan: plan)

            Section("タイトル") {
                TextField("タイトル", text: $draft.title, axis: .vertical)
                    .font(.headline)
                    .accessibilityIdentifier("draftTitleField")
            }

            gatingSection

            tagsSection

            Section {
                ForEach(draft.orderedBlocks) { block in
                    DraftBlockEditorRow(block: block, draft: draft, job: latestJob(for: block), needsWeb: webIDs.contains(block.id),
                                        canUpload: capabilities.uploadsMedia)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("削除", role: .destructive) { deleteRequested(block) }
                        }
                        .contextMenu {
                            Button { env.drafts.moveBlock(block, by: -1) } label: { Label("上へ移動", systemImage: "arrow.up") }
                            Button { env.drafts.moveBlock(block, by: 1) } label: { Label("下へ移動", systemImage: "arrow.down") }
                            Button(role: .destructive) { deleteRequested(block) } label: { Label("削除", systemImage: "trash") }
                        }
                }
                .onMove { source, destination in
                    env.drafts.moveBlocks(in: draft, from: source, to: destination)
                }
                .onDelete { offsets in
                    let ordered = draft.orderedBlocks
                    for index in offsets where index < ordered.count { env.drafts.deleteBlock(ordered[index]) }
                }
            } header: {
                HStack {
                    Text("本文")
                    Spacer()
                    Button(editMode.isEditing ? "完了" : "並べ替え") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .font(.caption)
                    .textCase(nil)
                    .accessibilityIdentifier("draftReorderButton")
                }
            } footer: {
                Text("長押しでドラッグ、または「並べ替え」で順序を変更できます。")
            }

            addBlockSection

            if hasMedia {
                DraftUploadPanel(draft: draft, jobs: jobs, canUpload: capabilities.uploadsMedia,
                                 awaitsPost: capabilities.uploadsNeedPost && draft.remotePostID == nil,
                                 webItemCount: plan.webItems.filter { $0.kind == .image || $0.kind == .file }.count,
                                 showChecklist: { showHandoff = true })
            }
        }
        .environment(\.editMode, $editMode)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("draftEditorList")
        .onChange(of: draft.title) { env.drafts.touch(draft) }
        .onChange(of: draft.hasAdultContent) { env.drafts.touch(draft) }
    }

    private func statusSection(plan: DraftSendPlan) -> some View {
        Section {
            HStack(spacing: 8) {
                PillLabel(text: draft.status.creatorLabel, tint: draft.status.creatorTint)
                if let remote = draft.remoteStatus {
                    PillLabel(text: remote == .unknown ? "FANBOX 投稿と連携" : "FANBOX: \(remote.creatorLabel)",
                              systemImage: "link", tint: remote == .unknown ? .purple : remote.creatorTint)
                        .accessibilityIdentifier("draftRemoteStatusPill")
                }
                Spacer()
                Text("自動保存 \(Formatters.time(draft.updatedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("draftAutosaveLabel")
            }
            if let progress = env.drafts.importProgress, progress.draftID == draft.id {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1))) {
                    Text("画像を読み込み中 \(progress.completed)/\(progress.total)").font(.caption)
                }
            }
            if !capabilities.nativeWrites {
                banner("このアカウントの投稿はアプリから送信できません。下書きは端末内に保存されます。送信は Web エディタで行ってください。",
                       systemImage: "safari", tint: .orange, withWebButton: true)
            } else if isExisting, let blocker = draft.nativeUpdateBlocker {
                banner(blocker, systemImage: "lock.fill", tint: .orange, withWebButton: true)
                    .accessibilityIdentifier("draftNativeUpdateBlocker")
            }
            if draft.webHandoffAt != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Web エディタでの仕上げが残っています（\(plan.webItems.count) 件）", systemImage: "checklist")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Button("チェックリストを開く") { showHandoff = true }
                        .font(.caption)
                        .accessibilityIdentifier("draftOpenHandoffButton")
                }
            }
            ForEach(plan.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if draft.status == .failed, let error = draft.lastError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    Text("下書きは端末内に保存されています。").font(.caption).foregroundStyle(.secondary)
                    openWebButton(reason: error)
                        .font(.caption)
                }
                .accessibilityIdentifier("draftErrorLabel")
            }
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color, withWebButton: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(tint)
            if withWebButton {
                openWebButton(reason: text).font(.caption)
            }
        }
    }

    // MARK: 公開範囲 / R-18

    private var planChoice: DraftPlanChoice {
        if let id = draft.targetPlanID, plans.contains(where: { $0.planID == id }) { return .plan(id) }
        if draft.feeRequired > 0 { return .fee(draft.feeRequired) }
        return .everyone
    }

    /// Fees without a matching local plan that must stay selectable: the current one and the one on FANBOX.
    private var extraFees: [Int] {
        var fees: [Int] = []
        if case .fee(let fee) = planChoice { fees.append(fee) }
        if let remote = draft.remoteFeeRequired, remote > 0, !plans.contains(where: { $0.fee == remote }), !fees.contains(remote) {
            fees.append(remote)
        }
        return fees.sorted()
    }

    private var gatingSection: some View {
        Section {
            Picker("公開範囲", selection: Binding(get: { planChoice }, set: { selectPlan($0) })) {
                Text("全体公開").tag(DraftPlanChoice.everyone)
                ForEach(plans) { plan in
                    Text("\(plan.title)（\(Formatters.yen(plan.fee))）").tag(DraftPlanChoice.plan(plan.planID))
                }
                ForEach(extraFees, id: \.self) { fee in
                    Text("\(Formatters.yen(fee)) 以上\(fee == draft.remoteFeeRequired ? "（FANBOX 上の設定）" : "")").tag(DraftPlanChoice.fee(fee))
                }
            }
            .accessibilityIdentifier("draftPlanPicker")
            Toggle("R-18", isOn: $draft.hasAdultContent)
                .disabled(!capabilities.sendsAdultFlag)
                .accessibilityIdentifier("draftAdultToggle")
        } header: {
            Text("公開範囲")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if plans.isEmpty {
                    Text("プラン情報が未取得です。取得できると、ここでプランを選べます。")
                }
                if !capabilities.sendsPlanID {
                    Text("プランは「その金額以上の支援者に公開」として送信されます。")
                }
                if !capabilities.sendsAdultFlag {
                    Text("R-18 の設定は FANBOX に送信されません。Web エディタで設定してください。")
                        .accessibilityIdentifier("draftAdultNotSentNote")
                }
                if isExisting, let old = draft.remoteFeeRequired, old != draft.feeRequired {
                    Text("FANBOX 上の設定（\(DraftSendPlanner.feeLabel(old))）から変わります。")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: Tags

    private var tagLimitReached: Bool { DraftPostMapping.normalizedTags(draft.tags).count >= DraftPostMapping.maxTags }

    private var tagsSection: some View {
        Section {
            if !draft.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(draft.tags.enumerated()), id: \.offset) { index, tag in
                            Button {
                                removeTag(at: index)
                            } label: {
                                HStack(spacing: 3) {
                                    Text("#\(tag)")
                                    Image(systemName: "xmark.circle.fill").font(.caption2)
                                }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.tint.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("タグ \(tag) を削除")
                        }
                    }
                }
            }
            HStack {
                TextField(tagLimitReached ? "タグは \(DraftPostMapping.maxTags) 個までです" : "タグを追加", text: $newTag)
                    .textInputAutocapitalization(.never)
                    .onSubmit(addTag)
                    .disabled(tagLimitReached)
                    .accessibilityIdentifier("draftTagField")
                Button("追加", action: addTag)
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty || tagLimitReached)
                    .accessibilityIdentifier("draftAddTagButton")
            }
        } header: {
            Text("タグ")
        } footer: {
            let count = DraftPostMapping.normalizedTags(draft.tags).count
            Text(count > DraftPostMapping.maxTags
                 ? "タグは \(DraftPostMapping.maxTags) 個までです（現在 \(count) 個）。送信前に減らしてください。"
                 : "\(count)/\(DraftPostMapping.maxTags)")
                .foregroundStyle(count > DraftPostMapping.maxTags ? .red : .secondary)
        }
    }

    // MARK: Add blocks

    private var addBlockSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                addButton("+ Text", systemImage: "text.alignleft", id: "draftAddText") { add(.text) }
                addButton("+ 見出し", systemImage: "textformat.size", id: "draftAddHeader") { add(.header) }
                addButton("+ Image", systemImage: "photo.on.rectangle", id: "draftAddImage", web: !capabilities.sendsNew(.image)) {
                    showPhotoPicker = true
                }
                addButton("+ File", systemImage: "paperclip", id: "draftAddFile", web: !capabilities.sendsNew(.file)) {
                    showFileImporter = true
                }
                addButton("+ URL", systemImage: "link", id: "draftAddURL", web: !capabilities.sendsNew(.url)) { add(.url) }
                addButton("+ Embed", systemImage: "play.rectangle", id: "draftAddEmbed", web: !capabilities.sendsNew(.embed)) { add(.embed) }
            }
            .padding(.vertical, 4)
        } header: {
            Text("ブロックを追加")
        } footer: {
            if capabilities.nativeWrites && !(capabilities.uploadsMedia && capabilities.createsLinkCards && capabilities.createsEmbeds) {
                Label("「Web」の付いたブロックはアプリから FANBOX に送信できません。本文を先に保存し、残りは Web エディタで追加します（順番のチェックリストと、縮小・変換済み画像の書き出しを用意します）。",
                      systemImage: "safari")
                    .accessibilityIdentifier("draftCapabilityNote")
            }
        }
    }

    private func addButton(_ title: String, systemImage: String, id: String, web: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline)
                if web {
                    Text("Web").font(.caption2.bold()).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(id)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("表示", selection: $mode) {
                ForEach(DraftEditorMode.allCases) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .accessibilityIdentifier("draftModePicker")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if !isExisting {
                    Button { request(publish: true) } label: { Label("公開…", systemImage: "paperplane") }
                        .accessibilityIdentifier("draftPublishButton")
                    Button { request(publish: false) } label: { Label("FANBOX に下書き保存", systemImage: "tray.and.arrow.up") }
                        .accessibilityIdentifier("draftSaveRemoteButton")
                } else if isLiveOrUnknown {
                    Button { request(publish: true) } label: { Label("更新（公開のまま）", systemImage: "arrow.triangle.2.circlepath") }
                        .accessibilityIdentifier("draftPublishButton")
                    Button(role: .destructive) { request(publish: false) } label: {
                        Label("非公開にして下書きに戻す…", systemImage: "eye.slash")
                    }
                    .accessibilityIdentifier("draftUnpublishButton")
                } else {
                    Button { request(publish: false) } label: { Label("FANBOX に下書き保存", systemImage: "tray.and.arrow.up") }
                        .accessibilityIdentifier("draftSaveRemoteButton")
                    Button { request(publish: true) } label: { Label("公開…", systemImage: "paperplane") }
                        .accessibilityIdentifier("draftPublishButton")
                }
                if draft.webHandoffAt != nil || !livePlan.webItems.isEmpty {
                    Button { showHandoff = true } label: { Label("Web で追加する項目", systemImage: "checklist") }
                }
                Divider()
                openWebButton(reason: "Web エディタで編集")
            } label: {
                Label("送信", systemImage: "paperplane.circle")
            }
            .disabled(isPublishing)
            .accessibilityIdentifier("draftSendMenu")
        }
    }

    private func openWebButton(reason: String) -> some View {
        Button {
            openWeb(reason: reason)
        } label: {
            Label("Web エディタで開く", systemImage: "safari")
        }
        .accessibilityIdentifier("draftOpenWebEditorButton")
    }

    /// Opens the account web editor on this post. A post that does not exist on FANBOX yet opens the (verified) post
    /// management page instead of the unverified "new post" URL (docs/API.md §20); "送信" creates it natively first.
    private func openWeb(reason: String) {
        env.drafts.saveNow()
        awaitingWebReturn = true
        let destination: WebDestination = draft.remotePostID.map { .managePostEditor(postID: $0) } ?? .managePosts
        env.web.openWeb(account: draft.accountID, destination: destination, purpose: .fallback(reason: reason))
    }

    @ViewBuilder
    private var webCompletionButtons: some View {
        if isExisting {
            Button("公開した") { completeOnWeb(.published) }
            Button("下書き保存した") { completeOnWeb(.savedAsDraft) }
            Button("ローカル下書きを削除", role: .destructive) { completeOnWeb(nil) }
        } else {
            Button("Web で投稿した（ローカル下書きを削除）", role: .destructive) { completeOnWeb(nil) }
        }
    }

    /// nil = delete the local draft (FANBOX holds the finished post).
    private func completeOnWeb(_ completion: DraftService.WebCompletion?) {
        showHandoff = false
        let accountID = draft.accountID
        if let completion {
            env.drafts.markCompletedOnWeb(draftID: draft.id, as: completion)
        } else {
            let draftID = draft.id
            dismiss()
            env.drafts.deleteDraft(draftID: draftID)
        }
        Task { await env.sync.sync(.creatorPosts, accountID: accountID, reason: .afterWrite) }
    }

    // MARK: Actions

    private func latestJob(for block: DraftBlock) -> UploadJob? {
        jobs.filter { $0.draftBlockID == block.id }.max { $0.createdAt < $1.createdAt }
    }

    private func add(_ kind: DraftBlockKind) {
        withAnimation { _ = env.drafts.addBlock(kind, to: draft) }
    }

    private func deleteRequested(_ block: DraftBlock) {
        let hasContent: Bool
        switch block.kind {
        case .text, .header: hasContent = !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || block.importedText != nil
        case .image, .file: hasContent = true
        case .url, .embed: hasContent = !(block.url ?? "").isEmpty || block.remoteMediaID != nil
        }
        if hasContent {
            blockPendingDeletion = block
        } else {
            env.drafts.deleteBlock(block)
        }
    }

    private func selectPlan(_ choice: DraftPlanChoice) {
        switch choice {
        case .everyone:
            draft.targetPlanID = nil
            draft.feeRequired = 0
        case .plan(let id):
            draft.targetPlanID = id
            if let plan = plans.first(where: { $0.planID == id }) { draft.feeRequired = plan.fee }
        case .fee(let fee):
            draft.targetPlanID = nil
            draft.feeRequired = fee
        }
        env.drafts.touch(draft)
    }

    private func addTag() {
        guard !tagLimitReached else { return }
        let normalized = DraftPostMapping.normalizedTags(draft.tags + [newTag])
        newTag = ""
        guard normalized != draft.tags else { return }
        draft.tags = normalized
        env.drafts.touch(draft)
    }

    private func removeTag(at index: Int) {
        guard draft.tags.indices.contains(index) else { return }
        draft.tags.remove(at: index)
        env.drafts.touch(draft)
    }

    private func importImages(_ items: [PhotosPickerItem]) async {
        let report = await env.drafts.addImages(from: items, to: draft.id)
        if !report.failures.isEmpty {
            importMessage = "\(report.added) 件追加しました。\n" + report.failures.joined(separator: "\n")
        }
    }

    private func importFiles(_ urls: [URL]) async {
        var failures: [String] = []
        for url in urls {
            do {
                _ = try await env.drafts.addFile(url: url, to: draft.id)
            } catch {
                failures.append("\(url.lastPathComponent): \((error as? LocalizedError)?.errorDescription ?? "読み込めませんでした")")
            }
        }
        if !failures.isEmpty { importMessage = failures.joined(separator: "\n") }
    }

    /// Plans the send; blocked sends explain why, everything that changes FANBOX state is confirmed first.
    private func request(publish: Bool) {
        env.drafts.saveNow()
        guard let plan = env.drafts.plan(draftID: draft.id, publish: publish) else { return }
        if !plan.canSend {
            blockedSend = BlockedSend(message: plan.blockers.joined(separator: "\n"), offersWeb: plan.validationError == nil)
            return
        }
        let title: String
        let confirm: String
        if plan.unpublishes {
            title = "非公開にして下書きに戻しますか？"
            confirm = "非公開にする"
        } else if isExisting && isLiveOrUnknown && plan.sendsPublished {
            title = "公開中の投稿を更新しますか？"
            confirm = "更新（公開のまま）"
        } else if publish && !plan.sendsPublished {
            title = "本文を FANBOX に下書き保存しますか？"
            confirm = "下書き保存して Web で仕上げる"
        } else if plan.sendsPublished {
            title = "公開しますか？"
            confirm = "公開"
        } else {
            title = "FANBOX に下書き保存しますか？"
            confirm = "下書き保存"
        }
        let needsConfirmation = plan.sendsPublished || plan.unpublishes || isExisting || !plan.warnings.isEmpty || !plan.notes.isEmpty
        if needsConfirmation {
            pendingSend = PendingSend(publish: publish, plan: plan, title: title, confirmLabel: confirm)
        } else {
            send(publish: publish, acceptWarnings: false, allowUnpublish: false)
        }
    }

    private func confirmationMessage(_ pending: PendingSend) -> String {
        var lines = ["公開範囲: \(planTitle)"]
        lines += pending.plan.notes
        lines += pending.plan.warnings.map { "⚠︎ \($0)" }
        if pending.plan.webItems.isEmpty && capabilities.uploadsMedia && hasMedia {
            lines.append("未アップロードのメディアを送信してから投稿します。")
        }
        return lines.joined(separator: "\n")
    }

    private func send(publish: Bool, acceptWarnings: Bool, allowUnpublish: Bool) {
        let draftID = draft.id
        let accountID = draft.accountID
        Task {
            let result = await env.drafts.send(draftID: draftID, publish: publish, acceptWarnings: acceptWarnings,
                                               allowUnpublish: allowUnpublish)
            switch result {
            case .success(let receipt):
                if receipt.needsWebCompletion {
                    handoffChecked = []
                    showHandoff = true
                } else {
                    sendResult = DraftSendResult(published: receipt.sentPublished, error: nil)
                }
                Task { await env.sync.sync(.creatorPosts, accountID: accountID, reason: .afterWrite) }
            case .failure(let error):
                let detail = env.drafts.store.draft(id: draftID)?.lastError
                sendResult = DraftSendResult(published: publish, error: error, detail: detail ?? error.userMessage)
            }
        }
    }
}

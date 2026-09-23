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

/// Outcome of a publish / FANBOX draft save, shown as an alert.
private struct DraftSendResult: Identifiable {
    let id = UUID()
    var published: Bool
    var error: RemoteError?

    var title: String {
        if error == nil { return published ? "公開しました" : "FANBOX に下書き保存しました" }
        return published ? "公開できませんでした" : "下書き保存できませんでした"
    }

    var message: String {
        guard let error else { return "ローカルの下書きはそのまま残っています。" }
        if case .unsupported = error {
            return "この操作はアプリから行えません。下書きは端末内に残っています。Web エディタで続けてください。"
        }
        return "\(error.userMessage)\n下書きは端末内に残っています。"
    }

    var offersWeb: Bool {
        guard let error else { return false }
        switch error {
        case .unsupported, .forbidden, .unauthorized, .decoding, .server: return true
        default: return false
        }
    }
}

private struct DraftEditorContent: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var draft: Draft
    @Query private var plans: [Plan]
    @Query private var jobs: [UploadJob]

    @State private var mode: DraftEditorMode = .edit
    @State private var editMode: EditMode = .inactive
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var confirmPublish = false
    @State private var sendResult: DraftSendResult?
    @State private var importMessage: String?
    @State private var newTag = ""
    @State private var blockPendingDeletion: DraftBlock?

    init(draft: Draft) {
        self.draft = draft
        let creatorID = draft.creatorID ?? ""
        let draftID = draft.id
        _plans = Query(filter: #Predicate<Plan> { $0.creatorID == creatorID }, sort: [SortDescriptor(\.fee), SortDescriptor(\.sortOrder)])
        _jobs = Query(filter: #Predicate<UploadJob> { $0.draftID == draftID }, sort: [SortDescriptor(\.order)])
    }

    private var isPublishing: Bool { env.drafts.isPublishing(draft.id) }

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
        .navigationTitle(draft.remotePostID == nil ? "新規投稿" : "投稿の編集")
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
        .confirmationDialog("公開しますか？", isPresented: $confirmPublish, titleVisibility: .visible) {
            Button("公開") { send(publish: true) }
                .accessibilityIdentifier("draftConfirmPublishButton")
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("公開範囲: \(planTitle)\n未アップロードのメディアを送信してから投稿します。")
        }
        .alert(sendResult?.title ?? "", isPresented: Binding(get: { sendResult != nil }, set: { if !$0 { sendResult = nil } }),
               presenting: sendResult) { result in
            if result.offersWeb { openWebButton(reason: result.error?.userMessage ?? "") }
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
        .onDisappear { env.drafts.saveNow() }
    }

    // MARK: Editor

    private var editor: some View {
        List {
            statusSection

            Section("タイトル") {
                TextField("タイトル", text: $draft.title, axis: .vertical)
                    .font(.headline)
                    .accessibilityIdentifier("draftTitleField")
            }

            Section {
                Picker("公開範囲", selection: Binding(get: { draft.targetPlanID }, set: { selectPlan($0) })) {
                    Text("全体公開").tag(String?.none)
                    ForEach(plans) { plan in
                        Text("\(plan.title)（\(Formatters.yen(plan.fee))）").tag(Optional(plan.planID))
                    }
                    if let id = draft.targetPlanID, !plans.contains(where: { $0.planID == id }) {
                        Text("\(Formatters.yen(draft.feeRequired)) 以上のプラン").tag(Optional(id))
                    }
                }
                .accessibilityIdentifier("draftPlanPicker")
                Toggle("R-18", isOn: $draft.hasAdultContent)
            } header: {
                Text("公開範囲")
            } footer: {
                if plans.isEmpty { Text("プラン情報が未取得です。「全体公開」以外はプラン一覧の取得後に選べます。") }
            }

            tagsSection

            Section {
                ForEach(draft.orderedBlocks) { block in
                    DraftBlockEditorRow(block: block, draft: draft, job: latestJob(for: block))
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
                DraftUploadPanel(draft: draft, jobs: jobs)
            }
        }
        .environment(\.editMode, $editMode)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("draftEditorList")
        .onChange(of: draft.title) { env.drafts.touch(draft) }
        .onChange(of: draft.hasAdultContent) { env.drafts.touch(draft) }
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 8) {
                PillLabel(text: draft.status.creatorLabel, tint: draft.status.creatorTint)
                if draft.remotePostID != nil { PillLabel(text: "FANBOX 投稿と連携", systemImage: "link", tint: .purple) }
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

    private var tagsSection: some View {
        Section("タグ") {
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
                TextField("タグを追加", text: $newTag)
                    .textInputAutocapitalization(.never)
                    .onSubmit(addTag)
                    .accessibilityIdentifier("draftTagField")
                Button("追加", action: addTag)
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var addBlockSection: some View {
        Section("ブロックを追加") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                addButton("+ Text", systemImage: "text.alignleft", id: "draftAddText") { add(.text) }
                addButton("+ 見出し", systemImage: "textformat.size", id: "draftAddHeader") { add(.header) }
                addButton("+ Image", systemImage: "photo.on.rectangle", id: "draftAddImage") { showPhotoPicker = true }
                addButton("+ File", systemImage: "paperclip", id: "draftAddFile") { showFileImporter = true }
                addButton("+ URL", systemImage: "link", id: "draftAddURL") { add(.url) }
                addButton("+ Embed", systemImage: "play.rectangle", id: "draftAddEmbed") { add(.embed) }
            }
            .padding(.vertical, 4)
        }
    }

    private func addButton(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
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
                Button {
                    send(publish: false)
                } label: {
                    Label("FANBOX に下書き保存", systemImage: "tray.and.arrow.up")
                }
                .accessibilityIdentifier("draftSaveRemoteButton")
                Button {
                    confirmPublish = true
                } label: {
                    Label("公開", systemImage: "paperplane")
                }
                .accessibilityIdentifier("draftPublishButton")
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
            env.drafts.saveNow()
            env.web.openWeb(account: draft.accountID, destination: .managePostEditor(postID: draft.remotePostID),
                            purpose: .fallback(reason: reason))
        } label: {
            Label("Web エディタで開く", systemImage: "safari")
        }
        .accessibilityIdentifier("draftOpenWebEditorButton")
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
        case .text, .header: hasContent = !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image, .file: hasContent = true
        case .url, .embed: hasContent = !(block.url ?? "").isEmpty
        }
        if hasContent {
            blockPendingDeletion = block
        } else {
            env.drafts.deleteBlock(block)
        }
    }

    private func selectPlan(_ planID: String?) {
        draft.targetPlanID = planID
        if let planID, let plan = plans.first(where: { $0.planID == planID }) {
            draft.feeRequired = plan.fee
        } else if planID == nil {
            draft.feeRequired = 0
        }
        env.drafts.touch(draft)
    }

    private func addTag() {
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

    private func send(publish: Bool) {
        let draftID = draft.id
        let accountID = draft.accountID
        Task {
            let result = await env.drafts.publish(draftID: draftID, publish: publish)
            switch result {
            case .success:
                sendResult = DraftSendResult(published: publish, error: nil)
                Task { await env.sync.sync(.creatorPosts, accountID: accountID, reason: .afterWrite) }
            case .failure(let error):
                sendResult = DraftSendResult(published: publish, error: error)
            }
        }
    }
}

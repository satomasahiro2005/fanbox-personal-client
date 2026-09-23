import SwiftData
import SwiftUI
import UIKit

// MARK: - Local thumbnails

/// Decoded thumbnails of draft media (thread-safe cache).
final class DraftThumbnailCache: @unchecked Sendable {
    static let shared = DraftThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    init() { cache.countLimit = 200 }

    func image(for url: URL, maxPixel: Int) async -> UIImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            DraftImageProcessor.thumbnail(at: url, maxPixel: maxPixel).map { UIImage(cgImage: $0) }
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

/// Image of a draft block: local file first (works offline), remote URL for Post Edit blocks without a local copy.
struct DraftBlockImage: View {
    @Environment(AppEnvironment.self) private var env
    let block: DraftBlock
    var maxPixel: Int = 240
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if block.localFileName == nil, let remote = block.remoteURL {
                RemoteImageView(thumbnailURL: remote, displayURL: remote, maxVariant: maxPixel > 400 ? .display : .thumbnail,
                                accountID: block.draft?.accountID, contentMode: contentMode)
            } else if block.localFileName == nil {
                // FANBOX image the app cannot preview (kept by id).
                Rectangle()
                    .fill(.quaternary)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        if failed {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .task(id: block.localFileName) {
            guard let url = env.drafts.localFileURL(for: block) else { return }
            image = await DraftThumbnailCache.shared.image(for: url, maxPixel: maxPixel)
            failed = image == nil
        }
    }
}

// MARK: - Editor rows

/// One editable block in the native editor.
struct DraftBlockEditorRow: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var block: DraftBlock
    let draft: Draft
    var job: UploadJob?
    /// The block cannot be sent natively by this account: it is added in the web editor after a text-first send.
    var needsWeb: Bool = false
    var canUpload: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if block.isLockedRemote {
                lockedRow
            } else {
                switch block.kind {
                case .text:
                    TextField(block.importedText == "" ? "空行（段落の間隔）" : "本文", text: $block.text, axis: .vertical)
                        .lineLimit(2...)
                        .accessibilityIdentifier("draftTextBlock")
                    formattingNote
                case .header:
                    TextField("見出し", text: $block.text, axis: .vertical)
                        .font(.title3.bold())
                        .accessibilityIdentifier("draftHeaderBlock")
                    formattingNote
                case .image:
                    imageRow
                case .file:
                    fileRow
                case .url:
                    urlRow
                case .embed:
                    embedRow
                }
            }
            if needsWeb {
                Label("Web で追加（アプリから送信できません）", systemImage: "safari")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("draftNeedsWebBadge")
            }
        }
        .padding(.vertical, 2)
        .onChange(of: block.text) { env.drafts.blockTextChanged(block, in: draft) }
        .onChange(of: block.url) { referenceEdited() }
        .onChange(of: block.embedProvider) { referenceEdited() }
        .onChange(of: block.embedContentID) { referenceEdited() }
    }

    /// An edited link card / embed is a NEW one: never re-send the old FANBOX id for a different target (a link card is
    /// registered again for the new URL when the draft is sent).
    private func referenceEdited() {
        if (block.kind == .url || block.kind == .embed), block.remoteMediaID != nil, !block.isLockedRemote {
            block.remoteMediaID = nil
            block.remoteMediaJSON = nil
        }
        env.drafts.touch(draft)
    }

    /// Imported paragraph with bold / links / size: tells whether they survive the edit.
    @ViewBuilder
    private var formattingNote: some View {
        if !block.importedStyles.isEmpty {
            let lost = DraftPostMapping.sentStyles(of: block).lost
            Label(lost > 0 ? "書式（太字・リンクなど）の一部が失われます" : "書式（太字・リンクなど）を保持",
                  systemImage: lost > 0 ? "exclamationmark.triangle" : "bold")
                .font(.caption2)
                .foregroundStyle(lost > 0 ? .orange : .secondary)
        }
    }

    /// FANBOX content the app keeps by reference only (sent back unchanged, not editable here).
    private var lockedRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                switch block.kind {
                case .text, .header:
                    Text(block.text).font(.subheadline)
                    Text("アプリで扱えないブロックです（Web エディタで編集してください）").font(.caption2).foregroundStyle(.secondary)
                case .image:
                    Text("FANBOX 上の画像（プレビューできません）").font(.subheadline)
                case .file:
                    Text(block.originalFileName ?? "FANBOX 上のファイル").font(.subheadline)
                case .url:
                    Text(block.text.isEmpty ? (block.url ?? "FANBOX 上のリンクカード") : block.text).font(.subheadline).lineLimit(2)
                    Text("リンクカード（そのまま残します）").font(.caption2).foregroundStyle(.secondary)
                case .embed:
                    Text(block.url ?? block.embedContentID ?? "FANBOX 上の埋め込み").font(.subheadline).lineLimit(2)
                    Text("埋め込み（そのまま残します）").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("draftLockedBlock")
    }

    private var imageRow: some View {
        HStack(spacing: 12) {
            DraftBlockImage(block: block)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(block.originalFileName ?? "画像").font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if let w = block.width, let h = block.height {
                        Text("\(w)×\(h)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let size = block.fileSize {
                        Text(Formatters.bytes(Int64(size))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                DraftMediaUploadBadge(block: block, job: job, canUpload: canUpload)
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("draftImageBlock")
    }

    private var fileRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.zipper")
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(block.originalFileName ?? "ファイル").font(.subheadline.weight(.medium)).lineLimit(1)
                if let size = block.fileSize {
                    Text(Formatters.bytes(Int64(size))).font(.caption).foregroundStyle(.secondary)
                }
                DraftMediaUploadBadge(block: block, job: job, canUpload: canUpload)
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("draftFileBlock")
    }

    private var urlRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("URL", systemImage: "link").font(.caption).foregroundStyle(.secondary)
                if block.remoteMediaID != nil {
                    Text(block.remoteMedia != nil ? "リンクカード登録済み" : "FANBOX 上のリンクカード").font(.caption2).foregroundStyle(.secondary)
                }
            }
            TextField("https://", text: Binding(get: { block.url ?? "" }, set: { block.url = $0 }))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("draftURLBlock")
        }
    }

    private var embedRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("埋め込み", systemImage: "play.rectangle").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("サービス", selection: Binding(get: { block.embedProvider ?? DraftEmbedProvider.youtube.rawValue },
                                                   set: { block.embedProvider = $0 })) {
                    ForEach(DraftEmbedProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                    if let raw = block.embedProvider, DraftEmbedProvider(rawValue: raw) == nil {
                        Text(raw).tag(raw)
                    }
                }
                .pickerStyle(.menu)
            }
            TextField("URL または ID", text: Binding(
                get: { block.url ?? block.embedContentID ?? "" },
                set: { value in
                    block.url = value
                    let provider = DraftEmbedProvider(rawValue: block.embedProvider ?? "") ?? .youtube
                    block.embedContentID = provider.contentID(from: value)
                }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("draftEmbedBlock")
            if let id = block.embedContentID, !id.isEmpty, id != block.url {
                Text("ID: \(id)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Upload state of one media block ("✓" / "Uploading 42%" / "Waiting" / 失敗).
struct DraftMediaUploadBadge: View {
    let block: DraftBlock
    var job: UploadJob?
    var canUpload: Bool = true

    var body: some View {
        if block.remoteMediaID != nil {
            Label(block.localFileName == nil ? "FANBOX 上のメディア" : "アップロード済み", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        } else if !canUpload {
            Text("縮小・変換済み（Web エディタで追加）").font(.caption2).foregroundStyle(.secondary)
        } else if let job, job.state == .paused, job.lastError == UploadQueue.awaitingPostMessage {
            Text("送信時にアップロード（FANBOX の下書き作成後）").font(.caption2).foregroundStyle(.secondary)
        } else if let job {
            HStack(spacing: 4) {
                Text(CreatorFormatting.uploadStatus(state: job.state, progress: job.progress))
                if job.state == .failed, let reason = job.lastError { Text(reason).lineLimit(1) }
            }
            .font(.caption2)
            .foregroundStyle(job.state == .failed ? .red : .secondary)
        } else {
            Text("未アップロード（公開時に送信）").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Upload queue panel (SPEC §20)

struct DraftUploadPanel: View {
    @Environment(AppEnvironment.self) private var env
    let draft: Draft
    let jobs: [UploadJob]
    /// False when the account uploads in the web editor (text-first send + checklist instead of the queue).
    var canUpload: Bool = true
    /// Uploads are stored into a FANBOX post that does not exist yet (new post): they start when the draft is sent, right
    /// after the FANBOX draft is created. No manual start, so tapping "upload" never creates a FANBOX post by surprise.
    var awaitsPost: Bool = false
    var webItemCount: Int = 0
    var showChecklist: () -> Void = {}

    private var mediaBlocks: [DraftBlock] { draft.orderedBlocks.filter { $0.kind == .image || $0.kind == .file } }
    private var activeJobs: [UploadJob] {
        let blockIDs = Set(mediaBlocks.map(\.id))
        return jobs.filter { blockIDs.contains($0.draftBlockID) }.sorted { $0.order < $1.order }
    }
    private var notQueued: Int {
        let jobBlockIDs = Set(jobs.filter { $0.state != .completed }.map(\.draftBlockID))
        return mediaBlocks.filter { $0.remoteMediaID == nil && $0.localFileName != nil && !jobBlockIDs.contains($0.id) }.count
    }

    var body: some View {
        if canUpload {
            queueSection
        } else {
            webSection
        }
    }

    /// Accounts without a native upload: media are prepared locally and added in the web editor.
    private var webSection: some View {
        Section {
            Label(webItemCount > 0 ? "Web エディタで追加する画像・ファイル \(webItemCount) 件" : "Web エディタで追加する画像・ファイルはありません",
                  systemImage: "safari")
                .font(.subheadline)
            if webItemCount > 0 {
                Button {
                    showChecklist()
                } label: {
                    Label("チェックリストと書き出し", systemImage: "checklist")
                }
                .accessibilityIdentifier("draftOpenChecklistButton")
            }
        } header: {
            Text("アップロード")
        } footer: {
            Text("このアカウントではアプリから画像・ファイルをアップロードできません。送信すると本文を先に FANBOX に保存し、ここで縮小・変換した画像を書き出して Web エディタで追加できます。")
        }
    }

    private var queueSection: some View {
        Section {
            ForEach(activeJobs) { job in
                DraftUploadJobRow(job: job)
            }
            if notQueued > 0 {
                Text("未アップロード \(notQueued) 件").font(.subheadline).foregroundStyle(.secondary)
            }
            if !env.uploads.isNetworkAvailable && (notQueued > 0 || activeJobs.contains { $0.state == .queued }) {
                Label("オフラインのため待機中です。接続後に送信できます。", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if awaitsPost {
                Label("送信（下書き保存 / 公開）すると、FANBOX に下書きを作成してから順にアップロードします。",
                      systemImage: "tray.and.arrow.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("draftUploadAwaitsPostNote")
            }
            HStack {
                if !awaitsPost && (notQueued > 0 || activeJobs.contains(where: { $0.state == .queued || $0.lastError == UploadQueue.awaitingPostMessage })) {
                    Button {
                        env.uploads.resumeAwaitingPost(draftID: draft.id)
                        env.uploads.enqueue(draftID: draft.id)
                        env.uploads.start()
                    } label: {
                        Label("アップロード開始", systemImage: "icloud.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!env.uploads.isNetworkAvailable || env.uploads.isRunning)
                    .accessibilityIdentifier("draftStartUploadButton")
                }
                Spacer()
                if activeJobs.contains(where: { $0.state == .failed }) {
                    Button {
                        env.uploads.retryFailed(draftID: draft.id)
                    } label: {
                        Label("失敗した項目のみ再送", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .accessibilityIdentifier("draftRetryFailedButton")
                }
            }
        } header: {
            HStack {
                Text("アップロード")
                if env.uploads.isRunning { ProgressView().controlSize(.mini) }
            }
        } footer: {
            Text(awaitsPost
                 ? "FANBOX では画像・ファイルを投稿に直接アップロードするため、先に FANBOX の下書きが必要です。画像は長辺 4096px を超える場合に縮小し、HEIC は JPEG に変換します。完了した項目は再送しません。"
                 : "画像は長辺 4096px を超える場合に縮小し、HEIC は JPEG に変換してから送信します。完了した項目は再送しません。")
        }
    }
}

struct DraftUploadJobRow: View {
    @Environment(AppEnvironment.self) private var env
    let job: UploadJob

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.kind == .image ? "photo" : "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(job.fileName).lineLimit(1)
                    Spacer()
                    Text(CreatorFormatting.uploadStatus(state: job.state, progress: job.progress))
                        .monospacedDigit()
                        .foregroundStyle(statusColor)
                }
                .font(.subheadline)
                if job.state == .uploading {
                    ProgressView(value: job.progress)
                }
                if job.state == .failed, let reason = job.lastError {
                    Text(reason).font(.caption).foregroundStyle(.red)
                } else if job.state == .paused, let reason = job.lastError {
                    // Paused by the app (web editor / waiting for the FANBOX draft), not by the creator.
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            switch job.state {
            case .queued, .uploading:
                Button { env.uploads.pause(jobID: job.id) } label: { Image(systemName: "pause.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("一時停止")
            case .paused where job.lastError == UploadQueue.awaitingPostMessage:
                EmptyView()
            case .paused:
                Button { env.uploads.resume(jobID: job.id) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("再開")
            case .failed, .completed:
                EmptyView()
            }
        }
        .accessibilityIdentifier("draftUploadJobRow")
    }

    private var statusColor: Color {
        switch job.state {
        case .completed: return .green
        case .failed: return .red
        case .uploading: return .blue
        case .queued, .paused: return .secondary
        }
    }
}

// MARK: - Preview (SPEC §19 "Upload 前のプレビュー")

/// Native rendering of the draft, similar to the post detail screen. Uses local media only (offline OK).
struct DraftPreviewView: View {
    let draft: Draft
    let planTitle: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if draft.status != .published {
                    Label("プレビュー（端末内の下書き）", systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(draft.title.isEmpty ? "（無題）" : draft.title)
                    .font(.title2.bold())
                HStack(spacing: 6) {
                    PillLabel(text: planTitle, tint: .purple)
                    if draft.hasAdultContent { PillLabel(text: "R-18", tint: .red) }
                }
                if !draft.tags.isEmpty {
                    Text(DraftPostMapping.normalizedTags(draft.tags).map { "#\($0)" }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                Divider()
                ForEach(draft.orderedBlocks) { block in
                    DraftPreviewBlock(block: block)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("draftPreview")
    }
}

private struct DraftPreviewBlock: View {
    let block: DraftBlock

    var body: some View {
        if block.isLockedRemote && (block.kind == .text || block.kind == .header) {
            Label(block.text, systemImage: "lock")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .text:
            if !block.text.isEmpty {
                Text(block.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Color.clear.frame(height: 8)
            }
        case .header:
            Text(block.text).font(.title3.bold())
        case .image:
            DraftBlockImage(block: block, maxPixel: 1400, contentMode: .fit)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .file:
            HStack {
                Image(systemName: "doc")
                Text(block.originalFileName ?? "ファイル")
                Spacer()
                if let size = block.fileSize { Text(Formatters.bytes(Int64(size))).foregroundStyle(.secondary) }
            }
            .font(.subheadline)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .url:
            let target = block.url ?? ""
            HStack {
                Image(systemName: "link")
                Text(target.isEmpty ? (block.remoteMediaID != nil ? "FANBOX 上のリンクカード" : "（URL 未入力）") : target).lineLimit(1)
            }
            .font(.subheadline)
            .foregroundStyle(target.isEmpty ? .secondary : Color.accentColor)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .embed:
            let provider = DraftEmbedProvider(rawValue: block.embedProvider ?? "")?.displayName ?? (block.embedProvider ?? "埋め込み")
            HStack {
                Image(systemName: "play.rectangle")
                Text("\(provider): \(block.embedContentID ?? block.url ?? "未入力")").lineLimit(1)
            }
            .font(.subheadline)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var aspectRatio: CGFloat {
        guard let w = block.width, let h = block.height, w > 0, h > 0 else { return 4.0 / 3.0 }
        return CGFloat(w) / CGFloat(h)
    }
}

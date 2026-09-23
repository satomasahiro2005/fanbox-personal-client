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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch block.kind {
            case .text:
                TextField("本文", text: $block.text, axis: .vertical)
                    .lineLimit(2...)
                    .accessibilityIdentifier("draftTextBlock")
            case .header:
                TextField("見出し", text: $block.text, axis: .vertical)
                    .font(.title3.bold())
                    .accessibilityIdentifier("draftHeaderBlock")
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
        .padding(.vertical, 2)
        .onChange(of: block.text) { env.drafts.touch(draft) }
        .onChange(of: block.url) { env.drafts.touch(draft) }
        .onChange(of: block.embedProvider) { env.drafts.touch(draft) }
        .onChange(of: block.embedContentID) { env.drafts.touch(draft) }
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
                DraftMediaUploadBadge(block: block, job: job)
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
                DraftMediaUploadBadge(block: block, job: job)
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("draftFileBlock")
    }

    private var urlRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("URL", systemImage: "link").font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        if block.remoteMediaID != nil {
            Label(block.localFileName == nil ? "FANBOX 上のメディア" : "アップロード済み", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
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
            HStack {
                if notQueued > 0 || activeJobs.contains(where: { $0.state == .queued }) {
                    Button {
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
            Text("画像は長辺 4096px を超える場合に縮小し、HEIC は JPEG に変換してから送信します。完了した項目は再送しません。")
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
                }
            }
            switch job.state {
            case .queued, .uploading:
                Button { env.uploads.pause(jobID: job.id) } label: { Image(systemName: "pause.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("一時停止")
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
                Text(target.isEmpty ? "（URL 未入力）" : target).lineLimit(1)
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

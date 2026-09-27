import SwiftUI
import AVKit
import QuickLook

/// Callbacks and identity passed down to block renderers.
struct PostDetailRenderContext {
    var postID: String
    var creatorID: String
    /// Account whose session is used for authenticated media.
    var accountID: String?
    /// Opens the full-screen image viewer at the image block with this key.
    var openImage: (String) -> Void
    /// Opens a link (FANBOX → account-aware WebView, others → system).
    var openLink: (URL) -> Void
    /// Opens the post in the account-aware WebView (fallback for unsupported blocks).
    var openInBrowser: () -> Void
}

/// Native rendering of post blocks (SPEC §6). Consecutive images become a gallery.
struct PostDetailBlocksView: View {
    let blocks: [PostBlock]
    let context: PostDetailRenderContext

    var body: some View {
        let items = PostDetailBlockLayout.group(blocks.map(\.kind))
        // Lazy: long posts only build (and start loading media for) the blocks near the viewport.
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(items, id: \.self) { item in
                switch item {
                case .single(let index):
                    PostDetailBlockView(block: blocks[index], context: context)
                case .gallery(let indices):
                    PostDetailGalleryView(blocks: indices.map { blocks[$0] }, context: context)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("postBlocks")
    }
}

struct PostDetailBlockView: View {
    let block: PostBlock
    let context: PostDetailRenderContext

    var body: some View {
        switch block.kind {
        case .paragraph:
            if block.text.isEmpty {
                Color.clear.frame(height: 6)
            } else {
                Text(PostTextStyler.attributedString(text: block.text, stylesJSON: block.stylesJSON))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .header:
            Text(block.text)
                .font(.title3.bold())
                .textSelection(.enabled)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        case .image:
            PostDetailImageBlockView(block: block, context: context)
        case .file:
            PostDetailDownloadableBlockView(block: block, context: context, mediaKind: .file)
        case .audio:
            PostDetailDownloadableBlockView(block: block, context: context, mediaKind: .audio)
        case .video:
            if block.embedProvider != nil || PostDetailDownloadableBlockView.remoteURL(of: block) == nil {
                PostDetailEmbedCardView(block: block, context: context)
            } else {
                PostDetailDownloadableBlockView(block: block, context: context, mediaKind: .video)
            }
        case .url:
            PostDetailLinkCardView(block: block, context: context)
        case .embed:
            PostDetailEmbedCardView(block: block, context: context)
        case .unknown:
            PostDetailUnknownBlockView(context: context)
        }
    }
}

// MARK: - Images

struct PostDetailImageBlockView: View {
    let block: PostBlock
    let context: PostDetailRenderContext

    private var aspectRatio: CGFloat {
        if let w = block.width, let h = block.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return 4.0 / 3.0
    }

    var body: some View {
        RemoteImageView(thumbnailURL: block.thumbnailURL, displayURL: block.displayURL, originalURL: block.originalURL,
                        maxVariant: .display, postID: context.postID, creatorID: context.creatorID, accountID: context.accountID,
                        contentMode: .fit)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { context.openImage(block.key) }
            .accessibilityElement()
            .accessibilityLabel("画像")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("postImage.\(block.index)")
    }
}

/// Consecutive images: a thumbnail grid (low-data friendly) or a full-width list; tap opens the paging viewer.
struct PostDetailGalleryView: View {
    let blocks: [PostBlock]
    let context: PostDetailRenderContext
    /// Per-device display preference ("grid" / "list").
    @AppStorage("home.galleryStyle") private var style = "grid"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("画像\(blocks.count)枚", systemImage: "photo.on.rectangle.angled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("表示", selection: $style) {
                    Image(systemName: "square.grid.2x2").tag("grid")
                    Image(systemName: "rectangle.grid.1x2").tag("list")
                }
                .pickerStyle(.segmented)
                .frame(width: 96)
                .accessibilityIdentifier("postGalleryStyle")
            }
            if style == "list" {
                VStack(spacing: 8) {
                    ForEach(blocks, id: \.key) { PostDetailImageBlockView(block: $0, context: context) }
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                    ForEach(blocks, id: \.key) { block in
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay {
                                // FANBOX images have no thumbnail URL: the tile then loads the display image under the
                                // display policy (manual in Extreme) and decodes it at thumbnail size (RemoteImageSources).
                                RemoteImageView(thumbnailURL: block.thumbnailURL, displayURL: block.displayURL, originalURL: block.originalURL,
                                                maxVariant: .thumbnail, postID: context.postID, creatorID: context.creatorID,
                                                accountID: context.accountID, contentMode: .fill)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .onTapGesture { context.openImage(block.key) }
                            .accessibilityElement()
                            .accessibilityLabel("画像")
                            .accessibilityAddTraits(.isButton)
                    }
                }
            }
        }
        .accessibilityIdentifier("postGallery")
    }
}

// MARK: - File / audio / video (manual download, SPEC §3.4 / §30)

struct PostDetailDownloadableBlockView: View {
    let block: PostBlock
    let context: PostDetailRenderContext
    let mediaKind: MediaKind

    @Environment(AppEnvironment.self) private var env
    @State private var localURL: URL?
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var previewURL: URL?
    @State private var player: AVPlayer?

    static func remoteURL(of block: PostBlock) -> String? {
        [block.originalURL, block.url, block.displayURL].compactMap { $0 }.first { !$0.isEmpty }
    }

    private var fileName: String {
        let name = block.fileName ?? block.title ?? (mediaKind == .file ? "ファイル" : mediaKind == .audio ? "音声" : "動画")
        if let ext = block.fileExtension, !ext.isEmpty, !name.lowercased().hasSuffix("." + ext.lowercased()) { return "\(name).\(ext)" }
        return name
    }

    private var detailText: String {
        var parts: [String] = []
        if let ext = block.fileExtension, !ext.isEmpty { parts.append(ext.uppercased()) }
        if let size = block.fileSize, size > 0 { parts.append(Formatters.bytes(Int64(size))) }
        if localURL != nil { parts.append("端末に保存済") }
        return parts.joined(separator: " · ")
    }

    private var icon: String {
        switch mediaKind {
        case .audio: return "waveform"
        case .video: return "film"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName).font(.subheadline.weight(.medium)).lineLimit(2)
                    if !detailText.isEmpty {
                        Text(detailText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                actionButtons
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
            if let localURL, mediaKind == .audio {
                PostDetailAudioPlayerView(url: localURL)
            }
            if let player, mediaKind == .video {
                VideoPlayer(player: player)
                    .aspectRatio(videoAspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .quickLookPreview($previewURL)
        .task(id: block.key) {
            if localURL == nil, let remote = Self.remoteURL(of: block),
               let cached = env.media.cachedFileURL(url: remote, variant: .original) {
                setLocal(cached)
            }
        }
        .onDisappear { player?.pause() }
        .accessibilityIdentifier("postFile.\(block.index)")
    }

    private var videoAspectRatio: CGFloat {
        if let w = block.width, let h = block.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return 16.0 / 9.0
    }

    @ViewBuilder
    private var actionButtons: some View {
        if isLoading {
            ProgressView()
        } else if let localURL {
            HStack(spacing: 12) {
                if mediaKind == .file {
                    Button("開く") { previewURL = localURL }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("postFileOpen.\(block.index)")
                }
                ShareLink(item: localURL) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("共有")
            }
        } else {
            Button("ダウンロード") { Task { await download() } }
                .buttonStyle(.bordered)
                .disabled(Self.remoteURL(of: block) == nil)
                .accessibilityIdentifier("postFileDownload.\(block.index)")
        }
    }

    private func setLocal(_ url: URL) {
        localURL = url
        if mediaKind == .video, player == nil { player = AVPlayer(url: url) }
    }

    /// Explicit user action → `.manual` trigger, allowed even in Low Data / Extreme (SPEC §30).
    private func download() async {
        guard let remote = Self.remoteURL(of: block) else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let url = try await env.media.load(MediaRequest(url: remote, variant: .original, kind: mediaKind, trigger: .manual,
                                                            priority: .foregroundMedia, postID: context.postID,
                                                            creatorID: context.creatorID, accountID: context.accountID))
            setLocal(url)
            if mediaKind == .file { previewURL = url }
        } catch let error as RemoteError {
            errorText = error.userMessage
        } catch {
            errorText = "ダウンロードできませんでした"
        }
    }
}

/// Minimal audio controls for a downloaded file.
struct PostDetailAudioPlayerView: View {
    let url: URL
    @State private var model = PostDetailAudioPlayerModel()

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.toggle(url: url)
            } label: {
                Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isPlaying ? "一時停止" : "再生")
            .accessibilityIdentifier("postAudioPlay")
            VStack(spacing: 2) {
                Slider(value: Binding(get: { model.currentTime }, set: { model.seek(to: $0) }),
                       in: 0...max(model.duration, 1))
                HStack {
                    Text(PostDetailAudioPlayerModel.format(model.currentTime))
                    Spacer()
                    Text(PostDetailAudioPlayerModel.format(model.duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .onDisappear { model.stop() }
    }
}

@MainActor
@Observable
final class PostDetailAudioPlayerModel {
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var loadedURL: URL?

    func toggle(url: URL) {
        if player == nil || loadedURL != url { load(url) }
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            if duration > 0 && currentTime >= duration - 0.5 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func stop() {
        player?.pause()
        isPlaying = false
    }

    private func load(_ url: URL) {
        if let player, let timeObserver { player.removeTimeObserver(timeObserver) }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        loadedURL = url
        currentTime = 0
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                let d = item.duration.seconds
                if d.isFinite && d > 0 { self.duration = d }
                if self.isPlaying && player.rate == 0 && d.isFinite && self.currentTime >= d - 0.25 { self.isPlaying = false }
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Links / embeds / unknown

struct PostDetailEmbedCardView: View {
    let block: PostBlock
    let context: PostDetailRenderContext

    private var url: URL? { PostDetailEmbedLink.url(explicitURL: block.url) }
    /// Provider name supplied by the adapter (`title`), else a Core display name for the stored key.
    private var providerName: String {
        block.title ?? DraftEmbedProvider.displayName(forKey: block.embedProvider) ?? block.embedProvider ?? "外部コンテンツ"
    }

    var body: some View {
        Button {
            if let url { context.openLink(url) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: block.kind == .video ? "play.rectangle.fill" : "puzzlepiece.extension")
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(providerName).font(.caption).foregroundStyle(.secondary)
                    Text(block.text.isEmpty ? (url?.absoluteString ?? block.embedContentID ?? "埋め込みコンテンツ") : block.text)
                        .font(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: url == nil ? "exclamationmark.circle" : "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .accessibilityIdentifier("postEmbed.\(block.index)")
    }
}

struct PostDetailLinkCardView: View {
    let block: PostBlock
    let context: PostDetailRenderContext

    private var url: URL? { block.url.flatMap(URL.init(string:)) }

    var body: some View {
        Button {
            if let url { context.openLink(url) }
        } label: {
            HStack(spacing: 10) {
                if block.thumbnailURL != nil {
                    RemoteImageView(thumbnailURL: block.thumbnailURL, maxVariant: .thumbnail, postID: context.postID,
                                    creatorID: context.creatorID, accountID: context.accountID, contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "link").font(.title3).frame(width: 32).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.title ?? url?.host ?? "リンク")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let subtitle = block.subtitle ?? (block.text.isEmpty ? nil : block.text) {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(url?.host ?? block.url ?? "").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .accessibilityIdentifier("postLink.\(block.index)")
    }
}

struct PostDetailUnknownBlockView: View {
    let context: PostDetailRenderContext

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.square.dashed").foregroundStyle(.secondary)
            Text("未対応のブロック").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Button("Browserで開く", action: context.openInBrowser)
                .font(.caption)
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("postUnknownBlock")
    }
}

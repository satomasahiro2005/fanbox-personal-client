import SwiftUI
import UIKit

struct ImageViewerItem: Identifiable, Hashable {
    let id: String
    var thumbnailURL: String?
    var displayURL: String?
    var originalURL: String?
    var width: Int?
    var height: Int?
    /// `originalURL` was derived from a resized pximg URL by the app (FANBOX may refuse it), not returned by the API.
    var originalIsDerived = false
    /// Post, creator and account of this image when one viewer pages through images of several posts (Offline Library);
    /// nil = the viewer's own.
    var postID: String?
    var creatorID: String?
    var accountID: String?
}

extension ImageViewerItem {
    /// Item for an image block of a post.
    init(block: PostBlock) {
        self.init(id: block.key, thumbnailURL: block.thumbnailURL, displayURL: block.displayURL ?? block.thumbnailURL,
                  originalURL: block.originalURL, width: block.width, height: block.height)
    }

    /// Item for an image FANBOX serves as one resized URL (icons, creator / post / plan covers). The original is the
    /// un-resized pximg image when the URL has that shape (docs/API.md §1.9), else the same URL.
    init(id: String, resizedURL: String) {
        let original = FanboxMediaURL.pximgOriginal(of: resizedURL)
        self.init(id: id, thumbnailURL: resizedURL, displayURL: resizedURL, originalURL: original ?? resizedURL,
                  originalIsDerived: original != nil)
    }

    /// All image blocks of a post, in order (for `ImageViewer(items:startIndex:)`).
    static func items(for post: Post) -> [ImageViewerItem] {
        post.orderedBlocks.filter { $0.kind == .image }.map(ImageViewerItem.init(block:))
    }

    /// Non-empty URLs by variant.
    var urls: [MediaVariant: String] {
        var map: [MediaVariant: String] = [:]
        if let u = thumbnailURL, !u.isEmpty { map[.thumbnail] = u }
        if let u = displayURL, !u.isEmpty { map[.display] = u }
        if let u = originalURL, !u.isEmpty { map[.original] = u }
        return map
    }

    /// What 「写真に保存」 writes for this item.
    func saveSource(postID: String? = nil, creatorID: String? = nil, accountID: String? = nil) -> ImageSaveSource {
        ImageSaveSource(urls: urls, postID: postID, creatorID: creatorID, accountID: accountID, derivedOriginal: originalIsDerived)
    }
}

/// Full-screen image gallery with paging + zoom. Loads Display first, Original on demand (SPEC §6).
///
/// Present with `.fullScreenCover`. Original images are fetched automatically only when the network policy allows it;
/// otherwise the page shows "オリジナルを読み込む". 「写真に保存」 adds the original to Photos (loading it as a manual
/// action when needed); when the mode blocks that, the best cached variant is saved.
struct ImageViewer: View {
    let items: [ImageViewerItem]
    var startIndex: Int = 0
    var postID: String? = nil
    var creatorID: String? = nil
    var accountID: String? = nil

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var selection: Int
    @State private var showsChrome = true
    /// Best local file per page (for sharing).
    @State private var files: [Int: URL] = [:]
    /// 「写真に保存」 per page (absent = not saved yet).
    @State private var photoSaves: [Int: PhotoSaveState] = [:]
    /// Variant each page put into Photos (a second save never adds the same file again).
    @State private var photoSavedVariants: [Int: MediaVariant] = [:]
    @State private var photoSaveError: PhotoSaveError?
    @State private var photoSaveCount = 0
    /// Bumped when a save loaded a new file, so the page shows it.
    @State private var reloads: [Int: Int] = [:]

    init(items: [ImageViewerItem], startIndex: Int = 0, postID: String? = nil, creatorID: String? = nil,
         accountID: String? = nil) {
        self.items = items
        self.startIndex = startIndex
        self.postID = postID
        self.creatorID = creatorID
        self.accountID = accountID
        _selection = State(initialValue: items.isEmpty ? 0 : min(max(startIndex, 0), items.count - 1))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if items.isEmpty {
                Text("画像がありません").foregroundStyle(.white.opacity(0.7))
            } else {
                TabView(selection: $selection) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        ImageViewerPage(item: item, postID: item.postID ?? postID, creatorID: item.creatorID ?? creatorID,
                                        accountID: item.accountID ?? accountID,
                                        reload: reloads[index] ?? 0, isNearSelection: abs(index - selection) <= 1,
                                        onToggleChrome: { withAnimation(.easeInOut(duration: 0.2)) { showsChrome.toggle() } },
                                        // A link, not the cache path: saving / releasing the post moves the cached file.
                                        onFileAvailable: { file in
                                            files[index] = MediaFileCache.namedLink(to: file, fileName: file.lastPathComponent) ?? file
                                        })
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
        }
        .overlay(alignment: .top) {
            if showsChrome { topBar.transition(.opacity) }
        }
        .statusBarHidden(!showsChrome)
        .preferredColorScheme(.dark)
        .sensoryFeedback(.success, trigger: photoSaveCount)
        .alert("写真に保存できませんでした",
               isPresented: Binding(get: { photoSaveError != nil }, set: { if !$0 { photoSaveError = nil } }),
               presenting: photoSaveError) { error in
            if error == .denied {
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("キャンセル", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { error in
            Text(error.message)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("imageViewer")
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(Text("閉じる"))
            .accessibilityIdentifier("imageViewerClose")

            Spacer()

            if !items.isEmpty {
                saveToPhotosButton
            }

            if let file = files[selection] {
                ShareLink(item: file) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(Text("共有"))
                .accessibilityIdentifier("imageViewerShare")
            } else {
                Color.clear.frame(width: 36, height: 36)
            }
        }
        .overlay {
            if !items.isEmpty {
                Text("\(selection + 1) / \(items.count)")
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("imageViewerPageIndicator")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var saveToPhotosButton: some View {
        let online = env.networkMode.isOnline
        let state = photoSaves[selection]
        let done = state?.isDone(online: online) ?? false
        return Button {
            let index = selection
            Task { await saveToPhotos(index: index) }
        } label: {
            Group {
                if state == .saving {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: done ? "checkmark" : "square.and.arrow.down")
                }
            }
            .font(.body.weight(.semibold))
            .frame(width: 36, height: 36)
            .background(.ultraThinMaterial, in: Circle())
        }
        .disabled(state == .saving || done || !canSave(selection, online: online))
        .accessibilityLabel(Text(done ? "写真に保存済み" : "写真に保存"))
        .accessibilityIdentifier("imageViewerSaveToPhotos")
    }

    private func saveSource(_ index: Int) -> ImageSaveSource {
        guard items.indices.contains(index) else { return ImageSaveSource(urls: [:]) }
        let item = items[index]
        return item.saveSource(postID: item.postID ?? postID, creatorID: item.creatorID ?? creatorID,
                               accountID: item.accountID ?? accountID)
    }

    /// Online, a manual load is always allowed (SPEC §30); offline only a cached file can be saved.
    private func canSave(_ index: Int, online: Bool) -> Bool {
        let source = saveSource(index)
        if online { return !source.urls.isEmpty }
        return env.media.saveChoice(for: source) != .unavailable
    }

    private func saveToPhotos(index: Int) async {
        let previous = photoSaves[index]
        guard previous?.isDone(online: env.networkMode.isOnline) != true, previous != .saving else { return }
        photoSaves[index] = .saving
        do {
            let saved = try await PhotoLibrarySaver.save(saveSource(index), media: env.media, alreadySaved: photoSavedVariants[index])
            photoSavedVariants[index] = saved.variant
            photoSaves[index] = saved.isBestAvailable ? .saved : .savedSmaller
            photoSaveCount += 1
            if saved.downloaded { reloads[index, default: 0] += 1 }
        } catch {
            photoSaves[index] = previous
            photoSaveError = PhotoSaveError(error)
        }
    }
}

private enum PhotoSaveState {
    case saving
    /// The largest variant (or the best FANBOX serves) is in Photos.
    case saved
    /// A smaller cached variant was saved while the original could not be loaded (offline).
    case savedSmaller

    /// Nothing more to save: a smaller variant counts only until connectivity returns (the original can be saved then).
    func isDone(online: Bool) -> Bool {
        switch self {
        case .saving: return false
        case .saved: return true
        case .savedSmaller: return !online
        }
    }
}

/// One page of the viewer: display variant first, then original (automatic only when the policy allows).
private struct ImageViewerPage: View {
    let item: ImageViewerItem
    let postID: String?
    let creatorID: String?
    let accountID: String?
    /// Changes when 「写真に保存」 loaded a new file for this page.
    let reload: Int
    /// The page is on screen or next to it. Pages further away drop their (up to full-resolution) bitmap: a paged
    /// TabView keeps every visited page's state, so a long gallery would otherwise keep one bitmap per page.
    let isNearSelection: Bool
    let onToggleChrome: () -> Void
    let onFileAvailable: (URL) -> Void

    @Environment(AppEnvironment.self) private var env
    @State private var image: UIImage?
    @State private var shown: MediaVariant?
    @State private var displayState: ViewerLoadState = .idle
    @State private var originalState: ViewerLoadState = .idle

    private var urls: [MediaVariant: String] { item.urls }

    /// Whether a distinct original exists beyond what is displayed.
    private var hasSeparateOriginal: Bool {
        guard let original = urls[.original], shown != .original else { return false }
        return original != urls[.display] || shown == nil
    }

    /// The display variant (or the thumbnail when there is no display URL) or something larger is shown already, e.g.
    /// the original that 「写真に保存」 loaded: the display controls have nothing left to load.
    private var showsDisplay: Bool {
        guard let shown else { return false }
        return shown >= (urls[.display] != nil ? .display : .thumbnail)
    }

    var body: some View {
        ZStack {
            if let image {
                ZoomableImageView(image: image, onSingleTap: onToggleChrome)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 12) {
                    if displayState == .loading || originalState == .loading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: displayState == .blocked ? "wifi.slash" : "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    if displayState == .blocked {
                        Text("オフラインのため表示できません")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    } else if displayState == .failed {
                        Text("画像を読み込めませんでした")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggleChrome)
            }
        }
        .overlay(alignment: .bottom) { controls }
        // Re-runs when connectivity returns (a fixed network mode keeps its mode while the path is down).
        .task(id: ImageViewerPageKey(itemID: item.id, online: env.networkMode.isOnline, reload: reload, near: isNearSelection)) {
            await start()
        }
        // A page that scrolled off screen gets no task run when it becomes far, so it drops its bitmap here; the task
        // rebuilds it from the caches when the page appears again.
        .onDisappear { release() }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 8) {
            if showsDisplay {
                EmptyView()
            } else if displayState == .manualRequired {
                Button {
                    Task { await loadDisplay(trigger: .manual) }
                } label: {
                    Label("画像を読み込む", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("imageViewerLoadDisplay")
            } else if displayState == .failed {
                Button {
                    Task { await loadDisplay(trigger: .manual) }
                } label: {
                    Label("再読み込み", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!env.networkMode.isOnline)
                .accessibilityIdentifier("imageViewerRetryDisplay")
            }
            switch originalState {
            case .manualRequired, .blocked, .failed:
                if hasSeparateOriginal {
                    Button {
                        Task { await loadOriginal(trigger: .manual) }
                    } label: {
                        Label(originalState == .failed ? "オリジナルを再読み込み" : "オリジナルを読み込む", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .disabled(originalState == .blocked && !env.networkMode.policy.allowsNetwork)
                    .accessibilityIdentifier("loadOriginalButton")
                }
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("オリジナルを読み込み中").font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.4), in: Capsule())
            default:
                EmptyView()
            }
        }
        .padding(.bottom, 32)
    }

    // MARK: - Loading

    private func start() async {
        guard isNearSelection else {
            // Far from the visible page: release the bitmap (reloaded from the caches when the page comes back).
            release()
            return
        }
        let media = env.media
        if image == nil, let hit = media.bestCachedImageWithVariant(urls: urls, upTo: .original) {
            image = hit.image
            shown = hit.variant
        }
        // A cached file can be shared right away, also when no load follows (Low Data / Extreme / Offline, or the
        // original already decoded).
        if let file = MediaVariant.allCases.reversed().lazy.compactMap({ variant in
            self.urls[variant].flatMap { media.peekCachedFileURL(url: $0, variant: variant) }
        }).first {
            onFileAvailable(file)
        }
        await loadDisplay(trigger: .automatic)
        await loadOriginal(trigger: .automatic)
    }

    private func release() {
        image = nil
        shown = nil
        displayState = .idle
        originalState = .idle
    }

    private func loadDisplay(trigger: MediaTrigger) async {
        guard let url = urls[.display] ?? urls[.thumbnail] else { return }
        let variant: MediaVariant = urls[.display] != nil ? .display : .thumbnail
        if let shown, shown >= variant { return }
        let media = env.media
        let cached = media.isFileCached(url: url, variant: variant)
        if !cached {
            switch media.decision(kind: .image, variant: variant, trigger: trigger) {
            case .allowed: break
            case .manualOnly:
                displayState = .manualRequired
                return
            case .blocked:
                displayState = .blocked
                return
            }
        }
        displayState = .loading
        do {
            let decoded = try await media.image(request(variant, url: url, trigger: trigger))
            apply(decoded, variant: variant, url: url)
            displayState = .done
        } catch {
            displayState = (error as? RemoteError) == .blockedByPolicy ? .blocked : .failed
        }
    }

    private func loadOriginal(trigger: MediaTrigger) async {
        guard let url = urls[.original] else { return }
        if let shown, shown >= .original { return }
        let media = env.media
        let cached = media.isFileCached(url: url, variant: .original)
        if !cached {
            switch media.decision(kind: .image, variant: .original, trigger: trigger) {
            case .allowed: break
            case .manualOnly:
                originalState = .manualRequired
                return
            case .blocked:
                originalState = .blocked
                return
            }
        }
        originalState = .loading
        do {
            let decoded = try await media.image(request(.original, url: url, trigger: trigger))
            apply(decoded, variant: .original, url: url)
            originalState = .done
        } catch {
            originalState = (error as? RemoteError) == .blockedByPolicy ? .blocked : .failed
        }
    }

    private func apply(_ decoded: UIImage, variant: MediaVariant, url: String) {
        if shown.map({ variant >= $0 }) ?? true {
            image = decoded
            shown = variant
        }
        if variant >= .display, [.manualRequired, .blocked, .failed].contains(displayState) { displayState = .done }
        if let file = env.media.peekCachedFileURL(url: url, variant: variant) {
            onFileAvailable(file)
        }
    }

    private func request(_ variant: MediaVariant, url: String, trigger: MediaTrigger) -> MediaRequest {
        MediaRequest(url: url, variant: variant, kind: .image, trigger: trigger, priority: .foregroundMedia, postID: postID,
                     creatorID: creatorID, accountID: accountID)
    }
}

private enum ViewerLoadState: Equatable {
    case idle, loading, manualRequired, blocked, failed, done
}

private struct ImageViewerPageKey: Hashable {
    var itemID: String
    var online: Bool
    var reload: Int
    var near: Bool
}

// MARK: - Zoom

/// UIScrollView-backed zoomable image (pinch + double-tap). Single tap toggles the viewer chrome.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var onSingleTap: () -> Void = {}

    func makeUIView(context: Context) -> ZoomImageScrollView {
        let view = ZoomImageScrollView()
        view.onSingleTap = onSingleTap
        view.setImage(image)
        return view
    }

    func updateUIView(_ uiView: ZoomImageScrollView, context: Context) {
        uiView.onSingleTap = onSingleTap
        if uiView.imageView.image !== image {
            uiView.setImage(image)
        }
    }
}

final class ZoomImageScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onSingleTap: (() -> Void)?
    private var lastBoundsSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "画像"
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Swaps the image. A higher-resolution version of the same picture keeps the current zoom.
    func setImage(_ image: UIImage) {
        let previous = imageView.image
        imageView.image = image
        let sameAspect: Bool = {
            guard let previous, previous.size.height > 0, image.size.height > 0 else { return false }
            return abs(previous.size.width / previous.size.height - image.size.width / image.size.height) < 0.01
        }()
        if !sameAspect || zoomScale <= minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: false)
            layoutImage()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            setZoomScale(minimumZoomScale, animated: false)
            layoutImage()
        }
        centerContent()
    }

    private func layoutImage() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        centerContent()
    }

    private func centerContent() {
        let insetX = max(0, (bounds.width - contentSize.width) / 2)
        let insetY = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        if contentInset != inset { contentInset = inset }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let target: CGFloat = 2.5
            let size = CGSize(width: bounds.width / target, height: bounds.height / target)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                 animated: true)
        }
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }
}

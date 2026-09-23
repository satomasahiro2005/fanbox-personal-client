import SwiftUI
import UIKit

/// Staged, policy-aware image view (Thumbnail → Display → Original) backed by `MediaService`.
///
/// - Shows the best cached image instantly (memory cache in `body`; disk-cached files are decoded off the main thread),
///   then progressively loads higher variants up to `maxVariant` through `MediaService` (network-mode policy, SPEC §30).
/// - No URL at or below `maxVariant` (FANBOX images have no thumbnail URL): the smallest larger variant is used, fetched
///   under its real variant (its own policy applies, e.g. "タップして読み込み" in Extreme) and decoded at `maxVariant` size.
/// - Manual-only (e.g. Extreme / Low Data originals): shows "タップして読み込み"; the tap loads with trigger `.manual`.
/// - Blocked / Offline: keeps whatever is cached, otherwise a placeholder with an offline glyph; reloads by itself when
///   connectivity returns.
/// - Failed: one automatic retry for transient errors, then a tap-to-retry control.
struct RemoteImageView: View {
    var thumbnailURL: String?
    var displayURL: String?
    var originalURL: String?
    /// Highest variant to load automatically.
    var maxVariant: MediaVariant = .display
    var postID: String?
    var creatorID: String?
    var accountID: String?
    var contentMode: ContentMode = .fill
    var priority: RequestPriority = .foregroundMedia
    /// Show the "タップして読み込み" affordance when the policy requires a manual load.
    var allowsManualLoad: Bool = true
    /// Placeholder glyph while nothing is cached.
    var placeholderSystemImage: String = "photo"

    @Environment(AppEnvironment.self) private var env
    @State private var image: UIImage?
    @State private var shownVariant: MediaVariant?
    @State private var loadedURLs: [MediaVariant: String] = [:]
    @State private var phase: RemoteImagePhase = .idle
    @State private var trigger: MediaTrigger = .automatic
    @State private var manualNonce = 0
    /// Bumped to re-run the load after a failure (automatic retry once, then the retry button).
    @State private var retryNonce = 0
    @State private var autoRetries = 0
    @State private var width: CGFloat = 0

    /// Automatic retries after a transient failure (per URL set).
    static let maxAutoRetries = 1
    static let autoRetryDelay: Duration = .seconds(2)

    init(thumbnailURL: String? = nil, displayURL: String? = nil, originalURL: String? = nil, maxVariant: MediaVariant = .display,
         postID: String? = nil, creatorID: String? = nil, accountID: String? = nil, contentMode: ContentMode = .fill,
         priority: RequestPriority = .foregroundMedia, allowsManualLoad: Bool = true, placeholderSystemImage: String = "photo") {
        self.thumbnailURL = thumbnailURL
        self.displayURL = displayURL
        self.originalURL = originalURL
        self.maxVariant = maxVariant
        self.postID = postID
        self.creatorID = creatorID
        self.accountID = accountID
        self.contentMode = contentMode
        self.priority = priority
        self.allowsManualLoad = allowsManualLoad
        self.placeholderSystemImage = placeholderSystemImage
    }

    /// URLs this view may load, keyed by their real variant (see `RemoteImageSources`).
    private var urls: [MediaVariant: String] {
        RemoteImageSources.make(thumbnail: thumbnailURL, display: displayURL, original: originalURL, maxVariant: maxVariant)
    }

    private var loadKey: RemoteImageLoadKey {
        RemoteImageLoadKey(urls: urls, mode: env.networkMode.effectiveMode, online: env.networkMode.isOnline, trigger: trigger,
                           nonce: manualNonce, retry: retryNonce)
    }

    var body: some View {
        let currentURLs = urls
        // Stale state guard: the view identity may be reused with different URLs.
        let current = loadedURLs == currentURLs ? image : nil
        let shown = current ?? env.media.memoryCachedImage(urls: currentURLs, upTo: maxVariant)

        Color.clear
            .overlay {
                if let shown {
                    Image(uiImage: shown)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                } else {
                    placeholder
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) { statusBadge(hasImage: shown != nil) }
            .overlay { centerOverlay(hasImage: shown != nil) }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .task(id: loadKey) { await load() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("画像"))
    }

    // MARK: - Subviews

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: phase == .blocked ? "wifi.slash" : (phase == .failed ? "exclamationmark.triangle" : placeholderSystemImage))
                    .font(width > 0 && width < 60 ? .caption : .title3)
                    .foregroundStyle(.secondary)
                    // The retry button takes the center when it is shown.
                    .opacity(phase == .failed && allowsManualLoad ? 0 : 1)
            }
    }

    @ViewBuilder
    private func statusBadge(hasImage: Bool) -> some View {
        switch phase {
        case .loading(let variant) where width >= 80:
            let fraction = urls[variant].flatMap { env.media.progress(url: $0, variant: variant) }
            Group {
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                } else {
                    ProgressView()
                }
            }
            .controlSize(.mini)
            .tint(.white)
            .padding(5)
            .background(.black.opacity(0.35), in: Circle())
            .padding(6)
            .accessibilityLabel(Text("読み込み中"))
        case .manualRequired where hasImage && allowsManualLoad:
            manualButton(compact: true)
                .padding(6)
        case .blocked where hasImage && width >= 80:
            Image(systemName: "wifi.slash")
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(5)
                .background(.black.opacity(0.35), in: Circle())
                .padding(6)
                .accessibilityLabel(Text("通信モードにより停止中"))
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func centerOverlay(hasImage: Bool) -> some View {
        if phase == .manualRequired, !hasImage, allowsManualLoad {
            manualButton(compact: width > 0 && width < 110)
        } else if phase == .failed, !hasImage, allowsManualLoad {
            retryButton(compact: width > 0 && width < 110)
        }
    }

    /// Tap-to-retry after a failed load (connection dropped, timeout, CDN error …).
    private func retryButton(compact: Bool) -> some View {
        Button {
            retryNonce += 1
        } label: {
            if compact {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.body)
                    .foregroundStyle(.white, .black.opacity(0.45))
            } else {
                Label("再読み込み", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("画像を再読み込み"))
        .accessibilityIdentifier("remoteImageRetry")
    }

    private func manualButton(compact: Bool) -> some View {
        Button {
            trigger = .manual
            manualNonce += 1
        } label: {
            if compact {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.body)
                    .foregroundStyle(.white, .black.opacity(0.45))
            } else {
                Label("タップして読み込み", systemImage: "arrow.down.circle")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("タップして読み込み"))
        .accessibilityIdentifier("remoteImageManualLoad")
    }

    // MARK: - Loading

    private func load() async {
        let media = env.media
        let currentURLs = urls
        if loadedURLs != currentURLs {
            image = nil
            shownVariant = nil
            loadedURLs = currentURLs
            autoRetries = 0
        }
        guard !currentURLs.isEmpty else {
            phase = .idle
            return
        }

        // 1. Instant: whatever is already decoded in memory (disk hits are decoded off-main in step 2,
        //    so scrolling lists never decode on the main thread).
        if image == nil, let hit = media.memoryCachedImageWithVariant(urls: currentURLs, upTo: maxVariant) {
            image = hit.image
            shownVariant = hit.variant
        }

        let order = MediaVariant.allCases.filter { currentURLs[$0] != nil }

        // 2. Higher variant already on disk ⇒ decode it (no network, no policy needed).
        if let cachedBest = order.last(where: { media.isFileCached(url: currentURLs[$0]!, variant: $0) }),
           shownVariant.map({ cachedBest > $0 }) ?? true {
            if let decoded = try? await media.image(request(cachedBest, url: currentURLs[cachedBest]!)) {
                guard !Task.isCancelled else { return }
                show(decoded, variant: cachedBest)
            }
        }

        // 3. Progressive network loading: thumbnail → display (→ original), each gated by the policy.
        for variant in order where shownVariant.map({ variant > $0 }) ?? true {
            guard let url = currentURLs[variant] else { continue }
            switch media.decision(kind: .image, variant: variant, trigger: trigger) {
            case .allowed:
                phase = .loading(variant)
                do {
                    let decoded = try await media.image(request(variant, url: url))
                    guard !Task.isCancelled else { return }
                    show(decoded, variant: variant)
                } catch is CancellationError {
                    return
                } catch RemoteError.cancelled {
                    return
                } catch RemoteError.blockedByPolicy {
                    phase = .blocked
                    return
                } catch {
                    if Task.isCancelled { return }
                    phase = image == nil ? .failed : .idle
                    // Transient failure (dropped connection, timeout, 5xx): retry once by itself after a short pause.
                    if autoRetries < Self.maxAutoRetries, RemoteImageSources.isTransient(error) {
                        autoRetries += 1
                        try? await Task.sleep(for: Self.autoRetryDelay)
                        guard !Task.isCancelled else { return }
                        retryNonce += 1
                    }
                    return
                }
            case .manualOnly:
                phase = .manualRequired
                return
            case .blocked:
                phase = .blocked
                return
            }
        }
        phase = .idle
    }

    private func request(_ variant: MediaVariant, url: String) -> MediaRequest {
        MediaRequest(url: url, variant: variant, kind: .image, trigger: trigger, priority: priority, postID: postID,
                     creatorID: creatorID, accountID: accountID, decodeAs: variant > maxVariant ? maxVariant : nil)
    }

    private func show(_ decoded: UIImage, variant: MediaVariant) {
        withAnimation(image == nil ? .easeOut(duration: 0.15) : nil) {
            image = decoded
        }
        shownVariant = variant
    }
}

enum RemoteImagePhase: Equatable {
    case idle
    case loading(MediaVariant)
    case manualRequired
    case blocked
    case failed
}

private struct RemoteImageLoadKey: Hashable {
    var urls: [MediaVariant: String]
    var mode: NetworkMode
    /// Path / Offline changes re-run the load (a fixed network mode does not change when the path drops).
    var online: Bool
    var trigger: MediaTrigger
    var nonce: Int
    var retry: Int
}

/// Pure source selection for `RemoteImageView` (unit-tested).
enum RemoteImageSources {
    /// URLs at or below `maxVariant`. When none exists — FANBOX image blocks carry only display / original URLs — the
    /// smallest larger variant is used instead, under its real variant key: the network policy of that size applies and
    /// cached files of it (e.g. Offline-saved display images) are found. The view decodes it at `maxVariant` size.
    static func make(thumbnail: String?, display: String?, original: String?, maxVariant: MediaVariant) -> [MediaVariant: String] {
        var all: [MediaVariant: String] = [:]
        if let thumbnail, !thumbnail.isEmpty { all[.thumbnail] = thumbnail }
        if let display, !display.isEmpty { all[.display] = display }
        if let original, !original.isEmpty { all[.original] = original }
        var map = all.filter { $0.key <= maxVariant }
        if map.isEmpty, let fallback = MediaVariant.allCases.first(where: { $0 > maxVariant && all[$0] != nil }) {
            map[fallback] = all[fallback]
        }
        return map
    }

    /// Worth an automatic retry: network / timeout / rate limit / 5xx (anything that is not a definite answer).
    static func isTransient(_ error: Error) -> Bool {
        guard let remote = error as? RemoteError else { return !(error is CancellationError) }
        return remote.isTransient
    }
}

/// Circular avatar.
struct AvatarView: View {
    var url: String?
    var size: CGFloat = 32

    var body: some View {
        RemoteImageView(thumbnailURL: url, maxVariant: .thumbnail, allowsManualLoad: false,
                        placeholderSystemImage: "person.crop.circle.fill")
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

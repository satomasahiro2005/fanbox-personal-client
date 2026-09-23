import SwiftData
import SwiftUI

enum OfflineLibrarySegment: String, CaseIterable, Identifiable {
    case posts, creators, images, files

    var id: String { rawValue }

    /// SPEC §31 labels.
    var title: String {
        switch self {
        case .posts: return "Posts"
        case .creators: return "Creators"
        case .images: return "Images"
        case .files: return "Files"
        }
    }
}

/// Offline Library (SPEC §31): saved posts, creator "recent N" rules, cached images and files, and cache usage.
/// Save units are limited to: this post / a creator's recent N / auto-saved viewed posts (no unlimited crawl).
struct OfflineLibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var segment: OfflineLibrarySegment = .posts
    @State private var isConfirmingClearAll = false
    @State private var isPickingCreator = false
    @State private var viewer: OfflineViewerSelection?

    @Query(filter: #Predicate<Post> { $0.offlineStateRaw != "none" }, sort: \Post.publishedAt, order: .reverse)
    private var posts: [Post]
    @Query(filter: #Predicate<Creator> { $0.offlineRecentCount > 0 }, sort: \Creator.name)
    private var creators: [Creator]
    // Sorted by creation (not last access) so viewing an image does not reshuffle the grid.
    @Query(filter: #Predicate<MediaCacheEntry> { $0.kindRaw == "image" && $0.postID != nil },
           sort: \MediaCacheEntry.createdAt, order: .reverse)
    private var imageEntries: [MediaCacheEntry]
    @Query(filter: #Predicate<MediaCacheEntry> { $0.kindRaw != "image" }, sort: \MediaCacheEntry.createdAt, order: .reverse)
    private var fileEntries: [MediaCacheEntry]

    var body: some View {
        @Bindable var settings = env.settings
        List {
            Section {
                StorageUsageSummaryView(usage: env.media.usage, capacity: env.settings.cacheCapacity)
                Toggle("閲覧した投稿を自動保存", isOn: $settings.autoSaveViewedPosts)
                    .accessibilityIdentifier("offlineAutoSaveToggle")
            } footer: {
                Text("保存単位: この投稿 / Creator の最近 N 件 / 今後閲覧した投稿。過去履歴の無制限な取得は行いません。")
            }

            Section {
                Picker("表示", selection: $segment) {
                    ForEach(OfflineLibrarySegment.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("offlineSegmentPicker")
            }

            switch segment {
            case .posts: postsSection
            case .creators: creatorsSection
            case .images: imagesSection
            case .files: filesSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Offline ライブラリ")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("キャッシュを削除（保存済みを除く）", systemImage: "trash") {
                        env.media.clearAll(includePinned: false)
                    }
                    Button("すべて削除（保存済みを含む）", systemImage: "trash.fill", role: .destructive) {
                        isConfirmingClearAll = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(Text("キャッシュ操作"))
                .accessibilityIdentifier("offlineCacheMenu")
            }
        }
        .confirmationDialog("保存済みを含むすべてのメディアを削除しますか？", isPresented: $isConfirmingClearAll, titleVisibility: .visible) {
            Button("すべて削除", role: .destructive) { env.media.clearAll(includePinned: true) }
        } message: {
            Text("画像・添付ファイルが削除されます。投稿本文・コメントなどのテキストは残ります。")
        }
        .sheet(isPresented: $isPickingCreator) { OfflineCreatorPicker() }
        .fullScreenCover(item: $viewer) { selection in
            ImageViewer(items: selection.items, startIndex: selection.index)
        }
        .refreshable {
            if segment == .creators { await env.offline.refreshCreatorRules() }
            env.media.refreshUsage()
        }
        .task { env.media.refreshUsage() }
        .accessibilityIdentifier("offlineLibrary")
    }

    // MARK: - Posts

    @ViewBuilder
    private var postsSection: some View {
        Section {
            if posts.isEmpty {
                EmptyStateView(title: "保存した投稿はありません", systemImage: "arrow.down.circle",
                               message: "投稿詳細の「Offline 保存」で本文と画像を端末に保存できます。")
            }
            ForEach(posts) { post in
                NavigationLink(value: AppRoute.post(postID: post.postID)) {
                    VStack(alignment: .leading, spacing: 4) {
                        LibraryPostRow(post: post)
                        OfflinePostStatusLine(postID: post.postID)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("解除", systemImage: "arrow.down.circle.dotted") {
                        env.offline.remove(postID: post.postID)
                    }
                    .tint(.orange)
                    Button("キャッシュ削除", systemImage: "trash", role: .destructive) {
                        env.media.clearCache(postID: post.postID)
                    }
                }
                .contextMenu {
                    Button("再保存", systemImage: "arrow.clockwise") {
                        Task { await env.offline.save(postID: post.postID) }
                    }
                    Button("Offline 保存を解除", systemImage: "arrow.down.circle.dotted") {
                        env.offline.remove(postID: post.postID)
                    }
                    Button("キャッシュ削除", systemImage: "trash", role: .destructive) {
                        env.media.clearCache(postID: post.postID)
                    }
                }
            }
        } header: {
            Text("保存済みの投稿 \(posts.count) 件")
        }
    }

    // MARK: - Creators

    @ViewBuilder
    private var creatorsSection: some View {
        Section {
            if creators.isEmpty {
                Text("クリエイターごとに「最近 N 件」を自動で保存できます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(creators) { creator in
                OfflineCreatorRuleRow(creator: creator)
            }
            Button("クリエイターを追加", systemImage: "plus.circle") { isPickingCreator = true }
                .accessibilityIdentifier("offlineAddCreator")
        } header: {
            Text("Creator の最近 N 件")
        } footer: {
            Text("最新ページを1回だけ取得して保存します。引っ張って更新すると各ルールを再適用します。")
        }
    }

    // MARK: - Images

    /// Saved post images: display / original entries (thumbnails only when nothing larger exists), deduplicated by URL.
    private var galleryEntries: [MediaCacheEntry] {
        var seenURLs = Set<String>()
        var postsWithLarge = Set<String>()
        var result: [MediaCacheEntry] = []
        for entry in imageEntries where entry.variant != .thumbnail {
            if seenURLs.insert(entry.url).inserted { result.append(entry) }
            if let postID = entry.postID { postsWithLarge.insert(postID) }
        }
        for entry in imageEntries where entry.variant == .thumbnail {
            guard let postID = entry.postID, !postsWithLarge.contains(postID) else { continue }
            if seenURLs.insert(entry.url).inserted { result.append(entry) }
        }
        return result
    }

    @ViewBuilder
    private var imagesSection: some View {
        let entries = galleryEntries
        Section {
            if entries.isEmpty {
                EmptyStateView(title: "キャッシュ済みの画像はありません", systemImage: "photo.on.rectangle")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 4)], spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.element.key) { index, entry in
                        Button {
                            viewer = OfflineViewerSelection(items: entries.map(Self.viewerItem), index: index)
                        } label: {
                            RemoteImageView(thumbnailURL: entry.url, maxVariant: .thumbnail, postID: entry.postID, allowsManualLoad: false)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(alignment: .topTrailing) {
                                    if entry.isPinned {
                                        Image(systemName: "pin.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.white)
                                            .padding(4)
                                            .background(.black.opacity(0.4), in: Circle())
                                            .padding(4)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let postID = entry.postID {
                                Button("投稿を開く", systemImage: "doc.text") {
                                    env.router.open(.post(postID: postID), in: .library)
                                }
                            }
                            Button("この画像を削除", systemImage: "trash", role: .destructive) {
                                env.media.removeEntry(key: entry.key)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("offlineImagesGrid")
            }
        } header: {
            Text("画像 \(entries.count) 枚")
        }
    }

    private static func viewerItem(_ entry: MediaCacheEntry) -> ImageViewerItem {
        ImageViewerItem(id: entry.key,
                        thumbnailURL: entry.variant == .thumbnail ? entry.url : nil,
                        displayURL: entry.variant == .display ? entry.url : nil,
                        originalURL: entry.variant == .original ? entry.url : nil)
    }

    // MARK: - Files

    @ViewBuilder
    private var filesSection: some View {
        Section {
            if fileEntries.isEmpty {
                EmptyStateView(title: "保存済みのファイルはありません", systemImage: "doc",
                               message: "Offline 保存した投稿の添付ファイル・音声・動画がここに表示されます。")
            }
            ForEach(fileEntries) { entry in
                Group {
                    if let postID = entry.postID {
                        NavigationLink(value: AppRoute.post(postID: postID)) { OfflineFileRow(entry: entry) }
                    } else {
                        OfflineFileRow(entry: entry)
                    }
                }
                    .swipeActions(edge: .trailing) {
                        Button("削除", systemImage: "trash", role: .destructive) {
                            env.media.removeEntry(key: entry.key)
                        }
                    }
            }
        } header: {
            Text("ファイル \(fileEntries.count) 件")
        }
    }
}

struct OfflineViewerSelection: Identifiable {
    let id = UUID()
    var items: [ImageViewerItem]
    var index: Int
}

/// "保存中 42%" / cached size line for an offline post.
private struct OfflinePostStatusLine: View {
    let postID: String
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: 6) {
            if env.offline.activeSaves.contains(postID) {
                ProgressView(value: env.offline.saveProgress[postID] ?? 0)
                    .frame(maxWidth: 120)
                Text("保存中").font(.caption2).foregroundStyle(.secondary)
            } else {
                let bytes = env.media.cachedBytes(postID: postID)
                Text(bytes > 0 ? "メディア \(Formatters.bytes(bytes))" : "テキストのみ")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let summary = env.offline.lastSummaries[postID], summary.mediaBlocked > 0 {
                    Text("通信モードにより \(summary.mediaBlocked) 件未取得")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.leading, 72)
    }
}

/// One creator "recent N" rule.
private struct OfflineCreatorRuleRow: View {
    let creator: Creator
    @Environment(AppEnvironment.self) private var env

    private static let choices = [5, 10, 20, 30, 50]

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: creator.iconURL, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(creator.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("最近 \(creator.offlineRecentCount) 件を保存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if env.offline.activeCreatorSaves.contains(creator.creatorID) {
                ProgressView().controlSize(.small)
            }
            Menu {
                ForEach(Self.choices, id: \.self) { n in
                    Button("\(n) 件") { run(count: n) }
                }
                Button("今すぐ保存", systemImage: "arrow.down.circle") { run(count: creator.offlineRecentCount) }
                Divider()
                Button("ルールを解除", systemImage: "xmark.circle", role: .destructive) {
                    Task { await env.offline.saveRecent(creatorID: creator.creatorID, count: 0) }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityIdentifier("offlineCreatorRule_\(creator.creatorID)")
        }
    }

    private func run(count: Int) {
        let id = creator.creatorID
        Task { await env.offline.saveRecent(creatorID: id, count: count) }
    }
}

/// Cached attachment row with share.
private struct OfflineFileRow: View {
    let entry: MediaCacheEntry
    @Environment(AppEnvironment.self) private var env

    private var displayName: String {
        if let postID = entry.postID {
            let url = entry.url
            let blocks = env.store.fetch(FetchDescriptor<PostBlock>(predicate: #Predicate { $0.postID == postID }))
            if let block = blocks.first(where: { $0.originalURL == url || $0.url == url }), let name = block.fileName, !name.isEmpty {
                if let ext = block.fileExtension, !ext.isEmpty, !name.lowercased().hasSuffix(".\(ext.lowercased())") {
                    return "\(name).\(ext)"
                }
                return name
            }
        }
        if let demo = DemoMediaURL(entry.url), case .file(let name, _) = demo { return name }
        return URL(string: entry.url)?.lastPathComponent ?? "ファイル"
    }

    private var icon: String {
        switch entry.kind {
        case .audio: return "music.note"
        case .video: return "film"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    var body: some View {
        let fileURL = env.media.fileCache.fileURL(relativePath: entry.relativePath)
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).font(.subheadline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Formatters.bytes(Int64(entry.byteSize)))
                    if let postID = entry.postID, let post = env.store.post(id: postID) {
                        Text(post.title).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            ShareLink(item: fileURL) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("共有"))
        }
    }
}

/// Sheet to add a creator "recent N" rule.
private struct OfflineCreatorPicker: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Creator> { $0.isFollowed || $0.isSupported || $0.hasKnownPosts }, sort: \Creator.name)
    private var candidates: [Creator]
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            List {
                let visible = candidates.filter {
                    $0.offlineRecentCount == 0 && (filter.isEmpty || $0.name.localizedStandardContains(filter))
                }
                if visible.isEmpty {
                    Text("追加できるクリエイターがいません").foregroundStyle(.secondary)
                }
                ForEach(visible) { creator in
                    Button {
                        let id = creator.creatorID
                        let count = max(1, env.settings.creatorRecentCount)
                        Task { await env.offline.saveRecent(creatorID: id, count: count) }
                        dismiss()
                    } label: {
                        LibraryCreatorRow(creator: creator)
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $filter, prompt: Text("クリエイター名"))
            .navigationTitle("最近 \(env.settings.creatorRecentCount) 件を保存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }
}

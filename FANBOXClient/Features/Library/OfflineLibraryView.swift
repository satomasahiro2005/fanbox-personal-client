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
///
/// Each segment is its own view with its own queries, so only the visible segment touches SwiftData; rows receive plain
/// values built once per render (no per-row fetches in `body`).
struct OfflineLibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var segment: OfflineLibrarySegment = .posts
    @State private var isConfirmingClearAll = false
    @State private var isPickingCreator = false
    @State private var viewer: OfflineViewerSelection?
    @State private var imageLimit = OfflineImagesSection.pageSize

    var body: some View {
        @Bindable var settings = env.settings
        List {
            Section {
                StorageUsageSummaryView(usage: env.media.usage, capacity: env.settings.cacheCapacity)
                Toggle("閲覧した投稿を自動保存", isOn: $settings.autoSaveViewedPosts)
                    .accessibilityIdentifier("offlineAutoSaveToggle")
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
            case .posts: OfflinePostsSection()
            case .creators: OfflineCreatorsSection(isPickingCreator: $isPickingCreator)
            case .images: OfflineImagesSection(limit: imageLimit, viewer: $viewer) { imageLimit += OfflineImagesSection.pageSize }
            case .files: OfflineFilesSection()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Offlineライブラリ")
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
        .closesOnNotificationRoute($isPickingCreator)
        .fullScreenCover(item: $viewer) { selection in
            ImageViewer(items: selection.items, startIndex: selection.index)
        }
        .closesOnNotificationRoute($viewer)
        .refreshable {
            if segment == .creators { await env.offline.refreshCreatorRules() }
            env.media.refreshUsage()
        }
        .task { env.media.refreshUsage() }
        .accessibilityIdentifier("offlineLibrary")
    }
}

// MARK: - Posts

private struct OfflinePostsSection: View {
    @Environment(AppEnvironment.self) private var env
    @Query(filter: #Predicate<Post> { $0.offlineStateRaw != "none" }, sort: \Post.publishedAt, order: .reverse)
    private var posts: [Post]

    var body: some View {
        let bytes = OfflineLibraryIndex.bytesByPost(store: env.store)
        Section {
            if posts.isEmpty {
                EmptyStateView(title: "保存した投稿はありません", systemImage: "arrow.down.circle",
                               message: "投稿詳細の「Offline保存」で本文と画像を端末に保存できます。")
            }
            ForEach(posts) { post in
                NavigationLink(value: AppRoute.post(postID: post.postID)) {
                    VStack(alignment: .leading, spacing: 4) {
                        LibraryPostRow(post: post)
                        OfflinePostStatusLine(postID: post.postID, hasBody: post.hasCachedBody, mediaBytes: bytes[post.postID] ?? 0)
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
                    Button("Offline保存を解除", systemImage: "arrow.down.circle.dotted") {
                        env.offline.remove(postID: post.postID)
                    }
                    Button("キャッシュ削除", systemImage: "trash", role: .destructive) {
                        env.media.clearCache(postID: post.postID)
                    }
                }
            }
        } header: {
            Text("保存済みの投稿\(posts.count)件")
        }
    }
}

/// Lookup tables built once per render (instead of one SwiftData fetch per row).
@MainActor
enum OfflineLibraryIndex {
    /// Cached media bytes per post, from one fetch of two columns.
    static func bytesByPost(store: LocalStore) -> [String: Int64] {
        var descriptor = FetchDescriptor<MediaCacheEntry>(predicate: #Predicate { $0.postID != nil })
        descriptor.propertiesToFetch = [\.postID, \.byteSize]
        var result: [String: Int64] = [:]
        for entry in store.fetch(descriptor) {
            guard let postID = entry.postID else { continue }
            result[postID, default: 0] += Int64(entry.byteSize)
        }
        return result
    }

    /// File name per attachment URL and title per post, from one PostBlock fetch and one Post fetch.
    static func fileNames(for entries: [OfflineFileItem], store: LocalStore) -> (names: [String: String], titles: [String: String]) {
        let postIDs = Array(Set(entries.compactMap(\.postID)))
        guard !postIDs.isEmpty else { return ([:], [:]) }
        let kinds = [PostBlockKind.file.rawValue, PostBlockKind.audio.rawValue, PostBlockKind.video.rawValue]
        var names: [String: String] = [:]
        for block in store.fetch(FetchDescriptor<PostBlock>(predicate: #Predicate {
            postIDs.contains($0.postID) && kinds.contains($0.kindRaw)
        })) {
            guard let name = block.fileName, !name.isEmpty else { continue }
            var display = name
            if let ext = block.fileExtension, !ext.isEmpty, !name.lowercased().hasSuffix(".\(ext.lowercased())") { display = "\(name).\(ext)" }
            for url in [block.originalURL, block.url].compactMap({ $0 }) where names[url] == nil { names[url] = display }
        }
        var titles: [String: String] = [:]
        for post in store.fetch(FetchDescriptor<Post>(predicate: #Predicate { postIDs.contains($0.postID) })) {
            titles[post.postID] = post.title
        }
        return (names, titles)
    }

    /// The picture (image block or cover of the post, with all its URLs, the post's creator and the account that loads its
    /// media) each cached image URL of `entries` belongs to, from one PostBlock fetch and one Post fetch.
    static func pictures(for entries: [OfflineImageItem], store: LocalStore) -> [String: ImageViewerItem] {
        let postIDs = Array(Set(entries.compactMap(\.postID)))
        guard !postIDs.isEmpty else { return [:] }
        let disabled = store.disabledAccountIDs()
        var result: [String: ImageViewerItem] = [:]
        var owners: [String: (creatorID: String, accountID: String?)] = [:]
        func add(_ picture: ImageViewerItem, postID: String) {
            var picture = picture
            picture.postID = postID
            picture.creatorID = owners[postID]?.creatorID
            picture.accountID = owners[postID]?.accountID
            for url in picture.urls.values where result[url] == nil { result[url] = picture }
        }
        let posts = store.fetch(FetchDescriptor<Post>(predicate: #Predicate { postIDs.contains($0.postID) }))
        for post in posts {
            owners[post.postID] = (post.creatorID, OfflineLibraryService.mediaAccount(for: post, excluding: disabled))
        }
        let image = PostBlockKind.image.rawValue
        for block in store.fetch(FetchDescriptor<PostBlock>(predicate: #Predicate {
            postIDs.contains($0.postID) && $0.kindRaw == image
        })) {
            add(ImageViewerItem(block: block), postID: block.postID)
        }
        for post in posts {
            guard let cover = post.coverImageURL, !cover.isEmpty else { continue }
            add(ImageViewerItem(id: "cover.\(post.postID)", resizedURL: cover), postID: post.postID)
        }
        return result
    }
}

/// "保存中 42%" / cached size / "本文未取得" line for an offline post.
private struct OfflinePostStatusLine: View {
    let postID: String
    let hasBody: Bool
    let mediaBytes: Int64
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: 6) {
            if env.offline.activeSaves.contains(postID) {
                ProgressView(value: env.offline.saveProgress[postID] ?? 0)
                    .frame(maxWidth: 120)
                Text("保存中").font(.caption2).foregroundStyle(.secondary)
            } else {
                if !hasBody {
                    Label("本文未取得", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if mediaBytes > 0 {
                    Text("メディア\(Formatters.bytes(mediaBytes))").font(.caption2).foregroundStyle(.tertiary)
                } else if hasBody {
                    Text("テキストのみ").font(.caption2).foregroundStyle(.tertiary)
                }
                if let summary = env.offline.lastSummaries[postID], summary.mediaBlocked > 0 {
                    Text("通信モードにより\(summary.mediaBlocked)件未取得")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.leading, 72)
    }
}

// MARK: - Creators

private struct OfflineCreatorsSection: View {
    @Binding var isPickingCreator: Bool
    @Query(filter: #Predicate<Creator> { $0.offlineRecentCount > 0 }, sort: \Creator.name)
    private var creators: [Creator]

    var body: some View {
        Section {
            ForEach(creators) { creator in
                OfflineCreatorRuleRow(creator: creator)
            }
            Button("クリエイターを追加", systemImage: "plus.circle") { isPickingCreator = true }
                .accessibilityIdentifier("offlineAddCreator")
        } header: {
            Text("Creatorの最近N件")
        }
    }
}

// MARK: - Images

/// Value snapshot of one cached image (no live model captured by rows or tap closures).
struct OfflineImageItem: Hashable, Identifiable {
    var key: String
    var url: String
    var variant: MediaVariant
    var postID: String?
    var isPinned: Bool
    /// The picture of the post this file is a variant of (`OfflineLibraryIndex.pictures`): the viewer gets all of its
    /// URLs (「写真に保存」 then saves the original, not the 1200 px sample).
    var picture: ImageViewerItem? = nil
    /// Other cached files of the same tile (e.g. the original next to the display image): deleted together.
    var otherKeys: [String] = []
    var id: String { key }

    var viewerItem: ImageViewerItem {
        picture ?? ImageViewerItem(id: key,
                                   thumbnailURL: variant == .thumbnail ? url : nil,
                                   displayURL: variant == .display ? url : nil,
                                   originalURL: variant == .original ? url : nil)
    }

    /// Saved post images, one tile per picture: the display / original / thumbnail files of one image block (or cover)
    /// share a tile, other files are deduplicated by URL. Thumbnails get a tile only when nothing larger exists for the
    /// post. In the input order.
    static func gallery(_ entries: [OfflineImageItem], pictures: [String: ImageViewerItem] = [:]) -> [OfflineImageItem] {
        var tiles: [String: Int] = [:]
        var postsWithLarge = Set<String>()
        var result: [OfflineImageItem] = []
        func place(_ entry: OfflineImageItem, newTile: Bool) {
            var entry = entry
            if let picture = pictures[entry.url], picture.postID == entry.postID { entry.picture = picture }
            let tile = entry.picture.map { "picture:\($0.id)" } ?? "url:\(entry.url)"
            if let index = tiles[tile] {
                result[index].otherKeys.append(entry.key)
                if entry.isPinned { result[index].isPinned = true }
            } else if newTile {
                tiles[tile] = result.count
                result.append(entry)
            }
        }
        for entry in entries where entry.variant != .thumbnail {
            place(entry, newTile: true)
            if let postID = entry.postID { postsWithLarge.insert(postID) }
        }
        for entry in entries where entry.variant == .thumbnail {
            place(entry, newTile: entry.postID.map { !postsWithLarge.contains($0) } ?? false)
        }
        return result
    }

    /// Rows of `columns` items (each row is its own lazily created List row).
    static func rows(_ items: [OfflineImageItem], columns: Int) -> [[OfflineImageItem]] {
        guard columns > 0 else { return [] }
        return stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
    }
}

struct OfflineImagesSection: View {
    static let pageSize = 300
    static let columns = 3

    let limit: Int
    @Binding var viewer: OfflineViewerSelection?
    let loadMore: () -> Void

    @Environment(AppEnvironment.self) private var env
    // Sorted by creation (not last access) so viewing an image does not reshuffle the grid.
    @Query private var entries: [MediaCacheEntry]

    init(limit: Int, viewer: Binding<OfflineViewerSelection?>, loadMore: @escaping () -> Void) {
        self.limit = limit
        _viewer = viewer
        self.loadMore = loadMore
        var descriptor = FetchDescriptor<MediaCacheEntry>(predicate: #Predicate { $0.kindRaw == "image" && $0.postID != nil },
                                                          sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        _entries = Query(descriptor)
    }

    var body: some View {
        let files = entries.map {
            OfflineImageItem(key: $0.key, url: $0.url, variant: $0.variant, postID: $0.postID, isPinned: $0.isPinned)
        }
        let items = OfflineImageItem.gallery(files, pictures: OfflineLibraryIndex.pictures(for: files, store: env.store))
        let rows = OfflineImageItem.rows(items, columns: Self.columns)
        Section {
            if items.isEmpty {
                EmptyStateView(title: "キャッシュ済みの画像はありません", systemImage: "photo.on.rectangle")
            }
            ForEach(Array(rows.enumerated()), id: \.element.first?.key) { rowIndex, row in
                HStack(spacing: 4) {
                    ForEach(Array(row.enumerated()), id: \.element.key) { column, item in
                        tile(item, index: rowIndex * Self.columns + column, items: items)
                    }
                    ForEach(row.count..<Self.columns, id: \.self) { _ in
                        Color.clear.aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity)
                    }
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                .listRowSeparator(.hidden)
                .accessibilityIdentifier(rowIndex == 0 ? "offlineImagesGrid" : "offlineImagesRow")
            }
            if entries.count >= limit {
                Button("さらに表示", action: loadMore)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("offlineImagesLoadMore")
            }
        } header: {
            Text("画像\(items.count)枚")
        }
    }

    private func tile(_ item: OfflineImageItem, index: Int, items: [OfflineImageItem]) -> some View {
        Button {
            viewer = OfflineViewerSelection(items: items.map(\.viewerItem), index: index)
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    // The cached file under its real variant, decoded at thumbnail size.
                    RemoteImageView(thumbnailURL: item.variant == .thumbnail ? item.url : nil,
                                    displayURL: item.variant == .display ? item.url : nil,
                                    originalURL: item.variant == .original ? item.url : nil,
                                    maxVariant: .thumbnail, postID: item.postID, allowsManualLoad: false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    if item.isPinned {
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
        .frame(maxWidth: .infinity)
        .contextMenu {
            if let postID = item.postID {
                Button("投稿を開く", systemImage: "doc.text") {
                    env.router.open(.post(postID: postID), in: .library)
                }
            }
            Button("この画像を削除", systemImage: "trash", role: .destructive) {
                for key in [item.key] + item.otherKeys { env.media.removeEntry(key: key) }
            }
        }
    }
}

// MARK: - Files

/// Value snapshot of one cached attachment.
struct OfflineFileItem: Hashable, Identifiable {
    var key: String
    var url: String
    var kind: MediaKind
    var byteSize: Int
    var relativePath: String
    var postID: String?
    var id: String { key }
}

private struct OfflineFilesSection: View {
    @Environment(AppEnvironment.self) private var env
    @Query(filter: #Predicate<MediaCacheEntry> { $0.kindRaw != "image" }, sort: \MediaCacheEntry.createdAt, order: .reverse)
    private var entries: [MediaCacheEntry]

    var body: some View {
        let items = entries.map {
            OfflineFileItem(key: $0.key, url: $0.url, kind: $0.kind, byteSize: $0.byteSize, relativePath: $0.relativePath, postID: $0.postID)
        }
        let index = OfflineLibraryIndex.fileNames(for: items, store: env.store)
        Section {
            if items.isEmpty {
                EmptyStateView(title: "保存済みのファイルはありません", systemImage: "doc",
                               message: "Offline保存した投稿の添付ファイル・音声・動画がここに表示されます。")
            }
            ForEach(items) { item in
                let row = OfflineFileRow(item: item, displayName: Self.displayName(item, names: index.names),
                                         postTitle: item.postID.flatMap { index.titles[$0] },
                                         fileURL: env.media.fileCache.fileURL(relativePath: item.relativePath))
                Group {
                    if let postID = item.postID {
                        NavigationLink(value: AppRoute.post(postID: postID)) { row }
                    } else {
                        row
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("削除", systemImage: "trash", role: .destructive) {
                        env.media.removeEntry(key: item.key)
                    }
                }
            }
        } header: {
            Text("ファイル\(items.count)件")
        }
    }

    static func displayName(_ item: OfflineFileItem, names: [String: String]) -> String {
        if let name = names[item.url] { return name }
        if let demo = DemoMediaURL(item.url), case .file(let name, _) = demo { return name }
        return URL(string: item.url)?.lastPathComponent ?? "ファイル"
    }
}

struct OfflineViewerSelection: Identifiable {
    let id = UUID()
    var items: [ImageViewerItem]
    var index: Int
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
                Text("最近\(creator.offlineRecentCount)件を保存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if env.offline.activeCreatorSaves.contains(creator.creatorID) {
                ProgressView().controlSize(.small)
            }
            Menu {
                ForEach(Self.choices, id: \.self) { n in
                    Button("\(n)件") { run(count: n) }
                }
                Button("今すぐ保存", systemImage: "arrow.down.circle") { run(count: creator.offlineRecentCount) }
                Divider()
                Button("ルールを解除", systemImage: "xmark.circle", role: .destructive) {
                    // Releases the posts this rule saved (explicitly saved posts stay).
                    env.offline.setRecentRule(creatorID: creator.creatorID, count: 0)
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

/// Cached attachment row with share (plain values only).
private struct OfflineFileRow: View {
    let item: OfflineFileItem
    let displayName: String
    let postTitle: String?
    let fileURL: URL
    /// The file under its real name (the cache names files by hash), made when the row appears.
    @State private var sharedURL: URL?

    private var icon: String {
        switch item.kind {
        case .audio: return "music.note"
        case .video: return "film"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).font(.subheadline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Formatters.bytes(Int64(item.byteSize)))
                    if let postTitle {
                        Text(postTitle).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            ShareLink(item: sharedURL ?? fileURL) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("共有"))
        }
        .task(id: fileURL) {
            let source = fileURL, name = displayName
            sharedURL = await Task.detached(priority: .utility) { MediaFileCache.namedLink(to: source, fileName: name) }.value
        }
    }
}

/// Sheet to add a creator "recent N" rule.
private struct OfflineCreatorPicker: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Creator> { $0.isFollowed || $0.isSupported || $0.hasKnownPosts }, sort: \Creator.name)
    private var candidates: [Creator]
    @Query(FetchDescriptorFactory.enabledAccounts()) private var accounts: [Account]
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            List {
                // `hasKnownPosts` also comes from a disabled account's feeds: creators related only to disabled accounts
                // stay hidden, as in the creator list.
                let enabled = Set(accounts.map(\.id))
                let visible = candidates.filter {
                    $0.offlineRecentCount == 0 && (filter.isEmpty || $0.name.localizedStandardContains(filter))
                        && !CreatorFilterFacts.isOnlyRelatedToDisabledAccounts($0, enabledAccountIDs: enabled)
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
            .navigationTitle("最近\(env.settings.creatorRecentCount)件を保存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }
}

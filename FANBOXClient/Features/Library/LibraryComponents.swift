import SwiftData
import SwiftUI

/// User-metadata post lists shown in the Library tab (SPEC §33).
enum LibraryListKind: String, Hashable, CaseIterable, Identifiable {
    case favorites, unread, readLater, memo, recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: return "お気に入り"
        case .unread: return "未読"
        case .readLater: return "あとで読む"
        case .memo: return "メモ付き"
        case .recent: return "最近見た投稿"
        }
    }

    var systemImage: String {
        switch self {
        case .favorites: return "star"
        case .unread: return "circle.inset.filled"
        case .readLater: return "bookmark"
        case .memo: return "note.text"
        case .recent: return "clock"
        }
    }

    var emptyMessage: String {
        switch self {
        case .favorites: return "投稿のお気に入りに追加するとここに表示されます。"
        case .unread: return "未読の投稿はありません。"
        case .readLater: return "「あとで読む」に追加した投稿がここに表示されます。"
        case .memo: return "メモを書いた投稿がここに表示されます。"
        case .recent: return "投稿を開くとここに履歴が残ります。"
        }
    }

    @MainActor
    func descriptor(limit: Int?) -> FetchDescriptor<Post> {
        switch self {
        case .favorites:
            return SearchService.descriptor(#Predicate<Post> { $0.isFavorite }, limit: limit)
        case .unread:
            return SearchService.descriptor(#Predicate<Post> { !$0.isRead }, limit: limit)
        case .readLater:
            return SearchService.descriptor(#Predicate<Post> { $0.isReadLater }, limit: limit)
        case .memo:
            return SearchService.descriptor(#Predicate<Post> { $0.memo != "" }, limit: limit)
        case .recent:
            var d = FetchDescriptor<Post>(predicate: #Predicate { $0.lastViewedAt != nil },
                                          sortBy: [SortDescriptor(\.lastViewedAt, order: .reverse)])
            d.fetchLimit = limit
            return d
        }
    }
}

/// Compact post row used across Library lists.
struct LibraryPostRow: View {
    let post: Post
    /// Optional context line (e.g. search snippet).
    var snippet: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let cover = post.coverImageURL {
                    RemoteImageView(thumbnailURL: cover, maxVariant: .thumbnail, postID: post.postID, creatorID: post.creatorID,
                                    accountID: post.detailAccountID)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "doc.text").foregroundStyle(.secondary))
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !post.isRead {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                            .accessibilityLabel(Text("未読"))
                    }
                    Text(post.title.isEmpty ? "(無題)" : post.title)
                        .font(.subheadline.weight(post.isRead ? .regular : .semibold))
                        .lineLimit(2)
                }
                Text(post.creatorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if !post.memo.isEmpty {
                    Label(post.memo, systemImage: "note.text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(Formatters.shortDate(post.publishedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if post.isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                            .accessibilityLabel(Text("お気に入り"))
                    }
                    if post.isReadLater {
                        Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(.orange)
                            .accessibilityLabel(Text("あとで読む"))
                    }
                    switch post.offlineState {
                    case .saved: PillLabel(text: "Offline", systemImage: "arrow.down.circle.fill", tint: .green)
                    case .autoSaved: PillLabel(text: "自動保存", systemImage: "arrow.down.circle", tint: .teal)
                    case .none: EmptyView()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// Creator row (avatar + name + memo / profile snippet).
struct LibraryCreatorRow: View {
    let creator: Creator
    var snippet: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: creator.iconURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(creator.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if creator.isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
                if let snippet, !snippet.isEmpty {
                    Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if !creator.memo.isEmpty {
                    Label(creator.memo, systemImage: "note.text").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// "#tag 12" chip.
struct TagChip: View {
    let name: String
    var count: Int? = nil
    var isSelected: Bool = false
    var showsRemove: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text("#\(name)")
                .lineLimit(1)
            if let count {
                Text("\(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if showsRemove {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.13)))
        .contentShape(Capsule())
    }
}

/// Wrapping horizontal layout for chips.
struct LibraryFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, maxWidth)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width
            widest = max(widest, x)
            x += spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Media cache usage summary (SPEC §32).
struct StorageUsageSummaryView: View {
    let usage: CacheUsage
    let capacity: CacheCapacity
    var showsBreakdown: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("メディアキャッシュ")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Formatters.bytes(usage.totalBytes)) / \(capacity.displayName)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let limit = capacity.bytes, limit > 0 {
                ProgressView(value: min(Double(usage.totalBytes) / Double(limit), 1))
                    .tint(Double(usage.totalBytes) / Double(limit) > 0.9 ? .orange : .accentColor)
            }
            if showsBreakdown {
                HStack(spacing: 12) {
                    usageItem("保存済み", usage.pinnedBytes)
                    usageItem("オリジナル", usage.bytesByVariant[.original] ?? 0)
                    usageItem("表示用", usage.bytesByVariant[.display] ?? 0)
                    usageItem("サムネイル", usage.bytesByVariant[.thumbnail] ?? 0)
                }
                Text("\(usage.fileCount) ファイル・本文やメタデータはキャッシュ削除の対象外です")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("storageUsageSummary")
    }

    private func usageItem(_ title: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(Formatters.bytes(bytes)).font(.caption.monospacedDigit())
        }
    }
}

/// Full list for one `LibraryListKind`.
struct LibraryPostListView: View {
    let kind: LibraryListKind

    @Environment(AppEnvironment.self) private var env
    @Query private var posts: [Post]

    init(kind: LibraryListKind) {
        self.kind = kind
        _posts = Query(kind.descriptor(limit: 500))
    }

    var body: some View {
        List {
            if posts.isEmpty {
                EmptyStateView(title: kind.title, systemImage: kind.systemImage, message: kind.emptyMessage)
                    .listRowSeparator(.hidden)
            }
            ForEach(posts) { post in
                NavigationLink(value: AppRoute.post(postID: post.postID)) {
                    LibraryPostRow(post: post)
                }
                .swipeActions(edge: .trailing) { swipeAction(for: post) }
            }
        }
        .listStyle(.plain)
        .navigationTitle(kind.title)
        .accessibilityIdentifier("libraryList_\(kind.rawValue)")
    }

    @ViewBuilder
    private func swipeAction(for post: Post) -> some View {
        switch kind {
        case .favorites:
            Button("解除", systemImage: "star.slash") { post.isFavorite = false; env.store.save() }.tint(.gray)
        case .unread:
            Button("既読", systemImage: "checkmark") { post.isRead = true; post.readAt = .now; env.store.save() }.tint(.blue)
        case .readLater:
            Button("外す", systemImage: "bookmark.slash") { post.isReadLater = false; env.store.save() }.tint(.gray)
        case .memo:
            EmptyView()
        case .recent:
            Button("履歴から削除", systemImage: "clock.badge.xmark") { post.lastViewedAt = nil; env.store.save() }.tint(.gray)
        }
    }
}

/// Short excerpt around the first occurrence of `term` in `text`.
enum LibrarySnippet {
    static func make(_ text: String, term: String?, radius: Int = 36) -> String? {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let term, !term.isEmpty,
              let range = flat.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) else { return nil }
        let start = flat.index(range.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        var snippet = String(flat[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > flat.startIndex { snippet = "…" + snippet }
        if end < flat.endIndex { snippet += "…" }
        return snippet
    }
}

import SwiftData
import SwiftUI

/// Library tab (SPEC §31 / §33): local search, Favorite / Unread / Read Later / Tags / Memo, recently viewed,
/// and the Offline Library entry with storage usage. Everything renders from the local store.
struct LibraryRootView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var query = ""
    @State private var results: LibrarySearchResults?

    @Query(LibraryListKind.favorites.descriptor(limit: 5)) private var favorites: [Post]
    @Query(LibraryListKind.unread.descriptor(limit: 5)) private var unread: [Post]
    @Query(LibraryListKind.readLater.descriptor(limit: 5)) private var readLater: [Post]
    @Query(LibraryListKind.memo.descriptor(limit: 5)) private var memoPosts: [Post]
    @Query(LibraryListKind.recent.descriptor(limit: 8)) private var recent: [Post]
    @Query(filter: #Predicate<Creator> { $0.isFavorite }, sort: \Creator.name) private var favoriteCreators: [Creator]
    @Query(filter: #Predicate<Creator> { $0.memo != "" }, sort: \Creator.name) private var memoCreators: [Creator]
    @Query(filter: #Predicate<Post> { $0.offlineStateRaw != "none" }) private var offlinePosts: [Post]
    @Query private var postTags: [PostTag]
    @Query private var tags: [Tag]

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        List {
            if isSearching {
                LibrarySearchResultsSections(query: query, results: results)
            } else {
                offlineSection
                favoritesSection
                postSection(.unread, posts: unread)
                postSection(.readLater, posts: readLater)
                tagSection
                memoSection
                postSection(.recent, posts: recent)
                if favorites.isEmpty, unread.isEmpty, readLater.isEmpty, memoPosts.isEmpty, recent.isEmpty, tagSummaries.isEmpty,
                   favoriteCreators.isEmpty, memoCreators.isEmpty {
                    Section {
                        EmptyStateView(title: "ライブラリは空です", systemImage: "books.vertical",
                                       message: "投稿をお気に入り・あとで読むに追加したり、タグやメモを付けるとここに集まります。")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("ライブラリ")
        .searchable(text: $query, prompt: Text("投稿・クリエイター・コメント・下書き・#タグ"))
        .modifier(LibraryTagSuggestions(query: $query))
        .task(id: query) {
            guard isSearching else {
                results = nil
                return
            }
            if results != nil {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            results = env.librarySearch.search(query)
        }
        .task { env.media.refreshUsage() }
        .navigationDestination(for: LibraryListKind.self) { LibraryPostListView(kind: $0) }
        .accessibilityIdentifier("libraryRoot")
    }

    // MARK: - Sections

    private var offlineSection: some View {
        Section {
            NavigationLink(value: AppRoute.offlineLibrary) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Offline ライブラリ")
                        Text(offlinePosts.isEmpty ? "保存した投稿はありません" : "保存済みの投稿 \(offlinePosts.count) 件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .accessibilityIdentifier("libraryOfflineLink")
            StorageUsageSummaryView(usage: env.media.usage, capacity: env.settings.cacheCapacity, showsBreakdown: false)
        }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        if !favorites.isEmpty || !favoriteCreators.isEmpty {
            Section {
                if !favoriteCreators.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(favoriteCreators) { creator in
                                Button {
                                    env.router.open(.creator(creatorID: creator.creatorID), in: .library)
                                } label: {
                                    VStack(spacing: 4) {
                                        AvatarView(url: creator.iconURL, size: 48)
                                        Text(creator.name).font(.caption2).lineLimit(1).frame(width: 64)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("libraryFavoriteCreator_\(creator.creatorID)")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                ForEach(favorites) { post in
                    NavigationLink(value: AppRoute.post(postID: post.postID)) { LibraryPostRow(post: post) }
                }
                seeAllLink(.favorites)
            } header: {
                sectionHeader(.favorites)
            }
        }
    }

    @ViewBuilder
    private func postSection(_ kind: LibraryListKind, posts: [Post]) -> some View {
        if !posts.isEmpty {
            Section {
                ForEach(posts) { post in
                    NavigationLink(value: AppRoute.post(postID: post.postID)) { LibraryPostRow(post: post) }
                }
                seeAllLink(kind)
            } header: {
                sectionHeader(kind)
            }
        }
    }

    private var tagSummaries: [TagSummary] {
        SearchService.summaries(postTags: postTags, tags: tags)
    }

    @ViewBuilder
    private var tagSection: some View {
        let summaries = tagSummaries
        if !summaries.isEmpty {
            Section {
                LibraryFlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(summaries) { tag in
                        Button {
                            env.router.open(.tag(name: tag.name), in: .library)
                        } label: {
                            TagChip(name: tag.name, count: tag.count)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("libraryTagChip_\(tag.name)")
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Label("タグ", systemImage: "number")
            }
        }
    }

    @ViewBuilder
    private var memoSection: some View {
        if !memoPosts.isEmpty || !memoCreators.isEmpty {
            Section {
                ForEach(memoCreators.prefix(5)) { creator in
                    NavigationLink(value: AppRoute.creator(creatorID: creator.creatorID)) { LibraryCreatorRow(creator: creator) }
                }
                ForEach(memoPosts) { post in
                    NavigationLink(value: AppRoute.post(postID: post.postID)) { LibraryPostRow(post: post) }
                }
                seeAllLink(.memo)
            } header: {
                sectionHeader(.memo)
            }
        }
    }

    private func sectionHeader(_ kind: LibraryListKind) -> some View {
        Label(kind.title, systemImage: kind.systemImage)
            .accessibilityIdentifier("librarySection_\(kind.rawValue)")
    }

    private func seeAllLink(_ kind: LibraryListKind) -> some View {
        NavigationLink(value: kind) {
            HStack {
                Text("すべて表示")
                Spacer()
                Text("\(count(kind))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.subheadline)
        }
        .accessibilityIdentifier("librarySeeAll_\(kind.rawValue)")
    }

    private func count(_ kind: LibraryListKind) -> Int {
        (try? env.store.context.fetchCount(kind.descriptor(limit: nil))) ?? 0
    }
}

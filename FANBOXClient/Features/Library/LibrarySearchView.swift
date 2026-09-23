import SwiftData
import SwiftUI

/// Full local search screen (SPEC §33). Results are grouped: クリエイター / 投稿 / コメント / 下書き.
/// `#tag` narrows posts by local tag. Everything runs against the local store — works fully offline.
struct LibrarySearchView: View {
    let initialQuery: String

    @Environment(AppEnvironment.self) private var env
    @State private var query: String
    @State private var results: LibrarySearchResults?

    init(initialQuery: String) {
        self.initialQuery = initialQuery
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        List {
            LibrarySearchResultsSections(query: query, results: results)
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("librarySearchResults")
        .navigationTitle("検索")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("投稿・クリエイター・コメント・下書き・#タグ"))
        .modifier(LibraryTagSuggestions(query: $query))
        .task(id: query) {
            if results != nil {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            results = env.librarySearch.search(query)
        }
    }
}

/// Grouped search results as List sections. Tapping navigates via `AppRoute`.
struct LibrarySearchResultsSections: View {
    let query: String
    let results: LibrarySearchResults?

    private var firstTerm: String? { results?.query.terms.first }

    var body: some View {
        if let results {
            if results.query.isEmpty {
                Section {
                    Text("キーワードまたは #タグ で、端末内の投稿・クリエイター・コメント・下書きを検索します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("librarySearchEmpty")
            } else {
                if !results.query.tags.isEmpty {
                    Section {
                        HStack(spacing: 6) {
                            ForEach(results.query.tags, id: \.self) { TagChip(name: $0, isSelected: true) }
                        }
                    } footer: {
                        Text("タグで絞り込み中（タグはこの端末だけのメタデータです）")
                    }
                }
                if !results.creators.isEmpty {
                    Section("クリエイター (\(results.creators.count))") {
                        ForEach(results.creators) { creator in
                            NavigationLink(value: AppRoute.creator(creatorID: creator.creatorID)) {
                                LibraryCreatorRow(creator: creator,
                                                  snippet: creator.name.localizedStandardContains(firstTerm ?? "") ? nil
                                                      : LibrarySnippet.make(creator.memo + " " + creator.profileText, term: firstTerm))
                            }
                        }
                    }
                }
                if !results.posts.isEmpty {
                    Section("投稿 (\(results.posts.count))") {
                        ForEach(results.posts) { post in
                            NavigationLink(value: AppRoute.post(postID: post.postID)) {
                                LibraryPostRow(post: post, snippet: postSnippet(post))
                            }
                        }
                    }
                }
                if !results.comments.isEmpty {
                    Section("コメント (\(results.comments.count))") {
                        ForEach(results.comments) { comment in
                            NavigationLink(value: AppRoute.comments(postID: comment.postID, focusCommentID: comment.commentID)) {
                                LibraryCommentRow(comment: comment, snippet: LibrarySnippet.make(comment.body, term: firstTerm))
                            }
                        }
                    }
                }
                if !results.drafts.isEmpty {
                    Section("下書き (\(results.drafts.count))") {
                        ForEach(results.drafts) { draft in
                            NavigationLink(value: AppRoute.draft(draftID: draft.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(draft.title.isEmpty ? "(無題の下書き)" : draft.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text("更新: \(Formatters.shortDate(draft.updatedAt))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func postSnippet(_ post: Post) -> String? {
        guard let term = firstTerm, !post.title.localizedStandardContains(term) else { return nil }
        return LibrarySnippet.make(post.bodyText, term: term)
            ?? LibrarySnippet.make(post.excerpt, term: term)
            ?? LibrarySnippet.make(post.memo, term: term)
    }
}

struct LibraryCommentRow: View {
    let comment: Comment
    var snippet: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: comment.authorIconURL, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(comment.authorName).font(.caption.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(Formatters.relative(comment.createdAt)).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(snippet ?? comment.body)
                    .font(.subheadline)
                    .lineLimit(3)
            }
        }
    }
}

/// Suggests existing local tags while typing "#…".
struct LibraryTagSuggestions: ViewModifier {
    @Binding var query: String
    @Query private var postTags: [PostTag]
    @Query private var tags: [Tag]

    func body(content: Content) -> some View {
        content.searchSuggestions {
            if let partial = currentTagPrefix {
                let summaries = SearchService.summaries(postTags: postTags, tags: tags)
                    .filter { partial.isEmpty || $0.name.hasPrefix(partial) }
                    .prefix(8)
                ForEach(Array(summaries)) { tag in
                    Label("#\(tag.name)  (\(tag.count))", systemImage: "number")
                        .searchCompletion(completion(for: tag.name))
                }
            }
        }
    }

    /// Normalized text after the last "#", when the last token is a tag being typed.
    private var currentTagPrefix: String? {
        guard let last = query.split(whereSeparator: { $0.isWhitespace }).last.map(String.init),
              !query.hasSuffix(" "), last.hasPrefix("#") || last.hasPrefix("＃") else { return nil }
        return Tag.normalize(last.replacingOccurrences(of: "＃", with: "#"))
    }

    private func completion(for name: String) -> String {
        var tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if !tokens.isEmpty { tokens.removeLast() }
        tokens.append("#\(name)")
        return tokens.joined(separator: " ") + " "
    }
}

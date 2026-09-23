import SwiftData
import SwiftUI

/// Posts carrying one local tag (SPEC §33), with tag rename / delete.
struct TaggedPostsView: View {
    let tagName: String

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query private var postTags: [PostTag]
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var isConfirmingDelete = false

    private let normalized: String

    init(tagName: String) {
        self.tagName = tagName
        let name = Tag.normalize(tagName)
        normalized = name
        _postTags = Query(filter: #Predicate<PostTag> { $0.tagName == name })
    }

    private var posts: [Post] {
        let ids = postTags.map(\.postID)
        guard !ids.isEmpty else { return [] }
        let published = ReaderPostQueries.publishedStatus
        return env.store.fetch(FetchDescriptor<Post>(predicate: #Predicate {
            ids.contains($0.postID) && ($0.remoteStatusRaw == nil || $0.remoteStatusRaw == published)
        }, sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]))
    }

    var body: some View {
        let posts = self.posts
        List {
            if posts.isEmpty {
                EmptyStateView(title: "#\(normalized)", systemImage: "number",
                               message: "このタグが付いた投稿はありません。投稿詳細の「タグとメモ」から付けられます。")
                    .listRowSeparator(.hidden)
            }
            ForEach(posts) { post in
                NavigationLink(value: AppRoute.post(postID: post.postID)) {
                    LibraryPostRow(post: post)
                }
                .swipeActions(edge: .trailing) {
                    Button("タグを外す", systemImage: "tag.slash") {
                        env.librarySearch.removeTag(normalized, fromPostID: post.postID)
                    }
                    .tint(.orange)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("#\(normalized)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("名前を変更", systemImage: "pencil") {
                        newName = normalized
                        isRenaming = true
                    }
                    Button("タグを削除", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(Text("タグの操作"))
                .accessibilityIdentifier("taggedPostsMenu")
            }
        }
        .alert("タグ名を変更", isPresented: $isRenaming) {
            TextField("新しいタグ名", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("変更") {
                let target = Tag.normalize(newName)
                guard !target.isEmpty, target != normalized else { return }
                env.librarySearch.renameTag(normalized, to: target)
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("同じ名前のタグが既にある場合は統合されます。")
        }
        .confirmationDialog("タグ「#\(normalized)」を削除しますか？", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                env.librarySearch.deleteTag(normalized)
                dismiss()
            }
        } message: {
            Text("投稿からこのタグが外れます。投稿自体は削除されません。")
        }
        .accessibilityIdentifier("taggedPosts")
    }
}

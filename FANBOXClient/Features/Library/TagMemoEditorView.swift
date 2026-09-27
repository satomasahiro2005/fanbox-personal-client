import SwiftData
import SwiftUI

/// Reusable sheet for editing a post's local tags + memo (+ favorite / read later). Present with `.sheet`:
///
///     .sheet(isPresented: $showsEditor) { TagMemoEditorView(postID: post.postID) }
///
/// All values are local user metadata and are never sent to FANBOX (SPEC §33).
struct TagMemoEditorView: View {
    let postID: String

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query private var allTags: [Tag]
    @Query private var allPostTags: [PostTag]

    @State private var tags: [String] = []
    @State private var memo = ""
    @State private var isFavorite = false
    @State private var isReadLater = false
    @State private var newTag = ""
    @State private var didLoad = false
    @FocusState private var tagFieldFocused: Bool

    init(postID: String) {
        self.postID = postID
    }

    private var post: Post? { env.store.post(id: postID) }

    private var suggestions: [TagSummary] {
        let typed = Tag.normalize(newTag)
        return SearchService.summaries(postTags: allPostTags, tags: allTags)
            .filter { !tags.contains($0.name) && (typed.isEmpty || $0.name.hasPrefix(typed)) }
            .prefix(12)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let post {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(post.title.isEmpty ? "(無題)" : post.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(post.creatorName).font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        if !tags.isEmpty {
                            LibraryFlowLayout {
                                ForEach(tags, id: \.self) { tag in
                                    Button {
                                        tags.removeAll { $0 == tag }
                                    } label: {
                                        TagChip(name: tag, isSelected: true, showsRemove: true)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.primary)
                                    .accessibilityLabel(Text("#\(tag)を外す"))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        HStack {
                            TextField("タグを追加（例: music）", text: $newTag)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .focused($tagFieldFocused)
                                .onSubmit(addTypedTags)
                                .accessibilityIdentifier("tagMemoEditorTagField")
                            Button("追加", action: addTypedTags)
                                .disabled(Tag.normalize(newTag).isEmpty)
                                .accessibilityIdentifier("tagMemoEditorAddTag")
                        }
                        if !suggestions.isEmpty {
                            LibraryFlowLayout {
                                ForEach(suggestions) { tag in
                                    Button {
                                        tags.append(tag.name)
                                        newTag = ""
                                    } label: {
                                        TagChip(name: tag.name, count: tag.count)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.primary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("タグ")
                    }

                    Section("メモ") {
                        TextEditor(text: $memo)
                            .frame(minHeight: 120)
                            .accessibilityIdentifier("tagMemoEditorMemo")
                    }

                    Section {
                        Toggle("お気に入り", systemImage: "star", isOn: $isFavorite)
                        Toggle("あとで読む", systemImage: "bookmark", isOn: $isReadLater)
                    }
                } else {
                    Text("投稿が見つかりません")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("タグとメモ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(post == nil)
                        .accessibilityIdentifier("tagMemoEditorSave")
                }
            }
            .onAppear(perform: loadOnce)
        }
        .accessibilityIdentifier("tagMemoEditor")
    }

    private func loadOnce() {
        guard !didLoad, let post else { return }
        didLoad = true
        tags = env.librarySearch.tags(forPostID: postID)
        memo = post.memo
        isFavorite = post.isFavorite
        isReadLater = post.isReadLater
    }

    private func addTypedTags() {
        let parts = newTag.split(whereSeparator: { $0 == "," || $0 == "、" || $0.isWhitespace }).map(String.init)
        for part in parts {
            let name = Tag.normalize(part.replacingOccurrences(of: "＃", with: "#"))
            if !name.isEmpty, !tags.contains(name) { tags.append(name) }
        }
        newTag = ""
    }

    private func save() {
        addTypedTags()
        guard let post else { return }
        let search = env.librarySearch
        search.setTags(tags, forPostID: postID)
        post.memo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        post.isFavorite = isFavorite
        post.isReadLater = isReadLater
        env.store.save()
        dismiss()
    }
}

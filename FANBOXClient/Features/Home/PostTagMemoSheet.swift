import SwiftUI
import SwiftData

/// Minimal local tag / memo editor for one post (SPEC §33). Local metadata only — never sent to FANBOX.
/// (Used by Post detail; the Library module may provide a richer shared editor.)
struct PostTagMemoSheet: View {
    let postID: String

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query private var postTags: [PostTag]
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var newTag = ""
    @State private var memo = ""
    @State private var loadedMemo = false

    init(postID: String) {
        self.postID = postID
        _postTags = Query(filter: #Predicate<PostTag> { $0.postID == postID }, sort: \PostTag.tagName)
    }

    private var assigned: Set<String> { Set(postTags.map(\.tagName)) }
    private var suggestions: [String] { allTags.map(\.name).filter { !assigned.contains($0) } }

    var body: some View {
        NavigationStack {
            Form {
                Section("タグ") {
                    HStack {
                        TextField("#タグを追加", text: $newTag)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addTag)
                            .accessibilityIdentifier("postTagField")
                        Button("追加", action: addTag)
                            .disabled(Tag.normalize(newTag).isEmpty)
                            .accessibilityIdentifier("postTagAddButton")
                    }
                    ForEach(postTags) { tag in
                        Label("#\(tag.tagName)", systemImage: "tag")
                    }
                    .onDelete { offsets in
                        for index in offsets { env.store.context.delete(postTags[index]) }
                        env.store.save()
                    }
                }
                if !suggestions.isEmpty {
                    Section("既存のタグ") {
                        HomeFlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(suggestions, id: \.self) { name in
                                Button("#\(name)") { assign(name) }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                            }
                        }
                    }
                }
                Section("メモ") {
                    TextEditor(text: $memo)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("postMemoEditor")
                }
                Section {
                    Text("タグとメモはこの端末だけに保存され、FANBOX には送信されません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("タグ・メモ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        saveMemo()
                        dismiss()
                    }
                    .accessibilityIdentifier("postTagMemoDone")
                }
            }
            .onAppear {
                guard !loadedMemo else { return }
                memo = env.store.post(id: postID)?.memo ?? ""
                loadedMemo = true
            }
        }
    }

    private func addTag() {
        let name = Tag.normalize(newTag)
        guard !name.isEmpty else { return }
        assign(name)
        newTag = ""
    }

    private func assign(_ rawName: String) {
        let name = Tag.normalize(rawName)
        guard !name.isEmpty, !assigned.contains(name) else { return }
        let context = env.store.context
        if env.store.first(#Predicate<Tag> { $0.name == name }) == nil {
            context.insert(Tag(name: name))
        }
        context.insert(PostTag(postID: postID, tagName: name))
        env.store.save()
    }

    private func saveMemo() {
        guard let post = env.store.post(id: postID) else { return }
        let trimmed = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        if post.memo != trimmed {
            post.memo = trimmed
            env.store.save()
        }
    }
}

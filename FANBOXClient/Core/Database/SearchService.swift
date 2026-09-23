import Foundation
import SwiftData

/// Parsed library search query: `#tag` tokens filter by local tags (AND), other tokens are text terms (AND).
struct LibrarySearchQuery: Equatable, Sendable {
    var terms: [String]
    var tags: [String]

    init(_ raw: String) {
        var terms: [String] = []
        var tags: [String] = []
        for token in raw.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            if token.hasPrefix("#") || token.hasPrefix("＃") {
                let name = Tag.normalize(token.replacingOccurrences(of: "＃", with: "#"))
                if !name.isEmpty, !tags.contains(name) { tags.append(name) }
            } else if !token.isEmpty {
                terms.append(token)
            }
        }
        self.terms = terms
        self.tags = tags
    }

    var isEmpty: Bool { terms.isEmpty && tags.isEmpty }
}

struct LibrarySearchResults {
    var query: LibrarySearchQuery
    var creators: [Creator] = []
    var posts: [Post] = []
    var comments: [Comment] = []
    var drafts: [Draft] = []

    var isEmpty: Bool { creators.isEmpty && posts.isEmpty && comments.isEmpty && drafts.isEmpty }
    var totalCount: Int { creators.count + posts.count + comments.count + drafts.count }
}

struct TagSummary: Identifiable, Hashable, Sendable {
    var name: String
    var count: Int
    var id: String { name }
}

/// Fully local search over the SwiftData store (SPEC §33) + user metadata helpers (Favorite / Unread / Read Later /
/// Tags / Memo). Nothing here is ever sent to FANBOX.
@MainActor
final class SearchService {
    let store: LocalStore
    /// Maximum results per group.
    var limit: Int

    init(store: LocalStore, limit: Int = 100) {
        self.store = store
        self.limit = limit
    }

    // MARK: - Search

    func search(_ raw: String) -> LibrarySearchResults {
        let query = LibrarySearchQuery(raw)
        var results = LibrarySearchResults(query: query)
        guard !query.isEmpty else { return results }

        results.posts = searchPosts(query)
        // Tag filters only apply to posts (tags are post metadata).
        if query.tags.isEmpty {
            results.creators = searchCreators(query.terms)
            results.comments = searchComments(query.terms)
            results.drafts = searchDrafts(query.terms)
        }
        return results
    }

    func searchPosts(_ query: LibrarySearchQuery) -> [Post] {
        let candidates: [Post]
        if !query.tags.isEmpty {
            var ids: Set<String>?
            for tag in query.tags {
                let tagged = Set(postIDs(taggedWith: tag))
                ids = ids.map { $0.intersection(tagged) } ?? tagged
            }
            let list = Array(ids ?? [])
            guard !list.isEmpty else { return [] }
            candidates = store.fetch(FetchDescriptor<Post>(predicate: #Predicate { list.contains($0.postID) }))
        } else if let first = query.terms.first {
            let byText = store.fetch(FetchDescriptor<Post>(predicate: #Predicate {
                $0.title.localizedStandardContains(first) || $0.excerpt.localizedStandardContains(first)
                    || $0.bodyText.localizedStandardContains(first)
            }))
            let byMeta = store.fetch(FetchDescriptor<Post>(predicate: #Predicate {
                $0.memo.localizedStandardContains(first) || $0.creatorName.localizedStandardContains(first)
            }))
            // FANBOX tags are an array property: matched in memory.
            let byFanboxTag = store.fetch(FetchDescriptor<Post>()).filter { post in
                post.fanboxTags.contains { $0.localizedStandardContains(first) }
            }
            var seen = Set<String>()
            candidates = (byText + byMeta + byFanboxTag).filter { seen.insert($0.postID).inserted }
        } else {
            return []
        }
        let terms = query.tags.isEmpty ? Array(query.terms.dropFirst()) : query.terms
        let filtered = candidates.filter { post in terms.allSatisfy { Self.post(post, matches: $0) } }
        return Array(filtered.sorted { $0.publishedAt > $1.publishedAt }.prefix(limit))
    }

    func searchCreators(_ terms: [String]) -> [Creator] {
        guard let first = terms.first else { return [] }
        let candidates = store.fetch(FetchDescriptor<Creator>(predicate: #Predicate {
            $0.name.localizedStandardContains(first) || $0.profileText.localizedStandardContains(first)
                || $0.memo.localizedStandardContains(first)
        }, sortBy: [SortDescriptor(\.name)]))
        let rest = terms.dropFirst()
        return Array(candidates.filter { creator in
            rest.allSatisfy {
                creator.name.localizedStandardContains($0) || creator.profileText.localizedStandardContains($0)
                    || creator.memo.localizedStandardContains($0)
            }
        }.prefix(limit))
    }

    func searchComments(_ terms: [String]) -> [Comment] {
        guard let first = terms.first else { return [] }
        let candidates = store.fetch(FetchDescriptor<Comment>(predicate: #Predicate {
            !$0.isRemoved && $0.body.localizedStandardContains(first)
        }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        let rest = terms.dropFirst()
        return Array(candidates.filter { comment in rest.allSatisfy { comment.body.localizedStandardContains($0) } }.prefix(limit))
    }

    func searchDrafts(_ terms: [String]) -> [Draft] {
        guard let first = terms.first else { return [] }
        let byTitle = store.fetch(FetchDescriptor<Draft>(predicate: #Predicate { $0.title.localizedStandardContains(first) }))
        let blockDraftIDs = Array(Set(store.fetch(FetchDescriptor<DraftBlock>(predicate: #Predicate {
            $0.text.localizedStandardContains(first)
        })).map(\.draftID)))
        let byBlock = blockDraftIDs.isEmpty ? [] : store.fetch(FetchDescriptor<Draft>(predicate: #Predicate {
            blockDraftIDs.contains($0.id)
        }))
        var seen = Set<String>()
        let candidates = (byTitle + byBlock).filter { seen.insert($0.id).inserted }
        let rest = terms.dropFirst()
        return Array(candidates.filter { draft in
            rest.allSatisfy { term in
                draft.title.localizedStandardContains(term) || draft.blocks.contains { $0.text.localizedStandardContains(term) }
            }
        }.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    static func post(_ post: Post, matches term: String) -> Bool {
        post.title.localizedStandardContains(term) || post.excerpt.localizedStandardContains(term)
            || post.bodyText.localizedStandardContains(term) || post.memo.localizedStandardContains(term)
            || post.creatorName.localizedStandardContains(term) || post.fanboxTags.contains { $0.localizedStandardContains(term) }
    }

    // MARK: - User metadata lists

    func favoritePosts(limit: Int? = nil) -> [Post] {
        store.fetch(Self.descriptor(#Predicate<Post> { $0.isFavorite }, limit: limit))
    }

    func favoriteCreators() -> [Creator] {
        store.fetch(FetchDescriptor<Creator>(predicate: #Predicate { $0.isFavorite }, sortBy: [SortDescriptor(\.name)]))
    }

    func unreadPosts(limit: Int? = nil) -> [Post] {
        store.fetch(Self.descriptor(#Predicate<Post> { !$0.isRead }, limit: limit))
    }

    func readLaterPosts(limit: Int? = nil) -> [Post] {
        store.fetch(Self.descriptor(#Predicate<Post> { $0.isReadLater }, limit: limit))
    }

    func memoPosts(limit: Int? = nil) -> [Post] {
        store.fetch(Self.descriptor(#Predicate<Post> { $0.memo != "" }, limit: limit))
    }

    func memoCreators() -> [Creator] {
        store.fetch(FetchDescriptor<Creator>(predicate: #Predicate { $0.memo != "" }, sortBy: [SortDescriptor(\.name)]))
    }

    func recentlyViewedPosts(limit: Int? = 50) -> [Post] {
        var d = FetchDescriptor<Post>(predicate: #Predicate { $0.lastViewedAt != nil },
                                      sortBy: [SortDescriptor(\.lastViewedAt, order: .reverse)])
        d.fetchLimit = limit
        return store.fetch(d)
    }

    func offlinePosts() -> [Post] {
        let none = OfflineState.none.rawValue
        return store.fetch(Self.descriptor(#Predicate<Post> { $0.offlineStateRaw != none }, limit: nil))
    }

    static func descriptor(_ predicate: Predicate<Post>, limit: Int?) -> FetchDescriptor<Post> {
        var d = FetchDescriptor<Post>(predicate: predicate, sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        d.fetchLimit = limit
        return d
    }

    // MARK: - Tags

    func postIDs(taggedWith name: String) -> [String] {
        let tag = Tag.normalize(name)
        return store.fetch(FetchDescriptor<PostTag>(predicate: #Predicate { $0.tagName == tag })).map(\.postID)
    }

    func posts(taggedWith name: String) -> [Post] {
        let ids = postIDs(taggedWith: name)
        guard !ids.isEmpty else { return [] }
        return store.fetch(FetchDescriptor<Post>(predicate: #Predicate { ids.contains($0.postID) },
                                                 sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]))
    }

    func tags(forPostID postID: String) -> [String] {
        store.fetch(FetchDescriptor<PostTag>(predicate: #Predicate { $0.postID == postID })).map(\.tagName).sorted()
    }

    /// All tags with usage counts (most used first). Tags without posts are included with count 0.
    func allTags() -> [TagSummary] {
        Self.summaries(postTags: store.fetch(FetchDescriptor<PostTag>()), tags: store.fetch(FetchDescriptor<Tag>()))
    }

    static func summaries(postTags: [PostTag], tags: [Tag]) -> [TagSummary] {
        var counts: [String: Int] = [:]
        for tag in tags { counts[tag.name] = counts[tag.name] ?? 0 }
        for postTag in postTags { counts[postTag.tagName, default: 0] += 1 }
        return counts.map { TagSummary(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    @discardableResult
    func createTag(_ raw: String) -> String? {
        let name = Tag.normalize(raw)
        guard !name.isEmpty else { return nil }
        if store.first(#Predicate<Tag> { $0.name == name }) == nil {
            store.context.insert(Tag(name: name))
        }
        return name
    }

    func addTag(_ raw: String, toPostID postID: String) {
        guard let name = createTag(raw) else { return }
        let key = "\(postID)|\(name)"
        if store.first(#Predicate<PostTag> { $0.key == key }) == nil {
            store.context.insert(PostTag(postID: postID, tagName: name))
        }
        store.save()
    }

    func removeTag(_ raw: String, fromPostID postID: String) {
        let key = "\(postID)|\(Tag.normalize(raw))"
        for postTag in store.fetch(FetchDescriptor<PostTag>(predicate: #Predicate { $0.key == key })) {
            store.context.delete(postTag)
        }
        store.save()
    }

    /// Replaces the post's tags with `names` (normalized, deduplicated).
    func setTags(_ names: [String], forPostID postID: String) {
        var wanted: [String] = []
        for raw in names {
            let name = Tag.normalize(raw)
            if !name.isEmpty, !wanted.contains(name) { wanted.append(name) }
        }
        let existing = store.fetch(FetchDescriptor<PostTag>(predicate: #Predicate { $0.postID == postID }))
        for postTag in existing where !wanted.contains(postTag.tagName) {
            store.context.delete(postTag)
        }
        let have = Set(existing.map(\.tagName))
        for name in wanted {
            createTag(name)
            if !have.contains(name) { store.context.insert(PostTag(postID: postID, tagName: name)) }
        }
        store.save()
    }

    /// Renames a tag everywhere. If the new name already exists, the tags are merged.
    func renameTag(_ oldRaw: String, to newRaw: String) {
        let old = Tag.normalize(oldRaw)
        let new = Tag.normalize(newRaw)
        guard !old.isEmpty, !new.isEmpty, old != new else { return }
        let color = store.first(#Predicate<Tag> { $0.name == old })?.colorHex
        for postTag in store.fetch(FetchDescriptor<PostTag>(predicate: #Predicate { $0.tagName == old })) {
            let postID = postTag.postID
            let newKey = "\(postID)|\(new)"
            store.context.delete(postTag)
            if store.first(#Predicate<PostTag> { $0.key == newKey }) == nil {
                store.context.insert(PostTag(postID: postID, tagName: new, createdAt: postTag.createdAt))
            }
        }
        for tag in store.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.name == old })) {
            store.context.delete(tag)
        }
        if store.first(#Predicate<Tag> { $0.name == new }) == nil {
            store.context.insert(Tag(name: new, colorHex: color))
        }
        store.save()
    }

    func deleteTag(_ raw: String) {
        let name = Tag.normalize(raw)
        for postTag in store.fetch(FetchDescriptor<PostTag>(predicate: #Predicate { $0.tagName == name })) {
            store.context.delete(postTag)
        }
        for tag in store.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.name == name })) {
            store.context.delete(tag)
        }
        store.save()
    }

    // MARK: - Memo / flags

    func setMemo(_ memo: String, forPostID postID: String) {
        guard let post = store.post(id: postID) else { return }
        post.memo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        store.save()
    }

    func setMemo(_ memo: String, forCreatorID creatorID: String) {
        guard let creator = store.creator(id: creatorID) else { return }
        creator.memo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        store.save()
    }
}

extension AppEnvironment {
    /// Local search / library metadata service (stateless; cheap to create).
    var librarySearch: SearchService { SearchService(store: store) }
}

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

/// Fetch descriptors for reader-facing post lists (Home, Library, search, creator pages, offline rules).
/// They hide my own FANBOX drafts / scheduled posts: `Post.isVisibleToReaders` expressed on the stored
/// `remoteStatusRaw` so SQLite does the filtering.
enum ReaderPostQueries {
    static let publishedStatus: String? = RemotePostStatus.published.rawValue

    /// `Post.isVisibleToReaders` as a predicate.
    static var visible: Predicate<Post> {
        let published = publishedStatus
        return #Predicate<Post> { $0.remoteStatusRaw == nil || $0.remoteStatusRaw == published }
    }

    /// Reader-visible posts of one creator, newest first.
    static func byCreator(_ creatorID: String, limit: Int? = nil) -> FetchDescriptor<Post> {
        let published = publishedStatus
        var d = FetchDescriptor<Post>(predicate: #Predicate {
            $0.creatorID == creatorID && ($0.remoteStatusRaw == nil || $0.remoteStatusRaw == published)
        }, sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        d.fetchLimit = limit
        return d
    }
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
    /// Rows materialized per group at most (SQLite pre-filters on the most selective term; the rest is matched in memory).
    var candidateLimit: Int

    init(store: LocalStore, limit: Int = 100, candidateLimit: Int = 1000) {
        self.store = store
        self.limit = limit
        self.candidateLimit = candidateLimit
    }

    /// Searchable form of FANBOX tags (`Post.fanboxTagsText`): one tag per line. Empty tags ⇒ "" (indexed, nothing to find).
    nonisolated static func tagsSearchText(_ tags: [String]) -> String {
        tags.joined(separator: "\n")
    }

    /// Fills `Post.fanboxTagsText` for rows written before it existed (nil = not indexed). One-time work after an
    /// upgrade; afterwards the SQL check finds nothing.
    func indexFanboxTagsIfNeeded() {
        var descriptor = FetchDescriptor<Post>(predicate: #Predicate { $0.fanboxTagsText == nil })
        descriptor.fetchLimit = 500
        for _ in 0..<1000 {
            let batch = store.fetch(descriptor)
            guard !batch.isEmpty else { return }
            for post in batch { post.fanboxTagsText = Self.tagsSearchText(post.fanboxTags) }
            store.save()
        }
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
        let published = ReaderPostQueries.publishedStatus
        let candidates: [Post]
        let remaining: [String]
        if !query.tags.isEmpty {
            var ids: Set<String>?
            for tag in query.tags {
                let tagged = Set(postIDs(taggedWith: tag))
                ids = ids.map { $0.intersection(tagged) } ?? tagged
            }
            let list = Array(ids ?? [])
            guard !list.isEmpty else { return [] }
            candidates = store.fetch(FetchDescriptor<Post>(predicate: #Predicate {
                list.contains($0.postID) && ($0.remoteStatusRaw == nil || $0.remoteStatusRaw == published)
            }))
            remaining = query.terms
        } else if let term = Self.mostSelective(query.terms) {
            indexFanboxTagsIfNeeded()
            // One SQL query on the most selective term (every searchable field, FANBOX tags included), newest first and
            // bounded, so a keystroke never materializes the whole library.
            var descriptor = FetchDescriptor<Post>(predicate: #Predicate {
                ($0.title.localizedStandardContains(term) || $0.excerpt.localizedStandardContains(term)
                    || $0.bodyText.localizedStandardContains(term) || $0.memo.localizedStandardContains(term)
                    || $0.creatorName.localizedStandardContains(term)
                    || $0.fanboxTagsText?.localizedStandardContains(term) == true)
                    && ($0.remoteStatusRaw == nil || $0.remoteStatusRaw == published)
            }, sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
            descriptor.fetchLimit = candidateLimit
            candidates = store.fetch(descriptor)
            var rest = query.terms
            if let index = rest.firstIndex(of: term) { rest.remove(at: index) }
            remaining = rest
        } else {
            return []
        }
        let filtered = candidates.filter { post in remaining.allSatisfy { Self.post(post, matches: $0) } }
        return Array(filtered.sorted { $0.publishedAt > $1.publishedAt }.prefix(limit))
    }

    /// The longest term narrows the SQL pre-filter the most.
    static func mostSelective(_ terms: [String]) -> String? {
        terms.max { $0.count < $1.count }
    }

    func searchCreators(_ terms: [String]) -> [Creator] {
        guard let first = terms.first else { return [] }
        var descriptor = FetchDescriptor<Creator>(predicate: #Predicate {
            $0.name.localizedStandardContains(first) || $0.profileText.localizedStandardContains(first)
                || $0.memo.localizedStandardContains(first)
        }, sortBy: [SortDescriptor(\.name)])
        descriptor.fetchLimit = candidateLimit
        let candidates = store.fetch(descriptor)
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
        var descriptor = FetchDescriptor<Comment>(predicate: #Predicate {
            !$0.isRemoved && $0.body.localizedStandardContains(first)
        }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = candidateLimit
        let candidates = store.fetch(descriptor)
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
        store.fetch(LibraryListKind.favorites.descriptor(limit: limit))
    }

    func favoriteCreators() -> [Creator] {
        store.fetch(FetchDescriptor<Creator>(predicate: #Predicate { $0.isFavorite }, sortBy: [SortDescriptor(\.name)]))
    }

    func unreadPosts(limit: Int? = nil) -> [Post] {
        store.fetch(LibraryListKind.unread.descriptor(limit: limit))
    }

    func readLaterPosts(limit: Int? = nil) -> [Post] {
        store.fetch(LibraryListKind.readLater.descriptor(limit: limit))
    }

    func memoPosts(limit: Int? = nil) -> [Post] {
        store.fetch(LibraryListKind.memo.descriptor(limit: limit))
    }

    func memoCreators() -> [Creator] {
        store.fetch(FetchDescriptor<Creator>(predicate: #Predicate { $0.memo != "" }, sortBy: [SortDescriptor(\.name)]))
    }

    func recentlyViewedPosts(limit: Int? = 50) -> [Post] {
        store.fetch(LibraryListKind.recent.descriptor(limit: limit))
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
        let published = ReaderPostQueries.publishedStatus
        return store.fetch(FetchDescriptor<Post>(predicate: #Predicate {
            ids.contains($0.postID) && ($0.remoteStatusRaw == nil || $0.remoteStatusRaw == published)
        }, sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]))
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

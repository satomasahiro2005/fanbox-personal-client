import SwiftData
import XCTest
@testable import FANBOXClient

@MainActor
final class SearchServiceTests: XCTestCase {
    private var store: LocalStore!
    private var search: SearchService!

    override func setUp() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        store = LocalStore(container: container)
        search = SearchService(store: store)
        seed()
    }

    override func tearDown() async throws {
        search = nil
        store = nil
    }

    private func seed() {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let creator = Creator(creatorID: "c1", name: "ピアノ工房", profileText: "Weekly piano lessons")
        let other = Creator(creatorID: "c2", name: "Sketch Room")
        other.memo = "好きな背景絵師"
        store.context.insert(creator)
        store.context.insert(other)

        func post(_ id: String, _ title: String, hoursAgo: Double, creatorID: String = "c1", creatorName: String = "ピアノ工房") -> Post {
            let p = Post(postID: id, creatorID: creatorID, creatorName: creatorName, title: title,
                         publishedAt: base.addingTimeInterval(-hoursAgo * 3600))
            store.context.insert(p)
            return p
        }
        let p1 = post("p1", "Piano practice log", hoursAgo: 1)
        p1.isFavorite = true
        p1.isRead = true
        let p2 = post("p2", "日記", hoursAgo: 2, creatorID: "c2", creatorName: "Sketch Room")
        p2.bodyText = "今日はピアノの練習をしました。背景も描いた。"
        p2.isReadLater = true
        let p3 = post("p3", "Memo holder", hoursAgo: 3, creatorID: "c2", creatorName: "Sketch Room")
        p3.memo = "check this PIANO arrangement"
        p3.isRead = true
        let p4 = post("p4", "Tagged by FANBOX", hoursAgo: 4, creatorID: "c2", creatorName: "Sketch Room")
        p4.fanboxTags = ["Piano", "楽譜"]
        p4.isRead = true
        p4.lastViewedAt = base
        let p5 = post("p5", "Unrelated", hoursAgo: 5, creatorID: "c2", creatorName: "Sketch Room")
        p5.excerpt = "landscape sketches"
        p5.lastViewedAt = base.addingTimeInterval(60)

        let comment = Comment(commentID: "cm1", postID: "p5", fetchedByAccountID: "a", authorUserID: "u", authorName: "fan",
                              body: "Great piano cover!", createdAt: base)
        let deleted = Comment(commentID: "cm2", postID: "p5", fetchedByAccountID: "a", authorUserID: "u", authorName: "fan",
                              body: "piano (deleted)", createdAt: base)
        deleted.isRemoved = true
        store.context.insert(comment)
        store.context.insert(deleted)

        let d1 = Draft(accountID: "a", title: "New piano post")
        let d2 = Draft(accountID: "a", title: "Untitled")
        store.context.insert(d1)
        store.context.insert(d2)
        let block = DraftBlock(draftID: d2.id, order: 0, kind: .text, text: "chords for piano")
        store.context.insert(block)
        block.draft = d2
        store.save()
    }

    func testQueryParsing() {
        let q = LibrarySearchQuery("  #Music piano ＃Ref  score #music ")
        XCTAssertEqual(q.tags, ["music", "ref"])
        XCTAssertEqual(q.terms, ["piano", "score"])
        XCTAssertTrue(LibrarySearchQuery("   ").isEmpty)
    }

    func testTextSearchCoversAllSources() {
        let results = search.search("piano")
        XCTAssertEqual(Set(results.posts.map(\.postID)), ["p1", "p3", "p4"])
        XCTAssertEqual(results.posts.map(\.postID), ["p1", "p3", "p4"], "newest first")
        XCTAssertEqual(results.creators.map(\.creatorID), ["c1"])
        XCTAssertEqual(results.comments.map(\.commentID), ["cm1"], "deleted comments are excluded")
        XCTAssertEqual(results.drafts.count, 2, "draft title and draft block text")
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.totalCount, 7)
    }

    func testSearchIsCaseInsensitiveAndSupportsJapanese() {
        XCTAssertEqual(Set(search.search("PIANO").posts.map(\.postID)), ["p1", "p3", "p4"])
        let jp = search.search("ピアノ")
        XCTAssertEqual(jp.posts.map(\.postID).sorted(), ["p1", "p2"], "body text + creator name")
        XCTAssertEqual(jp.creators.map(\.creatorID), ["c1"])
        XCTAssertEqual(search.search("背景").creators.map(\.creatorID), ["c2"], "creator memo")
        XCTAssertEqual(search.search("楽譜").posts.map(\.postID), ["p4"], "FANBOX tag")
    }

    func testMultipleTermsAreANDed() {
        XCTAssertEqual(search.search("piano log").posts.map(\.postID), ["p1"])
        XCTAssertTrue(search.search("piano zzzz").posts.isEmpty)
    }

    func testTagQueriesAndManagement() {
        search.addTag("#Music", toPostID: "p1")
        search.addTag("music", toPostID: "p2")
        search.addTag("ref", toPostID: "p2")
        search.addTag("music", toPostID: "p2") // duplicate is ignored

        XCTAssertEqual(search.search("#music").posts.map(\.postID), ["p1", "p2"])
        let tagOnly = search.search("#music")
        XCTAssertTrue(tagOnly.creators.isEmpty && tagOnly.comments.isEmpty && tagOnly.drafts.isEmpty)
        XCTAssertEqual(search.search("#music #ref").posts.map(\.postID), ["p2"])
        XCTAssertEqual(search.search("#music practice").posts.map(\.postID), ["p1"])
        XCTAssertTrue(search.search("#nothing").posts.isEmpty)

        XCTAssertEqual(search.allTags(), [TagSummary(name: "music", count: 2), TagSummary(name: "ref", count: 1)])
        XCTAssertEqual(search.tags(forPostID: "p2"), ["music", "ref"])
        XCTAssertEqual(search.posts(taggedWith: "#MUSIC").map(\.postID), ["p1", "p2"])

        search.renameTag("music", to: "#Audio")
        XCTAssertTrue(search.search("#music").posts.isEmpty)
        XCTAssertEqual(search.search("#audio").posts.map(\.postID), ["p1", "p2"])

        // Renaming onto an existing tag merges without duplicates.
        search.renameTag("ref", to: "audio")
        XCTAssertEqual(search.tags(forPostID: "p2"), ["audio"])
        XCTAssertEqual(search.allTags(), [TagSummary(name: "audio", count: 2)])

        search.removeTag("audio", fromPostID: "p1")
        XCTAssertEqual(search.postIDs(taggedWith: "audio"), ["p2"])

        search.deleteTag("audio")
        XCTAssertTrue(search.allTags().isEmpty)
        XCTAssertTrue(store.fetch(FetchDescriptor<PostTag>()).isEmpty)
    }

    func testSetTagsNormalizesAndReplaces() {
        search.setTags(["A", "#b", "a", "  "], forPostID: "p5")
        XCTAssertEqual(search.tags(forPostID: "p5"), ["a", "b"])
        search.setTags(["b", "c"], forPostID: "p5")
        XCTAssertEqual(search.tags(forPostID: "p5"), ["b", "c"])
        search.createTag("unused")
        XCTAssertTrue(search.allTags().contains(TagSummary(name: "unused", count: 0)))
    }

    func testUserMetadataLists() {
        XCTAssertEqual(search.favoritePosts().map(\.postID), ["p1"])
        XCTAssertEqual(search.readLaterPosts().map(\.postID), ["p2"])
        XCTAssertEqual(search.memoPosts().map(\.postID), ["p3"])
        XCTAssertEqual(search.unreadPosts().map(\.postID), ["p2", "p5"])
        XCTAssertEqual(search.recentlyViewedPosts().map(\.postID), ["p5", "p4"])
        XCTAssertEqual(search.memoCreators().map(\.creatorID), ["c2"])

        search.setMemo("  new memo  ", forPostID: "p1")
        XCTAssertEqual(store.post(id: "p1")?.memo, "new memo")
        XCTAssertEqual(search.memoPosts().map(\.postID), ["p1", "p3"])
        XCTAssertEqual(search.search("new memo").posts.map(\.postID), ["p1"])
    }

    func testLibraryListDescriptorsMatchService() throws {
        let unread = store.fetch(LibraryListKind.unread.descriptor(limit: nil)).map(\.postID)
        XCTAssertEqual(unread, search.unreadPosts().map(\.postID))
        let limited = store.fetch(LibraryListKind.recent.descriptor(limit: 1)).map(\.postID)
        XCTAssertEqual(limited, ["p5"])
        XCTAssertEqual(try store.context.fetchCount(LibraryListKind.favorites.descriptor(limit: nil)), 1)
    }

    func testSnippet() {
        let text = String(repeating: "a", count: 100) + "ピアノ" + String(repeating: "b", count: 100)
        let snippet = try? XCTUnwrap(LibrarySnippet.make(text, term: "ピアノ", radius: 5))
        XCTAssertEqual(snippet, "…aaaaaピアノbbbbb…")
        XCTAssertNil(LibrarySnippet.make("abc", term: "zzz"))
    }
}

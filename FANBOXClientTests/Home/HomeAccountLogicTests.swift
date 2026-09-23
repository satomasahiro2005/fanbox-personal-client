import XCTest
import SwiftData
@testable import FANBOXClient

@MainActor
final class HomeAccountLogicTests: XCTestCase {
    func testEffectiveAccountPrefersOverrideThenBest() {
        let enabled = ["A", "B", "C"]
        XCTAssertEqual(PostAccountLogic.effectiveAccountID(override: "C", best: "A", enabledAccountIDs: enabled), "C")
        XCTAssertEqual(PostAccountLogic.effectiveAccountID(override: nil, best: "B", enabledAccountIDs: enabled), "B")
        // Override of a removed / disabled account falls back to automatic.
        XCTAssertEqual(PostAccountLogic.effectiveAccountID(override: "Z", best: "B", enabledAccountIDs: enabled), "B")
        XCTAssertEqual(PostAccountLogic.effectiveAccountID(override: nil, best: "Z", enabledAccountIDs: enabled), "A")
        XCTAssertNil(PostAccountLogic.effectiveAccountID(override: "A", best: "A", enabledAccountIDs: []))
    }

    func testNeedsBodyRefresh() {
        let old = Date(timeIntervalSince1970: 1000), new = Date(timeIntervalSince1970: 2000)
        XCTAssertTrue(PostAccountLogic.needsBodyRefresh(hasCachedBody: false, cachedAccountID: nil, selectedAccountID: "A"))
        XCTAssertFalse(PostAccountLogic.needsBodyRefresh(hasCachedBody: true, cachedAccountID: "A", selectedAccountID: "A"))
        XCTAssertTrue(PostAccountLogic.needsBodyRefresh(hasCachedBody: true, cachedAccountID: "A", selectedAccountID: "B"),
                      "switching account re-fetches")
        XCTAssertFalse(PostAccountLogic.needsBodyRefresh(hasCachedBody: true, cachedAccountID: "A", selectedAccountID: "B",
                                                         selectedCanView: false),
                       "never replace a readable cache with a restricted copy")
        XCTAssertTrue(PostAccountLogic.needsBodyRefresh(hasCachedBody: false, cachedAccountID: nil, selectedAccountID: "B",
                                                        selectedCanView: false))
        XCTAssertTrue(PostAccountLogic.needsBodyRefresh(hasCachedBody: true, cachedAccountID: "A", selectedAccountID: "A",
                                                        bodyFetchedAt: old, postUpdatedAt: new), "edited after caching")
        XCTAssertFalse(PostAccountLogic.needsBodyRefresh(hasCachedBody: true, cachedAccountID: "A", selectedAccountID: "A",
                                                         bodyFetchedAt: new, postUpdatedAt: old))
        XCTAssertFalse(PostAccountLogic.needsBodyRefresh(hasCachedBody: true, cachedAccountID: nil, selectedAccountID: "A"))
    }

    func testRestricted() {
        XCTAssertTrue(PostAccountLogic.isRestricted(feeRequired: 500, accessAccountIDs: [], hasBlocks: false))
        XCTAssertFalse(PostAccountLogic.isRestricted(feeRequired: 500, accessAccountIDs: ["A"], hasBlocks: false))
        XCTAssertFalse(PostAccountLogic.isRestricted(feeRequired: 0, accessAccountIDs: [], hasBlocks: false))
        XCTAssertFalse(PostAccountLogic.isRestricted(feeRequired: 500, accessAccountIDs: [], hasBlocks: true), "cached body wins")
    }

    func testOptions() {
        let options = PostAccountLogic.options(accounts: [("A", "Alice", nil), ("B", "Bob", "#fff"), ("C", "Cat", nil)],
                                               accesses: ["A": true, "B": false], cachedAccountIDs: ["A"], best: "A")
        XCTAssertEqual(options.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(options[0].statusText, "閲覧可 · キャッシュ済 · 自動選択")
        XCTAssertEqual(options[1].statusText, "閲覧不可")
        XCTAssertEqual(options[2].statusText, "未確認")
    }

    func testDefaultCommentAccount() {
        let accounts: [(id: String, creatorID: String?)] = [("A", nil), ("B", nil), ("C", "me")]
        XCTAssertEqual(PostAccountLogic.defaultCommentAccountID(postCreatorID: "me", isOwnPost: true, accounts: accounts, best: "A"), "C")
        XCTAssertEqual(PostAccountLogic.defaultCommentAccountID(postCreatorID: "other", isOwnPost: false, accounts: accounts, best: "B"), "B")
        XCTAssertEqual(PostAccountLogic.defaultCommentAccountID(postCreatorID: nil, isOwnPost: false, accounts: accounts, best: nil), "A")
        XCTAssertEqual(PostAccountLogic.defaultCommentAccountID(postCreatorID: "x", isOwnPost: true, accounts: accounts, best: "A"), "C",
                       "own post without creator id match still uses a creator account")
        XCTAssertNil(PostAccountLogic.defaultCommentAccountID(postCreatorID: nil, isOwnPost: false, accounts: [], best: "A"))
    }

    func testDeleteAccount() {
        let accounts: [(id: String, userIDs: [String], creatorID: String?)] = [("A", ["uA"], nil), ("C", ["uC"], "me")]
        // My own comment, matched by user id.
        XCTAssertEqual(PostAccountLogic.deleteAccountID(commentIsOwn: false, authorUserID: "uA", fetchedByAccountID: "C",
                                                        postCreatorID: "other", commentIsOnOwnPost: false, accounts: accounts), "A")
        // isOwn flag without a user-id match → the fetching account.
        XCTAssertEqual(PostAccountLogic.deleteAccountID(commentIsOwn: true, authorUserID: "?", fetchedByAccountID: "A",
                                                        postCreatorID: "other", commentIsOnOwnPost: false, accounts: accounts), "A")
        // Someone else's comment on my creator's post → the owner.
        XCTAssertEqual(PostAccountLogic.deleteAccountID(commentIsOwn: false, authorUserID: "fan", fetchedByAccountID: "A",
                                                        postCreatorID: "me", commentIsOnOwnPost: true, accounts: accounts), "C")
        // Someone else's comment on someone else's post → not deletable.
        XCTAssertNil(PostAccountLogic.deleteAccountID(commentIsOwn: false, authorUserID: "fan", fetchedByAccountID: "A",
                                                      postCreatorID: "other", commentIsOnOwnPost: false, accounts: accounts))
    }

    func testBestAccountFromStoreThenOverride() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = LocalStore(container: container)
        let a = Account(id: "A", kind: .demo, displayName: "A", isMain: true, sortOrder: 0, sessionState: .valid)
        let b = Account(id: "B", kind: .demo, displayName: "B", sortOrder: 1, sessionState: .valid)
        store.context.insert(a)
        store.context.insert(b)
        let post = Post(postID: "p", creatorID: "c", creatorName: "C", title: "T", feeRequired: 500, publishedAt: .now)
        store.context.insert(post)
        store.context.insert(PostAccess(postID: "p", accountID: "A", canView: false, feeRequired: 500))
        store.context.insert(PostAccess(postID: "p", accountID: "B", canView: true, feeRequired: 500, accountPlanFee: 500))
        store.save()

        let best = AccountSelector.bestAccount(postID: "p", store: store)
        XCTAssertEqual(best, "B", "the viewing account beats the main account")
        let enabled = store.accounts().map(\.id)
        XCTAssertEqual(PostAccountLogic.effectiveAccountID(override: nil, best: best, enabledAccountIDs: enabled), "B")
        XCTAssertEqual(PostAccountLogic.effectiveAccountID(override: "A", best: best, enabledAccountIDs: enabled), "A")
        b.enabled = false
        store.save()
        XCTAssertEqual(PostAccountLogic.effectiveAccountID(override: "B", best: AccountSelector.bestAccount(postID: "p", store: store),
                                                           enabledAccountIDs: store.accounts().map(\.id)), "A",
                       "override of a disabled account falls back")
    }

    func testEmbedLinks() {
        XCTAssertEqual(PostDetailEmbedLink.url(provider: "youtube", contentID: "abc123", explicitURL: nil)?.absoluteString,
                       "https://www.youtube.com/watch?v=abc123")
        XCTAssertEqual(PostDetailEmbedLink.url(provider: "vimeo", contentID: "42", explicitURL: nil)?.absoluteString, "https://vimeo.com/42")
        XCTAssertEqual(PostDetailEmbedLink.url(provider: "youtube", contentID: "x", explicitURL: "https://e.example/v")?.absoluteString,
                       "https://e.example/v")
        XCTAssertNil(PostDetailEmbedLink.url(provider: "unknown", contentID: "x", explicitURL: nil))
        XCTAssertNil(PostDetailEmbedLink.url(provider: "youtube", contentID: "  ", explicitURL: nil))
        XCTAssertEqual(PostDetailEmbedLink.providerName("youtube"), "YouTube")
        XCTAssertTrue(PostDetailEmbedLink.isFanboxHost(URL(string: "https://www.fanbox.cc/@a/posts/1")!))
        XCTAssertTrue(PostDetailEmbedLink.isFanboxHost(URL(string: "https://creator.fanbox.cc/posts/1")!))
        XCTAssertFalse(PostDetailEmbedLink.isFanboxHost(URL(string: "https://notfanbox.cc/")!))
        XCTAssertFalse(PostDetailEmbedLink.isFanboxHost(URL(string: "https://example.com/fanbox.cc")!))
    }

    func testBlockLayoutGroupsConsecutiveImages() {
        let kinds: [PostBlockKind] = [.paragraph, .image, .paragraph, .image, .image, .image, .file, .image, .image]
        XCTAssertEqual(PostDetailBlockLayout.group(kinds), [
            .single(0), .single(1), .single(2), .gallery([3, 4, 5]), .single(6), .gallery([7, 8]),
        ])
        XCTAssertEqual(PostDetailBlockLayout.group([]), [])
        XCTAssertEqual(PostDetailBlockLayout.group([.image]), [.single(0)])
    }
}

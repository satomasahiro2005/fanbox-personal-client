import SwiftData
import SwiftUI
import XCTest
@testable import FANBOXClient

/// Reader fixes on the Home / post side: anchor links, timeline-only feed without my drafts, cross-account fallback,
/// web fallbacks, search on indexed FANBOX tags, and a FANBOX-shaped gallery rendering offline.
@MainActor
final class FixReaderHomeTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    // MARK: - Article anchor links (SPEC §6)

    private func links(_ attributed: AttributedString) -> [(String, URL)] {
        attributed.runs.compactMap { run in
            run.link.map { (String(attributed[run.range].characters), $0) }
        }
    }

    func testAnchorTextLinksBecomeTappable() {
        let text = "詳しくはこちらをご覧ください"
        let styles = [RemoteTextStyle(type: RemoteTextStyle.linkTypePrefix + "https://www.fanbox.cc/@creator/posts/42", offset: 4, length: 3,
                                      size: nil)]
        let result = links(PostTextStyler.attributedString(text: text, styles: styles))
        XCTAssertEqual(result.map(\.0), ["こちら"])
        XCTAssertEqual(result.first?.1.absoluteString, "https://www.fanbox.cc/@creator/posts/42")
        XCTAssertEqual(String(PostTextStyler.attributedString(text: text, styles: styles).characters), text, "text is kept")
    }

    func testAnchorLinkOffsetsAreUTF16WithEmojiAndBold() {
        // "😀" is 2 UTF-16 units: the link "link" starts at offset 3 (😀 + space).
        let text = "😀 link and more"
        let styles = [
            RemoteTextStyle(type: "bold", offset: 0, length: 2, size: nil),
            RemoteTextStyle(type: RemoteTextStyle.linkTypePrefix + "https://example.com/a", offset: 3, length: 4, size: nil),
        ]
        let result = links(PostTextStyler.attributedString(text: text, styles: styles))
        XCTAssertEqual(result.map(\.0), ["link"])
        // An offset inside the surrogate pair widens to the whole character instead of splitting it.
        let split = [RemoteTextStyle(type: RemoteTextStyle.linkTypePrefix + "https://example.com/b", offset: 1, length: 2, size: nil)]
        XCTAssertEqual(links(PostTextStyler.attributedString(text: text, styles: split)).map(\.0), ["😀 "])
    }

    func testLinkStylesAreFilteredAndWinOverDetectedURLs() {
        XCTAssertNil(RemoteTextStyle(type: RemoteTextStyle.linkTypePrefix + "javascript:alert(1)", offset: 0, length: 1, size: nil).linkURL)
        XCTAssertNil(RemoteTextStyle(type: "bold", offset: 0, length: 1, size: nil).linkURL)
        XCTAssertEqual(RemoteTextStyle.linkTypePrefix, FanboxAdapter.linkStylePrefix, "same encoding as the adapter")
        let text = "see https://a.example/x"
        let styles = [RemoteTextStyle(type: RemoteTextStyle.linkTypePrefix + "https://b.example/y", offset: 4, length: 19, size: nil),
                      RemoteTextStyle(type: RemoteTextStyle.linkTypePrefix + "https://c.example", offset: 500, length: 3, size: nil)]
        XCTAssertEqual(links(PostTextStyler.attributedString(text: text, styles: styles)).map(\.1.absoluteString), ["https://b.example/y"])
    }

    // MARK: - Unified timeline (SPEC §5)

    private func makeStore() throws -> LocalStore {
        LocalStore(container: try PersistenceController.makeContainer(inMemory: true))
    }

    func testHomeFeedIsTimelinePostsWithoutMyDrafts() throws {
        let store = try makeStore()
        let account = AccountContext(accountID: "A", kind: .fanbox, pixivUserID: "u", fanboxUserID: nil, creatorID: nil)
        store.upsertPostSummaries([SyncFixtures.summary("home1", creator: "followed", minutesAgo: 1)], account: account, source: .home)
        store.upsertPostSummaries([SyncFixtures.summary("sup1", creator: "supported", minutesAgo: 2)], account: account, source: .supporting)
        // A creator page of a creator none of my accounts follows, and a linked post (detail upsert).
        store.upsertPostSummaries([SyncFixtures.summary("page1", creator: "stranger", minutesAgo: 3)], account: account, source: .creator)
        store.upsertPostDetail(SyncFixtures.detail("link1", creator: "stranger2"), account: account)
        // My own FANBOX draft that arrived through the timeline listing.
        store.upsertPostSummaries([SyncFixtures.summary("draft1", creator: "followed", minutesAgo: 0)], account: account, source: .home)
        store.post(id: "draft1")?.remoteStatusRaw = RemotePostStatus.draft.rawValue
        store.post(id: "page1")?.isFavorite = true
        store.post(id: "draft1")?.isFavorite = true
        store.save()

        func ids(_ kind: HomeFeedFilterKind) -> [String] {
            let filter = HomeFeedFilter(kind: kind)
            return filter.apply(store.fetch(filter.descriptor(limit: nil))).map(\.postID)
        }
        XCTAssertEqual(ids(.all), ["home1", "sup1"])
        XCTAssertEqual(ids(.unread), ["home1", "sup1"])
        XCTAssertEqual(ids(.favorite), ["page1"], "favorites show any post, never my drafts")
        XCTAssertEqual(store.fetch(LibraryListKind.unread.descriptor(limit: nil)).map(\.postID), ["home1", "sup1"])

        let draftEntry = HomeFeedEntry(postID: "d", isFromFollowedCreator: true, isVisibleToReaders: false)
        XCTAssertFalse(HomeFeedFilter(kind: .following).matches(draftEntry))
        XCTAssertFalse(HomeFeedFilter(kind: .all).matches(HomeFeedEntry(postID: "x")), "link-only post")
        XCTAssertTrue(HomeFeedFilter(kind: .favorite).matches(HomeFeedEntry(postID: "x", isFavorite: true)))
    }

    func testCreatorPageAndSearchHideMyDrafts() throws {
        let store = try makeStore()
        let account = AccountContext(accountID: "A", kind: .fanbox, pixivUserID: "u", fanboxUserID: nil, creatorID: "me")
        store.upsertPostSummaries([SyncFixtures.summary("pub", creator: "me", title: "公開 ピアノ", minutesAgo: 5),
                                   SyncFixtures.summary("drf", creator: "me", title: "下書き ピアノ", minutesAgo: 1),
                                   SyncFixtures.summary("sch", creator: "me", title: "予約 ピアノ", minutesAgo: 2)],
                                  account: account, source: .creator)
        store.post(id: "pub")?.remoteStatusRaw = RemotePostStatus.published.rawValue
        store.post(id: "drf")?.remoteStatusRaw = RemotePostStatus.draft.rawValue
        store.post(id: "sch")?.remoteStatusRaw = RemotePostStatus.scheduled.rawValue
        store.save()

        XCTAssertEqual(store.fetch(ReaderPostQueries.byCreator("me")).map(\.postID), ["pub"])
        XCTAssertEqual(SearchService(store: store).search("ピアノ").posts.map(\.postID), ["pub"])
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<Post>(predicate: ReaderPostQueries.visible)), 1)
    }

    // MARK: - Search on indexed FANBOX tags (SPEC §33)

    func testFanboxTagsAreIndexedOnUpsertAndBackfilled() throws {
        let store = try makeStore()
        let account = AccountContext(accountID: "A", kind: .fanbox, pixivUserID: "u", fanboxUserID: nil, creatorID: nil)
        var tagged = SyncFixtures.summary("t1", creator: "c", title: "Untitled")
        tagged.tags = ["Piano", "楽譜"]
        store.upsertPostSummaries([tagged], account: account, source: .home)
        XCTAssertEqual(store.post(id: "t1")?.fanboxTagsText, "Piano\n楽譜")

        // A row written before the index existed.
        let legacy = Post(postID: "t2", creatorID: "c", creatorName: "C", title: "Old", publishedAt: .now)
        legacy.fanboxTags = ["ギター"]
        store.context.insert(legacy)
        store.save()
        XCTAssertNil(legacy.fanboxTagsText)

        let search = SearchService(store: store)
        XCTAssertEqual(search.search("楽譜").posts.map(\.postID), ["t1"])
        XCTAssertEqual(search.search("ギター").posts.map(\.postID), ["t2"], "backfilled on first search")
        XCTAssertEqual(legacy.fanboxTagsText, "ギター")
        XCTAssertEqual(search.search("piano 楽譜").posts.map(\.postID), ["t1"], "remaining terms still ANDed")
        XCTAssertEqual(SearchService.mostSelective(["a", "abcd", "ab"]), "abcd")
    }

    func testSearchCandidatesAreBounded() throws {
        let store = try makeStore()
        for i in 0..<30 {
            store.context.insert(Post(postID: "b\(i)", creatorID: "c", creatorName: "C", title: "bounded \(i)",
                                      publishedAt: Date(timeIntervalSince1970: Double(1_700_000_000 + i))))
        }
        store.save()
        let search = SearchService(store: store, limit: 5, candidateLimit: 10)
        let posts = search.search("bounded").posts
        XCTAssertEqual(posts.count, 5)
        XCTAssertEqual(posts.first?.postID, "b29", "newest first")
    }

    // MARK: - Account auto-selection (SPEC §8)

    func testUnknownAccessRanksAboveKnownRestricted() {
        let base = AccountCandidate(accountID: "x", isCached: false, canView: nil, sessionValid: true, planFee: 0, isMain: false, enabled: true)
        var restrictedMain = base; restrictedMain.accountID = "main"; restrictedMain.canView = false; restrictedMain.isMain = true
        var unknown = base; unknown.accountID = "B"
        XCTAssertEqual(AccountSelector.select([restrictedMain, unknown]), "B")
        var viewer = base; viewer.accountID = "C"; viewer.canView = true
        XCTAssertEqual(AccountSelector.select([unknown, viewer]), "C")
        XCTAssertEqual(AccountSelector.viewScore(true), 2)
        XCTAssertEqual(AccountSelector.viewScore(nil), 1)
        XCTAssertEqual(AccountSelector.viewScore(false), 0)
    }

    /// The post screen passes no account in automatic mode: main only gets a restricted copy, B (unknown so far) is
    /// tried next, its body is cached and the automatic choice ends on B.
    func testAutomaticRefreshFallsBackToAnotherAccount() async throws {
        let h = try SyncHarness()
        h.addAccount("Main", pixivUserID: "m", isMain: true)
        let b = h.addAccount("B", pixivUserID: "b")
        let mainID = try XCTUnwrap(h.store.mainAccount()?.id)
        h.mock.update {
            $0.details[mainID] = ["np": SyncFixtures.detail("np", restricted: true)]
            $0.details[b.id] = ["np": SyncFixtures.detail("np", text: "Bの本文")]
        }
        XCTAssertEqual(AccountSelector.bestAccount(postID: "np", store: h.store), mainID, "nothing known yet: main first")

        let error = await h.engine.refreshPost(postID: "np", accountID: nil)
        XCTAssertNil(error)
        XCTAssertEqual(h.mock.count("post|\(mainID)|np"), 1)
        XCTAssertEqual(h.mock.count("post|\(b.id)|np"), 1)
        let post = try XCTUnwrap(h.store.post(id: "np"))
        XCTAssertEqual(post.detailAccountID, b.id)
        XCTAssertEqual(post.bodyText, "Bの本文")
        XCTAssertEqual(AccountSelector.bestAccount(postID: "np", store: h.store), b.id, "selection ends on the account with the body")

        // Safety-net rule used by the post screen after the choice moved.
        XCTAssertFalse(PostAccountLogic.needsFetchAfterSelectionChange(selectedAccountID: b.id, cachedAccountID: b.id, hasCachedBody: true,
                                                                       selectedCanView: true))
        XCTAssertTrue(PostAccountLogic.needsFetchAfterSelectionChange(selectedAccountID: "B", cachedAccountID: nil, hasCachedBody: false,
                                                                      selectedCanView: nil))
        XCTAssertFalse(PostAccountLogic.needsFetchAfterSelectionChange(selectedAccountID: "B", cachedAccountID: nil, hasCachedBody: false,
                                                                       selectedCanView: false))
    }

    // MARK: - Web fallback (SPEC §21 / §40)

    func testWebFallbackDecisions() {
        XCTAssertTrue(PostAccountLogic.offersWebFallback(for: .forbidden))
        XCTAssertTrue(PostAccountLogic.offersWebFallback(for: .decoding(endpoint: "post.info", detail: "x")))
        XCTAssertTrue(PostAccountLogic.offersWebFallback(for: .server(status: 503)))
        XCTAssertFalse(PostAccountLogic.offersWebFallback(for: nil))
        XCTAssertFalse(PostAccountLogic.offersWebFallback(for: .offline))
        XCTAssertFalse(PostAccountLogic.offersWebFallback(for: .network(code: -1, detail: "")))
        XCTAssertFalse(PostAccountLogic.offersWebFallback(for: .cancelled))

        XCTAssertTrue(PostAccountLogic.commentOperationOffersWeb(.unsupported(operation: "deleteComment")))
        XCTAssertTrue(PostAccountLogic.commentOperationOffersWeb(.forbidden))
        XCTAssertTrue(PostAccountLogic.commentOperationOffersWeb(.invalidRequest("x")))
        XCTAssertFalse(PostAccountLogic.commentOperationOffersWeb(.offline))
        XCTAssertFalse(PostAccountLogic.commentOperationOffersWeb(.notFound))
    }

    // MARK: - FANBOX-shaped gallery, offline (SPEC §6 / §45 Offline 閲覧)

    private func host<V: View>(_ view: V, env: AppEnvironment, settle: TimeInterval = 2.0) throws {
        let root = NavigationStack {
            ScrollView { view }
                .navigationDestination(for: AppRoute.self) { AppRouteDestination(route: $0) }
        }
        .environment(env)
        .environment(env.router)
        .environment(env.settings)
        .modelContainer(env.container)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("no window scene in the test host")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        self.window?.isHidden = true
        self.window = window
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
    }

    /// Image blocks exactly as FanboxAdapter maps them (thumbnailURL nil). With the display files saved and the app
    /// Offline, the default grid shows every image (it used to stay a grid of gray placeholders).
    func testFanboxGalleryShowsSavedImagesOffline() throws {
        let env = AppEnvironment.preview(seedDemo: false)
        UserDefaults.standard.set("grid", forKey: "home.galleryStyle")
        let post = Post(postID: "fg", creatorID: "c", creatorName: "C", title: "Gallery", publishedAt: .now)
        post.bodyFetchedAt = .now
        env.store.context.insert(post)
        let token = UUID().uuidString
        var blocks: [PostBlock] = []
        for i in 0..<3 {
            let block = PostBlock(postID: "fg", index: i, kind: .image)
            block.displayURL = "demo://image/fg-\(token)-\(i)?w=1200&h=900&v=display"
            block.originalURL = "demo://image/fg-\(token)-\(i)?w=2400&h=1800&v=original"
            block.width = 1200
            block.height = 900
            env.store.context.insert(block)
            block.post = post
            blocks.append(block)
        }
        // Saved display files, written the way MediaService stores pinned downloads.
        for block in blocks {
            let url = try XCTUnwrap(block.displayURL)
            let path = MediaFileCache.relativePath(url: url, variant: .display, kind: .image, pinned: true)
            let size = try env.media.fileCache.write(try DemoMediaRenderer.render(url: url, requestedVariant: .display), relativePath: path)
            env.store.context.insert(MediaCacheEntry(key: MediaFileCache.key(url: url, variant: .display), url: url, variant: .display,
                                                     kind: .image, relativePath: path, byteSize: size, postID: "fg", isPinned: true))
        }
        env.store.save()
        env.settings.networkModePreference = .offline
        env.networkMode.recompute()
        defer { env.media.clearCache(postID: "fg") }

        let context = PostDetailRenderContext(postID: "fg", creatorID: "c", accountID: nil, openImage: { _ in }, openLink: { _ in },
                                              openInBrowser: {})
        try host(PostDetailGalleryView(blocks: blocks, context: context), env: env)

        for block in blocks {
            let hit = env.media.memoryCachedImageWithVariant(urls: [.display: block.displayURL!], upTo: .thumbnail)
            XCTAssertNotNil(hit, "tile \(block.index) decoded its saved display image")
        }
    }
}

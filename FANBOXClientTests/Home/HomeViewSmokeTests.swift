import XCTest
import SwiftUI
import SwiftData
@testable import FANBOXClient

/// Hosts the Home screens in a real window with seeded local data. Verifies the SwiftData queries / view code run
/// without crashing, that local rendering needs no network, and that opening a post marks it read.
/// Screenshots are written to the test process' temporary directory (home-smoke-*.png) for manual inspection.
@MainActor
final class HomeViewSmokeTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    @discardableResult
    private func seed(_ env: AppEnvironment) -> [String] {
        let store = env.store
        let ids = store.accounts().map(\.id)
        let (a, b) = (ids[0], ids[1])
        store.context.insert(Creator(creatorID: "cr1", name: "テストクリエイター"))
        store.context.insert(Plan(planID: "pl1", creatorID: "cr1", title: "ベーシック", fee: 500))
        let now = Date()
        for i in 0..<6 {
            let p = Post(postID: "hp\(i)", creatorID: "cr1", creatorName: "テストクリエイター", title: "投稿タイトル \(i)",
                         excerpt: "本文の冒頭です。これはテスト用の抜粋テキストで、カードでは二行まで表示されます。", type: .article,
                         feeRequired: i % 2 == 0 ? 500 : 0, coverImageURL: i % 3 == 0 ? "https://example.invalid/c\(i).jpg" : nil,
                         publishedAt: now.addingTimeInterval(Double(-i) * 3600))
            p.accessAccountIDs = i == 4 ? [] : Array([a, b].prefix(i % 2 + 1))
            p.seenByAccountIDs = [a]
            p.isFromSupportedCreator = true
            p.isRead = i > 2
            p.isFavorite = i == 1
            p.commentCount = i == 0 ? 3 : 0
            if i == 0 {
                p.bodyFetchedAt = now
                p.detailAccountID = a
                p.offlineState = .saved
                p.fanboxTags = ["イラスト", "テスト"]
            }
            store.context.insert(p)
            store.context.insert(PostAccess(postID: p.postID, accountID: a, canView: i != 4, feeRequired: p.feeRequired))
        }
        let bold = PostTextStyler.encodeStyles([RemoteTextStyle(type: "bold", offset: 0, length: 4, size: nil),
                                                RemoteTextStyle(type: "fontSize", offset: 5, length: 4, size: 24)])
        var blocks: [PostBlock] = []
        @discardableResult
        func block(_ kind: PostBlockKind, _ text: String = "") -> PostBlock {
            let blk = PostBlock(postID: "hp0", index: blocks.count, kind: kind, text: text)
            blocks.append(blk)
            return blk
        }
        block(.header, "見出しブロック")
        block(.paragraph, "太字です 大きい文字 と https://example.com へのリンク").stylesJSON = bold
        for _ in 0..<3 {
            let img = block(.image)
            img.width = 800
            img.height = 600
            img.thumbnailURL = "https://example.invalid/t.jpg"
        }
        let file = block(.file)
        file.fileName = "資料"
        file.fileExtension = "zip"
        file.fileSize = 1_234_567
        file.originalURL = "https://example.invalid/f.zip"
        let link = block(.url)
        link.url = "https://example.com/page"
        link.title = "リンクカード"
        let embed = block(.embed)
        embed.embedProvider = "youtube"
        embed.embedContentID = "abc"
        block(.unknown)
        for blk in blocks { store.context.insert(blk) }

        let t = now.addingTimeInterval(-600)
        store.context.insert(Comment(commentID: "hc1", postID: "hp0", fetchedByAccountID: a, authorUserID: "fan1", authorName: "ファン1",
                                     body: "素敵な投稿です！", createdAt: t))
        store.context.insert(Comment(commentID: "hc2", postID: "hp0", fetchedByAccountID: a, authorUserID: "creator", authorName: "テストクリエイター",
                                     body: "ありがとうございます", createdAt: t.addingTimeInterval(60), parentCommentID: "hc1", rootCommentID: "hc1"))
        store.context.insert(Comment(commentID: "hc3", postID: "hp0", fetchedByAccountID: a, authorUserID: "fan2", authorName: "ファン2",
                                     body: "次回も楽しみにしています", createdAt: t.addingTimeInterval(120)))
        store.context.insert(OutgoingComment(accountID: a, postID: "hp0", parentCommentID: "hc3", rootCommentID: "hc3",
                                             body: "オフラインで書いた返信", state: .queued))
        store.context.insert(OutgoingComment(accountID: b, postID: "hp0", body: "長時間待機した返信", state: .needsConfirmation))
        store.context.insert(OutgoingComment(accountID: a, postID: "hp0", body: "送信に失敗", state: .failed))
        store.save()
        return ids
    }

    @discardableResult
    private func host<V: View>(_ view: V, env: AppEnvironment, name: String, settle: TimeInterval = 1.5) throws -> UIImage {
        let root = NavigationStack {
            view.navigationDestination(for: AppRoute.self) { AppRouteDestination(route: $0) }
        }
        .environment(env)
        .environment(env.router)
        .environment(env.settings)
        .modelContainer(env.container)

        let controller = UIHostingController(rootView: root)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("no window scene in the test host")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window?.isHidden = true
        self.window = window
        RunLoop.main.run(until: Date().addingTimeInterval(settle))

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("home-smoke-\(name).png")
        try? image.pngData()?.write(to: url)
        print("HOME_SMOKE_SCREENSHOT \(url.path)")
        return image
    }

    func testHomeFeedRendersLocalPosts() throws {
        let env = AppEnvironment.preview()
        seed(env)
        let image = try host(HomeRootView(), env: env, name: "home")
        XCTAssertGreaterThan(image.size.width, 0)
        // Rendering alone must not change user metadata.
        XCTAssertEqual(env.store.post(id: "hp1")?.isRead, false)
    }

    func testPostDetailRendersFromCacheAndMarksRead() throws {
        let env = AppEnvironment.preview()
        seed(env)
        XCTAssertEqual(env.store.post(id: "hp0")?.isRead, false)
        try host(PostDetailView(postID: "hp0"), env: env, name: "detail")
        let post = env.store.post(id: "hp0")
        XCTAssertEqual(post?.isRead, true, "opening a post marks it read")
        XCTAssertNotNil(post?.readAt)
        XCTAssertNotNil(post?.lastViewedAt)
    }

    func testRestrictedPostDetail() throws {
        let env = AppEnvironment.preview()
        seed(env)
        try host(PostDetailView(postID: "hp4"), env: env, name: "restricted")
        XCTAssertEqual(env.store.post(id: "hp4")?.isRead, true)
    }

    func testUnknownPostShowsMissingStateWithoutCrash() throws {
        let env = AppEnvironment.preview()
        try host(PostDetailView(postID: "does-not-exist"), env: env, name: "missing", settle: 1.0)
        XCTAssertNil(env.store.post(id: "does-not-exist"))
    }

    func testCommentThreadRendersThreadsAndPendingReplies() throws {
        let env = AppEnvironment.preview()
        seed(env)
        try host(CommentThreadView(postID: "hp0", focusCommentID: "hc2"), env: env, name: "comments")
        XCTAssertEqual(env.store.comments(postID: "hp0").count, 3, "viewing never deletes cached comments")
    }
}

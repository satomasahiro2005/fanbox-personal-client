import XCTest
import SwiftUI
import SwiftData
@testable import FANBOXClient

/// Renders the Creator / Notifications screens with seeded local data (no network) to catch runtime failures
/// in queries and view bodies. Everything must render from the local DB alone (SPEC §3.1).
@MainActor
final class CreatorViewsSmokeTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    static func makeSeededEnvironment() -> AppEnvironment {
        let env = AppEnvironment.preview(seedDemo: true)
        let accounts = env.store.accounts()
        XCTAssertEqual(accounts.count, 3)
        let (a, b, c) = (accounts[0].id, accounts[1].id, accounts[2].id)
        let ctx = env.store.context

        let creator = Creator(creatorID: "smoke", name: "Smoke Creator", profileText: "プロフィール本文",
                              profileLinks: ["https://www.pixiv.net/users/1", "invalid link"])
        creator.followedByAccountIDs = [b]
        creator.isFollowed = true
        creator.memo = "#reference"
        ctx.insert(creator)
        ctx.insert(Creator(creatorID: "other", name: "Other"))
        ctx.insert(Plan(planID: "p500", creatorID: "smoke", title: "ワンコイン", fee: 500, planDescription: "説明"))
        ctx.insert(Plan(planID: "p1000", creatorID: "smoke", title: "スタンダード", fee: 1000))
        ctx.insert(Support(accountID: a, creatorID: "smoke", creatorName: "Smoke Creator", planID: "p500", planTitle: "ワンコイン", amount: 500))
        ctx.insert(Support(accountID: b, creatorID: "smoke", creatorName: "Smoke Creator", planID: "p1000", planTitle: "スタンダード", amount: 1000))
        let missing = Support(accountID: c, creatorID: "smoke", creatorName: "Smoke Creator", planID: "p1000", planTitle: "スタンダード",
                              amount: 1000, status: .missing)
        missing.needsAttention = true
        ctx.insert(missing)
        for i in 0..<5 {
            let post = Post(postID: "post\(i)", creatorID: "smoke", creatorName: "Smoke Creator", title: "投稿 \(i)", excerpt: "冒頭",
                            feeRequired: i == 0 ? 500 : 0, publishedAt: Date(timeIntervalSinceNow: Double(-i * 3600)))
            post.accessAccountIDs = [a]
            ctx.insert(post)
        }
        let event = NotificationEvent(id: "comment|c1", type: .comment, accountIDs: [c], title: "投稿 0", message: "コメント本文",
                                      timestamp: Date(timeIntervalSinceNow: -60), creatorID: "smoke", postID: "post0", commentID: "c1")
        event.actorName = "user123"
        event.prefetchState = .textReady
        ctx.insert(event)
        ctx.insert(NotificationEvent(id: "newPost|post1", type: .newPost, accountIDs: [a, b], title: "投稿 1", message: "",
                                     timestamp: Date(timeIntervalSinceNow: -180), creatorID: "smoke", postID: "post1"))
        ctx.insert(Newsletter(newsletterID: "n1", creatorID: "smoke", creatorName: "Smoke Creator", body: "いつもありがとう\nございます",
                              createdAt: Date(timeIntervalSinceNow: -720), accountIDs: [b]))
        ctx.insert(Newsletter(newsletterID: "n2", creatorID: "smoke", creatorName: "Smoke Creator", body: "",
                              createdAt: Date(timeIntervalSinceNow: -7200), accountIDs: [a]))
        env.store.save()
        return env
    }

    @discardableResult
    func render<V: View>(_ view: V, env: AppEnvironment, height: CGFloat = 844) throws -> UIWindow {
        let root = NavigationStack { view }
            .environment(env)
            .environment(env.router)
            .environment(env.settings)
            .modelContainer(env.container)
        let controller = UIHostingController(rootView: root)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("no window scene in the test host")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNotNil(controller.view)
        self.window?.isHidden = true
        self.window = window
        return window
    }

    func testCreatorsRootRenders() throws {
        let env = Self.makeSeededEnvironment()
        try render(CreatorsRootView(), env: env)
        // Local metadata is untouched by rendering.
        XCTAssertEqual(env.store.creator(id: "smoke")?.memo, "#reference")
    }

    func testCreatorDetailRendersEverySection() throws {
        let env = Self.makeSeededEnvironment()
        for section in CreatorDetailSection.allCases {
            try render(CreatorDetailView(creatorID: "smoke", initialSection: section), env: env)
        }
        // Unknown creator renders a local placeholder instead of waiting on the network.
        try render(CreatorDetailView(creatorID: "not-local"), env: env)
    }

    func testInboxAndNewsletterRender() throws {
        let env = Self.makeSeededEnvironment()
        try render(NotificationInboxView(), env: env)
        try render(NewsletterDetailView(newsletterID: "n1"), env: env)
        // Opening the newsletter marks it read locally.
        XCTAssertEqual(env.store.newsletter(id: "n1")?.isRead, true)
        try render(NewsletterDetailView(newsletterID: "missing"), env: env)
    }
}

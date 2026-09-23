import XCTest

/// Opens every screen with demo data and checks that it renders without crashing.
/// Catches runtime-only failures such as SwiftData predicates that compile but fail when executed.
final class ScreenTourUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-demoData"] + extra
        app.launch()
        return app
    }

    /// Waits for an element with the identifier (any type) and asserts the app is still running.
    private func expect(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 15,
                        file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(identifier) did not appear", file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, "app is not running after showing \(identifier)", file: file, line: line)
    }

    func testTabs() {
        let app = launch()
        expect("homeFeedList", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["homePost.demo-post-101"].firstMatch.waitForExistence(timeout: 15),
                      "demo timeline did not sync")
        for (tab, id) in [("クリエイター", "creatorsList"), ("支援", "supportDashboard"), ("Creator", "creatorModeList"),
                          ("ライブラリ", "libraryRoot"), ("ホーム", "homeFeedList")] {
            app.tabBars.buttons[tab].tap()
            expect(id, in: app)
        }
    }

    func testPostDetailAndComments() {
        let app = launch(["-openRoute", "post:demo-post-101"])
        expect("postTitle", in: app)
        expect("postBlocks", in: app)
        let comments = launch(["-openRoute", "comments:demo-post-101"])
        expect("commentList", in: comments)
    }

    func testEveryPostTypeRenders() {
        // image, file, image, article, text, image, video, image, file, text, file
        for n in 101...111 {
            let app = launch(["-openRoute", "post:demo-post-\(n)"])
            expect("postTitle", in: app)
        }
    }

    func testCreatorAndNewsletterAndSearch() {
        expect("creatorDetail", in: launch(["-initialTab", "creators", "-openRoute", "creator:demo-aoi"]))
        expect("newsletterDetail", in: launch(["-openRoute", "newsletter:demo-nl-a-1"]))
        expect("librarySearchResults", in: launch(["-initialTab", "library", "-openRoute", "search:Demo"]))
        expect("offlineLibrary", in: launch(["-initialTab", "library", "-openRoute", "offlineLibrary"]))
    }

    func testSupportScreens() {
        expect("supportHistoryList", in: launch(["-initialTab", "support", "-openRoute", "supportHistory"]))
        expect("paymentProfilesList", in: launch(["-initialTab", "support", "-openRoute", "paymentProfiles"]))
    }

    func testCreatorModeScreens() {
        expect("creatorCommentsList", in: launch(["-initialTab", "creatorMode", "-openRoute", "creatorComments"]))
        expect("creatorFansList", in: launch(["-initialTab", "creatorMode", "-openRoute", "fans"]))
        let app = launch(["-initialTab", "creatorMode"])
        expect("creatorModeList", in: app)
        let newPost = app.descendants(matching: .any)["creatorNewPostButton"].firstMatch
        XCTAssertTrue(newPost.waitForExistence(timeout: 15))
        newPost.tap()
        expect("draftEditorList", in: app)
    }

    func testSheets() {
        expect("notificationList", in: launch(["-openSheet", "notifications"]))
        let app = launch(["-openSheet", "settings"])
        expect("settingsView", in: app)
        let research = app.descendants(matching: .any)["researchModeLink"].firstMatch
        if research.waitForExistence(timeout: 5) {
            research.tap()
            expect("researchModeView", in: app)
        }
    }
}

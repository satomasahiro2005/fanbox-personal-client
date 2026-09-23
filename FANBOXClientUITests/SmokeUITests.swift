import XCTest

final class SmokeUITests: XCTestCase {
    func testLaunchShowsTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-demoData"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["ライブラリ"].exists)
    }
}

import XCTest
@testable import FANBOXClient

final class WebDestinationTests: XCTestCase {
    func testEveryDestinationMapsToExpectedURL() {
        let custom = URL(string: "https://www.pixiv.net/settings")!
        let cases: [(WebDestination, String)] = [
            (.login, "https://www.fanbox.cc/login"),
            (.home, "https://www.fanbox.cc/"),
            (.post(creatorID: "alice", postID: "123"), "https://www.fanbox.cc/@alice/posts/123"),
            (.creator(creatorID: "alice"), "https://www.fanbox.cc/@alice"),
            (.creatorPlans(creatorID: "alice"), "https://www.fanbox.cc/@alice/plans"),
            (.plan(creatorID: "alice", planID: "77"), "https://www.fanbox.cc/@alice/plans/77"),
            (.supportingPlans, "https://www.fanbox.cc/creators/supporting"),
            (.paymentSettings, "https://www.fanbox.cc/user/settings/payment"),
            (.paymentHistory, "https://www.fanbox.cc/user/payments"),
            (.notifications, "https://www.fanbox.cc/notifications"),
            (.newsletter(id: "n1"), "https://www.fanbox.cc/messages/n1"),
            (.newsletter(id: nil), "https://www.fanbox.cc/messages"),
            (.managePosts, "https://www.fanbox.cc/manage/posts"),
            (.managePostEditor(postID: "9"), "https://www.fanbox.cc/manage/posts/9"),
            (.managePostEditor(postID: nil), "https://www.fanbox.cc/manage/posts/new"),
            (.manageRelationships, "https://www.fanbox.cc/manage/relationships"),
            (.managePlans, "https://www.fanbox.cc/manage/plans"),
            (.manageDashboard, "https://www.fanbox.cc/manage/dashboard"),
            (.url(custom), "https://www.pixiv.net/settings"),
        ]
        for (destination, expected) in cases {
            XCTAssertEqual(destination.url.absoluteString, expected, "\(destination)")
            XCTAssertFalse(destination.title.isEmpty, "\(destination) has no title")
        }
    }

    func testAllFanboxDestinationsStayOnFanboxHost() {
        let destinations: [WebDestination] = [
            .login, .home, .post(creatorID: "a", postID: "1"), .creator(creatorID: "a"), .creatorPlans(creatorID: "a"),
            .plan(creatorID: "a", planID: "1"), .supportingPlans, .paymentSettings, .paymentHistory, .notifications,
            .newsletter(id: nil), .managePosts, .managePostEditor(postID: nil), .manageRelationships, .managePlans, .manageDashboard,
        ]
        for destination in destinations {
            XCTAssertEqual(destination.url.scheme, "https")
            XCTAssertTrue(WebCookieScope.isFanboxHost(destination.url.host), "\(destination)")
        }
    }

    @MainActor
    func testOpenWebAndDismissNotifiesWithRequest() {
        let bridge = WebBridge()
        var dismissed: WebSessionRequest?
        bridge.onDismiss = { dismissed = $0 }
        bridge.openWeb(account: "acc-1", destination: .paymentSettings, purpose: .payment)
        XCTAssertEqual(bridge.presented?.accountID, "acc-1")
        XCTAssertEqual(bridge.presented?.destination, .paymentSettings)
        bridge.dismiss()
        XCTAssertNil(bridge.presented)
        XCTAssertEqual(dismissed?.purpose, .payment)
        XCTAssertEqual(dismissed?.accountID, "acc-1")
    }
}

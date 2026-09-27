import Foundation

/// One page the account WebView can switch to when the requested FANBOX page does not exist.
struct WebFallbackStep: Hashable, Sendable, Identifiable {
    let url: URL
    let title: String

    var id: URL { url }

    // Pages the research marked verified (docs/API.md §20).
    static let pixivCards = WebFallbackStep(url: URL(string: "https://payment.pixiv.net/cards")!, title: "pixivのカード管理")
    static let invoices = WebFallbackStep(url: URL(string: "https://www.fanbox.cc/invoices")!, title: "領収書")
    static let userSettings = WebFallbackStep(url: URL(string: "https://www.fanbox.cc/user/settings")!, title: "ユーザー設定")
    static let home = WebFallbackStep(url: WebDestination.home.url, title: "FANBOXトップ")
}

extension WebDestination {
    /// Pages tried in order when this destination answers 404 / 410.
    ///
    /// Several paths the app builds are *unverified* (docs/API.md §20: plan pages, 支援中のプラン, payment settings /
    /// history). Every chain ends at a page the research marked **verified** (creator page, home, pixiv card management,
    /// invoices, user settings), so a payment flow never ends on a dead page. The same list is offered manually in the
    /// web screen, because a single-page app may render "not found" with status 200.
    var fallbackSteps: [WebFallbackStep] {
        switch self {
        case .plan(let creatorID, _):
            return [Self.step(.creatorPlans(creatorID: creatorID), "プラン一覧"), Self.step(.creator(creatorID: creatorID), "クリエイターページ")]
        case .creatorPlans(let creatorID):
            return [Self.step(.creator(creatorID: creatorID), "クリエイターページ")]
        case .supportingPlans:
            return [WebFallbackStep.home]
        case .paymentSettings:
            return [WebFallbackStep.pixivCards, WebFallbackStep.userSettings]
        case .paymentHistory:
            return [WebFallbackStep.invoices, WebFallbackStep.userSettings]
        case .post(let creatorID, _):
            return [Self.step(.creator(creatorID: creatorID), "クリエイターページ")]
        case .notifications, .newsletter:
            return [WebFallbackStep.home]
        case .managePostEditor:
            return [Self.step(.managePosts, "投稿管理")]
        case .login, .home, .creator, .managePosts, .manageRelationships, .managePlans, .manageDashboard, .url:
            return []
        }
    }

    private static func step(_ destination: WebDestination, _ title: String) -> WebFallbackStep {
        WebFallbackStep(url: destination.url, title: title)
    }

    /// Status codes meaning "this page does not exist" (as opposed to auth / server errors, which keep the page).
    static func isMissingPageStatus(_ status: Int?) -> Bool {
        status == 404 || status == 410
    }
}

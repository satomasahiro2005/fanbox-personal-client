import Foundation
import Observation

/// Destinations the account-aware WebView can open (SPEC §14 / §40).
enum WebDestination: Hashable, Sendable {
    case login
    case home
    case post(creatorID: String, postID: String)
    case creator(creatorID: String)
    case creatorPlans(creatorID: String)
    case plan(creatorID: String, planID: String)
    /// Supporting plans list (支援中のプラン).
    case supportingPlans
    /// Payment method settings (card / PayPal).
    case paymentSettings
    case paymentHistory
    case notifications
    case newsletter(id: String?)
    case managePosts
    /// nil = new post.
    case managePostEditor(postID: String?)
    case manageRelationships
    case managePlans
    case manageDashboard
    case url(URL)

    /// Resolved web URL (see docs/API.md "Web fallback URLs").
    var url: URL {
        let base = "https://www.fanbox.cc"
        let s: String
        switch self {
        case .login: s = "\(base)/login"
        case .home: s = "\(base)/"
        case .post(let creatorID, let postID): s = "\(base)/@\(creatorID)/posts/\(postID)"
        case .creator(let creatorID): s = "\(base)/@\(creatorID)"
        case .creatorPlans(let creatorID): s = "\(base)/@\(creatorID)/plans"
        case .plan(let creatorID, let planID): s = "\(base)/@\(creatorID)/plans/\(planID)"
        case .supportingPlans: s = "\(base)/creators/supporting"
        case .paymentSettings: s = "\(base)/user/settings/payment"
        case .paymentHistory: s = "\(base)/user/payments"
        case .notifications: s = "\(base)/notifications"
        case .newsletter(let id): s = id.map { "\(base)/messages/\($0)" } ?? "\(base)/messages"
        case .managePosts: s = "\(base)/manage/posts"
        case .managePostEditor(let postID): s = postID.map { "\(base)/manage/posts/\($0)" } ?? "\(base)/manage/posts/new"
        case .manageRelationships: s = "\(base)/manage/relationships"
        case .managePlans: s = "\(base)/manage/plans"
        case .manageDashboard: s = "\(base)/manage/dashboard"
        case .url(let url): return url
        }
        return URL(string: s) ?? URL(string: base)!
    }

    var title: String {
        switch self {
        case .login: return "ログイン"
        case .home: return "FANBOX"
        case .post: return "投稿"
        case .creator: return "クリエイター"
        case .creatorPlans, .plan: return "プラン"
        case .supportingPlans: return "支援中のプラン"
        case .paymentSettings: return "お支払い方法"
        case .paymentHistory: return "お支払い履歴"
        case .notifications: return "通知"
        case .newsletter: return "おたより"
        case .managePosts: return "投稿管理"
        case .managePostEditor: return "投稿エディタ"
        case .manageRelationships: return "ファン管理"
        case .managePlans: return "プラン管理"
        case .manageDashboard: return "ダッシュボード"
        case .url: return "Web"
        }
    }
}

enum WebPurpose: Hashable, Sendable {
    case browse
    case login
    /// Payment / plan flow — after dismissal supports are re-synced (SPEC §14 "状態再同期").
    case payment
    /// Native operation unavailable or failed; web is the fallback.
    case fallback(reason: String)
}

struct WebSessionRequest: Identifiable, Hashable, Sendable {
    let id = UUID()
    var accountID: String
    var destination: WebDestination
    var purpose: WebPurpose
}

/// `openWeb(account:destination:)` entry point (SPEC §40). Presents an account-aware WKWebView
/// (never plain Safari) that keeps the selected account's login state.
@MainActor
@Observable
final class WebBridge {
    var presented: WebSessionRequest?
    /// Called after a web session is dismissed (e.g. to re-sync supports after a payment flow).
    @ObservationIgnored var onDismiss: ((WebSessionRequest) -> Void)?

    init() {}

    func openWeb(account accountID: String, destination: WebDestination, purpose: WebPurpose = .browse) {
        presented = WebSessionRequest(accountID: accountID, destination: destination, purpose: purpose)
    }

    func dismiss() {
        guard let request = presented else { return }
        presented = nil
        onDismiss?(request)
    }
}

import Foundation
import Observation
import SwiftUI

/// SPEC §4 main tabs.
enum AppTab: String, Hashable, CaseIterable {
    case home, creators, support, creatorMode, library

    var title: String {
        switch self {
        case .home: return "ホーム"
        case .creators: return "クリエイター"
        case .support: return "支援"
        case .creatorMode: return "Creator"
        case .library: return "ライブラリ"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .creators: return "person.2"
        case .support: return "yensign.circle"
        case .creatorMode: return "paintbrush.pointed"
        case .library: return "books.vertical"
        }
    }
}

/// Navigation destinations shared by all tabs. Mapped to views in `AppRouteDestination`.
enum AppRoute: Hashable {
    case post(postID: String)
    case creator(creatorID: String)
    case comments(postID: String, focusCommentID: String?)
    case newsletter(newsletterID: String)
    case notificationInbox
    case supportCreator(creatorID: String)
    case supportAccount(accountID: String)
    /// Every observed payment of one account (all months).
    case paymentRecords(accountID: String)
    case supportHistory
    case paymentProfiles
    case draft(draftID: String)
    case creatorComments
    case fans
    case plans(creatorID: String)
    case offlineLibrary
    case search(query: String)
    case tag(name: String)
}

@MainActor
@Observable
final class AppRouter {
    var selectedTab: AppTab = .home
    var homePath = NavigationPath()
    var creatorsPath = NavigationPath()
    var supportPath = NavigationPath()
    var creatorModePath = NavigationPath()
    var libraryPath = NavigationPath()
    var isSettingsPresented = false
    var isNotificationInboxPresented = false

    init() {}

    /// Debug / screenshot hooks read from launch arguments (UserDefaults argument domain), e.g.
    /// `-initialTab support`, `-openRoute post:<id>` / `creator:<id>` / `comments:<postID>`, `-openSheet settings|notifications`.
    func applyLaunchArguments(_ defaults: UserDefaults = .standard) {
        if let raw = defaults.string(forKey: "initialTab"), let tab = AppTab(rawValue: raw) {
            selectedTab = tab
        }
        if let raw = defaults.string(forKey: "openRoute"), let route = Self.route(fromLaunchValue: raw) {
            open(route)
        }
        switch defaults.string(forKey: "openSheet") {
        case "settings": isSettingsPresented = true
        case "notifications": isNotificationInboxPresented = true
        default: break
        }
    }

    static func route(fromLaunchValue raw: String) -> AppRoute? {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            switch raw {
            case "supportHistory": return .supportHistory
            case "paymentProfiles": return .paymentProfiles
            case "creatorComments": return .creatorComments
            case "fans": return .fans
            case "offlineLibrary": return .offlineLibrary
            default: return nil
            }
        }
        switch parts[0] {
        case "post": return .post(postID: parts[1])
        case "creator": return .creator(creatorID: parts[1])
        case "comments": return .comments(postID: parts[1], focusCommentID: nil)
        case "newsletter": return .newsletter(newsletterID: parts[1])
        case "supportCreator": return .supportCreator(creatorID: parts[1])
        case "supportAccount": return .supportAccount(accountID: parts[1])
        case "paymentRecords": return .paymentRecords(accountID: parts[1])
        case "draft": return .draft(draftID: parts[1])
        case "plans": return .plans(creatorID: parts[1])
        case "search": return .search(query: parts[1])
        case "tag": return .tag(name: parts[1])
        default: return nil
        }
    }

    func binding(for tab: AppTab) -> Binding<NavigationPath> {
        Binding(
            get: { [unowned self] in self.path(for: tab) },
            set: { [unowned self] in self.setPath($0, for: tab) }
        )
    }

    func path(for tab: AppTab) -> NavigationPath {
        switch tab {
        case .home: return homePath
        case .creators: return creatorsPath
        case .support: return supportPath
        case .creatorMode: return creatorModePath
        case .library: return libraryPath
        }
    }

    func setPath(_ path: NavigationPath, for tab: AppTab) {
        switch tab {
        case .home: homePath = path
        case .creators: creatorsPath = path
        case .support: supportPath = path
        case .creatorMode: creatorModePath = path
        case .library: libraryPath = path
        }
    }

    /// Pushes a route on the given tab (default: current tab) and switches to it.
    func open(_ route: AppRoute, in tab: AppTab? = nil) {
        let target = tab ?? selectedTab
        var p = path(for: target)
        p.append(route)
        setPath(p, for: target)
        selectedTab = target
    }

    /// Opens a route from a notification tap: dismiss sheets, reset the home stack and push immediately (local render).
    func openFromNotification(_ route: AppRoute) {
        isSettingsPresented = false
        isNotificationInboxPresented = false
        var p = NavigationPath()
        p.append(route)
        homePath = p
        selectedTab = .home
    }
}

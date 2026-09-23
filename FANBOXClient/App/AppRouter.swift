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

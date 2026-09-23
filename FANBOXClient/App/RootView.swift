import SwiftUI

/// SPEC §4: TabView (ホーム / クリエイター / 支援 / Creator / ライブラリ). Settings open from the navigation bar.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            Tab(AppTab.home.title, systemImage: AppTab.home.systemImage, value: AppTab.home) {
                TabStack(tab: .home) { HomeRootView() }
            }
            Tab(AppTab.creators.title, systemImage: AppTab.creators.systemImage, value: AppTab.creators) {
                TabStack(tab: .creators) { CreatorsRootView() }
            }
            Tab(AppTab.support.title, systemImage: AppTab.support.systemImage, value: AppTab.support) {
                TabStack(tab: .support) { SupportRootView() }
            }
            Tab(AppTab.creatorMode.title, systemImage: AppTab.creatorMode.systemImage, value: AppTab.creatorMode) {
                TabStack(tab: .creatorMode) { CreatorModeRootView() }
            }
            Tab(AppTab.library.title, systemImage: AppTab.library.systemImage, value: AppTab.library) {
                TabStack(tab: .library) { LibraryRootView() }
            }
        }
        .sheet(isPresented: $router.isSettingsPresented) {
            NavigationStack { SettingsRootView() }
        }
        .sheet(isPresented: $router.isNotificationInboxPresented) {
            NavigationStack { NotificationInboxView() }
        }
        .modifier(WebBridgePresenter())
    }
}

/// NavigationStack bound to the router path of one tab, with shared route destinations and toolbar.
struct TabStack<Content: View>: View {
    let tab: AppTab
    @ViewBuilder var content: () -> Content
    @Environment(AppRouter.self) private var router

    var body: some View {
        NavigationStack(path: router.binding(for: tab)) {
            content()
                .navigationDestination(for: AppRoute.self) { route in
                    AppRouteDestination(route: route)
                }
                .toolbar { GlobalToolbar() }
        }
    }
}

/// Bell (notification inbox) + settings buttons available on every tab root.
struct GlobalToolbar: ToolbarContent {
    @Environment(AppRouter.self) private var router

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            NotificationBellButton()
            Button {
                router.isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("設定")
            .accessibilityIdentifier("settingsButton")
        }
    }
}

/// Maps `AppRoute` to feature views.
struct AppRouteDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .post(let postID): PostDetailView(postID: postID)
        case .creator(let creatorID): CreatorDetailView(creatorID: creatorID)
        case .comments(let postID, let focus): CommentThreadView(postID: postID, focusCommentID: focus)
        case .newsletter(let id): NewsletterDetailView(newsletterID: id)
        case .notificationInbox: NotificationInboxView()
        case .supportCreator(let creatorID): SupportCreatorDetailView(creatorID: creatorID)
        case .supportAccount(let accountID): SupportAccountDetailView(accountID: accountID)
        case .supportHistory: SupportHistoryView()
        case .paymentProfiles: PaymentProfilesView()
        case .draft(let draftID): DraftEditorView(draftID: draftID)
        case .creatorComments: CreatorCommentsView()
        case .fans: FansView()
        case .plans(let creatorID): CreatorPlansView(creatorID: creatorID)
        case .offlineLibrary: OfflineLibraryView()
        case .search(let query): LibrarySearchView(initialQuery: query)
        case .tag(let name): TaggedPostsView(tagName: name)
        }
    }
}

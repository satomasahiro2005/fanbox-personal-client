import SwiftUI
import SwiftData
import UIKit

@main
struct FANBOXClientApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var env: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let env = AppEnvironment.live()
        _env = State(initialValue: env)
        AppDelegate.environment = env
        // Registration must happen before launch completes (BGTaskScheduler requirement).
        BackgroundRefresh.register { AppDelegate.environment }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .environment(env.router)
                .environment(env.settings)
                .modelContainer(env.container)
                .task {
                    // Local DB first → UI is already on screen. Network work starts afterwards (SPEC §3.1).
                    env.networkMode.start()
                    env.notifications.configure()
                    env.coordinator.start()
                    RemoteRelay.shared.registerIfEnabled(settings: env.settings)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            env.coordinator.scenePhaseChanged(phase)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var environment: AppEnvironment?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in RemoteRelay.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in RemoteRelay.shared.didFailToRegister(error: error) }
    }

    /// Silent push from the optional relay (SPEC §28): fetch directly from FANBOX, then notify locally.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            guard let env = AppDelegate.environment else {
                completionHandler(.noData)
                return
            }
            completionHandler(await RemoteRelay.shared.handleSilentPush(environment: env))
        }
    }
}

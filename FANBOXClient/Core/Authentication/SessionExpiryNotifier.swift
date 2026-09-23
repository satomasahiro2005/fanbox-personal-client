import Foundation
import UserNotifications

/// Posts ONE local notification when a FANBOX account's session moves to `.expired` (SPEC §44 / §7): the user learns
/// about it even while the app is in the background, instead of only seeing failed syncs. The request identifier is
/// per account, so a repeated expiry replaces the previous notice instead of stacking.
enum SessionExpiryNotifier {
    static func identifier(accountID: String) -> String { "session-expired-\(accountID)" }

    static func content(accountName: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "再ログインが必要です"
        content.body = "「\(accountName)」のログインの有効期限が切れました。アプリを開いて再ログインしてください。"
        content.sound = .default
        content.threadIdentifier = "session"
        return content
    }

    @MainActor
    static func notify(accountID: String, accountName: String, enabled: Bool) {
        guard enabled else { return }
        let request = UNNotificationRequest(identifier: identifier(accountID: accountID),
                                            content: content(accountName: accountName), trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLog.auth.notice("session expiry notification not posted: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }
}

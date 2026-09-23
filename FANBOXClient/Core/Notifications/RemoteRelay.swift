import Foundation
import UIKit

/// Optional APNs relay client (SPEC §28). Design: docs/NOTIFICATION_RELAY.md.
/// The relay only sends content-free silent pushes ("something happened for account-hint X");
/// the app then fetches directly from FANBOX with its own session. No FANBOX secret or content is sent to the relay.
///
/// Design notes (v1.0):
/// - Trigger source (relay side, self-hosted, optional): FANBOX official notification mail → mail event detection →
///   private relay → APNs `content-available: 1` push with NO alert text, NO post / comment / supporter content and
///   NO session material. Payload is at most an opaque, rotating account hint.
/// - The relay stores only the APNs device token (sent by the user when enabling the relay). It never receives FANBOXSESSID,
///   cookies, CSRF tokens or any FANBOX response body (SPEC §28 / §38).
/// - App side: a silent push runs `SyncEngine.syncLightweight(reason: .notification)` — notifications first, then supports and
///   the newest timeline page. New events flow through the normal pipeline (text prefetch → local DB → local notification),
///   so the visible notification is always produced on-device from data fetched with the device's own session.
/// - iOS throttles silent pushes; delivery is best-effort and never the only detection path (foreground polling,
///   launch refresh and BGAppRefreshTask remain in place).
/// - Everything is off by default (`AppSettings.remoteRelayEnabled`).
@MainActor
final class RemoteRelay {
    static let shared = RemoteRelay()

    private(set) var deviceToken: String?
    private(set) var lastError: String?
    private(set) var lastPushAt: Date?
    private(set) var lastResult: UIBackgroundFetchResult?

    private init() {}

    func didRegister(deviceToken data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        lastError = nil
    }

    func didFailToRegister(error: Error) {
        lastError = String(describing: error)
    }

    /// Registers for remote notifications only when the user enabled the optional relay.
    func registerIfEnabled(settings: AppSettings) {
        guard settings.remoteRelayEnabled, !settings.remoteRelayURL.isEmpty else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func handleSilentPush(environment: AppEnvironment) async -> UIBackgroundFetchResult {
        lastPushAt = .now
        guard environment.sync.canReachNetwork else {
            lastResult = .failed
            return .failed
        }
        let outcomes = await environment.sync.syncLightweightOutcomes(reason: .notification)
        await environment.replies.flush()
        let result = Self.fetchResult(for: outcomes)
        lastResult = result
        return result
    }

    /// `.newData` when anything new was stored, `.failed` when every request failed, otherwise `.noData`.
    static func fetchResult(for outcomes: [SyncOutcome]) -> UIBackgroundFetchResult {
        if outcomes.contains(where: { !$0.newItemIDs.isEmpty }) { return .newData }
        if !outcomes.isEmpty && outcomes.allSatisfy({ $0.error != nil }) { return .failed }
        return .noData
    }
}

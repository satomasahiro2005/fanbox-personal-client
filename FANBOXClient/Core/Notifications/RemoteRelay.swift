import Foundation
import UIKit

/// Optional APNs relay client (SPEC §28). Design: docs/NOTIFICATION_RELAY.md.
/// The relay only sends content-free silent pushes ("something happened for account-hint X");
/// the app then fetches directly from FANBOX with its own session. No FANBOX secret or content is sent to the relay.
@MainActor
final class RemoteRelay {
    static let shared = RemoteRelay()

    private(set) var deviceToken: String?
    private(set) var lastError: String?

    private init() {}

    func didRegister(deviceToken data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
    }

    func didFailToRegister(error: Error) {
        lastError = String(describing: error)
    }

    func handleSilentPush(environment: AppEnvironment) async -> UIBackgroundFetchResult { .noData }
}

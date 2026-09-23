import Foundation
import Observation
import SwiftUI

/// Schedules sync work: launch refresh (after the first frame, never blocking UI), foreground polling,
/// scene-phase handling and BackgroundTasks refresh (SPEC §3.1 / §28 / §35).
@MainActor
@Observable
final class SyncCoordinator {
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?
    private(set) var lastError: RemoteError?

    @ObservationIgnored let engine: SyncEngine
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let network: NetworkModeController
    @ObservationIgnored let replies: ReplyQueue

    init(engine: SyncEngine, settings: AppSettings, network: NetworkModeController, replies: ReplyQueue) {
        self.engine = engine
        self.settings = settings
        self.network = network
        self.replies = replies
    }

    /// Called once after the first frame is on screen.
    func start() {}

    func scenePhaseChanged(_ phase: ScenePhase) {}

    /// Pull-to-refresh.
    func refreshNow() async {}
}

/// BGAppRefreshTask integration (SPEC §35).
enum BackgroundRefresh {
    static let refreshTaskID = "ai.nemut.FANBOXClient.refresh"
    static let maintenanceTaskID = "ai.nemut.FANBOXClient.maintenance"

    /// Must be called before the app finishes launching.
    @MainActor
    static func register(environment: @escaping @MainActor () -> AppEnvironment?) {}

    static func schedule() {}
}

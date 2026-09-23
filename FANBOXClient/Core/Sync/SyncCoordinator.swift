import BackgroundTasks
import Foundation
import Observation
import os
import SwiftData
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

    /// Every Nth polling tick also refreshes the newest timeline page (lightweight).
    static let timelineEveryNthTick = 5
    /// Lower bound so a misconfigured interval never hammers FANBOX.
    static let minimumPollingInterval: TimeInterval = 15

    @ObservationIgnored private var started = false
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private(set) var pollTickCount = 0

    init(engine: SyncEngine, settings: AppSettings, network: NetworkModeController, replies: ReplyQueue) {
        self.engine = engine
        self.settings = settings
        self.network = network
        self.replies = replies
    }

    var isPolling: Bool { pollingTask != nil }

    /// Called once after the first frame is on screen.
    func start() {
        guard !started else { return }
        started = true
        // The UI already renders from the local DB; the network refresh runs afterwards (SPEC §3.1).
        Task { [weak self] in
            guard let self else { return }
            await self.engine.syncAll(reason: .appLaunch)
            self.absorbEngineState()
            await self.replies.flush()
        }
        startPolling()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            guard started else { return }
            startPolling()
            Task { [weak self] in
                guard let self else { return }
                await self.refreshNotifications(reason: .foregroundPolling)
                await self.replies.flush()
            }
        case .background:
            stopPolling()
            BackgroundRefresh.schedule()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// Pull-to-refresh.
    func refreshNow() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await engine.syncAll(reason: .userRefresh)
        absorbEngineState()
        await replies.flush()
    }

    /// One foreground polling step: notifications for all accounts + reply flush; every Nth tick the newest timeline page.
    func pollOnce() async {
        pollTickCount += 1
        guard engine.canReachNetwork else { return }
        await refreshNotifications(reason: .foregroundPolling)
        await replies.flush()
        if pollTickCount % Self.timelineEveryNthTick == 0 {
            await forEachAccount { engine, accountID in
                await engine.sync(.timeline, accountID: accountID, reason: .foregroundPolling)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Private

    private func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = max(Self.minimumPollingInterval, self?.settings.foregroundPollingInterval ?? 60)
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.pollOnce()
            }
        }
    }

    private func refreshNotifications(reason: SyncReason) async {
        await forEachAccount { engine, accountID in
            await engine.sync(.notifications, accountID: accountID, reason: reason)
        }
    }

    private func forEachAccount(_ body: @escaping @MainActor (SyncEngine, String) async -> Void) async {
        let ids = engine.store.accounts().map(\.id)
        let engine = self.engine
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { @MainActor in await body(engine, id) }
            }
        }
    }

    private func absorbEngineState() {
        lastError = engine.lastError
        if let at = engine.lastSuccessAt { lastRefreshAt = at }
    }
}

/// BGAppRefreshTask / BGProcessingTask integration (SPEC §35).
enum BackgroundRefresh {
    static let refreshTaskID = "ai.nemut.FANBOXClient.refresh"
    static let maintenanceTaskID = "ai.nemut.FANBOXClient.maintenance"
    /// SPEC §35: lightweight refresh no more often than every 15 minutes (iOS decides the real time).
    static let refreshInterval: TimeInterval = 15 * 60
    static let maintenanceInterval: TimeInterval = 12 * 60 * 60
    /// Research logs older than this are pruned by the maintenance task.
    static let researchLogRetention: TimeInterval = 14 * 24 * 60 * 60

    @MainActor private static var registered = false

    /// Must be called before the app finishes launching.
    @MainActor
    static func register(environment: @escaping @MainActor () -> AppEnvironment?) {
        guard !registered else { return }       // BGTaskScheduler traps on duplicate registration.
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: .main) { task in
            MainActor.assumeIsolated {
                handleRefresh(task, environment: environment())
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: maintenanceTaskID, using: .main) { task in
            MainActor.assumeIsolated {
                handleMaintenance(task, environment: environment())
            }
        }
    }

    static func schedule() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: refreshInterval)
        submit(refresh)

        let maintenance = BGProcessingTaskRequest(identifier: maintenanceTaskID)
        maintenance.earliestBeginDate = Date(timeIntervalSinceNow: maintenanceInterval)
        maintenance.requiresNetworkConnectivity = false
        maintenance.requiresExternalPower = false
        submit(maintenance)
    }

    private static func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator / Background App Refresh disabled: not fatal.
            AppLog.sync.info("BGTask submit skipped for \(request.identifier, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    @MainActor
    private static func handleRefresh(_ task: BGTask, environment env: AppEnvironment?) {
        schedule()      // keep the chain going
        guard let env else {
            task.setTaskCompleted(success: false)
            return
        }
        let completion = TaskCompletion(task)
        let work = Task { @MainActor in
            let outcomes = await env.sync.syncLightweightOutcomes(reason: .backgroundRefresh)
            await env.replies.flush()
            let failed = !outcomes.isEmpty && outcomes.allSatisfy { $0.error != nil }
            completion.complete(success: !failed && !Task.isCancelled)
        }
        task.expirationHandler = {
            work.cancel()
            completion.complete(success: false)
        }
    }

    @MainActor
    private static func handleMaintenance(_ task: BGTask, environment env: AppEnvironment?) {
        guard let env else {
            task.setTaskCompleted(success: false)
            return
        }
        let completion = TaskCompletion(task)
        let work = Task { @MainActor in
            env.media.enforceCapacity()
            env.store.maintenancePruneResearchLogs(before: Date(timeIntervalSinceNow: -researchLogRetention))
            completion.complete(success: !Task.isCancelled)
        }
        task.expirationHandler = {
            work.cancel()
            completion.complete(success: false)
        }
    }

    /// Calls `setTaskCompleted` exactly once, from whichever side (work / expiration) finishes first.
    private final class TaskCompletion: @unchecked Sendable {
        private let task: BGTask
        private let done = OSAllocatedUnfairLock(initialState: false)

        init(_ task: BGTask) { self.task = task }

        func complete(success: Bool) {
            let first = done.withLock { (flag: inout Bool) -> Bool in
                if flag { return false }
                flag = true
                return true
            }
            if first { task.setTaskCompleted(success: success) }
        }
    }
}

import Foundation

extension SyncEngine {
    /// SPEC §11 `observedSource` of the SupportHistory rows written by a `.supports` sync.
    /// `.afterWrite` is the re-sync after an account-aware payment web session (SPEC §14, `PaymentResyncScheduler`), so
    /// its observations are labeled "Web 操作後に観測".
    nonisolated static func supportObservedSource(reason: SyncReason, kind: AccountKind) -> ObservedSource {
        if kind == .demo { return .demo }
        switch reason {
        case .backgroundRefresh: return .backgroundSync
        case .notification: return .notification
        case .afterWrite: return .webBridge
        case .appLaunch, .foregroundPolling, .userRefresh, .onDemand: return .sync
        }
    }
}

/// SPEC §14 "状態再同期" after a payment web session.
///
/// Supports are re-synced right after the web session closes. FANBOX can take a while to list a new or changed support
/// (activation can take up to ~15 minutes, docs/API.md §18.10), so a few follow-up checks run later while the app is
/// alive; they stop at the first one that observes a change. A new session of the same account restarts the schedule.
/// All syncs use `.afterWrite`, so resulting history rows are labeled `.webBridge`.
@MainActor
final class PaymentResyncScheduler {
    /// Delays of the follow-up checks, counted from the previous check.
    nonisolated static let followUpDelays: [Duration] = [.seconds(60), .seconds(4 * 60), .seconds(10 * 60)]

    typealias SyncSupports = @MainActor (_ accountID: String) async -> SyncOutcome
    typealias Sleep = @Sendable (_ duration: Duration) async throws -> Void

    private let syncSupports: SyncSupports
    private let sleep: Sleep
    private let delays: [Duration]
    private var tasks: [String: Task<Void, Never>] = [:]

    init(delays: [Duration] = PaymentResyncScheduler.followUpDelays,
         sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
         syncSupports: @escaping SyncSupports) {
        self.delays = delays
        self.sleep = sleep
        self.syncSupports = syncSupports
    }

    convenience init(engine: SyncEngine) {
        self.init { [weak engine] accountID in
            guard let engine else { return .skipped(.supports, accountID: accountID) }
            return await engine.sync(.supports, accountID: accountID, reason: .afterWrite)
        }
    }

    /// True while follow-up checks are pending for the account.
    func isScheduled(accountID: String) -> Bool { tasks[accountID] != nil }

    /// Destinations on which the user can start, stop or change a support; only these get follow-up checks.
    /// Payment settings / history only get the immediate re-sync.
    static func expectsSupportChange(_ destination: WebDestination) -> Bool {
        switch destination {
        case .plan, .creatorPlans, .supportingPlans, .creator: return true
        default: return false
        }
    }

    /// Re-sync after the payment web session of `request` closed.
    @discardableResult
    func handleDismissedPaymentSession(_ request: WebSessionRequest) -> Task<Void, Never>? {
        guard case .payment = request.purpose else { return nil }
        return start(accountID: request.accountID, followUps: Self.expectsSupportChange(request.destination))
    }

    /// Immediate re-sync, then (optionally) follow-ups until one observes a change. Returns the task (tests await it).
    @discardableResult
    func start(accountID: String, followUps: Bool = true) -> Task<Void, Never> {
        tasks[accountID]?.cancel()
        let delays = followUps ? self.delays : []
        let sleep = self.sleep
        let syncSupports = self.syncSupports
        let task = Task { @MainActor [weak self] in
            var outcome = await syncSupports(accountID)
            for delay in delays {
                if outcome.error == nil && !outcome.newItemIDs.isEmpty { break }   // FANBOX already reflects a change
                do { try await sleep(delay) } catch { break }
                if Task.isCancelled { break }
                outcome = await syncSupports(accountID)
            }
            if !Task.isCancelled { self?.tasks[accountID] = nil }
        }
        tasks[accountID] = task
        return task
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
    }
}

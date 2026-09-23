import Foundation

/// Explicit request priority classes (SPEC §29). Higher value wins.
enum RequestPriority: Int, Comparable, CaseIterable, Sendable {
    case interactiveWrite = 100
    case interactiveRead = 90
    case notificationPrefetch = 80
    case foregroundMedia = 50
    case backgroundSync = 20
    case mediaPrefetch = 5

    static func < (lhs: RequestPriority, rhs: RequestPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    var isMedia: Bool { self == .foregroundMedia || self == .mediaPrefetch }
    var isInteractive: Bool { self == .interactiveWrite || self == .interactiveRead }

    /// Mapping to `URLSessionTask.priority` (0...1).
    var urlSessionTaskPriority: Float {
        switch self {
        case .interactiveWrite: return URLSessionTask.highPriority
        case .interactiveRead: return 0.9
        case .notificationPrefetch: return 0.8
        case .foregroundMedia: return URLSessionTask.defaultPriority
        case .backgroundSync: return 0.2
        case .mediaPrefetch: return URLSessionTask.lowPriority
        }
    }

    var displayName: String {
        switch self {
        case .interactiveWrite: return "interactiveWrite"
        case .interactiveRead: return "interactiveRead"
        case .notificationPrefetch: return "notificationPrefetch"
        case .foregroundMedia: return "foregroundMedia"
        case .backgroundSync: return "backgroundSync"
        case .mediaPrefetch: return "mediaPrefetch"
        }
    }

    /// Classes that pause media while they are in flight ("Text-first", SPEC §29).
    var pausesMedia: Bool { isInteractive || self == .notificationPrefetch }

    /// Transfers at or below this priority are suspended while text-first work runs.
    var isPausableTransferClass: Bool { self <= .foregroundMedia }
}

/// Handle for a registered long-running transfer.
struct TransferToken: Hashable, Sendable {
    let id: UUID
}

/// A long-running transfer the scheduler can pause while text-first requests run, and cancel when the app switches to
/// Offline. `URLSessionTask` conforms.
protocol PausableTransfer: AnyObject, Sendable {
    func suspend()
    func resume()
    func cancel()
}

extension PausableTransfer {
    /// Default for transfers that cannot be cancelled (test doubles).
    func cancel() {}
}

extension URLSessionTask: PausableTransfer {}

/// Admission limits (SPEC §29). Interactive classes are never limited.
struct SchedulerLimits: Sendable, Equatable {
    /// Overall cap for non-interactive requests in flight.
    var maxConcurrent: Int
    /// Per-class caps; classes missing here are only bounded by `maxConcurrent`.
    var perClass: [RequestPriority: Int]
    /// SPEC §46 "Thumbnail → Display Image → Original / Video / Attachment": at most this many large media transfers
    /// (originals, video, audio, attachments, uploads — see `MediaSizeClass`) hold foregroundMedia slots at once, so
    /// thumbnails and display images always keep the remaining slots. nil = no separate cap.
    var largeMediaCap: Int? = 1

    static let `default` = SchedulerLimits(maxConcurrent: 6, perClass: [
        .notificationPrefetch: 3,
        .foregroundMedia: 3,
        .backgroundSync: 2,
        .mediaPrefetch: 1,
    ])
}

/// Size class of a media request, derived from its scheduler label (`media.<variant>` endpoint keys, SPEC §46).
enum MediaSizeClass: Int, Comparable, Sendable {
    case thumbnail = 0
    case display = 1
    /// Originals, attachments (files / audio / video share `media.original`) and uploads.
    case large = 2

    static func < (lhs: MediaSizeClass, rhs: MediaSizeClass) -> Bool { lhs.rawValue < rhs.rawValue }

    /// nil for non-media priorities (the size class only orders media admissions).
    static func of(label: String, priority: RequestPriority) -> MediaSizeClass? {
        guard priority.isMedia else { return nil }
        switch label {
        case "media.thumbnail": return .thumbnail
        case "media.display": return .display
        default: return .large
        }
    }
}

/// Text-first network scheduler (SPEC §29).
///
/// - Every HTTP request runs through `run(_:label:operation:)`.
/// - Interactive requests are admitted immediately; lower classes wait for free slots in a queue ordered by
///   priority, then FIFO. Caps: overall 6 (non-interactive), notificationPrefetch 3, foregroundMedia 3, backgroundSync 2,
///   mediaPrefetch 1. notificationPrefetch does not count media against the overall cap (media is paused meanwhile).
/// - While any interactive / notification request is in flight, no new media request is admitted and registered media
///   transfers (priority ≤ foregroundMedia) are suspended (`URLSessionTask.suspend()`); they resume when none remain
///   ("Media pause / deprioritize → Comment POST → Resume Media").
/// - In Offline mode every request fails fast with `RemoteError.offline`; queued waiters are failed when the mode
///   switches to Offline.
/// - Cancelling the calling Task while it waits removes it from the queue and throws `RemoteError.cancelled`.
/// - Re-entrant calls (an operation that itself calls `run`) bypass admission to avoid self-deadlock.
actor NetworkScheduler {
    let policy: NetworkPolicyStore
    let limits: SchedulerLimits

    private struct Waiter {
        let id: UInt64
        let priority: RequestPriority
        let label: String
        let size: MediaSizeClass?
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct Transfer {
        let transfer: PausableTransfer
        let priority: RequestPriority
        var suspended: Bool
    }

    private var active: [RequestPriority: Int] = [:]
    /// Large media transfers in flight (subset of the media classes, see `SchedulerLimits.largeMediaCap`).
    private var activeLarge = 0
    private var waiters: [Waiter] = []
    private var transfers: [TransferToken: Transfer] = [:]
    private var nextWaiterID: UInt64 = 0
    private var observerToken: UUID?

    @TaskLocal static var isAdmitted = false

    init(policy: NetworkPolicyStore) {
        self.init(policy: policy, limits: .default)
    }

    init(policy: NetworkPolicyStore, limits: SchedulerLimits) {
        self.policy = policy
        self.limits = limits
    }

    deinit {
        if let observerToken { policy.removeObserver(observerToken) }
    }

    /// Runs `operation` under the given priority class.
    func run<T: Sendable>(_ priority: RequestPriority, label: String,
                          operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard policy.current.allowsNetwork else { throw RemoteError.offline }
        observePolicyIfNeeded()
        if Self.isAdmitted {
            // Nested call from inside an admitted operation: it already holds a slot.
            return try await operation()
        }
        let size = MediaSizeClass.of(label: label, priority: priority)
        try await acquire(priority, label: label, size: size)
        do {
            let value = try await Self.$isAdmitted.withValue(true) { try await operation() }
            release(priority, size: size)
            return value
        } catch {
            release(priority, size: size)
            throw error
        }
    }

    /// Registers a media transfer so it can be paused while interactive requests run.
    func register(task: URLSessionTask, priority: RequestPriority) -> TransferToken {
        register(transfer: task, priority: priority)
    }

    /// Registers any pausable transfer. Transfers with priority ≤ foregroundMedia are suspended immediately when
    /// text-first work is in flight.
    func register(transfer: PausableTransfer, priority: RequestPriority) -> TransferToken {
        let token = TransferToken(id: UUID())
        var entry = Transfer(transfer: transfer, priority: priority, suspended: false)
        if priority.isPausableTransferClass && textFirstInFlight {
            transfer.suspend()
            entry.suspended = true
        }
        transfers[token] = entry
        return token
    }

    /// Forgets a transfer (after it finished). A still-suspended transfer is resumed so it can complete or cancel.
    func unregister(_ token: TransferToken) {
        guard let entry = transfers.removeValue(forKey: token) else { return }
        if entry.suspended { entry.transfer.resume() }
    }

    /// Number of requests currently running per priority (Research Mode display).
    func snapshot() -> [RequestPriority: Int] { active.filter { $0.value > 0 } }

    /// Number of requests waiting for admission per priority.
    func queuedSnapshot() -> [RequestPriority: Int] {
        var result: [RequestPriority: Int] = [:]
        for w in waiters { result[w.priority, default: 0] += 1 }
        return result
    }

    /// Labels of queued requests in admission order (Research Mode display / tests).
    func queuedLabels() -> [String] { orderedWaiters().map(\.label) }

    /// (registered, suspended) transfer counts.
    func transferCounts() -> (registered: Int, suspended: Int) {
        (transfers.count, transfers.values.filter(\.suspended).count)
    }

    /// Fails every queued request with `.offline` when the policy no longer allows network access.
    func failQueuedIfOffline() {
        guard !policy.current.allowsNetwork, !waiters.isEmpty else { return }
        let failed = waiters
        waiters.removeAll()
        for w in failed { w.continuation.resume(throwing: RemoteError.offline) }
    }

    /// SPEC §30 Offline ("ネットワーク通信を完全停止する"): cancels every registered long-running transfer (downloads /
    /// uploads) when the policy no longer allows network access. The transport reports them as `.offline`.
    /// Admitted writes (`interactiveWrite`) are never cancelled: the server outcome would become ambiguous.
    func cancelTransfersIfOffline() {
        guard !policy.current.allowsNetwork else { return }
        for (token, entry) in transfers where entry.priority != .interactiveWrite {
            transfers.removeValue(forKey: token)
            entry.transfer.cancel()
            if entry.suspended { entry.transfer.resume() }
        }
    }

    /// Makes sure the Offline observer is installed (the transport calls this when it registers a transfer).
    func ensureObservingPolicy() { observePolicyIfNeeded() }

    // MARK: - Admission

    /// Fails queued waiters and cancels registered transfers as soon as the mode switches to Offline
    /// (registered lazily; actor inits cannot escape self).
    private func observePolicyIfNeeded() {
        guard observerToken == nil else { return }
        observerToken = policy.addObserver { [weak self] snapshot in
            guard !snapshot.allowsNetwork, let self else { return }
            Task {
                await self.failQueuedIfOffline()
                await self.cancelTransfersIfOffline()
            }
        }
    }

    private var textFirstInFlight: Bool {
        RequestPriority.allCases.contains { $0.pausesMedia && (active[$0] ?? 0) > 0 }
    }

    private func count(_ p: RequestPriority) -> Int { active[p] ?? 0 }

    private func canAdmit(_ priority: RequestPriority, size: MediaSizeClass? = nil) -> Bool {
        if priority.isInteractive { return true }
        if priority.isMedia && textFirstInFlight { return false }
        if let cap = limits.perClass[priority], count(priority) >= cap { return false }
        if size == .large, let cap = limits.largeMediaCap, activeLarge >= cap { return false }
        let nonInteractive = RequestPriority.allCases.filter { !$0.isInteractive }.reduce(0) { $0 + count($1) }
        if priority == .notificationPrefetch {
            let media = count(.foregroundMedia) + count(.mediaPrefetch)
            return nonInteractive - media < limits.maxConcurrent
        }
        return nonInteractive < limits.maxConcurrent
    }

    private func acquire(_ priority: RequestPriority, label: String, size: MediaSizeClass?) async throws {
        // Queued smaller media go first: a new large transfer never overtakes waiting thumbnails / display images.
        let smallerWaiting = size == .large && waiters.contains { $0.priority == priority && ($0.size ?? .large) < .large }
        if !smallerWaiting && canAdmit(priority, size: size) {
            admit(priority, size: size)
            return
        }
        nextWaiterID &+= 1
        let id = nextWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: RemoteError.cancelled)
                    return
                }
                waiters.append(Waiter(id: id, priority: priority, label: label, size: size, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: RemoteError.cancelled)
    }

    private func admit(_ priority: RequestPriority, size: MediaSizeClass? = nil) {
        let wasTextFirst = textFirstInFlight
        active[priority, default: 0] += 1
        if size == .large { activeLarge += 1 }
        if priority.pausesMedia && !wasTextFirst {
            suspendMediaTransfers()
        }
    }

    private func release(_ priority: RequestPriority, size: MediaSizeClass? = nil) {
        active[priority] = max(0, count(priority) - 1)
        if size == .large { activeLarge = max(0, activeLarge - 1) }
        if priority.pausesMedia && !textFirstInFlight {
            resumeMediaTransfers()
        }
        pump()
    }

    /// Admits queued waiters in priority-then-FIFO order while slots are available.
    private func pump() {
        guard !waiters.isEmpty else { return }
        guard policy.current.allowsNetwork else {
            failQueuedIfOffline()
            return
        }
        var admittedAny = true
        while admittedAny {
            admittedAny = false
            for waiter in orderedWaiters() where canAdmit(waiter.priority, size: waiter.size) {
                waiters.removeAll { $0.id == waiter.id }
                admit(waiter.priority, size: waiter.size)
                waiter.continuation.resume()
                admittedAny = true
                break
            }
        }
    }

    /// Priority first; within a media class smaller variants first (thumbnail → display → large); then FIFO.
    private func orderedWaiters() -> [Waiter] {
        waiters.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            let sa = a.size ?? .thumbnail, sb = b.size ?? .thumbnail
            if sa != sb { return sa < sb }
            return a.id < b.id
        }
    }

    /// Large media transfers currently admitted (tests / Research Mode).
    func activeLargeMediaCount() -> Int { activeLarge }

    private func suspendMediaTransfers() {
        for (token, entry) in transfers where entry.priority.isPausableTransferClass && !entry.suspended {
            entry.transfer.suspend()
            transfers[token]?.suspended = true
        }
    }

    private func resumeMediaTransfers() {
        for (token, entry) in transfers where entry.suspended {
            entry.transfer.resume()
            transfers[token]?.suspended = false
        }
    }
}

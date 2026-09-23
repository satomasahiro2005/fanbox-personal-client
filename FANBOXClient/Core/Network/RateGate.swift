import Foundation

/// Device-wide FANBOX request budget and circuit breakers (docs/API.md §1.8, SPEC §3.7 / §29 / §40).
///
/// Consulted by `RoutingHTTPClient` before every request to api.fanbox.cc / www.fanbox.cc (both transports), BEFORE the
/// request takes a `NetworkScheduler` slot:
///
/// - **Spacing.** `post.info` / `post.getEditable` ("heavy" lane) start at least `heavySpacing` (1 s) apart, for every
///   priority, device-wide (Cloudflare limits are per IP). Interactive requests are served before queued background
///   ones. Other calls ("light" lane) are spaced `lightSpacing` (0.2 s) apart unless they are interactive.
/// - **Background budget.** backgroundSync / notificationPrefetch may start at most `backgroundHeavyPerMinute` heavy
///   calls per `budgetWindow`; a request that would wait longer than `maxBudgetWait` fails fast with `.rateLimited`.
/// - **429 cooldown.** After a 429 every budgeted call fails fast with `.rateLimited(retryAfter: remaining)` for
///   Retry-After (or `defaultRateLimitCooldown`, 6 min). Interactive requests are not exempt: a 429 is per IP.
/// - **Edge-block breakers.** A native edge block trips a device-wide breaker for that endpoint on the native transport
///   (every account would get the same block); a WebView edge block trips a breaker for that account's WebView
///   transport; WebView blocks on two different accounts within `multiAccountWindow` start a device-wide cooldown
///   (most likely IP-level). Breakers never multiply one block across accounts.
///
/// Time and sleeping are injected so tests run on a virtual clock.
actor RateGate {
    struct Configuration: Sendable {
        var heavySpacing: TimeInterval = 1.0
        var lightSpacing: TimeInterval = 0.2
        var backgroundHeavyPerMinute = 6
        var budgetWindow: TimeInterval = 60
        var maxBudgetWait: TimeInterval = 30
        var defaultRateLimitCooldown: TimeInterval = 360
        var maxCooldown: TimeInterval = 3600
        var nativeEdgeBlockCooldown: TimeInterval = 15 * 60
        var webEdgeBlockCooldown: TimeInterval = 360
        var multiAccountWindow: TimeInterval = 120

        static let standard = Configuration()
    }

    enum Lane: String, Sendable {
        case heavy, light
    }

    /// Endpoints Cloudflare guards most heavily (docs/API.md §1.7 / §1.8).
    static let heavyEndpoints: Set<String> = ["post.info", "post.getEditable"]

    static func lane(for endpointKey: String) -> Lane { heavyEndpoints.contains(endpointKey) ? .heavy : .light }

    /// Research Mode / banner view of the gate.
    struct Snapshot: Sendable, Equatable {
        var cooldownUntil: Date?
        var cooldownReason: String?
        /// "endpoint (native)" / "account (webview)" → until.
        var breakers: [String: Date]
        var queued: Int
        var backgroundHeavyStartsInWindow: Int
    }

    let configuration: Configuration
    private let clock: @Sendable () -> Date
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    private struct Waiter {
        let id: UInt64
        let interactive: Bool
        let background: Bool
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct LaneState {
        var lastStart: Date?
        var waiters: [Waiter] = []
        var wakeScheduled = false
    }

    private struct BreakerKey: Hashable {
        /// nil = device-wide.
        var accountID: String?
        /// "*" = every endpoint.
        var endpointKey: String
        var transport: TransportKind
    }

    private var lanes: [Lane: LaneState] = [:]
    private var backgroundHeavyStarts: [Date] = []
    private var cooldownUntil: Date?
    private var cooldownReason: String?
    private var breakers: [BreakerKey: Date] = [:]
    private var recentWebBlocks: [(accountID: String, at: Date)] = []
    private var nextID: UInt64 = 0

    init(configuration: Configuration = .standard,
         clock: @escaping @Sendable () -> Date = { Date() },
         sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         }) {
        self.configuration = configuration
        self.clock = clock
        self.sleeper = sleeper
    }

    // MARK: - Admission

    /// Waits until the request may start (spacing / budget) or throws `.rateLimited` during a cooldown or when the
    /// background budget is exhausted. Requests to hosts outside the budget pass immediately.
    func admit(endpointKey: String, host: String?, priority: RequestPriority) async throws {
        guard FanboxHostPolicy.isBudgetedHost(host) else { return }
        try checkCooldown()
        let lane = Self.lane(for: endpointKey)
        let interactive = priority.isInteractive
        let background = priority == .backgroundSync || priority == .notificationPrefetch || priority == .mediaPrefetch
        if lane == .light && interactive {
            lanes[lane, default: LaneState()].lastStart = clock()
            return
        }
        nextID &+= 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: RemoteError.cancelled)
                    return
                }
                lanes[lane, default: LaneState()].waiters.append(
                    Waiter(id: id, interactive: interactive, background: background, continuation: continuation))
                pump(lane)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, lane: lane) }
        }
    }

    /// Remaining device-wide cooldown (nil when none).
    func cooldownRemaining() -> TimeInterval? {
        guard let until = cooldownUntil else { return nil }
        let remaining = until.timeIntervalSince(clock())
        if remaining <= 0 {
            cooldownUntil = nil
            cooldownReason = nil
            return nil
        }
        return remaining
    }

    // MARK: - Outcomes

    /// A 429 (any account, any transport): pause every budgeted call device-wide.
    func recordRateLimited(retryAfter: TimeInterval?) {
        let seconds = min(configuration.maxCooldown, max(1, retryAfter ?? configuration.defaultRateLimitCooldown))
        startCooldown(seconds: seconds, reason: "429")
    }

    /// An edge block on `transport` (see the type comment for the scope of each breaker).
    func recordEdgeBlock(accountID: String?, endpointKey: String, transport: TransportKind, retryAfter: TimeInterval?) {
        let now = clock()
        switch transport {
        case .native:
            let seconds = max(configuration.nativeEdgeBlockCooldown, retryAfter ?? 0)
            breakers[BreakerKey(accountID: nil, endpointKey: endpointKey, transport: .native)] = now.addingTimeInterval(seconds)
        case .webView:
            guard let accountID else { return }
            let seconds = max(configuration.webEdgeBlockCooldown, retryAfter ?? 0)
            breakers[BreakerKey(accountID: accountID, endpointKey: "*", transport: .webView)] = now.addingTimeInterval(seconds)
            recentWebBlocks.removeAll { now.timeIntervalSince($0.at) > configuration.multiAccountWindow || $0.accountID == accountID }
            recentWebBlocks.append((accountID, now))
            if Set(recentWebBlocks.map(\.accountID)).count >= 2 {
                startCooldown(seconds: configuration.webEdgeBlockCooldown, reason: "edge-multi-account")
            }
        }
    }

    /// Remaining breaker time for sending `endpointKey` for `accountID` over `transport` (nil = closed).
    func breakerRemaining(accountID: String?, endpointKey: String, transport: TransportKind) -> TimeInterval? {
        let now = clock()
        var keys = [BreakerKey(accountID: nil, endpointKey: endpointKey, transport: transport),
                    BreakerKey(accountID: nil, endpointKey: "*", transport: transport)]
        if let accountID {
            keys.append(BreakerKey(accountID: accountID, endpointKey: endpointKey, transport: transport))
            keys.append(BreakerKey(accountID: accountID, endpointKey: "*", transport: transport))
        }
        var remaining: TimeInterval?
        for key in keys {
            guard let until = breakers[key] else { continue }
            let left = until.timeIntervalSince(now)
            if left <= 0 {
                breakers[key] = nil
            } else {
                remaining = max(remaining ?? 0, left)
            }
        }
        return remaining
    }

    /// Forgets the account's breakers (logout / removal / re-login).
    func reset(accountID: String) {
        breakers = breakers.filter { $0.key.accountID != accountID }
        recentWebBlocks.removeAll { $0.accountID == accountID }
    }

    /// Clears everything (Research Mode "reset").
    func resetAll() {
        breakers.removeAll()
        recentWebBlocks.removeAll()
        cooldownUntil = nil
        cooldownReason = nil
        backgroundHeavyStarts.removeAll()
    }

    func snapshot() -> Snapshot {
        let now = clock()
        _ = cooldownRemaining()
        var named: [String: Date] = [:]
        for (key, until) in breakers where until > now {
            let scope = key.accountID ?? "all"
            named["\(key.endpointKey) · \(scope) (\(key.transport.rawValue))"] = until
        }
        let window = backgroundHeavyStarts.filter { now.timeIntervalSince($0) < configuration.budgetWindow }.count
        return Snapshot(cooldownUntil: cooldownUntil, cooldownReason: cooldownReason, breakers: named,
                        queued: lanes.values.reduce(0) { $0 + $1.waiters.count }, backgroundHeavyStartsInWindow: window)
    }

    // MARK: - Private

    private func startCooldown(seconds: TimeInterval, reason: String) {
        let until = clock().addingTimeInterval(seconds)
        if let current = cooldownUntil, current >= until { return }
        cooldownUntil = until
        cooldownReason = reason
        AppLog.network.notice("FANBOX request cooldown \(Int(seconds), privacy: .public)s (\(reason, privacy: .public))")
        for lane in Array(lanes.keys) { failAll(lane) }
    }

    private func checkCooldown() throws {
        if let remaining = cooldownRemaining() { throw RemoteError.rateLimited(retryAfter: remaining) }
    }

    private func failAll(_ lane: Lane) {
        guard let remaining = cooldownRemaining() else { return }
        let failed = lanes[lane]?.waiters ?? []
        lanes[lane]?.waiters.removeAll()
        for waiter in failed { waiter.continuation.resume(throwing: RemoteError.rateLimited(retryAfter: remaining)) }
    }

    private func spacing(_ lane: Lane) -> TimeInterval {
        lane == .heavy ? configuration.heavySpacing : configuration.lightSpacing
    }

    /// Head of the lane: interactive first, then FIFO.
    private func headIndex(_ lane: Lane) -> Int? {
        guard let waiters = lanes[lane]?.waiters, !waiters.isEmpty else { return nil }
        return waiters.firstIndex(where: \.interactive) ?? 0
    }

    /// Admits due waiters; schedules one wake-up for the next due time.
    private func pump(_ lane: Lane) {
        if cooldownRemaining() != nil {
            failAll(lane)
            return
        }
        while let index = headIndex(lane) {
            let now = clock()
            let head = lanes[lane]!.waiters[index]
            var due = lanes[lane]?.lastStart.map { $0.addingTimeInterval(spacing(lane)) } ?? now
            if lane == .heavy && head.background {
                backgroundHeavyStarts.removeAll { now.timeIntervalSince($0) >= configuration.budgetWindow }
                if backgroundHeavyStarts.count >= configuration.backgroundHeavyPerMinute, let oldest = backgroundHeavyStarts.first {
                    let budgetDue = oldest.addingTimeInterval(configuration.budgetWindow)
                    if budgetDue.timeIntervalSince(now) > configuration.maxBudgetWait {
                        lanes[lane]?.waiters.remove(at: index)
                        head.continuation.resume(throwing: RemoteError.rateLimited(retryAfter: budgetDue.timeIntervalSince(now)))
                        continue
                    }
                    due = max(due, budgetDue)
                }
            }
            if due <= now {
                lanes[lane]?.waiters.remove(at: index)
                lanes[lane]?.lastStart = now
                if lane == .heavy && head.background { backgroundHeavyStarts.append(now) }
                head.continuation.resume()
                continue
            }
            scheduleWake(lane, after: due.timeIntervalSince(now))
            return
        }
    }

    private func scheduleWake(_ lane: Lane, after seconds: TimeInterval) {
        guard lanes[lane]?.wakeScheduled != true else { return }
        lanes[lane]?.wakeScheduled = true
        let sleeper = self.sleeper
        Task {
            try? await sleeper(seconds)
            self.wake(lane)
        }
    }

    private func wake(_ lane: Lane) {
        lanes[lane]?.wakeScheduled = false
        pump(lane)
    }

    private func cancelWaiter(_ id: UInt64, lane: Lane) {
        guard let index = lanes[lane]?.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = lanes[lane]!.waiters.remove(at: index)
        waiter.continuation.resume(throwing: RemoteError.cancelled)
        pump(lane)
    }
}

import XCTest
@testable import FANBOXClient

/// Virtual clock: `sleep` suspends until the test advances time past the wake-up point.
final class FixTransportManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    private var sleepers: [(until: Date, continuation: CheckedContinuation<Void, Never>)] = []

    var now: Date { lock.withLock { current } }
    var pendingSleeps: Int { lock.withLock { sleepers.count } }

    func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock { sleepers.append((current.addingTimeInterval(seconds), continuation)) }
        }
    }

    func advance(_ seconds: TimeInterval) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            current = current.addingTimeInterval(seconds)
            let due = sleepers.filter { $0.until <= current }
            sleepers.removeAll { $0.until <= current }
            return due.map(\.continuation)
        }
        for continuation in ready { continuation.resume() }
    }
}

final class FixTransportRateGateTests: XCTestCase {
    private func makeGate(_ configuration: RateGate.Configuration = .standard) -> (RateGate, FixTransportManualClock) {
        let clock = FixTransportManualClock()
        let gate = RateGate(configuration: configuration, clock: { clock.now }, sleeper: { await clock.sleep($0) })
        return (gate, clock)
    }

    private let api = "api.fanbox.cc"

    func testPostInfoIsSpacedOneSecondDeviceWideAndInteractiveGoesFirst() async throws {
        let (gate, clock) = makeGate()
        let log = NetModLog()
        try await gate.admit(endpointKey: "post.info", host: api, priority: .backgroundSync)
        log.append("bg1")

        let bg2 = Task { try await gate.admit(endpointKey: "post.info", host: self.api, priority: .notificationPrefetch); log.append("bg2") }
        await netModWaitUntil { clock.pendingSleeps == 1 }
        let tap = Task { try await gate.admit(endpointKey: "post.info", host: self.api, priority: .interactiveRead); log.append("tap") }
        await netModWaitUntil { await gate.snapshot().queued == 2 }
        XCTAssertEqual(log.values, ["bg1"], "nothing starts before the spacing elapsed")

        clock.advance(0.5)
        XCTAssertEqual(log.values, ["bg1"])
        clock.advance(0.5)
        await netModWaitUntil { log.values.count == 2 }
        XCTAssertEqual(log.values, ["bg1", "tap"], "the user's tap is served before queued background work")

        await netModWaitUntil { clock.pendingSleeps == 1 }
        clock.advance(1)
        try await bg2.value
        try await tap.value
        XCTAssertEqual(log.values, ["bg1", "tap", "bg2"])
    }

    func testInteractiveLightRequestsAreNotSpaced() async throws {
        let (gate, clock) = makeGate()
        for _ in 0..<5 {
            try await gate.admit(endpointKey: "post.getComments", host: api, priority: .interactiveRead)
        }
        XCTAssertEqual(clock.pendingSleeps, 0)
        // Hosts outside the budget (media) are never gated.
        try await gate.admit(endpointKey: "media.original", host: "downloads.fanbox.cc", priority: .foregroundMedia)
    }

    func testBackgroundPostInfoBudgetFailsFastWhenExhausted() async throws {
        var config = RateGate.Configuration()
        config.heavySpacing = 0
        config.backgroundHeavyPerMinute = 2
        let (gate, _) = makeGate(config)
        try await gate.admit(endpointKey: "post.info", host: api, priority: .backgroundSync)
        try await gate.admit(endpointKey: "post.info", host: api, priority: .notificationPrefetch)
        do {
            try await gate.admit(endpointKey: "post.info", host: api, priority: .backgroundSync)
            XCTFail("budget exhausted")
        } catch let error as RemoteError {
            guard case .rateLimited(let retryAfter) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(retryAfter ?? 0, 60, accuracy: 0.001)
        }
        // Interactive requests do not spend (or wait for) the background budget.
        try await gate.admit(endpointKey: "post.info", host: api, priority: .interactiveRead)
    }

    func testRateLimitStartsDeviceWideCooldownForEveryPriority() async throws {
        let (gate, clock) = makeGate()
        await gate.recordRateLimited(retryAfter: 120)
        for priority in [RequestPriority.interactiveWrite, .interactiveRead, .backgroundSync] {
            do {
                try await gate.admit(endpointKey: "post.addComment", host: api, priority: priority)
                XCTFail("cooldown")
            } catch let error as RemoteError {
                guard case .rateLimited(let retryAfter) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(retryAfter ?? 0, 120, accuracy: 0.001)
            }
        }
        try await gate.admit(endpointKey: "media.display", host: "downloads.fanbox.cc", priority: .foregroundMedia)
        clock.advance(121)
        try await gate.admit(endpointKey: "post.addComment", host: api, priority: .interactiveWrite)

        await gate.recordRateLimited(retryAfter: nil)
        let remaining = await gate.cooldownRemaining()
        XCTAssertEqual(remaining ?? 0, 360, accuracy: 0.001, "6 minutes without Retry-After (docs/API.md §1.8)")
    }

    func testQueuedRequestsFailWhenACooldownStarts() async throws {
        let (gate, clock) = makeGate()
        try await gate.admit(endpointKey: "post.info", host: api, priority: .backgroundSync)
        let waiting = Task { try await gate.admit(endpointKey: "post.info", host: self.api, priority: .backgroundSync) }
        await netModWaitUntil { clock.pendingSleeps == 1 }
        await gate.recordRateLimited(retryAfter: 30)
        do {
            try await waiting.value
            XCTFail("expected rateLimited")
        } catch let error as RemoteError {
            guard case .rateLimited = error else { return XCTFail("\(error)") }
        }
    }

    func testCancellingAQueuedAdmission() async throws {
        let (gate, clock) = makeGate()
        try await gate.admit(endpointKey: "post.info", host: api, priority: .backgroundSync)
        let waiting = Task { try await gate.admit(endpointKey: "post.info", host: self.api, priority: .backgroundSync) }
        await netModWaitUntil { clock.pendingSleeps == 1 }
        waiting.cancel()
        do {
            try await waiting.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? RemoteError, .cancelled)
        }
        let queued = await gate.snapshot().queued
        XCTAssertEqual(queued, 0)
    }

    func testEdgeBlockBreakersDoNotMultiplyAcrossAccounts() async {
        let (gate, clock) = makeGate()
        // Native edge block: device-wide for that endpoint on the native transport only.
        await gate.recordEdgeBlock(accountID: "A", endpointKey: "post.info", transport: .native, retryAfter: nil)
        let nativeB = await gate.breakerRemaining(accountID: "B", endpointKey: "post.info", transport: .native)
        XCTAssertEqual(nativeB ?? 0, 15 * 60, accuracy: 0.001, "account B would get the same block: not sent")
        let otherEndpoint = await gate.breakerRemaining(accountID: "B", endpointKey: "post.listHome", transport: .native)
        XCTAssertNil(otherEndpoint)
        let webB = await gate.breakerRemaining(accountID: "B", endpointKey: "post.info", transport: .webView)
        XCTAssertNil(webB, "the WebView transport stays available")

        // WebView edge block: that account's WebView only…
        await gate.recordEdgeBlock(accountID: "A", endpointKey: "post.info", transport: .webView, retryAfter: nil)
        let webA = await gate.breakerRemaining(accountID: "A", endpointKey: "bell.list", transport: .webView)
        XCTAssertEqual(webA ?? 0, 360, accuracy: 0.001)
        let webBAfter = await gate.breakerRemaining(accountID: "B", endpointKey: "post.info", transport: .webView)
        XCTAssertNil(webBAfter)
        var cooldown = await gate.cooldownRemaining()
        XCTAssertNil(cooldown)

        // …until a second account is blocked too: most likely IP-level → device-wide pause.
        clock.advance(10)
        await gate.recordEdgeBlock(accountID: "B", endpointKey: "post.info", transport: .webView, retryAfter: nil)
        cooldown = await gate.cooldownRemaining()
        XCTAssertEqual(cooldown ?? 0, 360, accuracy: 0.001)

        await gate.reset(accountID: "A")
        let webAReset = await gate.breakerRemaining(accountID: "A", endpointKey: "bell.list", transport: .webView)
        XCTAssertNil(webAReset)
        clock.advance(15 * 60)
        let expired = await gate.breakerRemaining(accountID: "B", endpointKey: "post.info", transport: .native)
        XCTAssertNil(expired)
    }
}

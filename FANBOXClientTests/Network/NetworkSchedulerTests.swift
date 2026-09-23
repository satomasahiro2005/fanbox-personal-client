import XCTest
@testable import FANBOXClient

final class NetworkSchedulerTests: XCTestCase {
    private func makeScheduler(limits: SchedulerLimits = .default, mode: NetworkMode = .normal) -> (NetworkScheduler, NetworkPolicyStore) {
        var snapshot = NetworkPolicySnapshot.default
        snapshot.mode = mode
        let policy = NetworkPolicyStore(snapshot)
        return (NetworkScheduler(policy: policy, limits: limits), policy)
    }

    /// Starts a request that holds its slot until `gate` opens.
    private func startBlocked(_ scheduler: NetworkScheduler, _ priority: RequestPriority, label: String, gate: NetModGate,
                              log: NetModLog? = nil) -> Task<Void, Error> {
        Task {
            try await scheduler.run(priority, label: label) {
                log?.append(label)
                await gate.wait()
            }
        }
    }

    func testOfflineThrowsImmediately() async {
        let (scheduler, _) = makeScheduler(mode: .offline)
        do {
            _ = try await scheduler.run(.interactiveWrite, label: "comment.add") { 1 }
            XCTFail("expected offline")
        } catch {
            XCTAssertEqual(error as? RemoteError, .offline)
        }
    }

    func testInteractiveAdmittedEvenWhenFull() async throws {
        let (scheduler, _) = makeScheduler(limits: SchedulerLimits(maxConcurrent: 1, perClass: [:]))
        let gate = NetModGate()
        let blocker = startBlocked(scheduler, .backgroundSync, label: "sync", gate: gate)
        await netModWaitUntil { await scheduler.snapshot()[.backgroundSync] == 1 }

        let value = try await scheduler.run(.interactiveRead, label: "post.info") { 42 }
        XCTAssertEqual(value, 42)

        await gate.open()
        _ = try await blocker.value
        let active = await scheduler.snapshot()
        XCTAssertTrue(active.isEmpty)
    }

    func testQueuedRequestsAdmittedByPriorityThenFIFO() async throws {
        let (scheduler, _) = makeScheduler(limits: SchedulerLimits(maxConcurrent: 1, perClass: [:]))
        let gate = NetModGate()
        let log = NetModLog()
        let blocker = startBlocked(scheduler, .backgroundSync, label: "blocker", gate: gate)
        await netModWaitUntil { await scheduler.snapshot()[.backgroundSync] == 1 }

        var tasks: [Task<Void, Error>] = []
        for (priority, label) in [(RequestPriority.mediaPrefetch, "prefetch"), (.backgroundSync, "sync-1"), (.foregroundMedia, "media"),
                                  (.backgroundSync, "sync-2"), (.notificationPrefetch, "notification")] {
            tasks.append(Task { try await scheduler.run(priority, label: label) { log.append(label) } })
            // Enqueue deterministically one after another.
            let expected = tasks.count
            await netModWaitUntil { await scheduler.queuedSnapshot().values.reduce(0, +) == expected }
        }
        let queued = await scheduler.queuedLabels()
        XCTAssertEqual(queued, ["notification", "media", "sync-1", "sync-2", "prefetch"])

        await gate.open()
        _ = try await blocker.value
        for t in tasks { _ = try await t.value }
        XCTAssertEqual(log.values, ["notification", "media", "sync-1", "sync-2", "prefetch"])
    }

    func testPerClassCaps() async throws {
        let (scheduler, _) = makeScheduler()
        let gate = NetModGate()
        let a = startBlocked(scheduler, .backgroundSync, label: "a", gate: gate)
        let b = startBlocked(scheduler, .backgroundSync, label: "b", gate: gate)
        await netModWaitUntil { await scheduler.snapshot()[.backgroundSync] == 2 }
        let c = startBlocked(scheduler, .backgroundSync, label: "c", gate: gate)
        await netModWaitUntil { await scheduler.queuedSnapshot()[.backgroundSync] == 1 }
        // Another class is not blocked by the backgroundSync cap.
        let v = try await scheduler.run(.foregroundMedia, label: "img") { "ok" }
        XCTAssertEqual(v, "ok")
        let stillActive = await scheduler.snapshot()[.backgroundSync]
        XCTAssertEqual(stillActive, 2)

        await gate.open()
        for t in [a, b, c] { _ = try await t.value }
        let queued = await scheduler.queuedSnapshot()
        XCTAssertTrue(queued.isEmpty)
    }

    func testMediaSuspendedDuringInteractiveAndResumedAfter() async throws {
        let (scheduler, _) = makeScheduler()
        let media = NetModFakeTransfer()
        let prefetch = NetModFakeTransfer()
        let upload = NetModFakeTransfer()
        let mediaToken = await scheduler.register(transfer: media, priority: .foregroundMedia)
        _ = await scheduler.register(transfer: prefetch, priority: .mediaPrefetch)
        _ = await scheduler.register(transfer: upload, priority: .interactiveWrite)
        XCTAssertFalse(media.isSuspended)

        let gate = NetModGate()
        let comment = startBlocked(scheduler, .interactiveWrite, label: "comment.add", gate: gate)
        await netModWaitUntil { await scheduler.snapshot()[.interactiveWrite] == 1 }
        XCTAssertTrue(media.isSuspended)
        XCTAssertTrue(prefetch.isSuspended)
        XCTAssertFalse(upload.isSuspended, "only transfers ≤ foregroundMedia are paused")

        // A second text-first request does not double-suspend.
        let read = try await scheduler.run(.interactiveRead, label: "comment.list") { 1 }
        XCTAssertEqual(read, 1)
        XCTAssertEqual(media.suspendCount, 1)
        XCTAssertTrue(media.isSuspended)

        // A transfer registered while text-first work runs starts suspended.
        let late = NetModFakeTransfer()
        _ = await scheduler.register(transfer: late, priority: .foregroundMedia)
        XCTAssertTrue(late.isSuspended)

        await gate.open()
        _ = try await comment.value
        XCTAssertFalse(media.isSuspended)
        XCTAssertFalse(prefetch.isSuspended)
        XCTAssertFalse(late.isSuspended)
        XCTAssertEqual(media.resumeCount, 1)

        await scheduler.unregister(mediaToken)
        let counts = await scheduler.transferCounts()
        XCTAssertEqual(counts.registered, 3)
        XCTAssertEqual(counts.suspended, 0)
    }

    func testNotificationPrefetchAlsoPausesMedia() async throws {
        let (scheduler, _) = makeScheduler()
        let media = NetModFakeTransfer()
        _ = await scheduler.register(transfer: media, priority: .foregroundMedia)
        let gate = NetModGate()
        let prefetch = startBlocked(scheduler, .notificationPrefetch, label: "notif", gate: gate)
        await netModWaitUntil { media.isSuspended }
        await gate.open()
        _ = try await prefetch.value
        XCTAssertFalse(media.isSuspended)
    }

    func testNewMediaWaitsWhileInteractiveInFlight() async throws {
        let (scheduler, _) = makeScheduler()
        let gate = NetModGate()
        let log = NetModLog()
        let comment = startBlocked(scheduler, .interactiveWrite, label: "comment", gate: gate, log: log)
        await netModWaitUntil { await scheduler.snapshot()[.interactiveWrite] == 1 }

        let image = Task { try await scheduler.run(.foregroundMedia, label: "image") { log.append("image") } }
        let sync = Task { try await scheduler.run(.backgroundSync, label: "sync") { log.append("sync") } }
        _ = try await sync.value   // non-media classes still run
        await netModWaitUntil { await scheduler.queuedSnapshot()[.foregroundMedia] == 1 }
        XCTAssertFalse(log.values.contains("image"))

        await gate.open()
        _ = try await comment.value
        _ = try await image.value
        XCTAssertEqual(log.values, ["comment", "sync", "image"])
    }

    func testCancellingAQueuedRequest() async throws {
        let (scheduler, _) = makeScheduler(limits: SchedulerLimits(maxConcurrent: 1, perClass: [:]))
        let gate = NetModGate()
        let blocker = startBlocked(scheduler, .backgroundSync, label: "blocker", gate: gate)
        await netModWaitUntil { await scheduler.snapshot()[.backgroundSync] == 1 }

        let ran = NetModLog()
        let waiter = Task { try await scheduler.run(.backgroundSync, label: "waiter") { ran.append("ran") } }
        await netModWaitUntil { await scheduler.queuedSnapshot()[.backgroundSync] == 1 }
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? RemoteError, .cancelled)
        }
        let queued = await scheduler.queuedSnapshot()
        XCTAssertTrue(queued.isEmpty)

        await gate.open()
        _ = try await blocker.value
        XCTAssertTrue(ran.values.isEmpty)
    }

    func testSwitchingToOfflineFailsQueuedRequests() async throws {
        let (scheduler, policy) = makeScheduler(limits: SchedulerLimits(maxConcurrent: 1, perClass: [:]))
        let gate = NetModGate()
        let blocker = startBlocked(scheduler, .backgroundSync, label: "blocker", gate: gate)
        await netModWaitUntil { await scheduler.snapshot()[.backgroundSync] == 1 }
        let waiter = Task { try await scheduler.run(.backgroundSync, label: "waiter") { 1 } }
        await netModWaitUntil { await scheduler.queuedSnapshot()[.backgroundSync] == 1 }

        policy.update { $0.mode = .offline }
        do {
            _ = try await waiter.value
            XCTFail("expected offline")
        } catch {
            XCTAssertEqual(error as? RemoteError, .offline)
        }
        await gate.open()
        _ = try await blocker.value
    }

    func testNestedRunDoesNotDeadlock() async throws {
        let (scheduler, _) = makeScheduler(limits: SchedulerLimits(maxConcurrent: 1, perClass: [.backgroundSync: 1]))
        let value = try await scheduler.run(.backgroundSync, label: "outer") {
            try await scheduler.run(.backgroundSync, label: "inner") { "nested" }
        }
        XCTAssertEqual(value, "nested")
    }

    func testOperationErrorsReleaseTheSlot() async throws {
        let (scheduler, _) = makeScheduler(limits: SchedulerLimits(maxConcurrent: 1, perClass: [:]))
        do {
            _ = try await scheduler.run(.backgroundSync, label: "fails") { () -> Int in throw RemoteError.server(status: 500) }
        } catch {
            XCTAssertEqual(error as? RemoteError, .server(status: 500))
        }
        let v = try await scheduler.run(.backgroundSync, label: "next") { 2 }
        XCTAssertEqual(v, 2)
        let active = await scheduler.snapshot()
        XCTAssertTrue(active.isEmpty)
    }

    func testPriorityMappingToURLSessionTask() {
        XCTAssertEqual(RequestPriority.interactiveWrite.urlSessionTaskPriority, URLSessionTask.highPriority)
        XCTAssertEqual(RequestPriority.mediaPrefetch.urlSessionTaskPriority, URLSessionTask.lowPriority)
        XCTAssertTrue(RequestPriority.interactiveWrite > .interactiveRead)
        XCTAssertTrue(RequestPriority.foregroundMedia.isPausableTransferClass)
        XCTAssertFalse(RequestPriority.notificationPrefetch.isPausableTransferClass)
    }
}

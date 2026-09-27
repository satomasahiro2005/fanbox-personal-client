import XCTest
@testable import FANBOXClient

/// Pausable transfer that also records cancellation.
final class FixTransportCancellableTransfer: PausableTransfer, @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var _suspended = false

    func suspend() { lock.withLock { _suspended = true } }
    func resume() { lock.withLock { _suspended = false } }
    func cancel() { lock.withLock { _cancelled = true } }

    var isCancelled: Bool { lock.withLock { _cancelled } }
}

/// SPEC §30 Offline (registered transfers are cancelled, reported as blocked / offline) and SPEC §46 media ordering.
final class FixTransportSchedulerTests: XCTestCase {
    func testSwitchingToOfflineCancelsRegisteredTransfersButNotWrites() async throws {
        let policy = NetworkPolicyStore()
        let scheduler = NetworkScheduler(policy: policy)
        let download = FixTransportCancellableTransfer()
        let upload = FixTransportCancellableTransfer()
        let write = FixTransportCancellableTransfer()
        // Register through `run` so the Offline observer is installed exactly as in production.
        try await scheduler.run(.foregroundMedia, label: "media.original") {
            _ = await scheduler.register(transfer: download, priority: .foregroundMedia)
            _ = await scheduler.register(transfer: upload, priority: .backgroundSync)
            _ = await scheduler.register(transfer: write, priority: .interactiveWrite)
        }
        policy.update { $0.mode = .offline }
        await netModWaitUntil { download.isCancelled && upload.isCancelled }
        XCTAssertFalse(write.isCancelled, "an admitted write is never cancelled (its outcome would become ambiguous)")
        let counts = await scheduler.transferCounts()
        XCTAssertEqual(counts.registered, 1)
    }

    /// An upload (a body with side effects, e.g. post.addImage at foregroundMedia) is neither cancelled by Offline nor
    /// suspended by text-first work: a body that already reached FANBOX would otherwise be uploaded again.
    func testUploadsAreNeverCancelledOrSuspendedMidway() async throws {
        let policy = NetworkPolicyStore()
        let scheduler = NetworkScheduler(policy: policy)
        let download = FixTransportCancellableTransfer()
        let upload = FixTransportCancellableTransfer()
        try await scheduler.run(.interactiveRead, label: "post.info") {
            _ = await scheduler.register(transfer: download, priority: .foregroundMedia)
            _ = await scheduler.register(transfer: upload, priority: .foregroundMedia, isWrite: true)
        }
        policy.update { $0.mode = .offline }
        await netModWaitUntil { download.isCancelled }
        XCTAssertFalse(upload.isCancelled)

        let task = URLSession.shared.uploadTask(with: {
            var request = URLRequest(url: URL(string: "https://api.fanbox.cc/post.addImage")!)
            request.httpMethod = "POST"
            return request
        }(), from: Data())
        let token = await scheduler.register(task: task, priority: .foregroundMedia)
        policy.update { $0.mode = .normal }
        let paused = NetModFakeTransfer()
        let gate = NetModGate()
        let read = Task { try await scheduler.run(.interactiveRead, label: "post.info") { await gate.wait() } }
        await netModWaitUntil { await scheduler.snapshot()[.interactiveRead] == 1 }
        _ = await scheduler.register(transfer: paused, priority: .foregroundMedia)
        XCTAssertTrue(paused.isSuspended, "a download waits for the text-first request")
        let counts = await scheduler.transferCounts()
        XCTAssertEqual(counts.suspended, 1, "the uploads keep running")
        await gate.open()
        _ = try await read.value
        await scheduler.unregister(token)
        task.cancel()
    }

    func testOfflineCancelledDownloadSurfacesAsOffline() async throws {
        let policy = NetworkPolicyStore()
        let scheduler = NetworkScheduler(policy: policy)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NetModStubProtocol.self]
        let credentials = InMemoryCredentialStore()
        let client = AccountHTTPClient(credentials: credentials, scheduler: scheduler, recorder: ResearchRecorder(), configuration: config)
        NetModStubProtocol.install { _ in NetModStubProtocol.Stub(hang: true) }
        defer { NetModStubProtocol.reset() }
        let task = Task {
            try await client.download(HTTPRequest(url: URL(string: "https://downloads.fanbox.cc/images/post/1/x.jpeg")!,
                                                  priority: .foregroundMedia, endpointKey: "media.original"),
                                      accountID: nil, progress: nil)
        }
        await netModWaitUntil { await scheduler.transferCounts().registered == 1 }
        policy.update { $0.mode = .offline }
        do {
            _ = try await task.value
            XCTFail("expected offline")
        } catch {
            XCTAssertEqual(error as? RemoteError, .offline, "stopped by the mode, not a failure of the download")
        }
    }

    func testThumbnailsAreNotStarvedByLargeMedia() async throws {
        let scheduler = NetworkScheduler(policy: NetworkPolicyStore())
        let gate = NetModGate()
        let log = NetModLog()
        // One original holds the single large-media slot.
        let first = Task { try await scheduler.run(.foregroundMedia, label: "media.original") { log.append("orig1"); await gate.wait() } }
        await netModWaitUntil { log.values.contains("orig1") }
        let largeActive = await scheduler.activeLargeMediaCount()
        XCTAssertEqual(largeActive, 1)

        // A second original waits for the large slot although a foregroundMedia slot is free…
        let second = Task { try await scheduler.run(.foregroundMedia, label: "media.original") { log.append("orig2") } }
        await netModWaitUntil { await scheduler.queuedLabels() == ["media.original"] }
        // …while thumbnails and display images still start immediately.
        try await scheduler.run(.foregroundMedia, label: "media.thumbnail") { log.append("thumb") }
        try await scheduler.run(.foregroundMedia, label: "media.display") { log.append("display") }
        XCTAssertEqual(log.values, ["orig1", "thumb", "display"])

        await gate.open()
        try await first.value
        try await second.value
        XCTAssertEqual(log.values.last, "orig2")
    }

    func testQueuedSmallMediaIsAdmittedBeforeQueuedLargeMedia() async throws {
        let limits = SchedulerLimits(maxConcurrent: 6, perClass: [.foregroundMedia: 1], largeMediaCap: 1)
        let scheduler = NetworkScheduler(policy: NetworkPolicyStore(), limits: limits)
        let gate = NetModGate()
        let log = NetModLog()
        let holder = Task { try await scheduler.run(.foregroundMedia, label: "media.display") { await gate.wait() } }
        await netModWaitUntil { await scheduler.snapshot()[.foregroundMedia] == 1 }
        let original = Task { try await scheduler.run(.foregroundMedia, label: "media.original") { log.append("original") } }
        await netModWaitUntil { await scheduler.queuedLabels().count == 1 }
        let thumb = Task { try await scheduler.run(.foregroundMedia, label: "media.thumbnail") { log.append("thumbnail") } }
        await netModWaitUntil { await scheduler.queuedLabels().count == 2 }
        let order = await scheduler.queuedLabels()
        XCTAssertEqual(order, ["media.thumbnail", "media.original"], "thumbnail → display → original (SPEC §46)")
        await gate.open()
        try await holder.value
        try await original.value
        try await thumb.value
        XCTAssertEqual(log.values, ["thumbnail", "original"])
    }

    func testPathKnownGatesWiFiOnlyPrefetch() {
        var snapshot = NetworkPolicySnapshot.default
        snapshot.pathKnown = false
        XCTAssertEqual(MediaPolicy.decide(kind: .image, variant: .display, trigger: .prefetch, policy: snapshot), .blocked,
                       "before Network.framework reported a path, Wi-Fi-only prefetch assumes cellular")
        XCTAssertEqual(MediaPolicy.decide(kind: .image, variant: .display, trigger: .automatic, policy: snapshot), .allowed)
        snapshot.pathKnown = true
        XCTAssertEqual(MediaPolicy.decide(kind: .image, variant: .display, trigger: .prefetch, policy: snapshot), .allowed)
    }

    @MainActor
    func testStartMarksThePathUnknownUntilTheMonitorReports() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "fixtransport-\(UUID().uuidString)")!)
        let policy = NetworkPolicyStore()
        let controller = NetworkModeController(settings: settings, policyStore: policy)
        XCTAssertTrue(policy.current.pathKnown)
        controller.start()
        defer { controller.stop() }
        controller.updatePath(satisfied: true, onWiFi: false, constrained: false, expensive: true)
        XCTAssertTrue(policy.current.pathKnown)
        XCTAssertFalse(policy.current.isKnownWiFi)
    }
}

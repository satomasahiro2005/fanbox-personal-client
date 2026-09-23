import Foundation
import XCTest
@testable import FANBOXClient

/// One-shot gate the test opens to let blocked operations finish.
actor NetModGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let w = waiters
        waiters.removeAll()
        for c in w { c.resume() }
    }
}

/// Thread-safe ordered log.
final class NetModLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ s: String) {
        lock.lock()
        items.append(s)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Fake pausable transfer counting suspend / resume calls.
final class NetModFakeTransfer: PausableTransfer, @unchecked Sendable {
    private let lock = NSLock()
    private var _suspendCount = 0
    private var _resumeCount = 0
    private var _isSuspended = false

    func suspend() {
        lock.lock()
        _suspendCount += 1
        _isSuspended = true
        lock.unlock()
    }

    func resume() {
        lock.lock()
        _resumeCount += 1
        _isSuspended = false
        lock.unlock()
    }

    var isSuspended: Bool { lock.lock(); defer { lock.unlock() }; return _isSuspended }
    var suspendCount: Int { lock.lock(); defer { lock.unlock() }; return _suspendCount }
    var resumeCount: Int { lock.lock(); defer { lock.unlock() }; return _resumeCount }
}

/// Polls `condition` until true or timeout (no shell sleep; short Task sleeps).
func netModWaitUntil(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                     _ condition: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    let ok = await condition()
    XCTAssertTrue(ok, "condition not met within \(timeout)s", file: file, line: line)
}

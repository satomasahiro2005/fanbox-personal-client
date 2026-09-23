import XCTest
import SwiftData
@testable import FANBOXClient

@MainActor
final class ResearchRecorderTests: XCTestCase {
    private var store: LocalStore!
    private var settings: AppSettings!

    override func setUp() async throws {
        try await super.setUp()
        store = LocalStore(container: try PersistenceController.makeContainer(inMemory: true))
        settings = AppSettings(defaults: UserDefaults(suiteName: "research-\(UUID().uuidString)")!)
    }

    private func rows() -> [ResearchLog] {
        store.fetch(FetchDescriptor<ResearchLog>(sortBy: [SortDescriptor(\.timestamp)]))
    }

    func testRecordRedactsAgainBeforePersisting() {
        settings.researchModeEnabled = true
        let recorder = ResearchRecorder()
        recorder.attach(store: store, settings: settings)
        recorder.record(ResearchEntry(kind: .request, accountID: "A", method: "GET",
                                      endpoint: "https://api.fanbox.cc/x?csrfToken=LEAK1", statusCode: 200,
                                      requestHeaders: "Cookie: FANBOXSESSID=LEAK2\nAccept: */*",
                                      responseHeaders: "Set-Cookie: FANBOXSESSID=LEAK3",
                                      responseBody: #"{"csrfToken":"LEAK4","card":"4111 1111 1111 1111"}"#,
                                      errorDescription: "password=LEAK5"))
        recorder.flush()
        let row = rows().first
        XCTAssertNotNil(row)
        let all = [row?.endpoint, row?.requestHeaders, row?.responseHeaders, row?.responseBody, row?.errorDescription]
            .compactMap { $0 }.joined(separator: "\n")
        for leak in ["LEAK1", "LEAK2", "LEAK3", "LEAK4", "LEAK5", "4111 1111 1111 1111"] {
            XCTAssertFalse(all.contains(leak), leak)
        }
        XCTAssertTrue(all.contains("Accept: */*"))
        XCTAssertTrue(all.contains("Cookie: <REDACTED>"))
    }

    func testBodiesDroppedWhenResearchModeOffAndFlagFollowsSetting() async {
        settings.researchModeEnabled = false
        let recorder = ResearchRecorder()
        recorder.attach(store: store, settings: settings)
        XCTAssertFalse(recorder.capturesBodies)
        recorder.record(ResearchEntry(kind: .request, method: "GET", endpoint: "https://api.fanbox.cc/a", responseBody: "{\"a\":1}"))
        recorder.flush()
        XCTAssertEqual(rows().first?.responseBody, "")

        settings.researchModeEnabled = true
        await netModWaitUntil { recorder.capturesBodies }
        settings.researchModeEnabled = false
        await netModWaitUntil { !recorder.capturesBodies }
    }

    func testEntriesBeforeAttachAreKeptAndDrainIsAutomatic() async {
        let recorder = ResearchRecorder()
        recorder.recordNote("early note")
        recorder.recordNavigation(accountID: "A", url: URL(string: "https://www.fanbox.cc/login?return_to=x&token=abc")!)
        recorder.attach(store: store, settings: settings)
        XCTAssertEqual(rows().count, 2)
        let nav = rows().first { $0.kind == .navigation }
        XCTAssertEqual(nav?.endpoint, "https://www.fanbox.cc/login?return_to=x&token=<REDACTED>")
        XCTAssertEqual(nav?.accountID, "A")

        // After attach, entries are drained by the scheduled main-actor task without an explicit flush.
        recorder.recordError("boom", endpoint: "sync.supports")
        await netModWaitUntil { self.rows().count == 3 }
        XCTAssertEqual(rows().last?.kind, .error)
    }

    func testPrunesOldestBeyondMaxRows() {
        let recorder = ResearchRecorder(maxRows: 50)
        recorder.attach(store: store, settings: settings)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<120 {
            recorder.record(ResearchEntry(timestamp: base.addingTimeInterval(TimeInterval(i)), kind: .request, method: "GET",
                                          endpoint: "https://api.fanbox.cc/\(i)"))
            if i % 30 == 29 { recorder.flush() }
        }
        recorder.flush()
        let remaining = rows()
        XCTAssertLessThanOrEqual(remaining.count, 50)
        XCTAssertGreaterThan(remaining.count, 0)
        XCTAssertEqual(remaining.last?.endpoint, "https://api.fanbox.cc/119", "newest kept")
        XCTAssertFalse(remaining.contains { $0.endpoint == "https://api.fanbox.cc/0" }, "oldest pruned")
    }

    func testClearAll() {
        let recorder = ResearchRecorder()
        recorder.attach(store: store, settings: settings)
        recorder.recordNote("a")
        recorder.recordNote("b")
        recorder.flush()
        XCTAssertEqual(rows().count, 2)
        recorder.clearAll()
        XCTAssertEqual(rows().count, 0)
    }

    func testRecordIsCallableFromBackgroundThreads() async {
        let recorder = ResearchRecorder()
        recorder.attach(store: store, settings: settings)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask {
                    recorder.record(ResearchEntry(kind: .sync, endpoint: "sync.\(i)"))
                }
            }
        }
        recorder.flush()
        XCTAssertEqual(rows().count, 40)
    }
}

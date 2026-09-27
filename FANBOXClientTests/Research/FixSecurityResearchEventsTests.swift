import SwiftData
import XCTest
@testable import FANBOXClient

/// Decoding / sync failures become research events (Sync / Errors list, "エラーのみ") — SPEC §36 / §44.
@MainActor
final class FixSecurityResearchEventsTests: XCTestCase {
    private var store: LocalStore!
    private var settings: AppSettings!
    private var recorder: ResearchRecorder!
    private var inspector: SchemaInspector!

    override func setUp() async throws {
        try await super.setUp()
        store = LocalStore(container: try PersistenceController.makeContainer(inMemory: true))
        settings = AppSettings(defaults: UserDefaults(suiteName: "fixsecurity-events-\(UUID().uuidString)")!)
        recorder = ResearchRecorder()
        recorder.attach(store: store, settings: settings)
        inspector = SchemaInspector(persistInterval: 0)
        inspector.attach(store: store)
        inspector.attach(recorder: recorder)
    }

    private func rows(_ kind: ResearchLogKind) -> [ResearchLog] {
        recorder.flush()
        return store.fetch(FetchDescriptor<ResearchLog>(sortBy: [SortDescriptor(\.timestamp)])).filter { $0.kind == kind }
    }

    private func makeSource(_ http: FanboxFakeHTTPClient) -> FanboxRemoteDataSource {
        FanboxRemoteDataSource(api: FanboxAPIClient(http: http, inspector: inspector), pageCache: FanboxPageURLCache(),
                               nativePostWritesEnabled: true)
    }

    func testUndecodable200ResponseBecomesErrorEvent() async throws {
        let http = FanboxFakeHTTPClient()
        http.stub("post.info", json: #"{"body":{"unexpected":{"csrfToken":"LEAKME"}}}"#)
        do {
            _ = try await makeSource(http).post(id: "6001", account: FanboxTestHarness.fan)
            XCTFail("expected a decoding error")
        } catch let error as RemoteError {
            guard case .decoding = error else { return XCTFail("unexpected \(error)") }
        }
        let errors = rows(.error)
        XCTAssertEqual(errors.count, 1)
        let row = try XCTUnwrap(errors.first)
        XCTAssertEqual(row.endpoint, "post.info")
        XCTAssertEqual(row.accountID, FanboxTestHarness.fan.accountID)
        let description = try XCTUnwrap(row.errorDescription)
        XCTAssertTrue(description.contains("HTTP 200"), description)
        XCTAssertTrue(description.contains("decoding(post.info)"), description)
        XCTAssertFalse(description.contains("LEAKME"))
        XCTAssertTrue(ResearchLogListView.isProblem(row), "shown under エラーのみ")
        XCTAssertTrue(ResearchLogListMode.events.kinds.contains(row.kind), "listed under Sync / Errors")
    }

    func testErrorEnvelopeOn200BecomesErrorEvent() async throws {
        let http = FanboxFakeHTTPClient()
        http.stub("post.info", json: #"{"error":"general_error"}"#)
        do {
            _ = try await makeSource(http).post(id: "6001", account: FanboxTestHarness.fan)
            XCTFail("expected an error")
        } catch {}
        let row = try XCTUnwrap(rows(.error).first)
        XCTAssertEqual(row.endpoint, "post.info")
        XCTAssertTrue(row.errorDescription?.contains("HTTP 200") ?? false)
    }

    func testMissingMetadataBecomesErrorEvent() async throws {
        let http = FanboxFakeHTTPClient()
        http.stub("www.metadata", data: Data("<html><body>challenge</body></html>".utf8), headers: ["Content-Type": "text/html"])
        let api = FanboxAPIClient(http: http, inspector: inspector)
        do {
            _ = try await api.fetchMetadata(accountID: "acc-1")
            XCTFail("expected a decoding error")
        } catch {}
        let row = try XCTUnwrap(rows(.error).first)
        XCTAssertEqual(row.endpoint, "www.metadata")
        XCTAssertTrue(row.errorDescription?.contains("metadataが見つかりません") ?? false)
    }

    func testSuccessfulResponsesRecordNoErrorEvent() async throws {
        let http = FanboxFakeHTTPClient()
        http.stub("post.info", json: FanboxFixtures.envelope(FanboxFixtures.articlePost))
        _ = try await makeSource(http).post(id: "6001", account: FanboxTestHarness.fan)
        XCTAssertTrue(rows(.error).isEmpty)
    }

    func testSyncFailuresBecomeSyncEventsExceptLocalConditions() async throws {
        let h = try SyncHarness()
        let recorder = ResearchRecorder()
        recorder.attach(store: h.store, settings: h.settings)
        h.engine.onFailure = { operation, accountID, error in
            recorder.recordSyncFailure(operation: operation, accountID: accountID, error: error)
        }
        let account = h.addAccount("A", pixivUserID: "1")
        h.mock.update { $0.accountErrors[account.id] = .decoding(endpoint: "post.listHome", detail: "型不一致 String at body.items") }
        _ = await h.engine.sync(.timeline, accountID: account.id, reason: .userRefresh)
        h.mock.update { $0.accountErrors[account.id] = .offline }
        _ = await h.engine.sync(.timeline, accountID: account.id, reason: .userRefresh)
        h.mock.update { $0.accountErrors[account.id] = .cancelled }
        _ = await h.engine.sync(.timeline, accountID: account.id, reason: .userRefresh)
        h.mock.update { $0.accountErrors[account.id] = .notFound }
        _ = await h.engine.refreshPost(postID: "777", accountID: account.id)
        recorder.flush()

        let events = h.store.fetch(FetchDescriptor<ResearchLog>(sortBy: [SortDescriptor(\.timestamp)])).filter { $0.kind == .sync }
        XCTAssertEqual(events.map(\.endpoint), [SyncResource.timeline.rawValue, "post:777"])
        XCTAssertTrue(events[0].errorDescription?.contains("decoding(post.listHome)") ?? false)
        XCTAssertEqual(events[0].accountID, account.id)
        XCTAssertTrue(events.allSatisfy(ResearchLogListView.isProblem))
    }

    func testRecordSyncFailureFiltersAndDescribes() {
        XCTAssertFalse(ResearchRecorder.isResearchRelevant(.cancelled))
        XCTAssertFalse(ResearchRecorder.isResearchRelevant(.blockedByPolicy))
        XCTAssertFalse(ResearchRecorder.isResearchRelevant(.offline))
        XCTAssertTrue(ResearchRecorder.isResearchRelevant(.unauthorized))
        XCTAssertTrue(ResearchRecorder.isResearchRelevant(.server(status: 503)))
        XCTAssertEqual(ResearchRecorder.describe(RemoteError.server(status: 503)), "server(503)")
        XCTAssertEqual(ResearchRecorder.describe(RemoteError.unauthorized), "unauthorized")
        XCTAssertEqual(ResearchRecorder.describe(RemoteError.rateLimited(retryAfter: 30)), "rateLimited(retryAfter: 30)")
        XCTAssertEqual(ResearchRecorder.describe(CancellationError()), "CancellationError")
    }

    /// AppEnvironment wires both sinks to its recorder.
    func testAppEnvironmentWiring() throws {
        let env = AppEnvironment.preview(seedDemo: false)
        env.schemaInspector.recordFailure(endpointKey: "post.listHome", accountID: "acc-x", statusCode: 200,
                                          error: RemoteError.decoding(endpoint: "post.listHome", detail: "body がありません"))
        env.sync.onFailure?("timeline", "acc-x", .server(status: 500))
        env.research.flush()
        let logs = env.store.fetch(FetchDescriptor<ResearchLog>())
        XCTAssertTrue(logs.contains { $0.kind == .error && $0.endpoint == "post.listHome" })
        XCTAssertTrue(logs.contains { $0.kind == .sync && $0.endpoint == "timeline" && $0.errorDescription == "server(500)" })
        XCTAssertEqual(ResearchLogCounts.load(store: env.store).events, 2)
    }
}

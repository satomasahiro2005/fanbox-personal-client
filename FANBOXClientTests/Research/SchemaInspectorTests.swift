import XCTest
import SwiftData
@testable import FANBOXClient

@MainActor
final class SchemaInspectorTests: XCTestCase {
    private var store: LocalStore!
    private var inspector: SchemaInspector!

    override func setUp() async throws {
        try await super.setUp()
        store = LocalStore(container: try PersistenceController.makeContainer(inMemory: true))
        inspector = SchemaInspector(persistInterval: 0)
        inspector.attach(store: store)
    }

    private let known: [String: Set<String>] = [
        "body": ["id", "title", "body", "creatorId"],
        "body.body.blocks[]": ["type", "text", "imageId"],
    ]

    private func postJSON(extraBodyField: String? = nil) -> Data {
        var body: [String: Any] = [
            "id": "1234567",
            "title": "t",
            "fooBar": 1,
            "body": ["blocks": [["type": "p", "text": "x"], ["type": "image", "imageId": "i", "newKey": true]]],
        ]
        if let extraBodyField { body[extraBodyField] = "v" }
        return try! JSONSerialization.data(withJSONObject: ["body": body])
    }

    private func snapshot(_ key: String) -> APISchemaSnapshot? {
        store.first(#Predicate<APISchemaSnapshot> { $0.endpointKey == key })
    }

    private func schemaLogs() -> [ResearchLog] {
        store.fetch(FetchDescriptor<ResearchLog>()).filter { $0.kind == .schema }
    }

    func testAnalyzeCollectsNewAndMissingPerPath() {
        let obs = SchemaInspector.analyze(rawJSON: postJSON(), known: known)
        let byPath = Dictionary(uniqueKeysWithValues: obs.map { ($0.path, $0) })
        XCTAssertEqual(byPath["body"]?.newFields, ["fooBar"])
        XCTAssertEqual(byPath["body"]?.missingFields, ["creatorId"])
        // Array element keys are unioned: "text" and "imageId" each appear in one element → not missing.
        XCTAssertEqual(byPath["body.body.blocks[]"]?.newFields, ["newKey"])
        XCTAssertEqual(byPath["body.body.blocks[]"]?.missingFields, [])
    }

    func testResolvePaths() throws {
        let root = try JSONSerialization.jsonObject(with: Data(#"{"body":{"items":[{"a":1},{"b":2},3],"nested":[[{"c":1}]]},"x":1}"#.utf8))
        XCTAssertEqual(SchemaInspector.resolve(path: "", in: root).first.map { Set($0.keys) }, ["body", "x"])
        XCTAssertEqual(SchemaInspector.resolve(path: "$", in: root).count, 1)
        XCTAssertEqual(SchemaInspector.resolve(path: "body.items[]", in: root).count, 2, "non-object elements ignored")
        XCTAssertEqual(SchemaInspector.resolve(path: "body.nested[][]", in: root).first.map { Set($0.keys) }, ["c"])
        XCTAssertTrue(SchemaInspector.resolve(path: "body.missing", in: root).isEmpty)
        XCTAssertTrue(SchemaInspector.resolve(path: "x.y", in: root).isEmpty)
    }

    func testObservePersistsSnapshotsAndSchemaLogs() async throws {
        await inspector.observeAndWait(endpointKey: "post.info", rawJSON: postJSON(), known: known)
        let body = try XCTUnwrap(snapshot("post.info:body"))
        XCTAssertEqual(body.knownFields, ["body", "creatorId", "id", "title"])
        XCTAssertEqual(body.observedFields, ["body", "fooBar", "id", "title"])
        XCTAssertEqual(body.newFields, ["fooBar"])
        XCTAssertEqual(body.missingFields, ["creatorId"])
        XCTAssertEqual(body.sampleCount, 1)
        XCTAssertNotNil(body.lastChangedAt)
        let blocks = try XCTUnwrap(snapshot("post.info:body.body.blocks[]"))
        XCTAssertEqual(blocks.newFields, ["newKey"])

        var logs = schemaLogs()
        XCTAssertEqual(logs.count, 2)
        XCTAssertTrue(logs.contains { $0.endpoint == "post.info:body" && $0.responseBody.contains("fooBar") })

        // Same shape again: counted, no new log, no change timestamp update.
        let changedAt = body.lastChangedAt
        await inspector.observeAndWait(endpointKey: "post.info", rawJSON: postJSON(), known: known,
                                       now: Date().addingTimeInterval(10))
        XCTAssertEqual(snapshot("post.info:body")?.sampleCount, 2)
        XCTAssertEqual(snapshot("post.info:body")?.lastChangedAt, changedAt)
        XCTAssertEqual(schemaLogs().count, 2)

        // A new field appears → logged once, lastChangedAt moves.
        let later = Date().addingTimeInterval(20)
        await inspector.observeAndWait(endpointKey: "post.info", rawJSON: postJSON(extraBodyField: "isPinned"), known: known, now: later)
        let updated = try XCTUnwrap(snapshot("post.info:body"))
        XCTAssertEqual(updated.newFields, ["fooBar", "isPinned"])
        XCTAssertEqual(updated.lastChangedAt, later)
        XCTAssertEqual(updated.lastSeenAt, later)
        logs = schemaLogs()
        XCTAssertEqual(logs.count, 3)
        XCTAssertTrue(logs.contains { $0.responseBody.contains("isPinned") && !$0.responseBody.contains("New: fooBar") })
    }

    func testDTOUpdateClearsNewFields() async throws {
        await inspector.observeAndWait(endpointKey: "post.info", rawJSON: postJSON(), known: known)
        var updatedKnown = known
        updatedKnown["body"]?.insert("fooBar")
        updatedKnown["body"]?.remove("creatorId")
        await inspector.observeAndWait(endpointKey: "post.info", rawJSON: postJSON(), known: updatedKnown,
                                       now: Date().addingTimeInterval(5))
        let body = try XCTUnwrap(snapshot("post.info:body"))
        XCTAssertEqual(body.newFields, [])
        XCTAssertEqual(body.missingFields, [])
        XCTAssertTrue(body.knownFields.contains("fooBar"))
    }

    func testMissingObjectsAndBadJSONAreIgnored() async {
        await inspector.observeAndWait(endpointKey: "x", rawJSON: Data("not json".utf8), known: known)
        await inspector.observeAndWait(endpointKey: "y", rawJSON: Data(#"{"error":"general_error"}"#.utf8), known: known)
        XCTAssertTrue(store.fetch(FetchDescriptor<APISchemaSnapshot>()).isEmpty)
        XCTAssertTrue(schemaLogs().isEmpty)
        // Fire-and-forget variant never throws / crashes.
        inspector.observe(endpointKey: "z", rawJSON: Data(), known: known)
        inspector.observe(endpointKey: "z", rawJSON: Data("[1,2".utf8), known: known)
    }

    func testCoalescesUnchangedObservationsWithinInterval() async throws {
        let throttled = SchemaInspector(persistInterval: 3600)
        throttled.attach(store: store)
        let t0 = Date()
        await throttled.observeAndWait(endpointKey: "post.info", rawJSON: postJSON(), known: known, now: t0)
        await throttled.observeAndWait(endpointKey: "post.info", rawJSON: postJSON(), known: known, now: t0.addingTimeInterval(1))
        await throttled.observeAndWait(endpointKey: "post.info", rawJSON: postJSON(), known: known, now: t0.addingTimeInterval(2))
        XCTAssertEqual(snapshot("post.info:body")?.sampleCount, 1, "unchanged samples are held back")
        await throttled.observeAndWait(endpointKey: "post.info", rawJSON: postJSON(), known: known, now: t0.addingTimeInterval(4000))
        XCTAssertEqual(snapshot("post.info:body")?.sampleCount, 4, "pending samples flushed after the interval")
    }
}

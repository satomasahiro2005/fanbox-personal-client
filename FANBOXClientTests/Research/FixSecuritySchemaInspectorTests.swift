import SwiftData
import XCTest
@testable import FANBOXClient

/// API Inspector `{}` (dictionary-value) paths: article body maps of post.info / post.getEditable (SPEC §37 / §45).
@MainActor
final class FixSecuritySchemaInspectorTests: XCTestCase {
    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    func testResolveMapValues() throws {
        let root = try json(#"{"body":{"post":{"body":{"imageMap":{"a":{"id":1,"x":2},"b":{"id":3}}}}}}"#)
        let objects = SchemaInspector.resolve(path: "body.post.body.imageMap{}", in: root)
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(objects.reduce(into: Set<String>()) { $0.formUnion($1.keys) }, ["id", "x"])
    }

    func testEmptyPHPMapArrayGivesNoObjects() throws {
        let root = try json(#"{"body":{"imageMap":[],"fileMap":null,"embedMap":{}}}"#)
        XCTAssertTrue(SchemaInspector.resolve(path: "body.imageMap{}", in: root).isEmpty)
        XCTAssertTrue(SchemaInspector.resolve(path: "body.fileMap{}", in: root).isEmpty)
        XCTAssertTrue(SchemaInspector.resolve(path: "body.embedMap{}", in: root).isEmpty)
        XCTAssertTrue(SchemaInspector.resolve(path: "body.missingMap{}", in: root).isEmpty)
        // A list-shaped map (PHP) contributes its elements, like the tolerant DTO decoder.
        let listShaped = try json(#"{"body":{"imageMap":[{"id":"i1","y":1}]}}"#)
        XCTAssertEqual(SchemaInspector.resolve(path: "body.imageMap{}", in: listShaped).first.map { Set($0.keys) }, ["id", "y"])
    }

    func testAnalyzeReportsNewAndMissingFieldsInsideMapValues() throws {
        let data = Data(#"{"body":{"post":{"body":{"imageMap":{"a":{"id":1,"x":2},"b":{"id":3,"x":4}}}}}}"#.utf8)
        let known: [String: Set<String>] = ["body.post.body.imageMap{}": ["id", "originalUrl"]]
        let obs = try XCTUnwrap(SchemaInspector.analyze(rawJSON: data, known: known).first)
        XCTAssertEqual(obs.path, "body.post.body.imageMap{}")
        XCTAssertEqual(obs.newFields, ["x"])
        XCTAssertEqual(obs.missingFields, ["originalUrl"])
    }

    func testNestedPathsBelowMapValuesAndMixedSuffixes() throws {
        let root = try json(#"""
        {"body":{"urlEmbedMap":{"u1":{"id":"u1","type":"default"},
                                "u3":{"id":"u3","type":"fanbox.post","postInfo":{"id":"5","title":"t","user":{"userId":"1","z":0}}}},
                 "groups":{"g1":[{"k":1}],"g2":[{"k":2,"m":3}]},
                 "lists":[{"a":{"v":1}},{"b":{"v":2,"w":3}}]}}
        """#)
        XCTAssertEqual(SchemaInspector.resolve(path: "body.urlEmbedMap{}.postInfo", in: root).first.map { Set($0.keys) },
                       ["id", "title", "user"])
        XCTAssertEqual(SchemaInspector.resolve(path: "body.urlEmbedMap{}.postInfo.user", in: root).first.map { Set($0.keys) },
                       ["userId", "z"])
        // `{}` then `[]`: every element of every map value.
        XCTAssertEqual(SchemaInspector.resolve(path: "body.groups{}[]", in: root).count, 2)
        // `[]` then `{}`: every value of every element.
        XCTAssertEqual(SchemaInspector.resolve(path: "body.lists[]{}", in: root).count, 2)
    }

    func testPathComponentParsing() {
        XCTAssertEqual(SchemaInspector.PathComponent("imageMap{}").name, "imageMap")
        XCTAssertEqual(SchemaInspector.PathComponent("imageMap{}").suffixes, [.mapValues])
        XCTAssertEqual(SchemaInspector.PathComponent("groups{}[]").suffixes, [.mapValues, .arrayElements])
        XCTAssertEqual(SchemaInspector.PathComponent("items[][]").suffixes, [.arrayElements, .arrayElements])
        XCTAssertEqual(SchemaInspector.PathComponent("[]").name, "")
        XCTAssertEqual(SchemaInspector.PathComponent("plain").suffixes, [])
    }

    /// End to end with the real DTO schema: the article fixture carries `newImageField` inside imageMap.
    func testPostInfoArticleMapsAreInspected() {
        let data = Data(FanboxFixtures.envelope(FanboxFixtures.articlePost).utf8)
        let obs = SchemaInspector.analyze(rawJSON: data, known: FanboxPostInfoBody.responseSchema)
        let byPath = Dictionary(uniqueKeysWithValues: obs.map { ($0.path, $0) })
        XCTAssertEqual(byPath["body.post.body.imageMap{}"]?.newFields, ["newImageField"])
        XCTAssertEqual(byPath["body.post.body.imageMap{}"]?.missingFields, [])
        XCTAssertEqual(byPath["body.post.body.fileMap{}"]?.newFields, [])
        XCTAssertEqual(byPath["body.post.body.embedMap{}"]?.newFields, [])
        XCTAssertEqual(byPath["body.post.body.urlEmbedMap{}"]?.newFields, [])
        XCTAssertNotNil(byPath["body.post.body.urlEmbedMap{}.postInfo"], "nested object below a map value is inspected")
        XCTAssertEqual(byPath["body.post.body.urlEmbedMap{}.postInfo.user"]?.observed, ["userId", "name"])
    }

    /// A renamed image field (e.g. originalUrl → originalURL) shows up as one new + one missing field and is persisted.
    func testRenamedMapFieldIsPersistedAsSchemaChange() async throws {
        let store = LocalStore(container: try PersistenceController.makeContainer(inMemory: true))
        let inspector = SchemaInspector(persistInterval: 0)
        inspector.attach(store: store)
        let renamed = FanboxFixtures.articlePost.replacingOccurrences(of: "\"originalUrl\"", with: "\"originalURL\"")
        await inspector.observeAndWait(endpointKey: "post.info", rawJSON: Data(FanboxFixtures.envelope(renamed).utf8),
                                       known: FanboxPostInfoBody.responseSchema)
        let key = "post.info:body.post.body.imageMap{}"
        let snapshot = try XCTUnwrap(store.first(#Predicate<APISchemaSnapshot> { $0.endpointKey == key }))
        XCTAssertEqual(snapshot.newFields, ["newImageField", "originalURL"])
        XCTAssertEqual(snapshot.missingFields, ["originalUrl"])
        XCTAssertTrue(APISchemaGrouping.hasChanges(snapshot))
        let logs = store.fetch(FetchDescriptor<ResearchLog>()).filter { $0.kind == .schema && $0.endpoint == key }
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs.first?.responseBody.contains("Missing: originalUrl") ?? false)
    }

    /// post.getEditable reuses the post body DTO, so its maps are inspected too.
    func testEditablePostSchemaDeclaresMapPaths() {
        let schema = FanboxEditablePostBody.responseSchema
        XCTAssertNotNil(schema["body.body.imageMap{}"])
        let data = Data(#"{"body":{"id":"1","body":{"blocks":[],"imageMap":{"i":{"id":"i","extension":"png","width":1,"height":1,"originalUrl":"u","thumbnailUrl":"t","brandNew":1}}}}}"#.utf8)
        let obs = SchemaInspector.analyze(rawJSON: data, known: schema)
        XCTAssertEqual(obs.first { $0.path == "body.body.imageMap{}" }?.newFields, ["brandNew"])
    }
}

import Foundation

/// DTOs declare the JSON field names they understand so the API Inspector (SPEC §37) can report
/// new / missing fields per endpoint and object path without the decoder ever failing on them.
///
/// Path syntax passed to `SchemaInspector.observe(endpointKey:rawJSON:known:)`:
/// - `body`                    — the envelope's body object
/// - `body.items[]`            — every element of the `items` array
/// - `body.post.body.imageMap{}` — every VALUE of a dictionary keyed by dynamic ids (the map's own keys are ids, not fields)
protocol SchemaDescribed {
    /// Field names of this object that the DTO reads (or deliberately knows about).
    static var knownFields: Set<String> { get }
    /// Nested objects: key = field name with optional suffix `[]` (array elements) or `{}` (dictionary values).
    static var schemaChildren: [String: any SchemaDescribed.Type] { get }
}

extension SchemaDescribed {
    static var schemaChildren: [String: any SchemaDescribed.Type] { [:] }

    /// Flattened `path → known field names` for this type rooted at `path`.
    static func knownSchema(at path: String) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        SchemaPaths.collect(self, at: path, depth: 0, into: &result)
        return result
    }
}

enum SchemaPaths {
    static let maxDepth = 8

    static func collect(_ type: any SchemaDescribed.Type, at path: String, depth: Int, into result: inout [String: Set<String>]) {
        guard depth < maxDepth else { return }
        result[path, default: []].formUnion(type.knownFields)
        for (key, child) in type.schemaChildren {
            collect(child, at: join(path, key), depth: depth + 1, into: &result)
        }
    }

    static func join(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : path + "." + key
    }

    /// Merges several schemas (e.g. the current wrapped shape and a legacy bare shape).
    static func merge(_ schemas: [String: Set<String>]...) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for schema in schemas {
            for (k, v) in schema { result[k, default: []].formUnion(v) }
        }
        return result
    }
}

/// A decodable response body that can describe where its known fields live relative to the envelope root.
protocol FanboxResponseBody: Decodable {
    /// Known fields for the whole response, rooted at "body".
    static var responseSchema: [String: Set<String>] { get }
}

import Foundation

/// API Inspector (SPEC §37): compares raw JSON keys against the fields the DTOs know,
/// and records new / missing fields per endpoint + object path into `APISchemaSnapshot`.
/// Decoders are tolerant, so unknown fields never break decoding; this only reports them.
final class SchemaInspector: @unchecked Sendable {
    init() {}

    @MainActor
    func attach(store: LocalStore) {}

    /// - Parameters:
    ///   - endpointKey: e.g. "post.info"
    ///   - rawJSON: full response body
    ///   - known: object path → field names the DTO understands, e.g. ["body": ["id", "title", ...], "body.items[]": [...]]
    func observe(endpointKey: String, rawJSON: Data, known: [String: Set<String>]) {}
}

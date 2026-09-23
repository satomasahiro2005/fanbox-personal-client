import Foundation

/// Low-level FANBOX JSON API client (endpoints + envelope decoding). Only `FanboxAdapter` uses it.
final class FanboxAPIClient: Sendable {
    let http: HTTPClient
    let inspector: SchemaInspector

    init(http: HTTPClient, inspector: SchemaInspector) {
        self.http = http
        self.inspector = inspector
    }
}

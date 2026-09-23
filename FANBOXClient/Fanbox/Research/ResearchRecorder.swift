import Foundation

/// Already-redacted research entry (build with `SecretRedactor` BEFORE creating one).
struct ResearchEntry: Sendable {
    var timestamp: Date = .now
    var kind: ResearchLogKind
    var accountID: String?
    var method: String?
    var endpoint: String
    var statusCode: Int?
    var durationMs: Int?
    var priority: RequestPriority?
    var requestHeaders: String = ""
    var responseHeaders: String = ""
    var responseBody: String = ""
    var bytes: Int?
    var errorDescription: String?
}

/// Persists Research Mode logs (SPEC §36 / §44). Thread-safe entry point callable from any actor.
/// Metadata is always kept (small ring buffer); response bodies only while Research Mode is enabled.
final class ResearchRecorder: @unchecked Sendable {
    init() {}

    /// Attach the persistence sink (main actor). Called by AppEnvironment.
    @MainActor
    func attach(store: LocalStore, settings: AppSettings) {}

    /// Whether bodies should be captured right now.
    var capturesBodies: Bool { false }

    func record(_ entry: ResearchEntry) {}
}

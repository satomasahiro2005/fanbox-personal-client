import Foundation
import Observation
import os
import SwiftData

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
///
/// - `record(_:)` re-applies `SecretRedactor` to every text field (defense in depth), buffers the entry and schedules
///   one main-actor drain that inserts `ResearchLog` rows in a batch.
/// - At most `maxRows` rows are kept; the oldest are pruned in batches.
/// - `capturesBodies` mirrors `AppSettings.researchModeEnabled` through a lock-protected flag readable from any thread.
final class ResearchRecorder: @unchecked Sendable {
    static let defaultMaxRows = 3_000
    /// Upper bound of entries waiting for the main actor (before attach, or under bursts).
    static let maxPending = 1_000
    static let bodyLimit = 64_000

    let maxRows: Int
    private let pruneSlack: Int

    private struct Buffer {
        var pending: [ResearchEntry] = []
        var drainScheduled = false
    }

    private let buffer = OSAllocatedUnfairLock(initialState: Buffer())
    private let bodyFlag = OSAllocatedUnfairLock(initialState: false)

    @MainActor private var store: LocalStore?
    @MainActor private var settings: AppSettings?
    @MainActor private var observingSettings = false

    init() {
        self.maxRows = Self.defaultMaxRows
        self.pruneSlack = 200
    }

    /// Custom capacity (tests).
    init(maxRows: Int) {
        self.maxRows = max(1, maxRows)
        self.pruneSlack = min(200, max(0, maxRows / 10))
    }

    /// Attach the persistence sink (main actor). Called by AppEnvironment.
    @MainActor
    func attach(store: LocalStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        let enabled = settings.researchModeEnabled
        bodyFlag.withLock { $0 = enabled }
        observeSettings()
        drain()
    }

    /// Whether bodies should be captured right now.
    var capturesBodies: Bool { bodyFlag.withLock { $0 } }

    /// Records an entry from any thread. Text fields are redacted again before persisting.
    func record(_ entry: ResearchEntry) {
        let clean = Self.sanitize(entry, capturesBodies: capturesBodies)
        let scheduleDrain = buffer.withLock { state -> Bool in
            state.pending.append(clean)
            if state.pending.count > Self.maxPending {
                state.pending.removeFirst(state.pending.count - Self.maxPending)
            }
            guard !state.drainScheduled else { return false }
            state.drainScheduled = true
            return true
        }
        if scheduleDrain {
            Task { @MainActor [self] in self.drain() }
        }
    }

    /// Records a WebView navigation (kind `.navigation`, redacted URL).
    func recordNavigation(accountID: String?, url: URL, note: String? = nil) {
        record(ResearchEntry(kind: .navigation, accountID: accountID, method: nil, endpoint: SecretRedactor.redactURL(url),
                             responseBody: note ?? ""))
    }

    /// Records a free-form note (kind `.note`), e.g. a support-state observation.
    func recordNote(_ text: String, accountID: String? = nil, endpoint: String = "note") {
        record(ResearchEntry(kind: .note, accountID: accountID, endpoint: endpoint, responseBody: text))
    }

    /// Records an error that did not come from an HTTP request (kind `.error`), e.g. an undecodable 2xx response.
    func recordError(_ description: String, accountID: String? = nil, endpoint: String) {
        record(ResearchEntry(kind: .error, accountID: accountID, endpoint: endpoint, errorDescription: description))
    }

    /// Records a failed sync / refresh (kind `.sync`), e.g. `timeline` failing with a decoding error.
    /// Expected, non-research outcomes are skipped: cancellation, the network-mode policy and being offline.
    func recordSyncFailure(operation: String, accountID: String?, error: RemoteError) {
        guard Self.isResearchRelevant(error) else { return }
        record(ResearchEntry(kind: .sync, accountID: accountID, endpoint: operation, errorDescription: Self.describe(error)))
    }

    /// Whether a sync failure is worth a research event (API / session / server problems, not local conditions).
    static func isResearchRelevant(_ error: RemoteError) -> Bool {
        switch error {
        case .cancelled, .blockedByPolicy, .offline: return false
        default: return true
        }
    }

    /// Short, secret-free description of an error for research events (redacted again when recorded).
    static func describe(_ error: Error) -> String {
        guard let remote = error as? RemoteError else { return String(describing: type(of: error)) }
        switch remote {
        case .decoding(let endpoint, let detail): return "decoding(\(endpoint)): \(detail)"
        case .network(let code, let detail): return "network(\(code)): \(detail)"
        case .server(let status): return "server(\(status))"
        case .rateLimited(let retryAfter): return "rateLimited(retryAfter: \(retryAfter.map { String(Int($0)) } ?? "-"))"
        case .unsupported(let operation): return "unsupported(\(operation))"
        case .invalidRequest(let detail): return "invalidRequest: \(detail)"
        default: return "\(remote)"
        }
    }

    /// Persists everything recorded so far (tests / before showing the Research screen).
    @MainActor
    func flush() {
        drain()
    }

    /// Deletes all research rows (Research Mode "clear").
    @MainActor
    func clearAll() {
        buffer.withLock { $0.pending.removeAll() }
        guard let store else { return }
        do {
            try store.context.delete(model: ResearchLog.self)
        } catch {
            for row in store.fetch(FetchDescriptor<ResearchLog>()) { store.context.delete(row) }
        }
        store.save()
    }

    // MARK: - Persistence (main actor)

    @MainActor
    private func drain() {
        guard let store else {
            // Not attached yet: keep entries buffered; attach() drains them.
            buffer.withLock { $0.drainScheduled = false }
            return
        }
        let entries = buffer.withLock { state -> [ResearchEntry] in
            let taken = state.pending
            state.pending.removeAll(keepingCapacity: true)
            state.drainScheduled = false
            return taken
        }
        guard !entries.isEmpty else { return }
        for e in entries {
            store.context.insert(ResearchLog(timestamp: e.timestamp, kind: e.kind, accountID: e.accountID, method: e.method,
                                             endpoint: e.endpoint, statusCode: e.statusCode, durationMs: e.durationMs,
                                             priorityRaw: e.priority?.rawValue, requestHeaders: e.requestHeaders,
                                             responseHeaders: e.responseHeaders, responseBody: e.responseBody, bytes: e.bytes,
                                             errorDescription: e.errorDescription))
        }
        store.save()
        prune(store)
    }

    @MainActor
    private func prune(_ store: LocalStore) {
        let count = (try? store.context.fetchCount(FetchDescriptor<ResearchLog>())) ?? 0
        guard count > maxRows else { return }
        var oldest = FetchDescriptor<ResearchLog>(sortBy: [SortDescriptor(\.timestamp, order: .forward)])
        oldest.fetchLimit = count - (maxRows - pruneSlack)
        for row in store.fetch(oldest) { store.context.delete(row) }
        store.save()
    }

    @MainActor
    private func observeSettings() {
        guard !observingSettings, settings != nil else { return }
        observingSettings = true
        armSettingsObservation()
    }

    @MainActor
    private func armSettingsObservation() {
        guard let settings else { return }
        let enabled = withObservationTracking {
            settings.researchModeEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.armSettingsObservation() }
        }
        bodyFlag.withLock { $0 = enabled }
    }

    // MARK: - Sanitizing

    /// Re-applies redaction to every text field; drops request bodies when Research Mode is off.
    static func sanitize(_ entry: ResearchEntry, capturesBodies: Bool) -> ResearchEntry {
        var e = entry
        e.endpoint = redactEndpoint(entry.endpoint)
        e.method = entry.method.map { SecretRedactor.redact(String($0.prefix(16))) }
        e.requestHeaders = SecretRedactor.redact(entry.requestHeaders)
        e.responseHeaders = SecretRedactor.redact(entry.responseHeaders)
        if entry.kind == .request && !capturesBodies {
            e.responseBody = ""
        } else if !entry.responseBody.isEmpty {
            let body = entry.responseBody.count > bodyLimit
                ? String(entry.responseBody.prefix(bodyLimit)) + "\n…(truncated)"
                : entry.responseBody
            e.responseBody = SecretRedactor.redact(body)
        }
        e.errorDescription = entry.errorDescription.map { SecretRedactor.redact($0) }
        return e
    }

    private static func redactEndpoint(_ endpoint: String) -> String {
        endpoint.contains("://") ? SecretRedactor.redactURLString(endpoint) : SecretRedactor.redact(endpoint)
    }
}

import Foundation
import os
import SwiftData

/// API Inspector (SPEC §37): compares raw JSON keys against the fields the DTOs know,
/// and records new / missing fields per endpoint + object path into `APISchemaSnapshot`.
/// Decoders are tolerant, so unknown fields never break decoding; this only reports them.
///
/// Path syntax for `known` (see `SchemaDescribed`): dot-separated object keys; a component may end with suffixes that
/// are applied left to right — `[]` = array elements, `{}` = dictionary VALUES (dynamic-id maps such as `imageMap{}`).
/// Keys are the union over all resolved objects:
/// `"body"`, `"body.items[]"`, `"body.post.body.imageMap{}"`, `"body.post.body.urlEmbedMap{}.postInfo"`;
/// `""` / `"$"` = the root object. Snapshots are keyed `"<endpointKey>:<path>"`.
///
/// Decoding failures of a 2xx response are reported through `recordFailure` as `.error` research events (SPEC §36).
///
/// `observe` never throws and returns immediately; parsing runs on a utility task, persistence on the main actor.
/// Unchanged observations of a path are coalesced (sample counts accumulate) for `persistInterval` seconds.
final class SchemaInspector: @unchecked Sendable {
    /// What one response showed for one object path.
    struct PathObservation: Sendable, Equatable {
        var path: String
        var known: Set<String>
        var observed: Set<String>
        var newFields: Set<String> { observed.subtracting(known) }
        var missingFields: Set<String> { known.subtracting(observed) }
    }

    private struct PathState {
        var observedUnion: Set<String>
        var newFields: Set<String>
        var missingFields: Set<String>
        var known: Set<String>
        var lastPersistedAt: Date
        var pendingSamples: Int
    }

    /// One JSON response captured while a Live API check runs (Research Mode).
    struct CapturedResponse: Sendable {
        var endpointKey: String
        var rawJSON: Data
        var known: [String: Set<String>]
    }

    let persistInterval: TimeInterval
    private let states = OSAllocatedUnfairLock(initialState: [String: PathState]())
    /// Non-nil while `beginCapture()` is active: every observed response is kept (at most `captureLimit`).
    private let capture = OSAllocatedUnfairLock<[CapturedResponse]?>(initialState: nil)
    static let captureLimit = 80
    /// Sink for `.error` research events (`recordFailure`); set once by AppEnvironment, readable from any thread.
    private let recorder = OSAllocatedUnfairLock<ResearchRecorder?>(initialState: nil)
    @MainActor private var store: LocalStore?

    init() {
        self.persistInterval = 30
    }

    /// `persistInterval` 0 persists every observation (tests).
    init(persistInterval: TimeInterval) {
        self.persistInterval = max(0, persistInterval)
    }

    @MainActor
    func attach(store: LocalStore) {
        self.store = store
    }

    /// Where `recordFailure` sends its research events.
    func attach(recorder: ResearchRecorder) {
        self.recorder.withLock { $0 = recorder }
    }

    // MARK: - Failures (research events)

    /// Reports a response that reached the client with a 2xx status but could not be used — an undecodable body or an
    /// `{ "error": … }` envelope. Such a failure is the strongest sign of an API change, so it becomes a `.error` research
    /// event (Sync / Errors list, "エラーのみ") instead of hiding behind a plain `200` request row. Callable from any thread;
    /// never throws. The description holds the endpoint key, the status and a secret-free reason (key path, never the payload).
    func recordFailure(endpointKey: String, accountID: String?, statusCode: Int?, error: Error) {
        if let remote = error as? RemoteError, remote == .cancelled { return }
        let reason = ResearchRecorder.describe(error)
        AppLog.research.error("\(SecretRedactor.redact(endpointKey), privacy: .public) unusable response: \(SecretRedactor.redact(reason), privacy: .public)")
        guard let sink = recorder.withLock({ $0 }) else { return }
        let status = statusCode.map { "HTTP \($0) · " } ?? ""
        sink.recordError("\(status)\(reason)", accountID: accountID, endpoint: endpointKey)
    }

    /// - Parameters:
    ///   - endpointKey: e.g. "post.info"
    ///   - rawJSON: full response body
    ///   - known: object path → field names the DTO understands, e.g. ["body": ["id", "title", ...], "body.items[]": [...]]
    func observe(endpointKey: String, rawJSON: Data, known: [String: Set<String>]) {
        guard !rawJSON.isEmpty else { return }
        capture.withLock { buffer in
            guard buffer != nil, buffer!.count < Self.captureLimit else { return }
            buffer!.append(CapturedResponse(endpointKey: endpointKey, rawJSON: rawJSON, known: known))
        }
        guard !known.isEmpty else { return }
        Task.detached(priority: .utility) { [self] in
            await self.observeAndWait(endpointKey: endpointKey, rawJSON: rawJSON, known: known)
        }
    }

    /// Same as `observe` but completes after persistence (tests / callers that want ordering).
    func observeAndWait(endpointKey: String, rawJSON: Data, known: [String: Set<String>], now: Date = .now) async {
        let observations = Self.analyze(rawJSON: rawJSON, known: known)
        guard !observations.isEmpty else { return }
        let changes = coalesce(endpointKey: endpointKey, observations: observations, now: now)
        guard !changes.isEmpty else { return }
        await persist(changes, now: now)
    }

    // MARK: - Capture (Live API check)

    /// Starts keeping every observed response in memory (responses are never persisted by the capture).
    func beginCapture() {
        capture.withLock { $0 = [] }
    }

    /// Stops capturing and returns what was observed since `beginCapture()`.
    func endCapture() -> [CapturedResponse] {
        capture.withLock { buffer in
            let result = buffer ?? []
            buffer = nil
            return result
        }
    }

    // MARK: - Analysis (pure)

    /// Parses JSON and collects observed keys per known path. Paths whose object is absent are skipped.
    static func analyze(rawJSON: Data, known: [String: Set<String>]) -> [PathObservation] {
        guard let root = try? JSONSerialization.jsonObject(with: rawJSON, options: [.fragmentsAllowed]) else { return [] }
        var result: [PathObservation] = []
        for (path, fields) in known.sorted(by: { $0.key < $1.key }) {
            let objects = resolve(path: path, in: root)
            guard !objects.isEmpty else { continue }
            var observed = Set<String>()
            for object in objects { observed.formUnion(object.keys) }
            result.append(PathObservation(path: path, known: fields, observed: observed))
        }
        return result
    }

    /// Objects (dictionaries) found at `path`. Non-object results are ignored.
    /// - `[]` flattens array elements.
    /// - `{}` flattens dictionary values. A JSON array in that position (PHP encodes an empty map as `[]`, and a map with
    ///   sequential keys as a list) contributes its elements, mirroring the tolerant `LenientObject.map` decoding.
    static func resolve(path: String, in root: Any) -> [[String: Any]] {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        var current: [Any] = [root]
        if !(trimmed.isEmpty || trimmed == "$") {
            for rawComponent in trimmed.split(separator: ".", omittingEmptySubsequences: true) {
                let component = PathComponent(rawComponent)
                if component.name == "$" && component.suffixes.isEmpty { continue }
                var next: [Any] = []
                for value in current {
                    if component.name.isEmpty {
                        next.append(value)
                    } else if let dict = value as? [String: Any], let child = dict[component.name] {
                        next.append(child)
                    }
                }
                for suffix in component.suffixes {
                    next = next.flatMap { suffix.children(of: $0) }
                }
                current = next
                if current.isEmpty { break }
            }
        }
        return current.compactMap { $0 as? [String: Any] }
    }

    /// One dot-separated path component: `name` plus its collection suffixes in application order.
    struct PathComponent: Equatable {
        enum Suffix: Equatable {
            /// `[]`: elements of an array.
            case arrayElements
            /// `{}`: values of a dictionary keyed by dynamic ids.
            case mapValues

            func children(of value: Any) -> [Any] {
                switch self {
                case .arrayElements:
                    return (value as? [Any]) ?? []
                case .mapValues:
                    if let dict = value as? [String: Any] { return dict.keys.sorted().compactMap { dict[$0] } }
                    return (value as? [Any]) ?? []
                }
            }
        }

        var name: String
        var suffixes: [Suffix]

        init(_ raw: Substring) {
            var rest = raw
            var reversed: [Suffix] = []
            while true {
                if rest.hasSuffix("[]") {
                    reversed.append(.arrayElements)
                } else if rest.hasSuffix("{}") {
                    reversed.append(.mapValues)
                } else {
                    break
                }
                rest = rest.dropLast(2)
            }
            name = String(rest)
            suffixes = reversed.reversed()
        }
    }

    // MARK: - Coalescing

    private struct Change: Sendable {
        var key: String
        var known: Set<String>
        var observedUnion: Set<String>
        var newFields: Set<String>
        var missingFields: Set<String>
        var samples: Int
    }

    private func coalesce(endpointKey: String, observations: [PathObservation], now: Date) -> [Change] {
        states.withLock { states -> [Change] in
            var changes: [Change] = []
            for obs in observations {
                let key = "\(endpointKey):\(obs.path)"
                if var state = states[key] {
                    state.observedUnion.formUnion(obs.observed)
                    let newFields = state.observedUnion.subtracting(obs.known)
                    let missing = obs.missingFields
                    let changed = newFields != state.newFields || missing != state.missingFields || obs.known != state.known
                    state.pendingSamples += 1
                    state.newFields = newFields
                    state.missingFields = missing
                    state.known = obs.known
                    if changed || now.timeIntervalSince(state.lastPersistedAt) >= persistInterval {
                        changes.append(Change(key: key, known: obs.known, observedUnion: state.observedUnion, newFields: newFields,
                                              missingFields: missing, samples: state.pendingSamples))
                        state.pendingSamples = 0
                        state.lastPersistedAt = now
                    }
                    states[key] = state
                } else {
                    // First observation in this process: always persist (merges with the stored snapshot).
                    let state = PathState(observedUnion: obs.observed, newFields: obs.newFields, missingFields: obs.missingFields,
                                          known: obs.known, lastPersistedAt: now, pendingSamples: 0)
                    states[key] = state
                    changes.append(Change(key: key, known: obs.known, observedUnion: obs.observed, newFields: obs.newFields,
                                          missingFields: obs.missingFields, samples: 1))
                }
            }
            return changes
        }
    }

    // MARK: - Persistence (main actor)

    @MainActor
    private func persist(_ changes: [Change], now: Date) {
        guard let store else { return }
        for change in changes {
            let key = change.key
            let existing = store.first(#Predicate<APISchemaSnapshot> { $0.endpointKey == key })
            let snapshot: APISchemaSnapshot
            var loggedNew: Set<String>
            if let existing {
                snapshot = existing
                let storedObserved = Set(existing.observedFields)
                let union = storedObserved.union(change.observedUnion)
                let newFields = union.subtracting(change.known)
                let oldNew = Set(existing.newFields)
                let oldMissing = Set(existing.missingFields)
                loggedNew = newFields.subtracting(oldNew)
                snapshot.knownFields = change.known.sorted()
                snapshot.observedFields = union.sorted()
                snapshot.newFields = newFields.sorted()
                snapshot.missingFields = change.missingFields.sorted()
                if newFields != oldNew || change.missingFields != oldMissing {
                    snapshot.lastChangedAt = now
                }
                snapshot.sampleCount += change.samples
            } else {
                snapshot = APISchemaSnapshot(endpointKey: key, knownFields: change.known.sorted(), firstSeenAt: now)
                snapshot.observedFields = change.observedUnion.sorted()
                snapshot.newFields = change.newFields.sorted()
                snapshot.missingFields = change.missingFields.sorted()
                snapshot.sampleCount = change.samples
                if !change.newFields.isEmpty || !change.missingFields.isEmpty {
                    snapshot.lastChangedAt = now
                }
                store.context.insert(snapshot)
                loggedNew = change.newFields
            }
            snapshot.lastSeenAt = now

            if !loggedNew.isEmpty {
                let detail = "New: " + loggedNew.sorted().joined(separator: ", ")
                    + (change.missingFields.isEmpty ? "" : "\nMissing: " + change.missingFields.sorted().joined(separator: ", "))
                store.context.insert(ResearchLog(timestamp: now, kind: .schema, endpoint: SecretRedactor.redact(key),
                                                 responseBody: SecretRedactor.redact(detail)))
                AppLog.research.info("schema change at \(SecretRedactor.redact(key), privacy: .public): \(loggedNew.count) new field(s)")
            }
        }
        store.save()
    }
}

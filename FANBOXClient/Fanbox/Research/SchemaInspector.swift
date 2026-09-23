import Foundation
import os
import SwiftData

/// API Inspector (SPEC §37): compares raw JSON keys against the fields the DTOs know,
/// and records new / missing fields per endpoint + object path into `APISchemaSnapshot`.
/// Decoders are tolerant, so unknown fields never break decoding; this only reports them.
///
/// Path syntax for `known`: dot-separated object keys, `[]` = array elements (keys are the union over elements):
/// `"body"`, `"body.items[]"`, `"body.body.blocks[]"`; `""` / `"$"` = the root object.
/// Snapshots are keyed `"<endpointKey>:<path>"`.
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

    let persistInterval: TimeInterval
    private let states = OSAllocatedUnfairLock(initialState: [String: PathState]())
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

    /// - Parameters:
    ///   - endpointKey: e.g. "post.info"
    ///   - rawJSON: full response body
    ///   - known: object path → field names the DTO understands, e.g. ["body": ["id", "title", ...], "body.items[]": [...]]
    func observe(endpointKey: String, rawJSON: Data, known: [String: Set<String>]) {
        guard !known.isEmpty, !rawJSON.isEmpty else { return }
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

    /// Objects (dictionaries) found at `path`. `[]` flattens arrays; non-object elements are ignored.
    static func resolve(path: String, in root: Any) -> [[String: Any]] {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        var current: [Any] = [root]
        if !(trimmed.isEmpty || trimmed == "$") {
            for rawComponent in trimmed.split(separator: ".", omittingEmptySubsequences: true) {
                var component = Substring(rawComponent)
                if component == "$" { continue }
                var arrayDepth = 0
                while component.hasSuffix("[]") {
                    component = component.dropLast(2)
                    arrayDepth += 1
                }
                var next: [Any] = []
                for value in current {
                    if component.isEmpty {
                        next.append(value)
                    } else if let dict = value as? [String: Any], let child = dict[String(component)] {
                        next.append(child)
                    }
                }
                for _ in 0..<arrayDepth {
                    next = next.flatMap { ($0 as? [Any]) ?? [] }
                }
                current = next
                if current.isEmpty { break }
            }
        }
        return current.compactMap { $0 as? [String: Any] }
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

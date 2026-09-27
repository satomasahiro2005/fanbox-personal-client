import SwiftData
import SwiftUI

/// Pure helpers for the API Inspector (SPEC §37). Unit-tested.
enum APISchemaGrouping {
    struct Group<Item>: Identifiable {
        let endpoint: String
        let items: [Item]
        var id: String { endpoint }
    }

    /// "post.info:body.body.blocks[]" → ("post.info", "body.body.blocks[]"); "post.info" → ("post.info", "").
    static func split(_ endpointKey: String) -> (endpoint: String, path: String) {
        guard let colon = endpointKey.firstIndex(of: ":") else { return (endpointKey, "") }
        return (String(endpointKey[..<colon]), String(endpointKey[endpointKey.index(after: colon)...]))
    }

    static func pathLabel(_ path: String) -> String { path.isEmpty ? "(root)" : path }

    /// Groups by endpoint (sorted), items sorted by path. Endpoints with new / missing fields come first when `changedFirst`.
    static func group<Item>(_ items: [Item], key: (Item) -> String, hasChanges: (Item) -> Bool = { _ in false },
                            changedFirst: Bool = false) -> [Group<Item>] {
        let byEndpoint = Dictionary(grouping: items) { split(key($0)).endpoint }
        var groups = byEndpoint.map { endpoint, members in
            Group(endpoint: endpoint, items: members.sorted { split(key($0)).path < split(key($1)).path })
        }
        groups.sort { a, b in
            if changedFirst {
                let ac = a.items.contains(where: hasChanges), bc = b.items.contains(where: hasChanges)
                if ac != bc { return ac }
            }
            return a.endpoint < b.endpoint
        }
        return groups
    }

    static func hasChanges(_ snapshot: APISchemaSnapshot) -> Bool {
        !snapshot.newFields.isEmpty || !snapshot.missingFields.isEmpty
    }

    /// Number of snapshots with new (unknown) fields — "Schema Change Detection" badge.
    static func changedCount(_ snapshots: [APISchemaSnapshot]) -> Int {
        snapshots.filter { !$0.newFields.isEmpty }.count
    }

    /// Plain-text summary for exports: one line per snapshot with changes.
    static func summaryLine(endpointKey: String, known: Int, newFields: [String], missingFields: [String]) -> String {
        var line = "\(endpointKey): known \(known)"
        if !newFields.isEmpty { line += ", NEW [\(newFields.sorted().joined(separator: ", "))]" }
        if !missingFields.isEmpty { line += ", MISSING [\(missingFields.sorted().joined(separator: ", "))]" }
        return line
    }

    static func exportLines(_ snapshots: [APISchemaSnapshot]) -> [String] {
        snapshots.sorted { $0.endpointKey < $1.endpointKey }.map {
            summaryLine(endpointKey: $0.endpointKey, known: $0.knownFields.count, newFields: $0.newFields, missingFields: $0.missingFields)
        }
    }
}

/// API Inspector list: observed schemas grouped by endpoint (SPEC §37).
struct APIInspectorView: View {
    @Query(sort: \APISchemaSnapshot.endpointKey) private var snapshots: [APISchemaSnapshot]
    @State private var changedOnly = false
    @State private var searchText = ""

    var body: some View {
        let filtered = snapshots.filter { snapshot in
            (!changedOnly || APISchemaGrouping.hasChanges(snapshot))
                && (searchText.isEmpty || snapshot.endpointKey.localizedCaseInsensitiveContains(searchText))
        }
        let groups = APISchemaGrouping.group(filtered, key: \.endpointKey, hasChanges: { APISchemaGrouping.hasChanges($0) },
                                             changedFirst: true)
        let changed = APISchemaGrouping.changedCount(snapshots)
        List {
            Section {
                Toggle("変化があるものだけ", isOn: $changedOnly)
                if changed > 0 {
                    Label("\(changed)件のschemaに未知のフィールドがあります", systemImage: "sparkles")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            if groups.isEmpty {
                EmptyStateView(title: "Schemaの記録がありません", systemImage: "curlybraces",
                               message: "FANBOX APIのレスポンスを受け取ると、endpointごとのフィールドが記録されます。")
            }

            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { snapshot in
                        NavigationLink {
                            APISchemaDetailView(endpointKey: snapshot.endpointKey)
                        } label: {
                            APISchemaRow(snapshot: snapshot)
                        }
                    }
                } header: {
                    HStack {
                        Text(group.endpoint).textCase(nil).font(.subheadline.monospaced())
                        if group.items.contains(where: { !$0.newFields.isEmpty }) {
                            PillLabel(text: "New", systemImage: "sparkles", tint: .orange)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "endpoint")
        .navigationTitle("API Schema")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("apiInspectorList")
    }
}

private struct APISchemaRow: View {
    let snapshot: APISchemaSnapshot

    var body: some View {
        let path = APISchemaGrouping.split(snapshot.endpointKey).path
        VStack(alignment: .leading, spacing: 4) {
            Text(APISchemaGrouping.pathLabel(path))
                .font(.callout.monospaced())
                .lineLimit(2)
            HStack(spacing: 6) {
                Text("Known \(snapshot.knownFields.count)")
                Text("Observed \(snapshot.observedFields.count)")
                if !snapshot.newFields.isEmpty {
                    PillLabel(text: "New \(snapshot.newFields.count)", tint: .orange)
                }
                if !snapshot.missingFields.isEmpty {
                    PillLabel(text: "Missing \(snapshot.missingFields.count)", tint: .red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// SPEC §37 layout: endpoint, Known fields, highlighted New / Missing fields.
struct APISchemaDetailView: View {
    let endpointKey: String
    @Query private var matches: [APISchemaSnapshot]

    init(endpointKey: String) {
        self.endpointKey = endpointKey
        _matches = Query(filter: #Predicate<APISchemaSnapshot> { $0.endpointKey == endpointKey })
    }

    var body: some View {
        List {
            if let snapshot = matches.first {
                let parts = APISchemaGrouping.split(snapshot.endpointKey)
                Section {
                    LabeledContent("Endpoint") { Text(parts.endpoint).font(.callout.monospaced()) }
                    LabeledContent("Object path") { Text(APISchemaGrouping.pathLabel(parts.path)).font(.callout.monospaced()) }
                    LabeledContent("Samples", value: "\(snapshot.sampleCount)")
                    LabeledContent("First seen", value: SystemStatusText.date(snapshot.firstSeenAt))
                    LabeledContent("Last seen", value: SystemStatusText.date(snapshot.lastSeenAt))
                    LabeledContent("Last changed", value: SystemStatusText.date(snapshot.lastChangedAt))
                }

                Section {
                    if snapshot.newFields.isEmpty {
                        Text("なし").foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.newFields.sorted(), id: \.self) { field in
                        FieldRow(name: field, systemImage: "sparkles", tint: .orange)
                    }
                } header: {
                    Text("New (\(snapshot.newFields.count))")
                }

                Section {
                    if snapshot.missingFields.isEmpty {
                        Text("なし").foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.missingFields.sorted(), id: \.self) { field in
                        FieldRow(name: field, systemImage: "exclamationmark.triangle", tint: .red)
                    }
                } header: {
                    Text("Missing (\(snapshot.missingFields.count))")
                }

                Section("Known (\(snapshot.knownFields.count))") {
                    let missing = Set(snapshot.missingFields)
                    ForEach(snapshot.knownFields.sorted(), id: \.self) { field in
                        FieldRow(name: field, systemImage: missing.contains(field) ? "exclamationmark.triangle" : "checkmark",
                                 tint: missing.contains(field) ? .red : .secondary)
                    }
                }

                let extra = Set(snapshot.observedFields).subtracting(snapshot.knownFields).subtracting(snapshot.newFields)
                if !extra.isEmpty {
                    Section("Observed (過去に見えた未知フィールド)") {
                        ForEach(extra.sorted(), id: \.self) { field in
                            FieldRow(name: field, systemImage: "eye", tint: .secondary)
                        }
                    }
                }
            } else {
                EmptyStateView(title: "記録がありません", systemImage: "curlybraces")
            }
        }
        .navigationTitle(APISchemaGrouping.split(endpointKey).endpoint)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FieldRow: View {
    let name: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(name).font(.callout.monospaced()).textSelection(.enabled)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
    }
}

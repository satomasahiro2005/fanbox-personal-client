import SwiftData
import SwiftUI

/// Research Mode (SPEC §36): Requests / Responses / Navigation / API Schema / Account State / Support State / Scheduler.
struct ResearchModeView: View {
    @Environment(AppEnvironment.self) private var env
    @Query private var schemaSnapshots: [APISchemaSnapshot]
    @State private var counts = ResearchLogCounts()
    @State private var exportFileURL: URL?
    @State private var isExporting = false
    @State private var confirmClearLogs = false
    @State private var confirmResetSchema = false

    var body: some View {
        @Bindable var settings = env.settings
        let changed = APISchemaGrouping.changedCount(schemaSnapshots)
        List {
            Section {
                Toggle("Research Mode", isOn: $settings.researchModeEnabled)
                    .accessibilityIdentifier("researchModeInnerToggle")
                if !settings.researchModeEnabled {
                    Label("Research Mode がオフのため、メタデータ（メソッド・endpoint・ステータス・時間）だけを記録しています。"
                          + "レスポンス本文は保存されません。", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("researchMetadataOnlyNote")
                }
            } footer: {
                Text("表示するすべての値は、保存時と表示時の 2 回 Secret を伏せています（Cookie / FANBOXSESSID / Authorization / CSRF Token / パスワード / カード情報）。")
            }

            Section("通信") {
                NavigationLink {
                    ResearchLogListView(mode: .requests)
                } label: {
                    ResearchIndexRow(title: "Requests", systemImage: "arrow.up.circle", count: counts.requests)
                }
                .accessibilityIdentifier("researchRequestsLink")
                NavigationLink {
                    ResearchLogListView(mode: .responses)
                } label: {
                    ResearchIndexRow(title: "Responses", systemImage: "arrow.down.circle", count: counts.requests)
                }
                .accessibilityIdentifier("researchResponsesLink")
                NavigationLink {
                    ResearchLogListView(mode: .navigation)
                } label: {
                    ResearchIndexRow(title: "Navigation", systemImage: "safari", count: counts.navigation)
                }
                .accessibilityIdentifier("researchNavigationLink")
                NavigationLink {
                    ResearchLogListView(mode: .events)
                } label: {
                    ResearchIndexRow(title: "Sync / Errors", systemImage: "exclamationmark.bubble", count: counts.events)
                }
            }

            Section {
                NavigationLink {
                    APIInspectorView()
                } label: {
                    HStack {
                        Label("API Schema", systemImage: "curlybraces")
                        Spacer()
                        if changed > 0 {
                            PillLabel(text: "New \(changed)", systemImage: "sparkles", tint: .orange)
                        } else {
                            Text("\(schemaSnapshots.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .accessibilityIdentifier("researchSchemaLink")
            } header: {
                Text("API Inspector")
            } footer: {
                if changed > 0 {
                    Text("Schema Change Detection: 未知のフィールドを含む schema が \(changed) 件あります。")
                }
            }

            Section("状態") {
                NavigationLink {
                    ResearchAccountStateView()
                } label: {
                    Label("Account State", systemImage: "person.crop.circle.badge.checkmark")
                }
                .accessibilityIdentifier("researchAccountStateLink")
                NavigationLink {
                    ResearchSupportStateView()
                } label: {
                    Label("Support State", systemImage: "yensign.circle")
                }
                .accessibilityIdentifier("researchSupportStateLink")
                NavigationLink {
                    ResearchSchedulerView()
                } label: {
                    Label("Scheduler", systemImage: "gauge.with.dots.needle.33percent")
                }
                .accessibilityIdentifier("researchSchedulerLink")
            }

            Section {
                Button {
                    prepareExport()
                } label: {
                    Label(isExporting ? "書き出し中…" : "ログを書き出す（Secret は伏せ字）", systemImage: "doc.text")
                }
                .disabled(isExporting)
                .accessibilityIdentifier("researchPrepareExportButton")
                if let exportFileURL {
                    ShareLink(item: exportFileURL) {
                        Label("共有", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("researchShareExportLink")
                }
                Button(role: .destructive) {
                    confirmClearLogs = true
                } label: {
                    Label("ログを削除", systemImage: "trash")
                }
                .accessibilityIdentifier("researchClearLogsButton")
                Button(role: .destructive) {
                    confirmResetSchema = true
                } label: {
                    Label("API Schema の記録をリセット", systemImage: "arrow.counterclockwise")
                }
            } header: {
                Text("操作")
            } footer: {
                Text("書き出しには最新 \(ResearchExportBuilder.maxEntries) 件までを含めます。本文は 1 件あたり \(ResearchLogFormatter.exportBodyLimit) 文字までです。")
            }
        }
        .navigationTitle("Research Mode")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("researchModeView")
        .task {
            env.research.flush()
            counts = ResearchLogCounts.load(store: env.store)
        }
        .refreshable {
            env.research.flush()
            counts = ResearchLogCounts.load(store: env.store)
        }
        .confirmationDialog("Research ログを削除しますか？", isPresented: $confirmClearLogs, titleVisibility: .visible) {
            Button("ログを削除", role: .destructive) {
                env.research.clearAll()
                ResearchExportBuilder.removeExports()
                exportFileURL = nil
                counts = ResearchLogCounts.load(store: env.store)
            }
            .accessibilityIdentifier("researchConfirmClearLogsButton")
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog("API Schema の記録をリセットしますか？", isPresented: $confirmResetSchema, titleVisibility: .visible) {
            Button("リセット", role: .destructive) { ResearchMaintenance.resetSchemaSnapshots(store: env.store) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("次に API のレスポンスを受け取ったときに、あらためて記録されます。")
        }
    }

    private func prepareExport() {
        isExporting = true
        defer { isExporting = false }
        env.research.flush()
        exportFileURL = ResearchExportBuilder.writeExport(store: env.store, researchModeEnabled: env.settings.researchModeEnabled)
    }
}

private struct ResearchIndexRow: View {
    let title: String
    let systemImage: String
    let count: Int

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// Row counts per log kind (cheap `fetchCount`).
struct ResearchLogCounts: Equatable {
    var requests = 0
    var navigation = 0
    var events = 0

    @MainActor
    static func load(store: LocalStore) -> ResearchLogCounts {
        func count(_ kinds: [String]) -> Int {
            let descriptor = FetchDescriptor<ResearchLog>(predicate: #Predicate { kinds.contains($0.kindRaw) })
            return (try? store.context.fetchCount(descriptor)) ?? 0
        }
        return ResearchLogCounts(requests: count(ResearchLogListMode.requests.kindRaws),
                                 navigation: count(ResearchLogListMode.navigation.kindRaws),
                                 events: count(ResearchLogListMode.events.kindRaws))
    }
}

/// Deletion helpers for Research data (user-initiated only).
enum ResearchMaintenance {
    @MainActor
    static func clearLogs(store: LocalStore) {
        for log in store.fetch(FetchDescriptor<ResearchLog>()) { store.context.delete(log) }
        store.save()
    }

    @MainActor
    static func resetSchemaSnapshots(store: LocalStore) {
        for snapshot in store.fetch(FetchDescriptor<APISchemaSnapshot>()) { store.context.delete(snapshot) }
        store.save()
    }
}

/// Builds the redacted plain-text export file.
enum ResearchExportBuilder {
    static let maxEntries = 300

    static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ResearchExport", isDirectory: true)
    }

    @MainActor
    static func snapshots(store: LocalStore, limit: Int = maxEntries) -> [ResearchLogSnapshot] {
        var descriptor = FetchDescriptor<ResearchLog>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = limit
        let names = Dictionary(store.accounts(includeDisabled: true).map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        return store.fetch(descriptor).map { log in
            ResearchLogSnapshot(log, accountName: log.accountID.flatMap { names[$0] })
        }
    }

    @MainActor
    static func exportText(store: LocalStore, researchModeEnabled: Bool, now: Date = .now) -> String {
        let schema = APISchemaGrouping.exportLines(store.fetch(FetchDescriptor<APISchemaSnapshot>()))
        return ResearchLogFormatter.export(snapshots(store: store), schemaLines: schema, researchModeEnabled: researchModeEnabled,
                                           appVersion: AppVersionInfo.displayString(), generatedAt: now)
    }

    /// Writes the export into a protected temporary file and returns its URL (nil on failure).
    @MainActor
    static func writeExport(store: LocalStore, researchModeEnabled: Bool, now: Date = .now) -> URL? {
        removeExports()
        let text = exportText(store: store, researchModeEnabled: researchModeEnabled, now: now)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = exportDirectory
        let url = dir.appendingPathComponent("FANBOX-Research-\(f.string(from: now)).txt")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            AppLog.database.error("research export failed: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    /// Deletes earlier export files (they are only needed while the share sheet is open).
    static func removeExports() {
        try? FileManager.default.removeItem(at: exportDirectory)
    }
}

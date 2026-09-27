import SwiftData
import SwiftUI

/// Which slice of `ResearchLog` a list shows.
enum ResearchLogListMode: String, CaseIterable, Identifiable {
    /// kind .request, request-oriented columns (method / endpoint / priority / duration).
    case requests
    /// kind .request, response-oriented columns (status / bytes / body / error).
    case responses
    /// kind .navigation (account-aware WebView main-frame navigations).
    case navigation
    /// kind .sync / .error / .schema / .note.
    case events

    var id: String { rawValue }

    var title: String {
        switch self {
        case .requests: return "Requests"
        case .responses: return "Responses"
        case .navigation: return "Navigation"
        case .events: return "Sync / Errors"
        }
    }

    var kinds: [ResearchLogKind] {
        switch self {
        case .requests, .responses: return [.request]
        case .navigation: return [.navigation]
        case .events: return [.sync, .error, .schema, .note]
        }
    }

    var kindRaws: [String] { kinds.map(\.rawValue) }
}

/// Newest-first list of research log entries (at most `fetchLimit` rows).
struct ResearchLogListView: View {
    let mode: ResearchLogListMode
    @Query private var logs: [ResearchLog]
    @State private var searchText = ""
    @State private var problemsOnly = false

    static let fetchLimit = 500

    init(mode: ResearchLogListMode) {
        self.mode = mode
        let kinds = mode.kindRaws
        var descriptor = FetchDescriptor<ResearchLog>(predicate: #Predicate { kinds.contains($0.kindRaw) },
                                                      sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = Self.fetchLimit
        _logs = Query(descriptor)
    }

    var body: some View {
        let visible = logs.filter { log in
            (!problemsOnly || ResearchLogListView.isProblem(log))
                && (searchText.isEmpty || log.endpoint.localizedCaseInsensitiveContains(searchText)
                    || (log.method ?? "").localizedCaseInsensitiveContains(searchText))
        }
        List {
            Section {
                Toggle("エラーのみ", isOn: $problemsOnly)
            } footer: {
                if logs.count >= Self.fetchLimit {
                    Text("最新\(Self.fetchLimit)件を表示しています")
                }
            }
            if visible.isEmpty {
                EmptyStateView(title: "ログがありません", systemImage: "list.bullet.rectangle")
            }
            ForEach(visible) { log in
                NavigationLink {
                    ResearchLogDetailView(logID: log.id, focus: mode)
                } label: {
                    ResearchLogRow(log: log, mode: mode)
                }
            }
        }
        .searchable(text: $searchText, prompt: "endpoint / method")
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("researchLogList_\(mode.rawValue)")
    }

    static func isProblem(_ log: ResearchLog) -> Bool {
        if let code = log.statusCode, code >= 400 { return true }
        if log.errorDescription?.isEmpty == false { return true }
        return log.kind == .error
    }
}

private struct ResearchLogRow: View {
    let log: ResearchLog
    let mode: ResearchLogListMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                switch mode {
                case .requests:
                    Text(ResearchLogFormatter.safe(log.method) ?? "—").font(.caption.bold().monospaced())
                    if let raw = log.priorityRaw, let p = RequestPriority(rawValue: raw) {
                        PillLabel(text: p.displayName, tint: p.isInteractive ? .accentColor : .secondary)
                    }
                    Spacer()
                    Text(ResearchLogFormatter.durationText(log.durationMs)).font(.caption).monospacedDigit()
                case .responses:
                    ResearchStatusBadge(code: log.statusCode, error: log.errorDescription)
                    Text(ResearchLogFormatter.bytesText(log.bytes)).font(.caption)
                    if !log.responseBody.isEmpty {
                        PillLabel(text: "body", tint: .secondary)
                    }
                    Spacer()
                    Text(ResearchLogFormatter.safe(log.method) ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                case .navigation, .events:
                    Text(log.kind.rawValue).font(.caption.bold().monospaced())
                    if log.statusCode != nil || log.errorDescription != nil {
                        ResearchStatusBadge(code: log.statusCode, error: log.errorDescription)
                    }
                    Spacer()
                }
            }
            Text(ResearchLogFormatter.safe(log.endpoint))
                .font(.caption.monospaced())
                .lineLimit(3)
            if mode == .responses || mode == .events, let error = log.errorDescription, !error.isEmpty {
                Text(ResearchLogFormatter.safe(error)).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
            HStack(spacing: 8) {
                if let accountID = log.accountID {
                    AccountBadge(accountID: accountID)
                }
                Spacer()
                Text(log.timestamp.formatted(.dateTime.month().day().hour().minute().second()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }
}

struct ResearchStatusBadge: View {
    let code: Int?
    let error: String?

    var body: some View {
        let cls = ResearchLogFormatter.statusClass(code: code, error: error)
        PillLabel(text: code.map { "\($0)" } ?? (cls == .failed ? "ERR" : "—"), tint: color(cls))
    }

    private func color(_ cls: ResearchLogFormatter.StatusClass) -> Color {
        switch cls {
        case .success: return .green
        case .redirect: return .blue
        case .clientError: return .orange
        case .serverError, .failed: return .red
        case .pending: return .secondary
        }
    }
}

/// SPEC §44 Research display: HTTP Status / Endpoint / Method / Safe Response Body / headers / Account / Timestamp.
///
/// The row is read once and rendered off the main actor (`ResearchLogRendering`): no `@Query`, so background saves
/// by the recorder never re-run the redaction / formatting while the screen is open; the pretty-JSON toggle and the
/// share button only use cached strings; bodies render as lazy rows.
struct ResearchLogDetailView: View {
    let logID: String
    var focus: ResearchLogListMode = .requests
    @Environment(AppEnvironment.self) private var env
    @State private var rendering: ResearchLogRendering?
    @State private var isMissing = false
    @State private var prettyJSON = true

    init(logID: String, focus: ResearchLogListMode = .requests) {
        self.logID = logID
        self.focus = focus
    }

    var body: some View {
        List {
            if let rendering {
                Section("概要") {
                    ForEach(rendering.summary) { field in
                        LabeledContent(field.label) {
                            Text(field.value)
                                .font(.callout.monospaced())
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }
                if focus == .responses {
                    bodySection(rendering)
                    headerSections(rendering)
                } else {
                    headerSections(rendering)
                    bodySection(rendering)
                }
                if !rendering.hasBody && !env.settings.researchModeEnabled {
                    Section {
                        Text("Research Modeがオフの間はレスポンス本文を記録しません。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if isMissing {
                EmptyStateView(title: "ログが見つかりません", systemImage: "trash", message: "削除された可能性があります。")
            } else {
                HStack {
                    Spacer()
                    ProgressView("整形中…")
                    Spacer()
                }
            }
        }
        .navigationTitle(focus == .responses ? "Response" : (focus == .navigation ? "Navigation" : "Request"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let rendering {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: rendering.shareText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("このログを共有")
                }
            }
        }
        .accessibilityIdentifier("researchLogDetail")
        .task(id: logID) { await load() }
    }

    private func headerSections(_ rendering: ResearchLogRendering) -> some View {
        ForEach(rendering.headerBlocks) { block in
            Section {
                ForEach(block.chunks) { chunk in
                    BlockText(text: chunk.text)
                }
            } header: {
                Text(block.label)
            }
        }
    }

    private func bodySection(_ rendering: ResearchLogRendering) -> some View {
        let body = (prettyJSON ? rendering.prettyBody : nil) ?? rendering.plainBody
        return Section {
            if rendering.prettyBody != nil {
                Toggle("JSONを整形", isOn: $prettyJSON)
            }
            ForEach(body.chunks) { chunk in
                BlockText(text: chunk.text)
            }
        } header: {
            Text(ResearchLogRendering.bodyLabel)
        } footer: {
            if body.truncatedCount > 0 {
                Text("…（\(body.truncatedCount)文字省略）")
            }
        }
    }

    /// Reads the row once, then redacts / formats it on a background thread.
    private func load() async {
        let id = logID
        guard let log = env.store.first(#Predicate<ResearchLog> { $0.id == id }) else {
            isMissing = true
            return
        }
        let snapshot = ResearchLogSnapshot(log, accountName: log.accountID.flatMap { env.store.account(id: $0)?.displayName })
        let result = await Task.detached(priority: .userInitiated) { ResearchLogRendering.make(snapshot) }.value
        guard !Task.isCancelled else { return }
        rendering = result
    }
}

private struct BlockText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

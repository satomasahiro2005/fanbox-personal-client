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
                Text("最新 \(Self.fetchLimit) 件まで表示します。")
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
struct ResearchLogDetailView: View {
    let logID: String
    var focus: ResearchLogListMode = .requests
    @Environment(AppEnvironment.self) private var env
    @Query private var matches: [ResearchLog]
    @State private var prettyJSON = true

    init(logID: String, focus: ResearchLogListMode = .requests) {
        self.logID = logID
        self.focus = focus
        _matches = Query(filter: #Predicate<ResearchLog> { $0.id == logID })
    }

    var body: some View {
        List {
            if let log = matches.first {
                let entry = ResearchLogSnapshot(log, accountName: log.accountID.flatMap { env.store.account(id: $0)?.displayName })
                let fields = ResearchLogFormatter.fields(for: entry)
                Section("概要") {
                    ForEach(fields.filter { !$0.isBlock }) { field in
                        LabeledContent(field.label) {
                            Text(field.value)
                                .font(.callout.monospaced())
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }
                ForEach(orderedBlocks(fields)) { field in
                    Section {
                        if field.label == "Safe Response Body" {
                            Toggle("JSON を整形", isOn: $prettyJSON)
                            BlockText(text: bodyText(entry))
                        } else {
                            BlockText(text: field.value)
                        }
                    } header: {
                        Text(field.label)
                    }
                }
                if entry.responseBody.isEmpty && !env.settings.researchModeEnabled {
                    Section {
                        Text("Research Mode がオフの間はレスポンス本文を記録しません。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                EmptyStateView(title: "ログが見つかりません", systemImage: "trash", message: "削除された可能性があります。")
            }
        }
        .navigationTitle(focus == .responses ? "Response" : (focus == .navigation ? "Navigation" : "Request"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let log = matches.first {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: ResearchLogFormatter.text(
                        for: ResearchLogSnapshot(log, accountName: log.accountID.flatMap { env.store.account(id: $0)?.displayName }),
                        bodyLimit: ResearchLogFormatter.displayBodyLimit)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("このログを共有")
                }
            }
        }
        .accessibilityIdentifier("researchLogDetail")
    }

    /// Responses show the body first; requests show request headers first.
    private func orderedBlocks(_ fields: [ResearchLogFormatter.Field]) -> [ResearchLogFormatter.Field] {
        let blocks = fields.filter(\.isBlock)
        guard focus == .responses else { return blocks }
        let isBody: (ResearchLogFormatter.Field) -> Bool = { $0.label == "Safe Response Body" }
        return blocks.filter(isBody) + blocks.filter { !isBody($0) }
    }

    private func bodyText(_ entry: ResearchLogSnapshot) -> String {
        let result = ResearchLogFormatter.displayBody(entry.responseBody, prettyJSON: prettyJSON)
        if result.text.isEmpty { return "(なし)" }
        return result.truncatedCount > 0 ? result.text + "\n… (\(result.truncatedCount) 文字省略)" : result.text
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

import SwiftData
import SwiftUI
import UIKit

/// Research Mode → Live API チェック: runs `LiveAPICheck` with one of the user's FANBOX accounts and shows, per endpoint,
/// whether the real service answered in the shape the app expects. The report can be shared (masked structure only).
struct LiveAPICheckView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(FetchDescriptorFactory.enabledAccounts()) private var accounts: [Account]
    @State private var check: LiveAPICheck?
    @State private var selectedAccountID: String?
    @State private var reportURL: URL?
    @State private var detail: LiveAPICheck.Step?
    @State private var confirmsRun = false

    private var fanboxAccounts: [Account] {
        accounts.filter { $0.kind == .fanbox && $0.sessionState != .error }
    }

    var body: some View {
        List {
            Section {
                if fanboxAccounts.isEmpty {
                    Label("FANBOXアカウントがありません。「設定」→「アカウント」からログインしてください（デモアカウントは対象外です）。",
                          systemImage: "person.crop.circle.badge.questionmark")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("アカウント", selection: $selectedAccountID) {
                        ForEach(fanboxAccounts) { account in
                            Text(account.displayName).tag(Optional(account.id))
                        }
                    }
                    .accessibilityIdentifier("liveCheckAccountPicker")
                    Button {
                        confirmsRun = true
                    } label: {
                        Label(check?.isRunning == true ? "実行中…" : "実行", systemImage: "play.circle")
                    }
                    .disabled(check?.isRunning == true || selectedAccountID == nil || env.networkMode.effectiveMode == .offline)
                    .accessibilityIdentifier("liveCheckRunButton")
                    .confirmationDialog("実際のFANBOXに送信します", isPresented: $confirmsRun, titleVisibility: .visible) {
                        Button("実行") { startCheck() }
                        Button("キャンセル", role: .cancel) {}
                    } message: {
                        Text("読み取りAPIを約20回、2秒間隔で送ります（書き込みはしません）。")
                    }
                    if check?.isRunning == true {
                        Button("中止", role: .destructive) { check?.cancel() }
                    }
                }
            }

            if let check, !check.steps.isEmpty {
                Section("結果") {
                    ForEach(check.steps) { step in
                        Button {
                            detail = step
                        } label: {
                            LiveCheckStepRow(step: step)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("liveCheckStep-\(step.id)")
                    }
                }
                if !check.isRunning, check.finishedAt != nil {
                    Section {
                        Button {
                            reportURL = check.writeReport(appVersion: AppVersionInfo.displayString())
                        } label: {
                            Label("レポートを作成", systemImage: "doc.badge.gearshape")
                        }
                        if let reportURL {
                            ShareLink(item: reportURL) {
                                Label("レポートを共有", systemImage: "square.and.arrow.up")
                            }
                            .accessibilityIdentifier("liveCheckShareReport")
                        }
                    } header: {
                        Text("レポート")
                    }
                }
            }
        }
        .navigationTitle("Live APIチェック")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $detail) { step in
            NavigationStack {
                LiveCheckStepDetailView(step: step, endpoints: check?.endpoints ?? [])
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("閉じる") { detail = nil } }
                    }
            }
        }
        .onAppear {
            if selectedAccountID == nil { selectedAccountID = fanboxAccounts.first(where: \.isMain)?.id ?? fanboxAccounts.first?.id }
        }
        .onDisappear {
            check?.cancel()
            if let reportURL { try? FileManager.default.removeItem(at: reportURL) }
        }
        .accessibilityIdentifier("liveCheckView")
    }

    private func startCheck() {
        guard let id = selectedAccountID, let account = fanboxAccounts.first(where: { $0.id == id }) else { return }
        if let reportURL { try? FileManager.default.removeItem(at: reportURL) }
        reportURL = nil
        let runner = check ?? LiveAPICheck(remote: env.remote, inspector: env.schemaInspector)
        check = runner
        runner.start(account: account.context)
    }
}

private struct LiveCheckStepRow: View {
    let step: LiveAPICheck.Step

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.subheadline.weight(.medium))
                if let error = step.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if !step.summary.isEmpty {
                    Text(step.summary).font(.caption).foregroundStyle(.secondary)
                }
                let newCount = step.newFields.values.reduce(0) { $0 + $1.count }
                let missingCount = step.missingFields.values.reduce(0) { $0 + $1.count }
                if newCount + missingCount > 0 {
                    HStack(spacing: 6) {
                        if missingCount > 0 { PillLabel(text: "欠落\(missingCount)", systemImage: "minus.circle", tint: .orange) }
                        if newCount > 0 { PillLabel(text: "未知\(newCount)", systemImage: "sparkles", tint: .blue) }
                    }
                }
            }
            Spacer(minLength: 0)
            if let ms = step.durationMs {
                Text("\(ms) ms").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch step.status {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "forward.circle").foregroundStyle(.secondary)
        }
    }
}

private struct LiveCheckStepDetailView: View {
    let step: LiveAPICheck.Step
    let endpoints: [LiveAPICheck.EndpointResult]

    var body: some View {
        List {
            Section("結果") {
                LabeledContent("状態", value: step.status.rawValue)
                if !step.summary.isEmpty { Text(step.summary).font(.callout) }
                if let error = step.error { Text(error).font(.callout).foregroundStyle(.red) }
                if let ms = step.durationMs { LabeledContent("時間", value: "\(ms) ms") }
            }
            ForEach(step.endpointKeys, id: \.self) { key in
                let result = endpoints.first { $0.endpointKey == key }
                Section(key) {
                    fieldList("DTOが知っているのに無かったフィールド（改名・廃止の可能性）", step.missingFields, tint: .orange)
                    fieldList("DTOが知らないフィールド（新規）", step.newFields, tint: .blue)
                    if let shape = result?.shapeJSON, !shape.isEmpty {
                        NavigationLink("レスポンス構造（伏せ字済み）") {
                            ScrollView([.vertical, .horizontal]) {
                                Text(shape.count > 40_000 ? String(shape.prefix(40_000)) + "\n…" : shape)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .padding()
                            }
                            .navigationTitle(key)
                        }
                    }
                }
            }
        }
        .navigationTitle(step.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func fieldList(_ title: String, _ fields: [String: [String]], tint: Color) -> some View {
        if !fields.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint)
                ForEach(fields.keys.sorted(), id: \.self) { path in
                    Text("\(path): \(fields[path]?.joined(separator: ", ") ?? "")")
                        .font(.caption.monospaced())
                }
            }
        }
    }
}

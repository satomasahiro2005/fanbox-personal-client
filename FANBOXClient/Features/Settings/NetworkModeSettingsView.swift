import SwiftUI

/// SPEC §30 mode table, derived from the real `MediaPolicy` so the explanation can never drift from the behavior.
enum NetworkModeGuide {
    enum Cell: String, Equatable, Sendable {
        case on = "ON"
        case manual = "手動"
        case off = "OFF"

        init(_ decision: MediaDecision) {
            switch decision {
            case .allowed: self = .on
            case .manualOnly: self = .manual
            case .blocked: self = .off
            }
        }
    }

    struct Row: Identifiable, Equatable, Sendable {
        let label: String
        /// nil = text / JSON row (uses `MediaPolicy.allowsText`).
        let kind: MediaKind?
        let variant: MediaVariant
        let trigger: MediaTrigger
        var id: String { label }
    }

    static let modes: [NetworkMode] = [.normal, .lowData, .extreme, .offline]

    static let rows: [Row] = [
        Row(label: "本文 / JSON", kind: nil, variant: .thumbnail, trigger: .automatic),
        Row(label: "Thumbnail", kind: .image, variant: .thumbnail, trigger: .automatic),
        Row(label: "Display Image", kind: .image, variant: .display, trigger: .automatic),
        Row(label: "Original Image", kind: .image, variant: .original, trigger: .automatic),
        Row(label: "Video", kind: .video, variant: .original, trigger: .automatic),
        Row(label: "Audio / File", kind: .file, variant: .original, trigger: .automatic),
        Row(label: "Image Prefetch", kind: .image, variant: .display, trigger: .prefetch),
        Row(label: "Original Prefetch", kind: .image, variant: .original, trigger: .prefetch),
        Row(label: "Video Prefetch", kind: .video, variant: .original, trigger: .prefetch),
    ]

    /// Cell of the table for `mode`, assuming a connected Wi-Fi path (Wi-Fi-only prefetch is explained separately).
    static func cell(_ row: Row, mode: NetworkMode, extremeShowsThumbnails: Bool) -> Cell {
        let policy = NetworkPolicySnapshot(mode: mode, pathSatisfied: true, isOnWiFi: true, isConstrained: false, isExpensive: false,
                                           mediaPrefetchWiFiOnly: false, extremeShowsThumbnails: extremeShowsThumbnails)
        guard let kind = row.kind else { return MediaPolicy.allowsText(policy: policy) ? .on : .off }
        return Cell(MediaPolicy.decide(kind: kind, variant: row.variant, trigger: row.trigger, policy: policy))
    }

    static func summary(_ preference: NetworkModePreference) -> String {
        switch preference {
        case .automatic:
            return "Network.frameworkの状態から自動で決めます。未接続ならOffline、iOSの省データモード（Low Data Mode）ならLow Data、それ以外はNormal。"
        case .normal:
            return "本文・Thumbnail・表示用画像を通常どおり取得し、先読み（Prefetch）も行います。"
        case .lowData:
            return "本文とThumbnailは取得します。Original画像と動画の先読みは行いません。"
        case .extreme:
            return "JSON / テキストのみ自動取得します。画像・音声・動画・ファイルはタップしたときだけ取得します（Thumbnailは設定で選択）。"
        case .offline:
            return "ネットワーク通信を完全に停止します。保存済みのデータで閲覧・検索・下書き・返信の作成ができます。"
        }
    }
}

/// "通信モード" section of the Settings root (SPEC §30 / §35).
struct NetworkModeSettingsSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        let network = env.networkMode
        Section {
            Picker("通信モード", selection: $settings.networkModePreference) {
                ForEach(NetworkModePreference.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityIdentifier("networkModePicker")

            LabeledContent("現在のモード") {
                Text(network.effectiveMode.displayName)
                    .foregroundStyle(network.effectiveMode == .normal ? Color.secondary : Color.orange)
            }
            .accessibilityIdentifier("effectiveNetworkMode")

            LabeledContent("回線", value: NetworkPathText.describe(network))

            Toggle("メディアの先読みはWi-Fiのときだけ", isOn: $settings.mediaPrefetchWiFiOnly)
                .accessibilityIdentifier("mediaPrefetchWiFiOnlyToggle")
            Toggle("ExtremeでもThumbnailを表示", isOn: $settings.extremeShowsThumbnails)
                .accessibilityIdentifier("extremeShowsThumbnailsToggle")

            NavigationLink {
                NetworkModeGuideView()
            } label: {
                Label("各モードの説明", systemImage: "tablecells")
            }
            .accessibilityIdentifier("networkModeGuideLink")
        } header: {
            Text("通信モード")
        }
        .onChange(of: settings.networkModePreference) { _, _ in network.recompute() }
        .onChange(of: settings.mediaPrefetchWiFiOnly) { _, _ in network.recompute() }
        .onChange(of: settings.extremeShowsThumbnails) { _, _ in network.recompute() }
    }
}

enum NetworkPathText {
    @MainActor
    static func describe(_ network: NetworkModeController) -> String {
        describe(pathSatisfied: network.pathSatisfied, isOnWiFi: network.isOnWiFi, isConstrained: network.isConstrained,
                 isExpensive: network.isExpensive)
    }

    static func describe(pathSatisfied: Bool, isOnWiFi: Bool, isConstrained: Bool, isExpensive: Bool) -> String {
        guard pathSatisfied else { return "未接続" }
        var parts = [isOnWiFi ? "Wi-Fi" : "Wi-Fi以外"]
        if isConstrained { parts.append("省データモード") }
        if isExpensive { parts.append("従量制") }
        return parts.joined(separator: " / ")
    }
}

/// Per-mode explanation table (SPEC §30) and request priorities (SPEC §29).
struct NetworkModeGuideView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let showsThumbs = env.settings.extremeShowsThumbnails
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("項目").font(.caption.bold())
                            ForEach(NetworkModeGuide.modes, id: \.self) { mode in
                                Text(mode.displayName).font(.caption.bold())
                                    .foregroundStyle(mode == env.networkMode.effectiveMode ? Color.accentColor : Color.primary)
                            }
                        }
                        Divider()
                        ForEach(NetworkModeGuide.rows) { row in
                            GridRow {
                                Text(row.label).font(.caption)
                                ForEach(NetworkModeGuide.modes, id: \.self) { mode in
                                    GuideCellView(cell: NetworkModeGuide.cell(row, mode: mode, extremeShowsThumbnails: showsThumbs))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("networkModeTable")
            } header: {
                Text("モード別の動作")
            } footer: {
                Text("「手動」はタップしたときだけ取得します。ExtremeのThumbnailは「ExtremeでもThumbnailを表示」の設定に従います。"
                     + "「メディアの先読みはWi-Fiのときだけ」がオンの場合、Wi-Fi以外では先読みを行いません。")
            }

            Section {
                ForEach(NetworkModePreference.allCases) { mode in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(mode.displayName).font(.headline)
                            if mode == env.settings.networkModePreference {
                                PillLabel(text: "選択中", tint: .accentColor)
                            }
                        }
                        Text(NetworkModeGuide.summary(mode)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("モード")
            } footer: {
                Text("キャリアの速度制限はiOSが検出できないことがあるため、遅いと感じたらExtremeを手動で選んでください。")
            }

            Section {
                ForEach(RequestPriority.allCases.sorted(by: >), id: \.self) { priority in
                    LabeledContent(priority.displayName) {
                        Text("\(priority.rawValue)").monospacedDigit()
                    }
                }
            } header: {
                Text("通信の優先度")
            } footer: {
                Text("コメント送信などの操作（interactiveWrite）は、画像の取得や先読みより常に優先されます。メディアの転送は操作中の通信が終わるまで一時停止します。")
            }
        }
        .navigationTitle("通信モード")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GuideCellView: View {
    let cell: NetworkModeGuide.Cell

    var body: some View {
        Text(cell.rawValue)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .frame(minWidth: 44, alignment: .leading)
    }

    private var color: Color {
        switch cell {
        case .on: return .green
        case .manual: return .orange
        case .off: return .secondary
        }
    }
}

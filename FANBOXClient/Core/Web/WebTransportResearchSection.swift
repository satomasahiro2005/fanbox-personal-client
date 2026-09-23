import SwiftUI

/// Research Mode section for the FANBOX transport (SPEC §36 / §40, docs/API.md §1.11): the Native / WebView override
/// used to check the live behaviour of post.info before trusting the automatic routing, the device-wide cooldown, the
/// edge-block breakers and the per-endpoint "prefer WebView" memory. No secrets are shown.
struct WebTransportResearchSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var override: TransportOverride = .automatic
    @State private var snapshot: RateGate.Snapshot?
    @State private var preferences: [String: Date] = [:]
    @State private var liveHosts = 0

    var body: some View {
        Section {
            Picker("通信経路", selection: $override) {
                ForEach(TransportOverride.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .onChange(of: override) { _, value in env.transportPreferences.override = value }
            .accessibilityIdentifier("researchTransportPicker")
            LabeledContent("WebView 転送（常駐数）", value: "\(liveHosts)")
            if let until = snapshot?.cooldownUntil {
                LabeledContent("一時停止中（\(snapshot?.cooldownReason ?? "-")）", value: Formatters.time(until) + " まで")
            }
            ForEach(breakerRows, id: \.0) { row in
                LabeledContent(row.0, value: Formatters.time(row.1) + " まで")
                    .font(.caption)
            }
            ForEach(preferenceRows, id: \.0) { row in
                LabeledContent("WebView 優先: \(row.0)", value: Formatters.shortDate(row.1) + " " + Formatters.time(row.1))
                    .font(.caption)
            }
            if let snapshot, snapshot.backgroundHeavyStartsInWindow > 0 || snapshot.queued > 0 {
                LabeledContent("post.info（背景・直近 1 分）", value: "\(snapshot.backgroundHeavyStartsInWindow) 件 / 待機 \(snapshot.queued)")
                    .font(.caption)
            }
            Button("経路の記録をリセット", role: .destructive) {
                env.transportPreferences.clear()
                let gate = env.rateGate
                Task {
                    await gate.resetAll()
                    await reload()
                }
            }
        } header: {
            Text("通信経路（Native / WebView）")
        } footer: {
            Text("自動: post.info / post.getEditable はアカウント専用の非表示 WebView から、その他は URLSession から送ります。"
                 + "Cloudflare にブロックされたときだけ WebView で送り直し、その endpoint は 24 時間 WebView を優先します。"
                 + "バックグラウンドでは URLSession のみです。")
        }
        .task { await reload() }
    }

    private var breakerRows: [(String, Date)] {
        (snapshot?.breakers ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private var preferenceRows: [(String, Date)] {
        preferences.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private func reload() async {
        override = env.transportPreferences.override
        preferences = env.transportPreferences.webPreferences()
        liveHosts = env.webFetch.liveHostCount
        snapshot = await env.rateGate.snapshot()
    }
}

import SwiftUI
import UIKit
import UserNotifications

/// "通知" section of the Settings root (SPEC §24–§28 / §35).
struct NotificationSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @State private var authorization: UNAuthorizationStatus?
    @State private var backgroundRefresh: UIBackgroundRefreshStatus = .available
    @State private var isRequesting = false

    var body: some View {
        @Bindable var settings = env.settings
        Section {
            Toggle("ローカル通知", isOn: $settings.localNotificationsEnabled)
                .accessibilityIdentifier("localNotificationsToggle")

            LabeledContent("通知の許可", value: SystemStatusText.notificationAuthorization(authorization))
                .accessibilityIdentifier("notificationAuthorizationStatus")

            if authorization == .notDetermined || authorization == .provisional {
                Button {
                    Task { await requestAuthorization() }
                } label: {
                    Label("通知を許可", systemImage: "bell.badge")
                }
                .disabled(isRequesting)
                .accessibilityIdentifier("requestNotificationPermissionButton")
            } else if authorization == .denied {
                Button {
                    openSystemSettings()
                } label: {
                    Label("iOS の設定で通知を許可", systemImage: "gear")
                }
            }

            Picker("起動中の確認間隔", selection: $settings.foregroundPollingInterval) {
                ForEach(SettingsChoices.options(SettingsChoices.pollingIntervals, including: settings.foregroundPollingInterval),
                        id: \.self) { seconds in
                    Text(SettingsChoices.durationLabel(seconds)).tag(seconds)
                }
            }
            .accessibilityIdentifier("pollingIntervalPicker")

            LabeledContent("Background App Refresh", value: SystemStatusText.backgroundRefresh(backgroundRefresh))
                .accessibilityIdentifier("backgroundRefreshStatus")
            if backgroundRefresh == .denied {
                Button {
                    openSystemSettings()
                } label: {
                    Label("iOS の設定を開く", systemImage: "gear")
                }
            }

            NavigationLink {
                RemoteRelaySettingsView()
            } label: {
                LabeledContent("APNs Relay（任意）", value: settings.remoteRelayEnabled ? "オン" : "オフ")
            }
            .accessibilityIdentifier("remoteRelayLink")
        } header: {
            Text("通知")
        } footer: {
            Text("通知は起動時の更新・起動中の定期確認・Background App Refresh で検出し、本文やコメントを先に取得してから通知します。"
                 + "バックグラウンドの実行時刻は iOS が決めるため、即時の検出は保証されません。")
        }
        .task { await refreshStatus() }
        .task {
            for await _ in NotificationCenter.default.notifications(named: UIApplication.backgroundRefreshStatusDidChangeNotification) {
                backgroundRefresh = UIApplication.shared.backgroundRefreshStatus
            }
        }
        .task {
            // Returning from iOS Settings (permission changed there).
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                await refreshStatus()
            }
        }
        .onChange(of: settings.localNotificationsEnabled) { _, enabled in
            if enabled && authorization == .notDetermined {
                Task { await requestAuthorization() }
            }
        }
    }

    private func refreshStatus() async {
        backgroundRefresh = UIApplication.shared.backgroundRefreshStatus
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func requestAuthorization() async {
        isRequesting = true
        defer { isRequesting = false }
        await env.notifications.requestAuthorization()
        await refreshStatus()
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

/// Optional APNs Relay (SPEC §28). Client-side switch + registration status only; the relay server is not part of v1.0.
struct RemoteRelaySettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var urlDraft = ""
    @State private var deviceToken: String?
    @State private var lastError: String?

    var body: some View {
        @Bindable var settings = env.settings
        let validation = RelaySettingsSupport.validate(urlDraft)
        let state = RelaySettingsSupport.registrationState(enabled: settings.remoteRelayEnabled, urlText: settings.remoteRelayURL,
                                                           token: deviceToken, lastError: lastError)
        Form {
            Section {
                Text("APNs Relay は任意の機能です。使わなくても、起動時・起動中の定期確認・Background App Refresh で通知を検出できます。")
                Text("Relay は「アカウントのどれかに何かが起きた」という内容のない (content-free) サイレント通知を送るだけです。"
                     + "通知を受け取ったアプリが、自分のセッションで FANBOX から直接取得します。")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            Section {
                Toggle("APNs Relay を使う", isOn: $settings.remoteRelayEnabled)
                    .accessibilityIdentifier("remoteRelayToggle")
                TextField("https://relay.example.com", text: $urlDraft)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { commitURL() }
                    .accessibilityIdentifier("remoteRelayURLField")
                if !urlDraft.isEmpty || settings.remoteRelayEnabled, let message = RelaySettingsSupport.validationMessage(validation) {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                Button("URL を保存") { commitURL() }
                    .disabled(urlDraft == settings.remoteRelayURL || !(validation.isValid || urlDraft.isEmpty))
            } header: {
                Text("Relay")
            } footer: {
                Text("自分で運用する Relay の URL を入力します。https のみ使用できます。")
            }

            Section {
                LabeledContent("状態", value: RelaySettingsSupport.registrationText(state))
                    .accessibilityIdentifier("remoteRelayState")
                LabeledContent("APNs デバイストークン", value: RelaySettingsSupport.tokenHint(deviceToken))
                if let lastError, !lastError.isEmpty {
                    LabeledContent("登録エラー") {
                        Text(ResearchLogFormatter.safe(lastError)).font(.caption).multilineTextAlignment(.trailing)
                    }
                }
                Button {
                    registerIfReady()
                } label: {
                    Label("APNs に登録", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(!settings.remoteRelayEnabled || !RelaySettingsSupport.validate(settings.remoteRelayURL).isValid)
            } header: {
                Text("登録状態")
            } footer: {
                Text("デバイストークンは先頭のみ表示します。v1.0 には Relay サーバは含まれていません（設計: docs/NOTIFICATION_RELAY.md）。")
            }

            Section("Relay に渡すもの") {
                RelayDataRow(text: "APNs デバイストークン", allowed: true)
                RelayDataRow(text: "アカウントを区別する不透明なヒント（ランダム値）", allowed: true)
                RelayDataRow(text: "FANBOX の Cookie / FANBOXSESSID / CSRF Token", allowed: false)
                RelayDataRow(text: "投稿本文・コメント・おたより", allowed: false)
                RelayDataRow(text: "支援者・支援状態・決済の情報", allowed: false)
            }
        }
        .navigationTitle("APNs Relay")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { urlDraft = settings.remoteRelayURL }
        .onDisappear { commitURL() }
        .onChange(of: settings.remoteRelayEnabled) { _, enabled in
            if enabled {
                commitURL()
                registerIfReady()
            }
        }
        .task {
            // RemoteRelay is not observable; poll its two fields while this screen is visible.
            while !Task.isCancelled {
                deviceToken = RemoteRelay.shared.deviceToken
                lastError = RemoteRelay.shared.lastError
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func commitURL() {
        let trimmed = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != env.settings.remoteRelayURL else { return }
        switch RelaySettingsSupport.validate(trimmed) {
        case .valid:
            env.settings.remoteRelayURL = trimmed
            registerIfReady()
        case .empty:
            env.settings.remoteRelayURL = trimmed
        case .notHTTPS, .invalid:
            break
        }
    }

    /// APNs registration only when the user enabled the relay and set a valid https URL (nothing happens otherwise).
    private func registerIfReady() {
        let settings = env.settings
        guard settings.remoteRelayEnabled, RelaySettingsSupport.validate(settings.remoteRelayURL).isValid else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }
}

private struct RelayDataRow: View {
    let text: String
    let allowed: Bool

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: allowed ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(allowed ? Color.green : Color.red)
        }
        .font(.callout)
        .accessibilityLabel("\(text): \(allowed ? "渡す" : "渡さない")")
    }
}

extension RelaySettingsSupport.URLValidation {
    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

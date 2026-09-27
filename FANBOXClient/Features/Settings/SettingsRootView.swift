import SwiftData
import SwiftUI

/// Settings sheet (SPEC §4: opened from the navigation bar). Presented by `RootView` inside a `NavigationStack`.
struct SettingsRootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query(FetchDescriptorFactory.enabledAccounts()) private var accounts: [Account]

    var body: some View {
        Form {
            Section("アカウント") {
                NavigationLink {
                    AccountsSettingsView()
                } label: {
                    LabeledContent {
                        Text("\(accounts.count)件")
                    } label: {
                        Label("アカウント", systemImage: "person.2.circle")
                    }
                }
                .accessibilityIdentifier("accountsSettingsLink")
            }

            NetworkModeSettingsSection()
            NotificationSettingsSection()
            ReplySettingsSection()
            CacheSettingsSection()
            ResearchSettingsSection()

            Section("法的情報") {
                NavigationLink {
                    LegalView()
                } label: {
                    Label("著作権・ライセンス・プライバシー", systemImage: "doc.text")
                }
                .accessibilityIdentifier("legalLink")
                LabeledContent("バージョン", value: AppVersionInfo.displayString())
                    .accessibilityIdentifier("appVersion")
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("閉じる") {
                    env.router.isSettingsPresented = false
                    dismiss()
                }
                .accessibilityIdentifier("settingsCloseButton")
            }
        }
        .accessibilityIdentifier("settingsView")
    }
}

/// "コメント返信" section (SPEC §22): long-waiting replies are re-confirmed by default.
struct ReplySettingsSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        Section {
            Toggle("長時間待った返信も自動送信", isOn: $settings.autoSendStaleReplies)
                .accessibilityIdentifier("autoSendStaleRepliesToggle")
            Picker("「長時間」の基準", selection: $settings.staleReplyThreshold) {
                ForEach(SettingsChoices.options(SettingsChoices.staleReplyThresholds, including: settings.staleReplyThreshold),
                        id: \.self) { seconds in
                    Text(SettingsChoices.durationLabel(seconds)).tag(seconds)
                }
            }
            .accessibilityIdentifier("staleReplyThresholdPicker")
        } header: {
            Text("コメント返信")
        }
    }
}

/// "Research Mode" section (SPEC §36 / §37).
struct ResearchSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @Query private var schemaSnapshots: [APISchemaSnapshot]

    var body: some View {
        @Bindable var settings = env.settings
        let changed = APISchemaGrouping.changedCount(schemaSnapshots)
        Section {
            Toggle("Research Mode", isOn: $settings.researchModeEnabled)
                .accessibilityIdentifier("researchModeToggle")
            NavigationLink {
                ResearchModeView()
            } label: {
                HStack {
                    Label("Research / API Inspector", systemImage: "stethoscope")
                    Spacer()
                    if changed > 0 {
                        PillLabel(text: "Schema変化\(changed)", systemImage: "sparkles", tint: .orange)
                    }
                }
            }
            .accessibilityIdentifier("researchModeLink")
        } header: {
            Text("Research Mode")
        }
    }
}

#Preview {
    let env = AppEnvironment.preview()
    return NavigationStack { SettingsRootView() }
        .environment(env)
        .environment(env.router)
        .environment(env.settings)
        .modelContainer(env.container)
}

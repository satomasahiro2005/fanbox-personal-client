import SwiftUI

/// "オフライン / キャッシュ" section of the Settings root (SPEC §31 / §32).
struct CacheSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var pendingClear: CacheClearKind?

    var body: some View {
        @Bindable var settings = env.settings
        let usage = env.media.usage
        Section {
            Picker("キャッシュ容量", selection: $settings.cacheCapacity) {
                ForEach(CacheCapacity.allCases) { capacity in
                    Text(capacity.displayName).tag(capacity)
                }
            }
            .accessibilityIdentifier("cacheCapacityPicker")

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("使用量", value: CacheUsageText.usageLine(usage: usage, capacity: settings.cacheCapacity))
                if let fraction = CacheUsageText.fraction(usage: usage, capacity: settings.cacheCapacity) {
                    ProgressView(value: fraction)
                        .tint(fraction > 0.9 ? .orange : .accentColor)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("cacheUsage")

            NavigationLink {
                CacheUsageDetailView()
            } label: {
                Label("内訳", systemImage: "chart.bar.doc.horizontal")
            }

            Toggle("閲覧した投稿を自動保存", isOn: $settings.autoSaveViewedPosts)
                .accessibilityIdentifier("autoSaveViewedPostsToggle")

            Stepper(value: $settings.creatorRecentCount, in: SettingsChoices.creatorRecentCountRange) {
                LabeledContent("Creator の最近 N 件", value: "\(settings.creatorRecentCount) 件")
            }
            .accessibilityIdentifier("creatorRecentCountStepper")

            Button {
                pendingClear = .unpinned
            } label: {
                Label("キャッシュを削除", systemImage: "trash")
            }
            .accessibilityIdentifier("clearCacheButton")

            Button(role: .destructive) {
                pendingClear = .includingSaved
            } label: {
                Label("保存済みも含めて削除", systemImage: "trash.slash")
            }
            .accessibilityIdentifier("clearAllCacheButton")
        } header: {
            Text("オフライン / キャッシュ")
        } footer: {
            Text("容量を超えると、保存していないもの → 古いもの → Original → Display → Thumbnail の順に削除します。"
                 + "保存済みのメディアは最後に削除され、その投稿の Offline 保存は解除されます。"
                 + "本文・タイトル・Creator 情報などの軽量データは削除しません。")
        }
        .task { env.media.refreshUsage() }
        .onChange(of: settings.cacheCapacity) { _, _ in
            env.media.enforceCapacity()
            env.media.refreshUsage()
        }
        .confirmationDialog(pendingClear?.title ?? "", isPresented: Binding(get: { pendingClear != nil },
                                                                           set: { if !$0 { pendingClear = nil } }),
                            titleVisibility: .visible, presenting: pendingClear) { kind in
            Button(kind.confirmLabel, role: .destructive) {
                env.media.clearAll(includePinned: kind == .includingSaved)
                env.media.refreshUsage()
                pendingClear = nil
            }
            .accessibilityIdentifier("confirmClearCacheButton")
            Button("キャンセル", role: .cancel) { pendingClear = nil }
        } message: { kind in
            Text(kind.message)
        }
    }
}

enum CacheClearKind: Identifiable, Equatable {
    case unpinned
    case includingSaved

    var id: Self { self }

    var title: String {
        switch self {
        case .unpinned: return "キャッシュを削除しますか？"
        case .includingSaved: return "保存済みのメディアも削除しますか？"
        }
    }

    var message: String {
        switch self {
        case .unpinned:
            return "保存していない画像・ファイルのキャッシュを削除します。オフライン保存したメディアと本文は残ります。"
        case .includingSaved:
            return "オフライン保存したものを含め、すべての画像・ファイルのキャッシュを削除します。本文・タイトルなどのテキストは残ります。この操作は取り消せません。"
        }
    }

    var confirmLabel: String {
        switch self {
        case .unpinned: return "キャッシュを削除"
        case .includingSaved: return "保存済みも含めて削除"
        }
    }
}

/// Pure formatting of cache usage (unit-tested).
enum CacheUsageText {
    static func usageLine(usage: CacheUsage, capacity: CacheCapacity) -> String {
        let used = Formatters.bytes(usage.totalBytes)
        guard let limit = capacity.bytes else { return "\(used) / 無制限" }
        return "\(used) / \(Formatters.bytes(limit))"
    }

    /// Saved (pinned) media alone does not fit the capacity: it will be evicted too.
    static func savedExceedsCapacity(usage: CacheUsage, capacity: CacheCapacity) -> Bool {
        guard let limit = capacity.bytes else { return false }
        return usage.pinnedBytes > limit
    }

    /// 0...1, nil when unlimited.
    static func fraction(usage: CacheUsage, capacity: CacheCapacity) -> Double? {
        guard let limit = capacity.bytes, limit > 0 else { return nil }
        return min(1, max(0, Double(usage.totalBytes) / Double(limit)))
    }
}

/// Breakdown of the media cache by variant.
struct CacheUsageDetailView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let usage = env.media.usage
        List {
            Section {
                LabeledContent("使用量", value: Formatters.bytes(usage.totalBytes))
                LabeledContent("ファイル数", value: "\(usage.fileCount)")
                LabeledContent("保存済み", value: Formatters.bytes(usage.pinnedBytes))
                if CacheUsageText.savedExceedsCapacity(usage: usage, capacity: env.settings.cacheCapacity) {
                    Label("保存済みのメディアがキャッシュ容量を超えています。古いものから削除され、その投稿の Offline 保存は解除されます。",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("cacheSavedOverCapacity")
                }
            } header: {
                Text("合計")
            } footer: {
                Text("保存済み（この投稿・Creator の最近 N 件・自動保存）は、容量を超えたときに最後に削除されます。")
            }
            Section("種類別") {
                ForEach(MediaVariant.allCases.sorted(by: >), id: \.self) { variant in
                    LabeledContent(variant.settingsLabel, value: Formatters.bytes(usage.bytesByVariant[variant] ?? 0))
                }
            }
        }
        .navigationTitle("キャッシュの内訳")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { env.media.refreshUsage() }
        .task { env.media.refreshUsage() }
    }
}

extension MediaVariant {
    var settingsLabel: String {
        switch self {
        case .thumbnail: return "Thumbnail"
        case .display: return "Display Image"
        case .original: return "Original"
        }
    }
}

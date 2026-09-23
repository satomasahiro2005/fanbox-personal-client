import SwiftUI
import SwiftData

// MARK: - Posts

/// Local posts of the creator (newest first) + explicit "さらに読み込む" (no automatic crawl, SPEC §3.7).
struct CreatorPostsSection: View {
    let creatorID: String
    let posts: [Post]
    let accountsByID: [String: Account]

    @Environment(AppEnvironment.self) private var env
    @State private var isLoadingMore = false
    @State private var loadMoreMessage: String?

    var body: some View {
        Section {
            if posts.isEmpty {
                Text(isLoadingMore ? "投稿を取得しています…" : "この端末に保存された投稿はまだありません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(posts, id: \.postID) { post in
                NavigationLink(value: AppRoute.post(postID: post.postID)) {
                    CreatorPostCompactRow(post: post, accountsByID: accountsByID)
                }
                .accessibilityIdentifier("creatorPost.\(post.postID)")
            }
            Button {
                Task { await loadMore() }
            } label: {
                HStack {
                    Spacer()
                    if isLoadingMore {
                        ProgressView().controlSize(.small)
                        Text("読み込み中…")
                    } else {
                        Text("さらに読み込む")
                    }
                    Spacer()
                }
            }
            .disabled(isLoadingMore)
            .accessibilityIdentifier("creatorLoadMoreButton")
        } header: {
            Text("投稿（この端末 \(posts.count) 件）")
        } footer: {
            if let loadMoreMessage {
                Text(loadMoreMessage)
            }
        }
    }

    private func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreMessage = nil
        let before = localPostCount()
        let error = await RequestContext.$priority.withValue(.interactiveRead) {
            await env.sync.loadMoreCreatorPosts(creatorID: creatorID)
        }
        isLoadingMore = false
        if let error {
            loadMoreMessage = "読み込めませんでした（\(error.userMessage)）。キャッシュ済みの投稿を表示しています。"
        } else if localPostCount() <= before {
            loadMoreMessage = "新しく読み込める投稿はありませんでした"
        }
    }

    private func localPostCount() -> Int {
        let id = creatorID
        return (try? env.store.context.fetchCount(FetchDescriptor<Post>(predicate: #Predicate { $0.creatorID == id }))) ?? posts.count
    }
}

// MARK: - Plans

struct CreatorPlansSection: View {
    let plans: [Plan]
    let activeSupports: [Support]
    let accountOrder: [String]
    let onSupport: (Plan) -> Void

    var body: some View {
        Section {
            if plans.isEmpty {
                Text("プラン情報はまだ保存されていません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(plans, id: \.planID) { plan in
                CreatorPlanRow(plan: plan, supporterAccountIDs: supporters(of: plan), onSupport: { onSupport(plan) })
            }
        } header: {
            Text("プラン")
        } footer: {
            if !plans.isEmpty {
                Text("支援手続きはアカウントを選んで FANBOX / pixiv の決済画面で行います。カード情報はアプリに保存されません。")
            }
        }
    }

    private func supporters(of plan: Plan) -> [String] {
        let ids = Set(activeSupports.filter { $0.planID == plan.planID }.map(\.accountID))
        let ordered = accountOrder.filter(ids.contains)
        return ordered + ids.subtracting(ordered).sorted()
    }
}

struct CreatorPlanRow: View {
    let plan: Plan
    let supporterAccountIDs: [String]
    let onSupport: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                if let cover = plan.coverImageURL {
                    RemoteImageView(thumbnailURL: cover, maxVariant: .thumbnail, creatorID: plan.creatorID)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(CreatorSupportSummary.monthlyText(plan.fee))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if plan.hasAdultContent {
                    PillLabel(text: "R-18", tint: .red)
                }
            }

            if !plan.planDescription.isEmpty {
                Text(plan.planDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 3)
                    .onTapGesture { withAnimation { expanded.toggle() } }
            }

            if !supporterAccountIDs.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    PillLabel(text: "支援中", systemImage: "checkmark.circle.fill", tint: .pink)
                    AccountBadgeRow(accountIDs: supporterAccountIDs)
                }
            }

            Button(action: onSupport) {
                Label("このプランで支援", systemImage: "yensign.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("creatorSupportPlanButton.\(plan.planID)")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Support

/// Creator-level support summary (SPEC §10.1) with the payment profile the user assigned (SPEC §13).
struct CreatorSupportSection: View {
    let creatorID: String
    let summary: CreatorSupportSummary

    @Query private var assignments: [SupportPaymentAssignment]
    @Query private var profiles: [PaymentProfile]

    init(creatorID: String, summary: CreatorSupportSummary) {
        self.creatorID = creatorID
        self.summary = summary
        _assignments = Query(filter: #Predicate<SupportPaymentAssignment> { $0.creatorID == creatorID })
        _profiles = Query(sort: \PaymentProfile.sortOrder)
    }

    var body: some View {
        Section {
            HStack {
                Text("合計月額")
                Spacer()
                Text(Formatters.yen(summary.monthlyTotal))
                    .font(.title3.bold().monospacedDigit())
            }
            .accessibilityElement(children: .combine)

            ForEach(summary.lines) { line in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        AccountBadge(accountID: line.accountID)
                        Spacer()
                        Text("\(line.amountText) Plan")
                            .font(.subheadline.monospacedDigit())
                    }
                    Text(line.planTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    paymentLine(accountID: line.accountID)
                }
                .padding(.vertical, 2)
            }

            ForEach(summary.attentions) { attention in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    AccountBadge(accountID: attention.accountID)
                    Text(attention.reason).font(.caption).foregroundStyle(.secondary)
                }
            }

            NavigationLink(value: AppRoute.supportCreator(creatorID: creatorID)) {
                Label("支援の詳細・履歴", systemImage: "list.bullet.rectangle")
            }
            .accessibilityIdentifier("creatorSupportDetailLink")
        } header: {
            Text("支援")
        } footer: {
            if !summary.isSupporting {
                Text("このクリエイターを支援しているアカウントはありません。")
            }
        }
    }

    @ViewBuilder
    private func paymentLine(accountID: String) -> some View {
        if let assignment = assignments.first(where: { $0.accountID == accountID }) {
            let profile = assignment.paymentProfileID.flatMap { id in profiles.first { $0.id == id } }
            HStack(spacing: 6) {
                Image(systemName: "creditcard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(profile?.nickname ?? "未設定")
                    .font(.caption)
                if let detail = profile?.displayDetail, detail != profile?.nickname {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
                CreatorVerificationPill(state: assignment.verificationState, lastVerifiedAt: assignment.lastVerifiedAt)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "creditcard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("支払い方法: 未設定")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// SPEC §13: an inferred payment method MUST be labeled as a guess. Same labels, symbols and tints as the Support
/// screens (`VerificationLabel` / `SupportText.verificationLabel`), so one assignment reads the same everywhere.
struct CreatorVerificationPill: View {
    let state: VerificationState
    var lastVerifiedAt: Date? = nil

    var body: some View {
        VerificationLabel(state: state, lastVerifiedAt: lastVerifiedAt)
    }
}

// MARK: - About

struct CreatorAboutSection: View {
    let creatorID: String
    let creator: Creator?
    let webAccounts: [Account]

    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @State private var isSavingOffline = false
    @State private var offlineMessage: String?

    var body: some View {
        Section("プロフィール") {
            if let text = creator?.profileText, !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
            } else {
                Text("プロフィールはまだ保存されていません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if creator?.hasAdultContent == true {
                PillLabel(text: "R-18 コンテンツあり", tint: .red)
            }
        }

        let links = (creator?.profileLinks ?? []).compactMap(CreatorProfileLink.init)
        if !links.isEmpty {
            Section("リンク") {
                ForEach(links) { link in
                    Button {
                        openURL(link.url)
                    } label: {
                        HStack {
                            Label(link.title, systemImage: link.systemImage)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        if let creator {
            offlineSection(creator)
        }

        Section {
            CreatorWebAccountMenu(accounts: webAccounts, destination: .creator(creatorID: creatorID)) {
                Label("Web で開く", systemImage: "safari")
            }
            .accessibilityIdentifier("creatorAboutOpenWeb")
        } footer: {
            Text("選択したアカウントのログイン状態で FANBOX を開きます。")
        }
    }

    @ViewBuilder
    private func offlineSection(_ creator: Creator) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { creator.offlineRecentCount > 0 },
                set: { enabled in
                    creator.offlineRecentCount = enabled ? max(1, env.settings.creatorRecentCount) : 0
                    env.store.save()
                    if enabled { Task { await saveRecent(count: creator.offlineRecentCount) } }
                }
            )) {
                Text("最近 N 件をオフライン保存")
            }
            .accessibilityIdentifier("creatorOfflineRuleToggle")

            if creator.offlineRecentCount > 0 {
                Stepper(value: Binding(
                    get: { creator.offlineRecentCount },
                    set: { creator.offlineRecentCount = $0; env.store.save() }
                ), in: 1...100) {
                    Text("最近 \(creator.offlineRecentCount) 件")
                        .monospacedDigit()
                }
                .accessibilityIdentifier("creatorOfflineRecentStepper")

                Button {
                    Task { await saveRecent(count: creator.offlineRecentCount) }
                } label: {
                    HStack {
                        Text("今すぐ保存")
                        if isSavingOffline {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(isSavingOffline)
                .accessibilityIdentifier("creatorOfflineSaveNow")
            }
        } header: {
            Text("オフライン")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let offlineMessage { Text(offlineMessage) }
                Text("既知の投稿と最新ページの差分だけを保存します。過去の全履歴は取得しません。")
            }
        }
    }

    private func saveRecent(count: Int) async {
        guard !isSavingOffline, count > 0 else { return }
        isSavingOffline = true
        offlineMessage = nil
        await env.offline.saveRecent(creatorID: creatorID, count: count)
        isSavingOffline = false
        offlineMessage = "最近 \(count) 件の保存を実行しました"
    }
}

/// A profile link with a friendly title.
struct CreatorProfileLink: Identifiable, Hashable {
    let url: URL
    var id: String { url.absoluteString }

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        self.url = url
    }

    var title: String {
        let host = (url.host ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
        let path = url.path == "/" ? "" : url.path
        return host + path
    }

    var systemImage: String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("pixiv") { return "paintpalette" }
        if host.contains("twitter") || host.hasSuffix("x.com") { return "bubble.left" }
        if host.contains("youtube") { return "play.rectangle" }
        return "link"
    }
}

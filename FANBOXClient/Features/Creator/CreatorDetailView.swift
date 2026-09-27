import SwiftUI
import SwiftData

/// Segments of the creator page (SPEC §9: Posts / Plans / Support / About).
enum CreatorDetailSection: String, CaseIterable, Identifiable, Sendable {
    case posts, plans, support, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .posts: return "Posts"
        case .plans: return "Plans"
        case .support: return "Support"
        case .about: return "About"
        }
    }
}

/// Creator 統合表示 (SPEC §9 / §10.1). Renders from the local DB immediately, then refreshes in the background.
struct CreatorDetailView: View {
    let creatorID: String

    @Environment(AppEnvironment.self) private var env
    @Query private var creatorRows: [Creator]
    @Query private var supportRows: [Support]
    @Query private var plans: [Plan]
    @Query private var posts: [Post]
    /// Enabled accounts only: supports, follows and ownership of a disabled account are not shown.
    @Query(FetchDescriptorFactory.enabledAccounts()) private var accounts: [Account]

    @State private var section: CreatorDetailSection = .posts
    @State private var refreshError: RemoteError?
    @State private var isRefreshing = false
    @State private var didInitialRefresh = false
    /// "このプランで支援" → payment flow sheet (SPEC §14).
    @State private var paymentRequest: PaymentFlowRequest?
    @State private var isEditingMemo = false

    init(creatorID: String, initialSection: CreatorDetailSection = .posts) {
        self.creatorID = creatorID
        _section = State(initialValue: initialSection)
        _creatorRows = Query(filter: #Predicate<Creator> { $0.creatorID == creatorID })
        _supportRows = Query(filter: #Predicate<Support> { $0.creatorID == creatorID })
        _plans = Query(filter: #Predicate<Plan> { $0.creatorID == creatorID },
                       sort: [SortDescriptor(\Plan.fee), SortDescriptor(\Plan.sortOrder)])
        // Reader page: my own FANBOX drafts / scheduled posts are Creator Mode only.
        _posts = Query(ReaderPostQueries.byCreator(creatorID))
    }

    private var creator: Creator? { creatorRows.first }

    private var displayName: String {
        if let name = creator?.name, !name.isEmpty { return name }
        if let name = posts.first?.creatorName, !name.isEmpty { return name }
        return creatorID
    }

    var body: some View {
        let knownAccountIDs = Set(accounts.map(\.id))
        let summary = CreatorSupportSummary.make(creatorID: creatorID, supports: supportRows.map(CreatorSupportInput.init),
                                                 accountOrder: accounts.map(\.id), knownAccountIDs: knownAccountIDs)
        let accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let followingIDs = accounts.map(\.id).filter { (creator?.followedByAccountIDs ?? []).contains($0) }
        let ownerIDs = accounts.filter { $0.creatorID == creatorID || $0.id == creator?.ownedByAccountID }.map(\.id)
        let webAccounts = CreatorAccountOrdering.preferred(accounts, first: ownerIDs + summary.accountIDs + followingIDs)

        List {
            if let refreshError {
                Section {
                    SyncStatusBanner(error: refreshError, lastSync: creator?.fetchedAt)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }
            }

            Section {
                CreatorDetailHeader(creatorID: creatorID, creator: creator, displayName: displayName, isRefreshing: isRefreshing,
                                    onToggleFavorite: toggleFavorite, onEditMemo: { isEditingMemo = true })
                    .listRowInsets(EdgeInsets())
            }

            CreatorSupportBlock(summary: summary, followingAccountIDs: followingIDs, ownerAccountIDs: ownerIDs) {
                withAnimation { section = .plans }
            }

            Section {
                Picker("表示", selection: $section) {
                    ForEach(CreatorDetailSection.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("creatorDetailSectionPicker")
            }

            switch section {
            case .posts:
                CreatorPostsSection(creatorID: creatorID, posts: posts, accountsByID: accountsByID)
            case .plans:
                CreatorPlansSection(plans: plans, activeSupports: supportRows.filter { $0.isActive && knownAccountIDs.contains($0.accountID) },
                                    accountOrder: accounts.map(\.id)) { plan in
                    paymentRequest = PaymentFlowRequest(creatorID: creatorID, planID: plan.planID)
                }
            case .support:
                CreatorSupportSection(creatorID: creatorID, summary: summary)
            case .about:
                CreatorAboutSection(creatorID: creatorID, creator: creator, webAccounts: webAccounts)
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("creatorDetail")
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if creator != nil {
                    Button(action: toggleFavorite) {
                        Image(systemName: creator?.isFavorite == true ? "star.fill" : "star")
                            .foregroundStyle(creator?.isFavorite == true ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tint))
                    }
                    .accessibilityLabel(creator?.isFavorite == true ? "お気に入り解除" : "お気に入り")
                    .accessibilityIdentifier("creatorFavoriteButton")
                }
                CreatorWebAccountMenu(accounts: webAccounts, destination: .creator(creatorID: creatorID)) {
                    Image(systemName: "safari")
                }
                .accessibilityLabel("Web で開く")
                .accessibilityIdentifier("creatorOpenWebMenu")
            }
        }
        .refreshable { await refresh() }
        .task {
            // Local first: the page is already rendered from SwiftData. Refresh once per page instance
            // (not again when coming back from a pushed post).
            guard !didInitialRefresh else { return }
            didInitialRefresh = true
            await refresh()
        }
        .paymentFlowSheet($paymentRequest)
        .sheet(isPresented: $isEditingMemo) {
            if let creator {
                CreatorMemoEditor(creator: creator)
            }
        }
    }

    private func toggleFavorite() {
        guard let creator else { return }
        creator.isFavorite.toggle()
        env.store.save()
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let error = await RequestContext.$priority.withValue(.interactiveRead) {
            await env.sync.refreshCreator(creatorID: creatorID)
        }
        refreshError = error
    }
}

// MARK: - Header

struct CreatorDetailHeader: View {
    let creatorID: String
    let creator: Creator?
    let displayName: String
    let isRefreshing: Bool
    let onToggleFavorite: () -> Void
    let onEditMemo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let cover = creator?.coverImageURL {
                        RemoteImageView(thumbnailURL: cover, displayURL: cover, maxVariant: .display, creatorID: creatorID)
                    } else {
                        LinearGradient(colors: [.purple.opacity(0.35), .teal.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .clipped()

                AvatarView(url: creator?.iconURL, size: 64)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
                    .padding(.leading, 16)
                    .offset(y: 32)
            }
            .padding(.bottom, 36)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.title3.bold())
                            .lineLimit(2)
                            .accessibilityIdentifier("creatorName")
                        Text("@\(creatorID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                    if creator != nil {
                        Button(action: onToggleFavorite) {
                            Image(systemName: creator?.isFavorite == true ? "star.fill" : "star")
                                .font(.title3)
                                .foregroundStyle(creator?.isFavorite == true ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(creator?.isFavorite == true ? "お気に入り解除" : "お気に入り")
                    }
                }

                if creator == nil {
                    Text(isRefreshing ? "クリエイター情報を取得しています…" : "クリエイター情報はまだ保存されていません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let creator {
                    memoView(creator)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func memoView(_ creator: Creator) -> some View {
        if creator.memo.isEmpty {
            Button(action: onEditMemo) {
                Label("メモを追加", systemImage: "note.text.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("creatorMemoAddButton")
        } else {
            Button(action: onEditMemo) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "note.text")
                        .foregroundStyle(.secondary)
                    Text(creator.memo)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                    Spacer(minLength: 0)
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("メモ: \(creator.memo)")
            .accessibilityIdentifier("creatorMemo")
        }
    }
}

/// Local-only memo editor (SPEC §33: never sent to FANBOX).
struct CreatorMemoEditor: View {
    let creator: Creator
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                        .accessibilityIdentifier("creatorMemoEditor")
                } footer: {
                    Text("メモはこの端末内にのみ保存され、FANBOX には送信されません。")
                }
            }
            .navigationTitle("メモ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        creator.memo = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        env.store.save()
                        dismiss()
                    }
                    .accessibilityIdentifier("creatorMemoSaveButton")
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                text = creator.memo
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - SPEC §9 support block

/// ```
/// 支援中
/// Account A    ¥500
/// Account B  ¥1,000
/// 合計       ¥1,500 / 月
/// ```
struct CreatorSupportBlock: View {
    let summary: CreatorSupportSummary
    let followingAccountIDs: [String]
    let ownerAccountIDs: [String]
    let onShowPlans: () -> Void

    var body: some View {
        Section {
            if summary.isSupporting {
                ForEach(summary.lines) { line in
                    HStack(spacing: 8) {
                        AccountBadge(accountID: line.accountID)
                        Text(line.planTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(line.amountText)
                            .font(.body.monospacedDigit())
                    }
                    .accessibilityElement(children: .combine)
                }
                HStack {
                    Text("合計").font(.body.bold())
                    Spacer()
                    Text(summary.monthlyTotalText)
                        .font(.body.bold().monospacedDigit())
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("creatorSupportTotal")
            } else {
                HStack {
                    Text("支援していません")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("プランを見る", action: onShowPlans)
                        .buttonStyle(.borderless)
                }
            }

            ForEach(summary.attentions) { attention in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    AccountBadge(accountID: attention.accountID)
                    Text(attention.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }

            if !followingAccountIDs.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("フォロー中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    AccountBadgeRow(accountIDs: followingAccountIDs)
                    Spacer(minLength: 0)
                }
                .accessibilityIdentifier("creatorFollowingAccounts")
            }

            if !ownerAccountIDs.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("自分の Creator Account")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    AccountBadgeRow(accountIDs: ownerAccountIDs)
                    Spacer(minLength: 0)
                }
            }
        } header: {
            Text("支援中")
        }
        .accessibilityIdentifier("creatorSupportBlock")
    }
}

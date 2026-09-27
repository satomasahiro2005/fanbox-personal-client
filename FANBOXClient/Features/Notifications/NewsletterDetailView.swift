import SwiftUI
import SwiftData

/// おたより detail. Shows the local body immediately; fetches the body only when it is not cached yet.
struct NewsletterDetailView: View {
    let newsletterID: String

    @Environment(AppEnvironment.self) private var env
    @Query private var rows: [Newsletter]
    @Query(FetchDescriptorFactory.enabledAccounts()) private var accounts: [Account]

    @State private var isFetching = false
    @State private var fetchError: RemoteError?
    @State private var didLoad = false

    init(newsletterID: String) {
        self.newsletterID = newsletterID
        _rows = Query(filter: #Predicate<Newsletter> { $0.newsletterID == newsletterID })
    }

    private var newsletter: Newsletter? { rows.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let fetchError {
                    SyncStatusBanner(error: fetchError, lastSync: newsletter?.fetchedAt)
                }
                if let newsletter {
                    content(newsletter)
                } else if isFetching {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("おたよりを取得しています…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                } else {
                    EmptyStateView(title: "おたよりが見つかりません", systemImage: "envelope",
                                   message: "この端末にはまだ保存されていません")
                }
            }
            .padding()
        }
        .accessibilityIdentifier("newsletterDetail")
        .navigationTitle("おたより")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .refreshable { await fetchBody(force: true) }
        .task {
            guard !didLoad else { return }
            didLoad = true
            markRead()
            await fetchBody(force: false)
        }
    }

    @ViewBuilder
    private func content(_ newsletter: Newsletter) -> some View {
        NavigationLink(value: AppRoute.creator(creatorID: newsletter.creatorID)) {
            HStack(spacing: 10) {
                AvatarView(url: newsletter.creatorIconURL, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(newsletter.creatorName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(newsletter.createdAt.formatted(.dateTime.year().month().day().hour().minute()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("newsletterCreatorLink")

        if !newsletter.accountIDs.isEmpty {
            HStack(spacing: 6) {
                Text("受信")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AccountBadgeRow(accountIDs: newsletter.accountIDs.filter { id in accounts.contains { $0.id == id } })
            }
        }

        if let title = newsletter.title, !title.isEmpty {
            Text(title)
                .font(.title3.bold())
        }

        Divider()

        if !newsletter.body.isEmpty {
            Text(newsletter.body)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("newsletterBody")
        } else if isFetching {
            HStack(spacing: 8) {
                ProgressView()
                Text("本文を取得しています…").foregroundStyle(.secondary)
            }
        } else {
            Text(newsletter.bodyFetched ? "本文はありません" : "本文はまだ取得されていません。下に引っ張って再取得できます。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let newsletter {
                    Button {
                        // The おたより and its inbox event share one read state; the badge counts the event.
                        if NotificationReadActions.setNewsletterRead(newsletterID: newsletterID, read: !newsletter.isRead,
                                                                     store: env.store) {
                            Task { await env.notifications.updateBadge() }
                        }
                    } label: {
                        Label(newsletter.isRead ? "未読にする" : "既読にする",
                              systemImage: newsletter.isRead ? "envelope.badge" : "envelope.open")
                    }
                }
                Menu {
                    let candidates = webAccounts
                    if candidates.isEmpty {
                        Text("有効なアカウントがありません")
                    }
                    ForEach(candidates, id: \.id) { account in
                        Button(account.displayName) {
                            env.web.openWeb(account: account.id, destination: .newsletter(id: newsletterID))
                        }
                    }
                } label: {
                    Label("Webで開く", systemImage: "safari")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("その他")
            .accessibilityIdentifier("newsletterMenu")
        }
    }

    /// Accounts that received the newsletter first (the right session for the web page), then other enabled accounts.
    private var webAccounts: [Account] {
        let receivers = newsletter?.accountIDs ?? []
        let head = receivers.compactMap { id in accounts.first { $0.id == id } }
        return head + accounts.filter { !receivers.contains($0.id) }
    }

    private func markRead() {
        if NotificationReadActions.markNewsletterRead(newsletterID: newsletterID, store: env.store) {
            Task { await env.notifications.updateBadge() }
        }
    }

    private func fetchBody(force: Bool) async {
        if !force, let newsletter, newsletter.bodyFetched { return }
        guard !isFetching else { return }
        isFetching = true
        let error = await RequestContext.$priority.withValue(.interactiveRead) {
            await env.sync.refreshNewsletter(id: newsletterID)
        }
        isFetching = false
        fetchError = error
        markRead()
    }
}

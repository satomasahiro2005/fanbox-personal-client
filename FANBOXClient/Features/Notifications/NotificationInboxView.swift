import SwiftUI
import SwiftData

enum NotificationInboxSegment: String, CaseIterable, Identifiable, Sendable {
    case notifications
    case newsletters

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notifications: return "通知"
        case .newsletters: return "おたより"
        }
    }
}

/// Unified notification inbox across accounts (SPEC §27) + おたより.
/// Presented as a sheet from the bell button (RootView) and also routable via `AppRoute.notificationInbox`.
/// Everything renders from the local DB; tapping a row opens the locally prefetched content (SPEC §26).
/// The event list is paged locally (`pageSize` rows, "さらに表示"), so the inbox stays fast as events accumulate.
struct NotificationInboxView: View {
    @Environment(AppEnvironment.self) private var env

    /// Unread events only (small set): segment counts, "すべて既読" state.
    @Query(filter: #Predicate<NotificationEvent> { !$0.isRead }) private var unreadEvents: [NotificationEvent]
    @Query(sort: \Newsletter.createdAt, order: .reverse) private var newsletters: [Newsletter]
    @Query(FetchDescriptorFactory.enabledAccounts()) private var accounts: [Account]

    @State private var segment: NotificationInboxSegment = .notifications
    @State private var filter = NotificationInboxFilter()
    @State private var syncError: RemoteError?
    @State private var lastSyncAt: Date?
    @State private var isRefreshing = false
    @State private var eventLimit = NotificationInboxView.pageSize
    /// Latched on first appearance: true when this view is the root of the bell sheet (needs its own route destinations).
    @State private var latchedSheetHosted: Bool?

    /// Events rendered per local page.
    static let pageSize = 200

    init() {}

    private var isSheetHosted: Bool { latchedSheetHosted ?? env.router.isNotificationInboxPresented }

    /// Items of disabled accounts never show, whatever the user's filter.
    private var enabledOnly: NotificationInboxFilter { NotificationInboxFilter(enabledAccountIDs: Set(accounts.map(\.id))) }

    /// The user's filter restricted to enabled accounts; a chosen account that has been disabled since counts as none.
    private var effectiveFilter: NotificationInboxFilter {
        var effective = filter
        let enabled = Set(accounts.map(\.id))
        effective.enabledAccountIDs = enabled
        if let id = effective.accountID, !enabled.contains(id) { effective.accountID = nil }
        return effective
    }

    var body: some View {
        let hosted = isSheetHosted
        content
            .navigationTitle("通知")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar(hosted: hosted) }
            .modifier(NotificationInboxRouteDestinations(enabled: hosted))
            .onAppear {
                if latchedSheetHosted == nil { latchedSheetHosted = env.router.isNotificationInboxPresented }
                if lastSyncAt == nil { lastSyncAt = latestSuccessfulSync(for: .notifications) }
            }
            .onDisappear {
                Task { await env.notifications.updateBadge() }
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        switch segment {
        case .notifications:
            InboxEventList(limit: eventLimit, filter: effectiveFilter, syncError: syncError, lastSyncAt: lastSyncAt,
                           header: AnyView(header(showTypeChips: true, accountsByID: accountsByID)),
                           onOpen: open, onSetRead: setRead,
                           onShowMore: { eventLimit += Self.pageSize },
                           onRefresh: { await refresh(.notifications) })
        case .newsletters:
            newslettersList
        }
    }

    private var newslettersList: some View {
        let accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let filter = effectiveFilter.forNewsletters
        let visible = newsletters.filter {
            filter.matches(type: .newsletter, accountIDs: $0.accountIDs, isRead: $0.isRead)
        }
        // `.everyMinute` entries are minute-aligned; use the real clock so "1分前" is exact.
        return TimelineView(.everyMinute) { _ in
            let now = Date.now
            List {
                if let syncError {
                    SyncStatusBanner(error: syncError, lastSync: lastSyncAt)
                        .listRowSeparator(.hidden)
                }
                ForEach(visible, id: \.newsletterID) { newsletter in
                    NavigationLink(value: AppRoute.newsletter(newsletterID: newsletter.newsletterID)) {
                        NewsletterInboxRow(newsletter: newsletter, now: now,
                                           accountIDs: newsletter.accountIDs.filter { accountsByID[$0] != nil })
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            // Event and newsletter read states move together (both inbox segments).
                            NotificationReadActions.setNewsletterRead(newsletterID: newsletter.newsletterID, read: !newsletter.isRead,
                                                                      store: env.store)
                            Task { await env.notifications.updateBadge() }
                        } label: {
                            Label(newsletter.isRead ? "未読にする" : "既読にする",
                                  systemImage: newsletter.isRead ? "envelope.badge" : "envelope.open")
                        }
                        .tint(newsletter.isRead ? .blue : .gray)
                    }
                    .accessibilityIdentifier("newsletterRow.\(newsletter.newsletterID)")
                }
            }
            .listStyle(.plain)
            .overlay {
                if visible.isEmpty {
                    // Items hidden only because their accounts are disabled are not a user filter.
                    let noItems = newsletters.isEmpty || !filter.isActive
                    EmptyStateView(title: noItems ? "おたよりはありません" : "該当するおたよりはありません",
                                   systemImage: "envelope",
                                   message: noItems ? "クリエイターからのおたよりがここに表示されます" : "フィルターを変更してください")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { header(showTypeChips: false, accountsByID: accountsByID) }
            .refreshable { await refresh(.newsletters) }
            .accessibilityIdentifier("newsletterList")
        }
    }

    // MARK: Header (segment + filters)

    private func header(showTypeChips: Bool, accountsByID: [String: Account]) -> some View {
        VStack(spacing: 6) {
            Picker("表示", selection: $segment) {
                ForEach(NotificationInboxSegment.allCases) { seg in
                    Text(segmentTitle(seg)).tag(seg)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .accessibilityIdentifier("notificationSegmentPicker")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    accountFilterMenu(accountsByID: accountsByID)
                    InboxFilterChip(title: "未読のみ", systemImage: "circle.fill", isSelected: filter.unreadOnly) {
                        filter.unreadOnly.toggle()
                    }
                    .accessibilityIdentifier("notificationFilter.unread")
                    if showTypeChips {
                        Divider().frame(height: 20)
                        ForEach(NotificationInboxFilter.typeChips) { chip in
                            InboxFilterChip(title: chip.title, systemImage: chip.type.map(NotificationRowFormatter.systemImage(for:)),
                                            isSelected: filter.type == chip.type) {
                                withAnimation(.snappy) { filter.type = chip.type }
                            }
                            .accessibilityIdentifier("notificationFilter.\(chip.id)")
                        }
                    }
                }
                .padding(.horizontal)
            }
            AccountReloginBanner()
                .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func segmentTitle(_ seg: NotificationInboxSegment) -> String {
        let unread: Int
        let enabledOnly = self.enabledOnly
        switch seg {
        case .notifications: unread = unreadEvents.lazy.filter { enabledOnly.matches($0) }.count
        case .newsletters:
            unread = newsletters.lazy.filter {
                !$0.isRead && enabledOnly.matches(type: .newsletter, accountIDs: $0.accountIDs, isRead: $0.isRead)
            }.count
        }
        return unread > 0 ? "\(seg.title)（\(unread)）" : seg.title
    }

    private func accountFilterMenu(accountsByID: [String: Account]) -> some View {
        Menu {
            Picker("アカウント", selection: $filter.accountID) {
                Text("すべてのアカウント").tag(String?.none)
                ForEach(accounts, id: \.id) { account in
                    Text(account.displayName).tag(Optional(account.id))
                }
            }
        } label: {
            let accountID = effectiveFilter.accountID
            let name = accountID.flatMap { accountsByID[$0]?.displayName }
            InboxFilterChipLabel(title: name ?? "すべてのアカウント", systemImage: "person.crop.circle",
                                 isSelected: accountID != nil, showsChevron: true)
        }
        .accessibilityIdentifier("notificationAccountFilter")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(hosted: Bool) -> some ToolbarContent {
        if hosted {
            ToolbarItem(placement: .cancellationAction) {
                Button("閉じる") { env.router.isNotificationInboxPresented = false }
                    .accessibilityIdentifier("notificationInboxClose")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("すべて既読") { markAllRead() }
                .disabled(!hasUnreadInCurrentView)
                .accessibilityIdentifier("notificationMarkAllRead")
        }
    }

    private var hasUnreadInCurrentView: Bool {
        let filter = effectiveFilter
        switch segment {
        case .notifications:
            return unreadEvents.contains { filter.matches($0) }
        case .newsletters:
            let newsletterFilter = filter.forNewsletters
            return newsletters.contains {
                !$0.isRead && newsletterFilter.matches(type: .newsletter, accountIDs: $0.accountIDs, isRead: $0.isRead)
            }
        }
    }

    // MARK: Actions

    private func open(_ event: NotificationEvent) {
        // The service marks it read (event + its comment / おたより), resolves the local route and dismisses this sheet.
        env.notifications.open(eventID: event.id)
    }

    private func setRead(_ event: NotificationEvent, _ read: Bool) {
        NotificationReadActions.setEventRead(event, read: read, store: env.store)
        Task { await env.notifications.updateBadge() }
    }

    /// "すべて既読" applies to what matches the current filter (all unread rows when no filter is active), including rows
    /// beyond the locally shown page.
    private func markAllRead() {
        let filter = effectiveFilter
        switch segment {
        case .notifications: NotificationReadActions.markAllRead(unreadEvents, filter: filter, store: env.store)
        case .newsletters: NotificationReadActions.markAllRead(newsletters, filter: filter, store: env.store)
        }
        Task { await env.notifications.updateBadge() }
    }

    /// Pull-to-refresh: sync the resource for every enabled account in parallel (interactive priority).
    private func refresh(_ resource: SyncResource) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let accountIDs = env.store.accounts().map(\.id)
        let sync = env.sync
        let errors: [RemoteError] = await RequestContext.$priority.withValue(.interactiveRead) {
            await withTaskGroup(of: RemoteError?.self) { group in
                for accountID in accountIDs {
                    group.addTask { @MainActor in
                        await sync.sync(resource, accountID: accountID, reason: .userRefresh).error
                    }
                }
                var result: [RemoteError] = []
                for await error in group { if let error { result.append(error) } }
                return result
            }
        }
        syncError = errors.first
        lastSyncAt = latestSuccessfulSync(for: resource) ?? (errors.isEmpty && !accountIDs.isEmpty ? .now : lastSyncAt)
    }

    /// Newest successful sync of `resource` across accounts (for "最後の同期: HH:mm").
    private func latestSuccessfulSync(for resource: SyncResource) -> Date? {
        let resourceRaw = resource.rawValue
        let states = env.store.fetch(FetchDescriptor<SyncState>(predicate: #Predicate { $0.resourceRaw == resourceRaw }))
        return states.compactMap(\.lastSuccessfulSync).max()
    }
}

/// The notification rows of the inbox: newest `limit` events (a bounded @Query), plus the reply-queue entry.
private struct InboxEventList: View {
    let limit: Int
    let filter: NotificationInboxFilter
    let syncError: RemoteError?
    let lastSyncAt: Date?
    let header: AnyView
    let onOpen: (NotificationEvent) -> Void
    let onSetRead: (NotificationEvent, Bool) -> Void
    let onShowMore: () -> Void
    let onRefresh: () async -> Void

    @Environment(AppEnvironment.self) private var env
    @Query private var events: [NotificationEvent]
    @Query private var creators: [Creator]

    init(limit: Int, filter: NotificationInboxFilter, syncError: RemoteError?, lastSyncAt: Date?, header: AnyView,
         onOpen: @escaping (NotificationEvent) -> Void, onSetRead: @escaping (NotificationEvent, Bool) -> Void,
         onShowMore: @escaping () -> Void, onRefresh: @escaping () async -> Void) {
        self.limit = limit
        self.filter = filter
        self.syncError = syncError
        self.lastSyncAt = lastSyncAt
        self.header = header
        self.onOpen = onOpen
        self.onSetRead = onSetRead
        self.onShowMore = onShowMore
        self.onRefresh = onRefresh
        // One extra row tells whether older events exist beyond the page.
        _events = Query(FetchDescriptorFactory.notificationsNewestFirst(limit: limit + 1))
    }

    var body: some View {
        let creatorNames = Dictionary(creators.map { ($0.creatorID, $0.name) }, uniquingKeysWith: { first, _ in first })
        let hasMore = events.count > limit
        let page = hasMore ? Array(events.prefix(limit)) : events
        let visible = page.filter { filter.matches($0) }
        let replyQueueVisible = env.replies.pendingCount > 0
        // `.everyMinute` entries are minute-aligned; use the real clock so "1分前" is exact.
        return TimelineView(.everyMinute) { _ in
            let now = Date.now
            List {
                if let syncError {
                    SyncStatusBanner(error: syncError, lastSync: lastSyncAt)
                        .listRowSeparator(.hidden)
                }
                if replyQueueVisible {
                    NavigationLink {
                        ReplyQueueView()
                    } label: {
                        ReplyQueueSummaryLabel(pending: env.replies.pendingCount, attention: env.replies.attentionCount)
                    }
                    .accessibilityIdentifier("notificationReplyQueueRow")
                }
                ForEach(visible, id: \.id) { event in
                    let text = NotificationRowFormatter.format(
                        NotificationRowInput(event: event, creatorName: event.creatorID.flatMap { creatorNames[$0] }),
                        now: now)
                    Button {
                        onOpen(event)
                    } label: {
                        NotificationInboxRow(event: event, text: text,
                                             accountIDs: event.accountIDs.filter { filter.enabledAccountIDs?.contains($0) ?? true })
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            onSetRead(event, !event.isRead)
                        } label: {
                            Label(event.isRead ? "未読にする" : "既読にする",
                                  systemImage: event.isRead ? "envelope.badge" : "envelope.open")
                        }
                        .tint(event.isRead ? .blue : .gray)
                    }
                    .accessibilityIdentifier("notificationRow.\(event.id)")
                }
                if hasMore {
                    Button("さらに表示", action: onShowMore)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("notificationShowMore")
                }
            }
            .listStyle(.plain)
            .overlay {
                if visible.isEmpty && !hasMore {
                    // Items hidden only because their accounts are disabled are not a user filter.
                    if page.isEmpty || !filter.isActive {
                        EmptyStateView(title: "通知はありません", systemImage: "bell",
                                       message: "新しいコメント・投稿・おたよりなどがここに表示されます")
                    } else {
                        EmptyStateView(title: "該当する通知はありません", systemImage: "line.3.horizontal.decrease.circle",
                                       message: "フィルターを変更してください")
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .refreshable { await onRefresh() }
            .accessibilityIdentifier("notificationList")
        }
    }
}

/// "送信キュー" entry: pending replies, highlighting the ones that need a decision.
struct ReplyQueueSummaryLabel: View {
    let pending: Int
    let attention: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: attention > 0 ? "exclamationmark.bubble.fill" : "paperplane")
                .foregroundStyle(attention > 0 ? Color.orange : Color.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("送信キュー").font(.subheadline.weight(.semibold))
                Text(attention > 0 ? "確認が必要な返信が\(attention)件あります" : "送信待ちの返信が\(pending)件あります")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Adds `AppRoute` destinations when the inbox is the root of its own (sheet) NavigationStack,
/// so NavigationLinks (おたより, creator links …) work inside the sheet. Skipped when pushed on a tab stack,
/// which already declares them (avoids duplicate-destination warnings).
struct NotificationInboxRouteDestinations: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.navigationDestination(for: AppRoute.self) { route in
                AppRouteDestination(route: route)
            }
        } else {
            content
        }
    }
}

// MARK: - Rows

/// ● user123がコメントしました / Creator Account / 1分前
struct NotificationInboxRow: View {
    let event: NotificationEvent
    let text: NotificationRowText
    /// Receiving accounts to show (enabled ones).
    let accountIDs: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(event.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)

            ZStack {
                Circle()
                    .fill(NotificationRowFormatter.tint(for: event.type).opacity(0.15))
                Image(systemName: NotificationRowFormatter.systemImage(for: event.type))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NotificationRowFormatter.tint(for: event.type))
            }
            .frame(width: 32, height: 32)
            .accessibilityLabel(event.type.displayName)

            VStack(alignment: .leading, spacing: 3) {
                Text(text.headline)
                    .font(.subheadline.weight(event.isRead ? .regular : .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                ForEach(text.details, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                AccountBadgeRow(accountIDs: accountIDs)
                HStack(spacing: 6) {
                    Text(text.relativeTime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let badge = text.badge {
                        PillLabel(text: badge.text, systemImage: badge.systemImage, tint: badge.tint)
                            .accessibilityIdentifier("notificationPrefetchBadge")
                    }
                    if event.priority == .critical && !event.isRead {
                        PillLabel(text: "重要", tint: .red)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(event.isRead ? "既読" : "未読")
    }
}

struct NewsletterInboxRow: View {
    let newsletter: Newsletter
    let now: Date
    /// Receiving accounts to show (enabled ones).
    let accountIDs: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(newsletter.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)
            AvatarView(url: newsletter.creatorIconURL, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(newsletter.creatorName)からおたより")
                        .font(.subheadline.weight(newsletter.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(NotificationRowFormatter.relativeTime(newsletter.createdAt, now: now))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let title = newsletter.title, !title.isEmpty {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                Text(NewsletterExcerpt.rowText(body: newsletter.body, bodyFetched: newsletter.bodyFetched))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                AccountBadgeRow(accountIDs: accountIDs)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(newsletter.isRead ? "既読" : "未読")
    }
}

// MARK: - Chips

struct InboxFilterChip: View {
    let title: String
    var systemImage: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            InboxFilterChipLabel(title: title, systemImage: systemImage, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct InboxFilterChipLabel: View {
    let title: String
    var systemImage: String? = nil
    let isSelected: Bool
    var showsChevron: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(title).lineLimit(1)
            if showsChevron { Image(systemName: "chevron.down").imageScale(.small) }
        }
        .font(.footnote.weight(isSelected ? .semibold : .regular))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
    }
}

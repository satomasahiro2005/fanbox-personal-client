import SwiftData
import SwiftUI
import UIKit

/// Presents `WebBridge.presented` as a full-screen account-aware web session.
///
/// The session is presented with UIKit on top of whatever is currently on screen, so `env.web.openWeb(...)` also works
/// while a SwiftUI sheet (Settings, Notification Inbox, ...) is open — a SwiftUI `fullScreenCover` on the root view
/// cannot be shown above its own sheet.
struct WebBridgePresenter: ViewModifier {
    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        content
            .onChange(of: env.web.presented?.id, initial: true) { _, _ in
                WebSessionHostPresenter.shared.sync(env: env)
            }
    }
}

/// Keeps the UIKit-hosted web session in sync with `WebBridge.presented`.
@MainActor
final class WebSessionHostPresenter {
    static let shared = WebSessionHostPresenter()

    private(set) weak var host: WebSessionHostingController?
    private var isDismissing = false
    private var needsResync = false

    func sync(env: AppEnvironment) {
        guard !isDismissing else {
            needsResync = true
            return
        }
        let request = env.web.presented
        if let host {
            let isOnScreen = host.presentingViewController != nil
            if isOnScreen && host.requestID == request?.id { return }
            if isOnScreen {
                // Replace / close the current session first, then re-sync.
                isDismissing = true
                host.onGone = nil
                host.dismiss(animated: true) { [weak self] in
                    guard let self else { return }
                    self.host = nil
                    self.isDismissing = false
                    self.needsResync = false
                    self.sync(env: env)
                }
                return
            }
            // A previous presentation failed or was torn down without us: forget it.
            self.host = nil
        }
        guard let request else { return }

        let root = AccountWebSessionView(request: request)
            .environment(env)
            .environment(env.router)
            .environment(env.settings)
            .modelContainer(env.container)
        let controller = WebSessionHostingController(rootView: AnyView(root))
        controller.requestID = request.id
        controller.modalPresentationStyle = .fullScreen
        controller.isModalInPresentation = true
        controller.onGone = { [weak env] in
            // Dismissed from outside (e.g. the sheet below it closed): reflect it in WebBridge.
            guard let env, env.web.presented?.id == request.id else { return }
            env.web.dismiss()
        }
        if WebPresentationAnchor.present(controller) {
            host = controller
        } else {
            AppLog.web.error("no window to present the web session")
        }
    }
}

final class WebSessionHostingController: UIHostingController<AnyView> {
    var requestID: UUID?
    var onGone: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentingViewController == nil else { return }
            let callback = self.onGone
            self.onGone = nil
            callback?()
        }
    }
}

/// Account-aware web screen (SPEC §7.1 / §14 / §40). Shows WHICH account is active at all times so the user never
/// operates (or pays with) the wrong account.
struct AccountWebSessionView: View {
    let request: WebSessionRequest
    /// Called instead of `env.web.dismiss()` when the view is presented by its owner (embedded use).
    var onClose: (() -> Void)?

    @Environment(AppEnvironment.self) private var env
    @Query private var accounts: [Account]
    @State private var controller = AccountWebController()
    @State private var isPrepared = false
    @State private var loginState: WebLoginState = .waiting
    @State private var alert: WebSessionAlert?
    @State private var lastMetadata: WebPageMetadata?
    /// Who the pages of this session are logged in as, compared with the account (SPEC §3.2 / §7.1).
    @State private var identity: WebSessionIdentity = .unverified

    init(request: WebSessionRequest, onClose: (() -> Void)? = nil) {
        self.request = request
        self.onClose = onClose
        let accountID = request.accountID
        _accounts = Query(filter: #Predicate<Account> { $0.id == accountID })
    }

    private var account: Account? { accounts.first }
    private var isLogin: Bool { request.purpose == .login }
    private var isOffline: Bool { env.networkMode.effectiveMode == .offline }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AccountWebSessionBanner(account: account, isLoginPurpose: isLogin, identity: identity)
                if case .mismatch(let pageUserID) = identity {
                    WebIdentityMismatchBanner(accountName: account?.displayName ?? "このアカウント", pageUserID: pageUserID)
                }
                purposeBanner
                progressBar
                ZStack {
                    content
                    if let error = controller.loadError {
                        loadErrorOverlay(error)
                    }
                    if loginState == .verifying {
                        verifyingOverlay
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(controller.title ?? request.destination.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(item: $controller.popup) { popup in
                popupSheet(popup)
            }
            .alert(alert?.title ?? "", isPresented: alertBinding, presenting: alert) { item in
                Button("OK") {
                    if item.closesSession { close() }
                }
            } message: { item in
                Text(item.message)
            }
        }
        .interactiveDismissDisabled()
        .task { await prepare() }
        .onChange(of: isOffline) { _, offline in
            // SPEC §30: switching to Offline stops the page immediately (the web view is replaced by the offline state).
            if offline { controller.stopLoading() }
        }
        .onDisappear {
            let webSessions = env.webSessions
            Task {
                // Give WebKit a moment to release the WKWebView before retrying deferred store removals.
                try? await Task.sleep(for: .seconds(2))
                await webSessions.purgePendingRemovals()
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let account {
            if isOffline {
                offlineState
            } else if case .mismatch = identity {
                identityMismatchState
            } else if isPrepared {
                AccountWebView(accountID: account.id, webProfileID: account.webProfileID, initialURL: request.destination.url,
                               controller: controller, webSessions: env.webSessions, research: env.research,
                               policy: env.policyStore, fallbackURLs: request.destination.fallbacks.map(\.url))
            } else {
                ProgressView()
            }
        } else {
            EmptyStateView(title: "アカウントが見つかりません", systemImage: "person.crop.circle.badge.exclamationmark",
                           message: "このアカウントは削除されました。")
        }
    }

    /// SPEC §30 Offline: no page of the account web view is loaded at all.
    private var offlineState: some View {
        VStack(spacing: 12) {
            EmptyStateView(title: "オフラインモードです", systemImage: "wifi.slash",
                           message: env.settings.networkModePreference == .offline
                               ? "通信モードが「Offline」のためWebページを読み込みません。"
                               : "ネットワークに接続されていないためWebページを読み込めません。")
            if env.settings.networkModePreference == .offline {
                Button("通信モードをAutomaticに戻す") { env.settings.networkModePreference = .automatic }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("webOfflineRestoreButton")
            }
        }
        .accessibilityIdentifier("webOfflineState")
    }

    /// The page showed another pixiv user: the web store was reset and nothing is shown until the user reloads.
    private var identityMismatchState: some View {
        VStack(spacing: 12) {
            EmptyStateView(title: "別のpixivアカウントのページでした", systemImage: "person.crop.circle.badge.exclamationmark",
                           message: "「\(account?.displayName ?? "このアカウント")」以外のpixivアカウントでログインした状態を検出したため、"
                               + "このWebセッションを停止し、アカウントのセッションを元に戻しました。")
            Button("このアカウントとして開き直す") {
                identity = .unverified
                controller.load(request.destination.url)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("webIdentityReloadButton")
        }
        .accessibilityIdentifier("webIdentityMismatch")
    }

    @ViewBuilder
    private var purposeBanner: some View {
        if let fallback = controller.activeFallback {
            WebNoticeBanner(systemImage: "arrow.triangle.branch", tint: .orange,
                            text: "「\(request.destination.title)」のページを開けなかったため「\(fallback.title)」を表示しています")
                .accessibilityIdentifier("webFallbackBanner")
        }
        switch request.purpose {
        case .payment:
            WebFallbackMenu(steps: request.destination.fallbackSteps) { controller.openFallback($0) }
        case .login:
            if loginState != .completed {
                WebNoticeBanner(systemImage: "exclamationmark.bubble", tint: .orange, text: Self.googleLoginHint)
                    .lineLimit(1)
                    .accessibilityIdentifier("webGoogleLoginHint")
            }
        case .fallback(let reason):
            WebNoticeBanner(systemImage: "arrow.up.forward.app", tint: .orange,
                            text: reason.isEmpty ? "アプリ内で処理できないためWebで表示しています" : "Webで表示しています: \(reason)")
        case .browse:
            EmptyView()
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        ProgressView(value: controller.isLoading ? max(controller.estimatedProgress, 0.05) : 1)
            .progressViewStyle(.linear)
            .tint(Color(hex: account?.colorHex))
            .opacity(controller.isLoading ? 1 : 0)
            .frame(height: 2)
            .accessibilityHidden(!controller.isLoading)
    }

    private func loadErrorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
            Text(message).font(.subheadline).multilineTextAlignment(.center)
            Button("再読み込み") { controller.reload() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
        .accessibilityIdentifier("webLoadError")
    }

    private var verifyingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("ログインを確認中…").font(.subheadline)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("閉じる") { close() }
                .accessibilityIdentifier("webCloseButton")
        }
        if isLogin && loginState != .completed {
            ToolbarItem(placement: .confirmationAction) {
                Button("ログイン済み") {
                    Task { await attemptLogin(metadata: nil, manual: true) }
                }
                .disabled(loginState == .verifying)
                .accessibilityIdentifier("webLoginCheckButton")
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button { controller.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!controller.canGoBack)
                .accessibilityLabel("戻る")
                .accessibilityIdentifier("webBackButton")
            Button { controller.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!controller.canGoForward)
                .accessibilityLabel("進む")
                .accessibilityIdentifier("webForwardButton")
            Spacer()
            if let host = controller.currentURL?.host {
                Text(host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            if controller.isLoading {
                Button { controller.stopLoading() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("読み込みを中止")
            } else {
                Button { controller.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("再読み込み")
                    .accessibilityIdentifier("webReloadButton")
            }
        }
    }

    private func popupSheet(_ popup: AccountWebPopup) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                AccountWebSessionBanner(account: account, isLoginPurpose: isLogin, identity: identity)
                AccountWebPopupView(webView: popup.webView)
            }
            .navigationTitle(popup.webView.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { controller.closePopup() }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })
    }

    // MARK: Behaviour

    private func prepare() async {
        guard !isPrepared else { return }
        controller.fallbackSteps = request.destination.fallbackSteps
        controller.onMainFrameFinished = { url in
            Task { await handleMainFrameFinished(url) }
        }
        // Keep the account logged in on the web: re-install its Keychain session if the web store lost it (SPEC §40).
        await env.accounts.prepareWebSession(accountID: request.accountID)
        isPrepared = true
    }

    private func handleMainFrameFinished(_ url: URL) async {
        guard WebCookieScope.isFanboxHost(url.host) else { return }
        let metadata = await controller.inspectPage()
        if let metadata { lastMetadata = metadata }
        if isLogin && loginState != .completed && loginState != .verifying {
            await attemptLogin(metadata: metadata, manual: false)
            return
        }
        guard !env.accounts.isPlaceholder(accountID: request.accountID) else { return }
        let pageUserID = metadata?.isLoggedIn == false ? nil : metadata?.user?.pixivUserID
        let result = await env.accounts.refreshCredentialFromWeb(accountID: request.accountID, userAgent: metadata?.userAgent,
                                                                 csrfToken: metadata?.csrfToken, pageUserID: pageUserID)
        switch result {
        case .identityMismatch(let other):
            // Never keep operating (or paying) as another user: stop the page and any popup (PayPal / 3-D Secure);
            // the web store was already reset.
            controller.stopLoading()
            controller.closePopup()
            identity = .mismatch(pageUserID: other)
        case .updated, .unchanged, .rejected:
            if let pageUserID, pageUserID == account?.pixivUserID { identity = .verified }
        }
    }

    /// Google-only pixiv accounts cannot sign in inside an embedded WKWebView (Google refuses OAuth there).
    static let googleLoginHint = "Googleではログインできません"

    /// Login is complete when the account's store has a FANBOXSESSID cookie and the page shows a logged-in user
    /// (or, for the manual check, when the API confirms the session).
    private func attemptLogin(metadata: WebPageMetadata?, manual: Bool) async {
        guard let account else { return }
        var metadata = metadata
        if manual, let fresh = await controller.inspectPage() {
            metadata = fresh
            lastMetadata = fresh
        }
        metadata = metadata ?? lastMetadata
        var hasSession = await env.webSessions.hasSessionCookie(webProfileID: account.webProfileID)
        if !hasSession && metadata?.user != nil {
            // The page says logged in but the cookie may not be visible in the store yet: re-check a few times.
            for delay in [0.5, 1.0, 2.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                hasSession = await env.webSessions.hasSessionCookie(webProfileID: account.webProfileID)
                if hasSession { break }
            }
        }
        guard hasSession else {
            if manual {
                alert = WebSessionAlert(title: "まだログインしていません", message: "pixivの画面でログインを完了してから、もう一度確認してください。")
            }
            return
        }
        if !manual && (metadata?.isLoggedIn == false || metadata?.user == nil) { return }

        loginState = .verifying
        var userAgent = metadata?.userAgent
        if userAgent == nil { userAgent = await controller.userAgent() }
        do {
            try await env.accounts.completeLogin(accountID: request.accountID, userAgent: userAgent,
                                                 csrfToken: metadata?.csrfToken, metadata: metadata?.user)
            loginState = .completed
            let accountID = request.accountID
            let sync = env.sync
            Task {
                for resource in [SyncResource.creators, .supports, .timeline, .notifications] {
                    await sync.sync(resource, accountID: accountID, reason: .onDemand)
                }
            }
            close()
        } catch let error as AccountLoginError {
            loginState = .waiting
            switch error {
            case .duplicate, .accountNotFound:
                loginState = .failed
                alert = WebSessionAlert(title: "アカウントを追加できません", message: error.userMessage, closesSession: true)
            case .accountMismatch:
                // The web store was reset to this account's own session; the page must be reloaded before retrying.
                controller.stopLoading()
                alert = WebSessionAlert(title: "別のアカウントです", message: error.userMessage)
                controller.load(request.destination.url)
            case .noSessionCookie, .profileUnavailable, .credentialStorage:
                if manual || metadata?.user != nil {
                    alert = WebSessionAlert(title: "ログインを確認できませんでした", message: error.userMessage)
                }
            }
        } catch {
            loginState = .waiting
            if manual {
                alert = WebSessionAlert(title: "ログインを確認できませんでした", message: "しばらくしてから再度お試しください。")
            }
        }
    }

    private func close() {
        controller.stopLoading()
        if isLogin, loginState != .completed, env.accounts.isPlaceholder(accountID: request.accountID) {
            let accounts = env.accounts
            let accountID = request.accountID
            Task { await accounts.cancelLogin(accountID: accountID) }
        }
        if let onClose {
            onClose()
        } else {
            env.web.dismiss()
        }
    }
}

enum WebLoginState: Equatable {
    case waiting, verifying, completed, failed
}

/// Whether the pages of a web session are logged in as the session's account.
enum WebSessionIdentity: Equatable {
    /// No FANBOX page with a logged-in user has been seen yet.
    case unverified
    /// A FANBOX page confirmed the account's own pixiv user.
    case verified
    /// A FANBOX page showed another pixiv user: the session is stopped and its web store reset.
    case mismatch(pageUserID: String)
}

/// Red warning under the account banner when a page belonged to another pixiv user.
struct WebIdentityMismatchBanner: View {
    let accountName: String
    let pageUserID: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.white)
            Text("このWebセッションは「\(accountName)」ではないpixivアカウント（pixiv ID: \(pageUserID)）でした。"
                 + "操作・決済を止め、セッションを元に戻しました。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.red)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("webIdentityMismatchBanner")
    }
}

struct WebSessionAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var closesSession = false
}

/// Prominent "<Account> として表示中" bar in the account's color (SPEC §7.1 / §14 / §40). Shows whether the pages were
/// verified to be logged in as this account.
struct AccountWebSessionBanner: View {
    let account: Account?
    var isLoginPurpose = false
    var identity: WebSessionIdentity = .unverified

    var body: some View {
        let color = Color(hex: account?.colorHex, fallback: .gray)
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.25))
                if let url = account?.avatarURL {
                    AvatarView(url: url, size: 30)
                } else {
                    Image(systemName: "person.fill").foregroundStyle(color)
                }
            }
            .frame(width: 32, height: 32)
            .overlay(Circle().stroke(color, lineWidth: 2))

            VStack(alignment: .leading, spacing: 1) {
                Text("\(title)として表示中")
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let account, !AccountService.isPlaceholder(account) {
                AccountSessionPill(state: account.sessionState, kind: account.kind)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.16))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 5) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("webAccountBanner")
    }

    private var title: String {
        guard let account else { return "不明なアカウント" }
        if AccountService.isPlaceholder(account) { return "新しいアカウント" }
        return account.displayName
    }

    private var detail: String {
        guard let account else { return "アカウントが見つかりません" }
        if AccountService.isPlaceholder(account) {
            return isLoginPurpose ? "専用のWebストアでログイン中（まだ追加されていません）" : "ログイン前"
        }
        var parts: [String] = []
        if account.kind == .demo { parts.append("デモアカウント（FANBOX未ログイン）") }
        if let pixiv = account.pixivUserID, account.kind == .fanbox { parts.append("pixiv ID: \(pixiv)") }
        if account.creatorAccount { parts.append("クリエイター") }
        switch identity {
        case .verified: parts.append("ログイン中のユーザーを確認済み")
        case .mismatch: parts.append("別ユーザーを検出・停止")
        case .unverified: break
        }
        return parts.isEmpty ? "専用のWebストア" : parts.joined(separator: " ・ ")
    }
}

/// Session state badge shared by the web banner and the account settings screens.
struct AccountSessionPill: View {
    let state: SessionState
    var kind: AccountKind = .fanbox

    var body: some View {
        if kind == .demo {
            PillLabel(text: "デモ", systemImage: "wand.and.stars", tint: .indigo)
        } else {
            PillLabel(text: Self.label(state), systemImage: Self.symbol(state), tint: Self.tint(state))
        }
    }

    static func label(_ state: SessionState) -> String {
        switch state {
        case .valid: return "有効"
        case .expired: return "期限切れ"
        case .loggedOut: return "ログアウト"
        case .error: return "要再ログイン"
        case .unknown: return "未確認"
        }
    }

    static func symbol(_ state: SessionState) -> String {
        switch state {
        case .valid: return "checkmark.seal.fill"
        case .expired: return "clock.badge.exclamationmark"
        case .loggedOut: return "person.crop.circle.badge.xmark"
        case .error: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    static func tint(_ state: SessionState) -> Color {
        switch state {
        case .valid: return .green
        case .expired: return .orange
        case .loggedOut: return .gray
        case .error: return .red
        case .unknown: return .secondary
        }
    }
}

/// "ページが表示されない場合" — manual switch to the verified fallback pages of the destination (docs/API.md §20).
struct WebFallbackMenu: View {
    let steps: [WebFallbackStep]
    var onSelect: (WebFallbackStep) -> Void

    var body: some View {
        if !steps.isEmpty {
            Menu {
                ForEach(steps) { step in
                    Button(step.title) { onSelect(step) }
                }
            } label: {
                Label("ページが表示されない場合", systemImage: "arrow.triangle.branch")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08))
            .accessibilityIdentifier("webFallbackMenu")
        }
    }
}

/// One-line notice under the account banner (login / fallback purposes).
struct WebNoticeBanner: View {
    let systemImage: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(tint.opacity(0.08))
    }
}

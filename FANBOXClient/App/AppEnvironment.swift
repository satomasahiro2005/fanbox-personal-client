import Foundation
import Observation
import SwiftData

/// Dependency container. Features read it with `@Environment(AppEnvironment.self)`.
@MainActor
@Observable
final class AppEnvironment {
    @ObservationIgnored let container: ModelContainer
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let policyStore: NetworkPolicyStore
    @ObservationIgnored let networkMode: NetworkModeController
    @ObservationIgnored let scheduler: NetworkScheduler
    @ObservationIgnored let credentials: CredentialStoring
    @ObservationIgnored let research: ResearchRecorder
    @ObservationIgnored let schemaInspector: SchemaInspector
    @ObservationIgnored let http: HTTPClient
    /// FANBOX request router (native URLSession / account WebView transport, RateGate). Same object as `http`.
    @ObservationIgnored let transport: RoutingHTTPClient
    @ObservationIgnored let rateGate: RateGate
    @ObservationIgnored let transportPreferences: TransportPreferences
    /// Hidden per-account WebViews used as the fallback transport (docs/API.md §1.11).
    @ObservationIgnored let webFetch: WebFetchHostPool
    @ObservationIgnored let remote: RemoteDataSourceProvider
    @ObservationIgnored let sync: SyncEngine
    @ObservationIgnored let replies: ReplyQueue
    @ObservationIgnored let coordinator: SyncCoordinator
    @ObservationIgnored let router: AppRouter
    @ObservationIgnored let notifications: NotificationService
    @ObservationIgnored let media: MediaService
    @ObservationIgnored let offline: OfflineLibraryService
    @ObservationIgnored let prefetcher: MediaPrefetcher
    @ObservationIgnored let web: WebBridge
    /// SPEC §14 状態再同期 after payment web sessions (immediate + follow-up checks).
    @ObservationIgnored let paymentResync: PaymentResyncScheduler
    @ObservationIgnored let webSessions: WebSessionStore
    @ObservationIgnored let accounts: AccountService
    @ObservationIgnored let uploads: UploadQueue
    @ObservationIgnored let drafts: DraftService
    @ObservationIgnored let repository: DefaultFanboxRepository

    /// - Parameter transportDefaults: where transport preferences (per-endpoint "prefer WebView" and the Research
    ///   override) persist; nil keeps them in memory (previews / UI tests).
    init(container: ModelContainer, settings: AppSettings, credentials: CredentialStoring, transportDefaults: UserDefaults? = nil) {
        self.container = container
        self.settings = settings
        self.credentials = credentials
        store = LocalStore(container: container)
        policyStore = NetworkPolicyStore()
        networkMode = NetworkModeController(settings: settings, policyStore: policyStore)
        scheduler = NetworkScheduler(policy: policyStore)
        research = ResearchRecorder()
        schemaInspector = SchemaInspector()
        webSessions = WebSessionStore()
        let native = AccountHTTPClient(credentials: credentials, scheduler: scheduler, recorder: research)
        rateGate = RateGate()
        transportPreferences = TransportPreferences(defaults: transportDefaults)
        webFetch = WebFetchHostPool(webSessions: webSessions, credentials: credentials, scheduler: scheduler, recorder: research,
                                    policy: policyStore)
        transport = RoutingHTTPClient(native: native, web: webFetch, gate: rateGate, preferences: transportPreferences,
                                      recorder: research)
        http = transport
        // Credentials passed explicitly: the API client refreshes / stores CSRF tokens in the transport's own store.
        let api = FanboxAPIClient(http: transport, inspector: schemaInspector, credentials: credentials)
        remote = DefaultRemoteDataSourceProvider(fanbox: FanboxRemoteDataSource(api: api), demo: DemoRemoteDataSource(policy: policyStore))
        sync = SyncEngine(store: store, remote: remote, settings: settings, network: networkMode)
        replies = ReplyQueue(store: store, remote: remote, settings: settings, network: networkMode)
        coordinator = SyncCoordinator(engine: sync, settings: settings, network: networkMode, replies: replies)
        router = AppRouter()
        notifications = NotificationService(store: store, engine: sync, replies: replies, router: router, settings: settings)
        media = MediaService(store: store, http: http, network: networkMode, settings: settings)
        offline = OfflineLibraryService(store: store, engine: sync, media: media, settings: settings)
        prefetcher = MediaPrefetcher(store: store, media: media)
        web = WebBridge()
        paymentResync = PaymentResyncScheduler(engine: sync)
        accounts = AccountService(store: store, credentials: credentials, webSessions: webSessions, remote: remote)
        uploads = UploadQueue(store: store, remote: remote, network: networkMode)
        drafts = DraftService(store: store, uploads: uploads, remote: remote, web: web)
        repository = DefaultFanboxRepository(store: store, engine: sync)

        research.attach(store: store, settings: settings)
        schemaInspector.attach(store: store)
        schemaInspector.attach(recorder: research)
        wire()
    }

    /// Cross-service callbacks.
    private func wire() {
        sync.onNewNotificationEvents = { [weak self] ids in
            await self?.notifications.process(newEventIDs: ids)
            // Text is local now (Priority 0/1); avatars / thumbnails / display images follow at mediaPrefetch (SPEC §25).
            self?.prefetcher.notificationEventsProcessed(ids)
        }
        sync.onSyncFinished = { [weak self] outcome, reason in
            // Offline "recent N" rules keep applying to new posts (SPEC §31); Normal-mode media prefetch (SPEC §30).
            self?.offline.syncFinished(outcome, reason: reason)
            self?.prefetcher.syncFinished(outcome, reason: reason)
        }
        // Notification pipeline ↔ reply queue / coordinator / media (sync-notify).
        replies.onAttentionNeeded = { [weak self] itemID in
            await self?.notifications.handleReplyAttention(itemID: itemID)
        }
        coordinator.notifications = notifications
        notifications.mediaPrefetcher = { [weak self] request in
            guard let media = self?.media else { return }
            Task { _ = try? await media.load(request) }
        }
        sync.onFailure = { [research] operation, accountID, error in
            research.recordSyncFailure(operation: operation, accountID: accountID, error: error)
        }
        networkMode.onConnectivityRestored = { [weak self] in
            self?.replies.handleConnectivityRestored()
            self?.uploads.start()
        }
        web.onDismiss = { [weak self] request in
            guard let self else { return }
            // Payment flows: immediate resync + follow-ups (activation can lag, docs/API.md §18.10).
            self.paymentResync.handleDismissedPaymentSession(request)
            if CreatorWebReconcile.needsManagedPostsResync(request) {
                Task { await self.sync.sync(.creatorPosts, accountID: request.accountID, reason: .afterWrite) }
            }
        }

        // The badge counts events of enabled accounts only.
        accounts.onEnabledAccountsChanged = { [weak self] in
            Task { await self?.notifications.updateBadge() }
        }
        // Transport ↔ accounts (SPEC §3.2 / §7.2 / §40).
        accounts.sessionRevoker = transport
        transport.native.onSessionCookieChanged = { [weak self] accountID in
            Task { @MainActor in await self?.accounts.installAPISessionIntoWeb(accountID: accountID) }
        }
        webFetch.accountResolver = { [weak self] accountID in
            guard let account = self?.store.account(id: accountID), account.kind == .fanbox, account.enabled,
                  !AccountService.isPlaceholder(account), account.sessionState != .error else { return nil }
            return WebFetchAccount(accountID: account.id, webProfileID: account.webProfileID, pixivUserID: account.pixivUserID)
        }
        webFetch.prepareSession = { [weak self] accountID in
            await self?.accounts.prepareWebSession(accountID: accountID)
        }
        webFetch.onIdentityMismatch = { [weak self] accountID, pageUserID in
            Task { @MainActor in await self?.accounts.handleWebIdentityMismatch(accountID: accountID, pageUserID: pageUserID) }
        }
        sync.onIdentityMismatch = { [weak self] accountID, observedUserID in
            await self?.accounts.quarantineMismatchedSession(accountID: accountID, observedUserID: observedUserID)
        }
        sync.onSessionExpired = { [weak self] accountID in
            guard let self, let account = self.store.account(id: accountID) else { return }
            SessionExpiryNotifier.notify(accountID: accountID, accountName: account.displayName,
                                         enabled: self.settings.localNotificationsEnabled)
        }
    }

    /// Second supports resync after a payment web session (activation can take minutes).
    static let paymentResyncDelay: TimeInterval = 4 * 60

    /// Production environment with the on-disk store and Keychain credentials.
    static func live() -> AppEnvironment {
        let arguments = ProcessInfo.processInfo.arguments
        let inMemory = arguments.contains("-uiTesting")
        let container: ModelContainer
        do {
            container = try PersistenceController.makeContainer(inMemory: inMemory)
        } catch {
            AppLog.database.fault("store open failed, falling back to memory: \(String(describing: error), privacy: .public)")
            container = try! PersistenceController.makeContainer(inMemory: true)
        }
        let settings = inMemory ? AppSettings(defaults: UserDefaults(suiteName: "uiTesting-\(UUID().uuidString)")!) : AppSettings()
        let credentials: CredentialStoring = inMemory ? InMemoryCredentialStore() : CredentialStore()
        let env = AppEnvironment(container: container, settings: settings, credentials: credentials,
                                 transportDefaults: inMemory ? nil : .standard)
        if arguments.contains("-demoData") {
            env.seedDemoIfNeeded()
        }
        env.router.applyLaunchArguments()
        // The real network path is known in every launch mode, also background launches without a scene (SPEC §30 / §35).
        env.networkMode.start()
        // A multipart body interrupted by a kill may still be on disk; the CSRF token must not stay there (SPEC §39).
        MultipartFormData.removeStaleTemporaryFiles()
        env.refreshStoredFlagsAtLaunch()
        Task { @MainActor in await env.accounts.purgeOrphanCredentials() }
        return env
    }

    /// Re-derives the stored creator / feed relation flags once per launch. Earlier builds counted disabled accounts in
    /// them, and a sync only recomputes the syncing account's own creators; one Creator fetch when nothing changed.
    func refreshStoredFlagsAtLaunch() {
        store.refreshRelationFlags()
    }

    /// In-memory environment with demo accounts (previews / tests).
    static func preview(seedDemo: Bool = true) -> AppEnvironment {
        let container = try! PersistenceController.makeContainer(inMemory: true)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "preview-\(UUID().uuidString)")!)
        let env = AppEnvironment(container: container, settings: settings, credentials: InMemoryCredentialStore())
        if seedDemo { env.seedDemoIfNeeded() }
        return env
    }

    /// Adds demo accounts when there are no accounts at all (demo is clearly labeled).
    func seedDemoIfNeeded() {
        guard store.accounts(includeDisabled: true).isEmpty else { return }
        let a = accounts.addDemoAccount(name: "Demo A")
        a.colorHex = "#8B5CF6"
        let b = accounts.addDemoAccount(name: "Demo B")
        b.colorHex = "#2DD4BF"
        let c = accounts.addDemoAccount(name: "Demo Creator")
        c.colorHex = "#F59E0B"
        c.creatorID = "demo-creator-self"
        store.save()
    }
}

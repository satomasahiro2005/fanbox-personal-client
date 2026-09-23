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
    @ObservationIgnored let webSessions: WebSessionStore
    @ObservationIgnored let accounts: AccountService
    @ObservationIgnored let uploads: UploadQueue
    @ObservationIgnored let drafts: DraftService
    @ObservationIgnored let repository: DefaultFanboxRepository

    init(container: ModelContainer, settings: AppSettings, credentials: CredentialStoring) {
        self.container = container
        self.settings = settings
        self.credentials = credentials
        store = LocalStore(container: container)
        policyStore = NetworkPolicyStore()
        networkMode = NetworkModeController(settings: settings, policyStore: policyStore)
        scheduler = NetworkScheduler(policy: policyStore)
        research = ResearchRecorder()
        schemaInspector = SchemaInspector()
        http = AccountHTTPClient(credentials: credentials, scheduler: scheduler, recorder: research)
        let api = FanboxAPIClient(http: http, inspector: schemaInspector)
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
        webSessions = WebSessionStore()
        accounts = AccountService(store: store, credentials: credentials, webSessions: webSessions, remote: remote)
        uploads = UploadQueue(store: store, remote: remote, network: networkMode)
        drafts = DraftService(store: store, uploads: uploads, remote: remote, web: web)
        repository = DefaultFanboxRepository(store: store, engine: sync)

        research.attach(store: store, settings: settings)
        schemaInspector.attach(store: store)
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
        networkMode.onConnectivityRestored = { [weak self] in
            self?.replies.handleConnectivityRestored()
            self?.uploads.start()
        }
        web.onDismiss = { [weak self] request in
            guard let self else { return }
            if case .payment = request.purpose {
                Task { await self.sync.sync(.supports, accountID: request.accountID, reason: .afterWrite) }
            }
            if CreatorWebReconcile.needsManagedPostsResync(request) {
                Task { await self.sync.sync(.creatorPosts, accountID: request.accountID, reason: .afterWrite) }
            }
        }
    }

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
        let env = AppEnvironment(container: container, settings: settings, credentials: credentials)
        if arguments.contains("-demoData") {
            env.seedDemoIfNeeded()
        }
        env.router.applyLaunchArguments()
        return env
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

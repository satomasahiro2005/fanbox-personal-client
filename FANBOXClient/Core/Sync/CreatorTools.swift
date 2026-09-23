import Foundation
import Observation

/// Media upload job queue (SPEC §20). queued → uploading → completed | failed | paused. Only failed jobs are re-sent.
@MainActor
@Observable
final class UploadQueue {
    private(set) var isRunning = false

    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let remote: RemoteDataSourceProvider
    @ObservationIgnored let network: NetworkModeController

    init(store: LocalStore, remote: RemoteDataSourceProvider, network: NetworkModeController) {
        self.store = store
        self.remote = remote
        self.network = network
    }
}

/// Local drafts, native editor operations, Post Edit import and publish (SPEC §18 / §19).
@MainActor
@Observable
final class DraftService {
    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let uploads: UploadQueue
    @ObservationIgnored let remote: RemoteDataSourceProvider
    @ObservationIgnored let web: WebBridge

    init(store: LocalStore, uploads: UploadQueue, remote: RemoteDataSourceProvider, web: WebBridge) {
        self.store = store
        self.uploads = uploads
        self.remote = remote
        self.web = web
    }
}

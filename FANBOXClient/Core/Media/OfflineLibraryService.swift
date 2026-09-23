import Foundation
import Observation

/// Offline Library (SPEC §31). Save units: this post / creator's recent N / auto-save viewed posts.
/// Never crawls unlimited history.
@MainActor
@Observable
final class OfflineLibraryService {
    private(set) var activeSaves: Set<String> = []

    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let engine: SyncEngine
    @ObservationIgnored let media: MediaService
    @ObservationIgnored let settings: AppSettings

    init(store: LocalStore, engine: SyncEngine, media: MediaService, settings: AppSettings) {
        self.store = store
        self.engine = engine
        self.media = media
        self.settings = settings
    }

    /// Saves text + display images of a post and pins them.
    func save(postID: String) async {}

    func remove(postID: String) {}

    /// Saves the latest `count` posts of a creator (already-known + one differential fetch, no deep crawl).
    func saveRecent(creatorID: String, count: Int) async {}

    /// Called whenever a post detail is displayed.
    func postViewed(postID: String) async {}
}

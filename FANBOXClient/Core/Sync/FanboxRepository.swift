import Foundation
import SwiftData

/// Repository façade from SPEC §43. Combines `LocalStore` (LocalDataSource) and `RemoteDataSource`.
/// Reads return local data immediately; remote refreshes write through `LocalStore`.
@MainActor
protocol FanboxRepository {
    func timeline(account: String) async throws -> [Post]
    func post(id: String, account: String) async throws -> Post
    func creator(id: String, account: String) async throws -> Creator
    func supports(account: String) async throws -> [Support]
}

/// Default repository: every method refreshes through `SyncEngine` (differential, coalesced) and then answers from the
/// local DB. A network error only surfaces when there is nothing cached to return (SPEC §3.1 / §44).
@MainActor
final class DefaultFanboxRepository: FanboxRepository {
    let store: LocalStore
    let engine: SyncEngine

    init(store: LocalStore, engine: SyncEngine) {
        self.store = store
        self.engine = engine
    }

    /// Posts this account has seen in a listing, newest first.
    func timeline(account: String) async throws -> [Post] {
        let outcome = await engine.sync(.timeline, accountID: account, reason: .onDemand)
        let posts = store.fetch(FetchDescriptorFactory.postsNewestFirst()).filter { $0.seenByAccountIDs.contains(account) }
        if posts.isEmpty, let error = outcome.error { throw error }
        return posts
    }

    func post(id: String, account: String) async throws -> Post {
        if let local = store.post(id: id), local.hasCachedBody { return local }
        if let error = await engine.refreshPost(postID: id, accountID: account) {
            if let local = store.post(id: id) { return local }
            throw error
        }
        guard let post = store.post(id: id) else { throw RemoteError.notFound }
        return post
    }

    func creator(id: String, account: String) async throws -> Creator {
        if let error = await engine.refreshCreator(creatorID: id, accountID: account) {
            if let local = store.creator(id: id) { return local }
            throw error
        }
        guard let creator = store.creator(id: id) else { throw RemoteError.notFound }
        return creator
    }

    func supports(account: String) async throws -> [Support] {
        let outcome = await engine.sync(.supports, accountID: account, reason: .onDemand)
        let local = store.supports(accountID: account)
        if local.isEmpty, let error = outcome.error { throw error }
        return local
    }
}

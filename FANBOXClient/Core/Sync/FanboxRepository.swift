import Foundation

/// Repository façade from SPEC §43. Combines `LocalStore` (LocalDataSource) and `RemoteDataSource`.
/// Reads return local data immediately; remote refreshes write through `LocalStore`.
@MainActor
protocol FanboxRepository {
    func timeline(account: String) async throws -> [Post]
    func post(id: String, account: String) async throws -> Post
    func creator(id: String, account: String) async throws -> Creator
    func supports(account: String) async throws -> [Support]
}

@MainActor
final class DefaultFanboxRepository: FanboxRepository {
    let store: LocalStore
    let engine: SyncEngine

    init(store: LocalStore, engine: SyncEngine) {
        self.store = store
        self.engine = engine
    }

    func timeline(account: String) async throws -> [Post] {
        await engine.sync(.timeline, accountID: account, reason: .onDemand)
        let all = store.fetch(FetchDescriptorFactory.postsNewestFirst())
        return all.filter { $0.seenByAccountIDs.contains(account) }
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
        await engine.sync(.supports, accountID: account, reason: .onDemand)
        return store.supports(accountID: account)
    }
}

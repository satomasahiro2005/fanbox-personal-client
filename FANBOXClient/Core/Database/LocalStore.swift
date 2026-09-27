import Foundation
import SwiftData

/// Where a post listing came from (feed filter flags).
enum TimelineSource: String, Sendable {
    case home, supporting, creator, managed, notification
}

struct UpsertResult: Sendable, Equatable {
    var insertedIDs: [String] = []
    var updatedIDs: [String] = []
}

/// Result of applying a fresh supporting-plan listing for one account (SPEC §11 / §15).
struct SupportDiff: Sendable, Equatable {
    var started: [String] = []        // creatorIDs
    var changed: [String] = []
    var disappeared: [String] = []
    var restored: [String] = []
    /// No longer listed, explained by a stop of this / the previous billing month (SPEC §10.3): 支援終了, not an anomaly.
    var ended: [String] = []

    var isEmpty: Bool { started.isEmpty && changed.isEmpty && disappeared.isEmpty && restored.isEmpty && ended.isEmpty }
    /// Every creator whose support changed in this diff.
    var observedCreatorIDs: [String] { started + changed + restored + disappeared + ended }
}

/// Local data source (SPEC §43). The ONLY writer of normalized FANBOX data into SwiftData.
/// Runs on the main actor with the container's main context so `@Query` views update immediately
/// (Local DB → Immediate UI). Network work happens off-main in remote data sources.
@MainActor
final class LocalStore {
    let container: ModelContainer
    let context: ModelContext

    init(container: ModelContainer) {
        self.container = container
        self.context = container.mainContext
        self.context.autosaveEnabled = true
    }

    func save() {
        do { try context.save() } catch { AppLog.database.error("save failed: \(String(describing: error), privacy: .public)") }
    }

    // MARK: - Generic helpers

    func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> [T] {
        (try? context.fetch(descriptor)) ?? []
    }

    func first<T: PersistentModel>(_ predicate: Predicate<T>) -> T? {
        var d = FetchDescriptor<T>(predicate: predicate)
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    // MARK: - Accounts

    func accounts(includeDisabled: Bool = false) -> [Account] {
        let all = fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]))
        return includeDisabled ? all : all.filter(\.enabled)
    }

    func account(id: String) -> Account? { first(#Predicate<Account> { $0.id == id }) }

    /// Ids of the enabled accounts. Data of a disabled account stays stored but is hidden everywhere (lists, totals, badge).
    func enabledAccountIDs() -> Set<String> { Set(accounts().map(\.id)) }

    /// Ids of the disabled accounts (they send no requests, media included).
    func disabledAccountIDs() -> Set<String> { Set(accounts(includeDisabled: true).filter { !$0.enabled }.map(\.id)) }

    func mainAccount() -> Account? { accounts().first(where: \.isMain) ?? accounts().first }

    // MARK: - Lookups

    func post(id: String) -> Post? { first(#Predicate<Post> { $0.postID == id }) }

    func creator(id: String) -> Creator? { first(#Predicate<Creator> { $0.creatorID == id }) }

    func postAccesses(postID: String) -> [PostAccess] {
        fetch(FetchDescriptor<PostAccess>(predicate: #Predicate { $0.postID == postID }))
    }

    func comments(postID: String) -> [Comment] {
        fetch(FetchDescriptor<Comment>(predicate: #Predicate { $0.postID == postID }, sortBy: [SortDescriptor(\.createdAt)]))
    }

    func supports(accountID: String) -> [Support] {
        fetch(FetchDescriptor<Support>(predicate: #Predicate { $0.accountID == accountID }))
    }

    func supports(creatorID: String) -> [Support] {
        fetch(FetchDescriptor<Support>(predicate: #Predicate { $0.creatorID == creatorID }))
    }

    func plans(creatorID: String) -> [Plan] {
        fetch(FetchDescriptor<Plan>(predicate: #Predicate { $0.creatorID == creatorID }, sortBy: [SortDescriptor(\.fee)]))
    }

    func notificationEvent(id: String) -> NotificationEvent? { first(#Predicate<NotificationEvent> { $0.id == id }) }

    func newsletter(id: String) -> Newsletter? { first(#Predicate<Newsletter> { $0.newsletterID == id }) }

    func draft(id: String) -> Draft? { first(#Predicate<Draft> { $0.id == id }) }

    /// Returns (creating if needed) the sync state row.
    func syncState(accountID: String, resource: SyncResource, scope: String = "") -> SyncState {
        let key = SyncState.key(accountID: accountID, resource: resource, scope: scope)
        if let s = first(#Predicate<SyncState> { $0.key == key }) { return s }
        let s = SyncState(accountID: accountID, resource: resource, scope: scope)
        context.insert(s)
        return s
    }

    /// Subset of `ids` already present locally.
    func knownPostIDs(_ ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let posts = fetch(FetchDescriptor<Post>(predicate: #Predicate { ids.contains($0.postID) }))
        return Set(posts.map(\.postID))
    }

    // MARK: - Normalizing upserts (Remote* → SwiftData). Implemented in LocalStore+Upserts.swift.
}

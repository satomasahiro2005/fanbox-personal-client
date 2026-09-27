import Foundation
import SwiftData

/// Reusable fetch descriptors.
enum FetchDescriptorFactory {
    static func postsNewestFirst(limit: Int? = nil) -> FetchDescriptor<Post> {
        var d = FetchDescriptor<Post>(sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        d.fetchLimit = limit
        return d
    }

    static func postsByCreator(_ creatorID: String, limit: Int? = nil) -> FetchDescriptor<Post> {
        var d = FetchDescriptor<Post>(predicate: #Predicate { $0.creatorID == creatorID },
                                      sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        d.fetchLimit = limit
        return d
    }

    static func notificationsNewestFirst(limit: Int? = nil) -> FetchDescriptor<NotificationEvent> {
        var d = FetchDescriptor<NotificationEvent>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        d.fetchLimit = limit
        return d
    }

    /// Enabled accounts in display order, for every screen except Settings → アカウント: a disabled account (and a
    /// login placeholder) and its data are hidden until it is enabled again. `@Query(FetchDescriptorFactory.enabledAccounts())`.
    static func enabledAccounts() -> FetchDescriptor<Account> {
        FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.enabled },
                                 sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
    }
}

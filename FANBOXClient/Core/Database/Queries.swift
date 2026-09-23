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
}

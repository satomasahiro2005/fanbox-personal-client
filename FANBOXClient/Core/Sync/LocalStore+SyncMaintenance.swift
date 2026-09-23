import Foundation
import SwiftData

/// Maintenance helpers used by the sync layer (BGProcessingTask / launch).
extension LocalStore {
    /// Deletes Research Mode logs older than `date` (metadata ring buffer housekeeping). Never touches content.
    @discardableResult
    func maintenancePruneResearchLogs(before date: Date) -> Int {
        let old = fetch(FetchDescriptor<ResearchLog>(predicate: #Predicate { $0.timestamp < date }))
        for log in old { context.delete(log) }
        if !old.isEmpty { save() }
        return old.count
    }

    /// Inbox housekeeping (SPEC §27): deletes READ notification events that happened and were detected before `date`.
    /// Unread events are never deleted. `upsertNotifications` does not re-import remote items older than
    /// `LocalStore.notificationRetention`, so a pruned event does not come back as new.
    @discardableResult
    func maintenancePruneNotificationEvents(before date: Date) -> Int {
        let old = fetch(FetchDescriptor<NotificationEvent>(predicate: #Predicate { $0.isRead && $0.timestamp < date && $0.detectedAt < date }))
        for event in old { context.delete(event) }
        if !old.isEmpty { save() }
        return old.count
    }

    /// Prefetches interrupted by an app kill / suspension stay `.inProgress` forever; make them retryable.
    @discardableResult
    func resetInterruptedPrefetches() -> Int {
        let raw = PrefetchState.inProgress.rawValue
        let stuck = fetch(FetchDescriptor<NotificationEvent>(predicate: #Predicate { $0.prefetchStateRaw == raw }))
        for event in stuck { event.prefetchState = .failed }
        if !stuck.isEmpty { save() }
        return stuck.count
    }

    /// Recent events whose text prefetch failed (retried when the app becomes active), newest first.
    func failedPrefetchEventIDs(since date: Date, limit: Int) -> [String] {
        let failed = PrefetchState.failed.rawValue
        var descriptor = FetchDescriptor<NotificationEvent>(predicate: #Predicate { $0.prefetchStateRaw == failed && $0.timestamp > date },
                                                            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = limit
        return fetch(descriptor).map(\.id)
    }

    /// Unread notification events (badge count). Uses a count query, never loads the rows.
    func unreadNotificationEventCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<NotificationEvent>(predicate: #Predicate { !$0.isRead }))) ?? 0
    }
}

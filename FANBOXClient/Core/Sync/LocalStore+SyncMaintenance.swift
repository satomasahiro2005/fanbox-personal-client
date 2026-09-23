import Foundation
import SwiftData

/// Maintenance helpers used by the sync layer (BGProcessingTask).
extension LocalStore {
    /// Deletes Research Mode logs older than `date` (metadata ring buffer housekeeping). Never touches content.
    @discardableResult
    func maintenancePruneResearchLogs(before date: Date) -> Int {
        let old = fetch(FetchDescriptor<ResearchLog>(predicate: #Predicate { $0.timestamp < date }))
        for log in old { context.delete(log) }
        if !old.isEmpty { save() }
        return old.count
    }
}

import Foundation
import SwiftData

/// Creator Mode bookkeeping of my own managed posts (SPEC §16 / §45 Posts).
extension LocalStore {
    /// `Post.remoteStatusRaw` of an own post that disappeared from a complete managed listing (deleted on FANBOX).
    /// Hidden from reader views (`isVisibleToReaders`) and from the Creator post list; user metadata is kept.
    nonisolated static let removedManagedStatus = "removed"

    /// Records the FANBOX status of listed managed posts. An unknown status leaves the stored one, except that a post
    /// listed again is no longer "removed".
    func applyManagedStatuses(_ items: [RemotePostSummary]) {
        guard !items.isEmpty else { return }
        var statuses: [String: String?] = [:]
        for item in items where statuses[item.id] == nil { statuses[item.id] = .some(item.remoteStatus?.rawValue) }
        let ids = Array(statuses.keys)
        let removed = Self.removedManagedStatus
        var changed = false
        for post in fetch(FetchDescriptor<Post>(predicate: #Predicate { ids.contains($0.postID) })) {
            guard let entry = statuses[post.postID] else { continue }
            let target: String? = entry ?? (post.remoteStatusRaw == removed ? nil : post.remoteStatusRaw)
            if post.remoteStatusRaw != target {
                post.remoteStatusRaw = target
                changed = true
            }
        }
        if changed { save() }
    }

    /// After a COMPLETE managed listing: own posts of the account's creator page that are missing from it are marked
    /// removed (never deleted — favorites, memo, read state and offline copies stay). Only posts at least as new as the
    /// oldest listed post are judged, so a listing capped by the service never marks older posts. An empty listing
    /// judges nothing (it may be a service-side glitch). Returns the ids marked.
    @discardableResult
    func markMissingManagedPostsRemoved(presentIDs: Set<String>, oldestListed: Date?, creatorID: String) -> [String] {
        guard !presentIDs.isEmpty, let oldestListed else { return [] }
        let removed = Self.removedManagedStatus
        let candidates = fetch(FetchDescriptor<Post>(predicate: #Predicate { $0.creatorID == creatorID }))
        var marked: [String] = []
        for post in candidates where !presentIDs.contains(post.postID) && post.publishedAt >= oldestListed {
            guard post.remoteStatusRaw != removed else { continue }
            post.remoteStatusRaw = removed
            marked.append(post.postID)
        }
        if !marked.isEmpty { save() }
        return marked
    }

    /// Existing sync state row (never creates one).
    func existingSyncState(accountID: String, resource: SyncResource, scope: String = "") -> SyncState? {
        let key = SyncState.key(accountID: accountID, resource: resource, scope: scope)
        return first(#Predicate<SyncState> { $0.key == key })
    }

    /// True once the creator's complete plan list (plan.listCreator) was read by any account. Plan rows written by support
    /// listings alone cover only the plans some account supports.
    func hasFetchedPlanList(creatorID: String) -> Bool {
        let raw = SyncResource.plans.rawValue
        return fetch(FetchDescriptor<SyncState>(predicate: #Predicate { $0.resourceRaw == raw && $0.scope == creatorID }))
            .contains { $0.lastSuccessfulSync != nil }
    }
}

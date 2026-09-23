import Foundation
import SwiftData
import UIKit

/// Media prefetch — the lowest network stage (SPEC §1 item 6, §25 Priority 2–3, §29 `mediaPrefetch`, §30 Normal "Prefetch ON").
///
/// - After a foreground timeline sync: thumbnails (card cover + creator icon) of the newest new posts.
/// - After notification text is ready (Priority 0/1 done by `NotificationService`): Priority 2 (actor / creator avatar,
///   post thumbnail) for all events first, then Priority 3 (the post's first display images).
/// - Everything goes through `MediaService.load` with trigger `.prefetch` / priority `.mediaPrefetch`, so `MediaPolicy`
///   applies (Wi-Fi-only setting, Low Data, Extreme / Offline block) and the scheduler runs it behind every other request.
///   Never Priority 4 (original / video / attachments). Never in a background launch (SPEC §35).
/// - One serial queue: a burst of events never fans out into parallel downloads; a policy block stops the batch.
@MainActor
final class MediaPrefetcher {
    let store: LocalStore
    let media: MediaService
    /// Replaceable for tests.
    var isAppInBackground: () -> Bool = { UIApplication.shared.applicationState == .background }

    /// New timeline posts whose thumbnails are prefetched per sync.
    static let feedPostLimit = 12
    /// Display images prefetched per notification post (Priority 3).
    static let notificationDisplayLimit = 3

    private var queue: [MediaRequest] = []
    private var queuedKeys: Set<String> = []
    private var drainTask: Task<Void, Never>?

    init(store: LocalStore, media: MediaService) {
        self.store = store
        self.media = media
    }

    // MARK: - Triggers

    /// Hook for `SyncEngine.onSyncFinished`.
    func syncFinished(_ outcome: SyncOutcome, reason: SyncReason) {
        guard outcome.error == nil, !outcome.newItemIDs.isEmpty,
              outcome.resource == .timeline || outcome.resource == .supportingTimeline,
              Self.allowsFeedPrefetch(reason: reason), !isAppInBackground() else { return }
        enqueue(feedRequests(postIDs: outcome.newItemIDs))
    }

    /// Hook after `NotificationService.process(newEventIDs:)` (text is local by then).
    func notificationEventsProcessed(_ eventIDs: [String]) {
        guard !eventIDs.isEmpty, !isAppInBackground() else { return }
        let events = eventIDs.compactMap { store.notificationEvent(id: $0) }.sorted { $0.priority > $1.priority }
        var small: [MediaRequest] = []
        var large: [MediaRequest] = []
        for event in events {
            let post = event.postID.flatMap { store.post(id: $0) }
            let accountID = post.flatMap(Self.account(for:)) ?? event.accountIDs.first
            // Priority 2: small avatar + thumbnail.
            add(event.actorIconURL, .thumbnail, postID: nil, creatorID: event.creatorID, accountID: accountID, to: &small)
            let creatorIcon = post?.creatorIconURL ?? event.creatorID.flatMap { store.creator(id: $0)?.iconURL }
            add(creatorIcon, .thumbnail, postID: nil, creatorID: event.creatorID, accountID: accountID, to: &small)
            if let post {
                add(post.coverImageURL, .thumbnail, postID: post.postID, creatorID: post.creatorID, accountID: accountID, to: &small)
                // Priority 3: the first display images of a readable body.
                for block in post.orderedBlocks.filter({ $0.kind == .image }).prefix(Self.notificationDisplayLimit) {
                    add(block.displayURL ?? block.thumbnailURL, .display, postID: post.postID, creatorID: post.creatorID,
                        accountID: accountID, to: &large)
                }
            }
        }
        enqueue(small + large)
    }

    static func allowsFeedPrefetch(reason: SyncReason) -> Bool {
        switch reason {
        case .appLaunch, .userRefresh, .foregroundPolling: return true
        case .backgroundRefresh, .notification, .afterWrite, .onDemand: return false
        }
    }

    // MARK: - Requests

    /// Card cover (as PostCardView loads it: the cover URL at thumbnail size) and creator icon of the newest new posts.
    func feedRequests(postIDs: [String]) -> [MediaRequest] {
        guard !postIDs.isEmpty else { return [] }
        let published = ReaderPostQueries.publishedStatus
        var descriptor = FetchDescriptor<Post>(predicate: #Predicate {
            postIDs.contains($0.postID) && ($0.remoteStatusRaw == nil || $0.remoteStatusRaw == published)
        }, sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        descriptor.fetchLimit = Self.feedPostLimit
        var result: [MediaRequest] = []
        for post in store.fetch(descriptor) {
            let accountID = Self.account(for: post)
            add(post.coverImageURL, .thumbnail, postID: post.postID, creatorID: post.creatorID, accountID: accountID, to: &result)
            add(post.creatorIconURL, .thumbnail, postID: nil, creatorID: post.creatorID, accountID: accountID, to: &result)
        }
        return result
    }

    private static func account(for post: Post) -> String? {
        post.detailAccountID ?? post.accessAccountIDs.first ?? post.seenByAccountIDs.first
    }

    private func add(_ url: String?, _ variant: MediaVariant, postID: String?, creatorID: String?, accountID: String?,
                     to list: inout [MediaRequest]) {
        guard let url, !url.isEmpty, OfflineLibraryService.isFetchable(url) else { return }
        guard !list.contains(where: { $0.url == url && $0.variant == variant }) else { return }
        list.append(MediaRequest(url: url, variant: variant, kind: .image, trigger: .prefetch, priority: .mediaPrefetch,
                                 postID: postID, creatorID: creatorID, accountID: accountID))
    }

    // MARK: - Serial queue

    /// Queues requests (deduplicated, already-cached ones skipped) and drains them one at a time.
    func enqueue(_ requests: [MediaRequest]) {
        for request in requests {
            let key = MediaFileCache.key(url: request.url, variant: request.variant)
            guard !queuedKeys.contains(key), !media.isFileCached(url: request.url, variant: request.variant) else { continue }
            queuedKeys.insert(key)
            queue.append(request)
        }
        guard drainTask == nil, !queue.isEmpty else { return }
        drainTask = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    /// Waits until the queue is empty (tests).
    func waitUntilIdle() async {
        while let task = drainTask { await task.value }
    }

    private func drain() async {
        while !queue.isEmpty {
            let request = queue.removeFirst()
            queuedKeys.remove(MediaFileCache.key(url: request.url, variant: request.variant))
            // The policy for prefetch is the same for every queued image: once it blocks, drop the batch.
            guard media.decision(kind: request.kind, variant: request.variant, trigger: .prefetch) == .allowed, !isAppInBackground() else {
                queue.removeAll()
                queuedKeys.removeAll()
                break
            }
            do {
                _ = try await RequestContext.$priority.withValue(.mediaPrefetch) {
                    try await media.load(request)
                }
            } catch {
                continue    // best effort: the screen loads it on demand
            }
        }
        drainTask = nil
    }
}

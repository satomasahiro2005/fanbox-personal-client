import Foundation
import Observation
import SwiftData
import UIKit

/// Result of one offline save (for UI feedback).
struct OfflineSaveSummary: Sendable, Equatable {
    var postID: String
    var textAvailable: Bool
    var mediaRequested: Int
    var mediaSaved: Int
    /// Media skipped because the current network mode does not allow it (text is still saved).
    var mediaBlocked: Int
    var mediaFailed: Int
    var finishedAt: Date
    /// Why the post could not be saved (no body available). nil when the text is local.
    var failureReason: OfflineSaveFailure? = nil

    var isComplete: Bool { textAvailable && mediaSaved == mediaRequested }
}

/// Why an offline save did not happen (the post is left unsaved; nothing is claimed that is not local).
enum OfflineSaveFailure: Sendable, Equatable {
    /// None of my accounts can view the body (paid post without a matching support).
    case restricted
    /// The body could not be fetched (offline, network or access error).
    case bodyUnavailable(RemoteError?)

    var message: String {
        switch self {
        case .restricted:
            return "閲覧できるアカウントがないため、この投稿は保存できません。"
        case .bodyUnavailable(let error?):
            return "本文を取得できなかったため保存できませんでした（\(error.userMessage)）。接続を確認してもう一度お試しください。"
        case .bodyUnavailable(nil):
            return "本文を取得できなかったため保存できませんでした。接続を確認してもう一度お試しください。"
        }
    }
}

/// Offline Library (SPEC §31). Save units: this post / creator's recent N / auto-save viewed posts.
/// Never crawls unlimited history.
///
/// State rules:
/// - A post is only marked saved when its body text is local (`Post.hasCachedBody`).
/// - All three save units pin their media (evicted last, kept by "キャッシュを削除（保存済みを除く）", stored outside Caches).
/// - `.ruleSaved` posts belong to a creator's "recent N" rule: re-applied after every foreground timeline / creator sync,
///   released (unpinned, back to `.none`) when they fall out of the newest N or the rule is removed. Explicit `.saved` and
///   `.autoSaved` posts are never released by a rule.
@MainActor
@Observable
final class OfflineLibraryService {
    private(set) var activeSaves: Set<String> = []
    /// Progress (0...1) of media downloads per post being saved.
    private(set) var saveProgress: [String: Double] = [:]
    /// Last save result per post.
    private(set) var lastSummaries: [String: OfflineSaveSummary] = [:]
    /// Creators whose "recent N" save is running.
    private(set) var activeCreatorSaves: Set<String> = []

    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let engine: SyncEngine
    @ObservationIgnored let media: MediaService
    @ObservationIgnored let settings: AppSettings
    /// Background launches never run rule re-application (SPEC §35: lightweight data only). Replaceable for tests.
    @ObservationIgnored var isAppInBackground: () -> Bool = { UIApplication.shared.applicationState == .background }
    /// Delay that coalesces the burst of syncs of one refresh (timeline + supporting × accounts) into one rule pass.
    @ObservationIgnored var ruleDebounce: Duration = .milliseconds(800)
    /// A rule does not re-try fetching the same missing body more often than this.
    @ObservationIgnored var ruleRetryInterval: TimeInterval = 30 * 60

    @ObservationIgnored private var ruleTask: Task<Void, Never>?
    @ObservationIgnored private var pendingAllRules = false
    @ObservationIgnored private var pendingRuleCreators: Set<String> = []
    @ObservationIgnored private var pendingRefill = false
    @ObservationIgnored private var ruleBodyAttempts: [String: Date] = [:]

    init(store: LocalStore, engine: SyncEngine, media: MediaService, settings: AppSettings) {
        self.store = store
        self.engine = engine
        self.media = media
        self.settings = settings
    }

    // MARK: - この投稿

    /// Saves text + display images of a post and pins them. The post is marked saved only when its body is local;
    /// otherwise nothing is marked and the summary carries `failureReason`.
    @discardableResult
    func save(postID: String) async -> OfflineSaveSummary {
        guard !activeSaves.contains(postID) else {
            return lastSummaries[postID] ?? OfflineSaveSummary(postID: postID, textAvailable: false, mediaRequested: 0, mediaSaved: 0,
                                                               mediaBlocked: 0, mediaFailed: 0, finishedAt: .now)
        }
        activeSaves.insert(postID)
        saveProgress[postID] = 0
        defer {
            activeSaves.remove(postID)
            saveProgress[postID] = nil
        }

        // 1. Text first (SPEC §46 priority: body before any media). A post every enabled account is known NOT to be
        // entitled to is not re-requested (docs/API.md §1.8: restricted post.info calls only spend the budget).
        var fetchError: RemoteError?
        if store.post(id: postID)?.hasCachedBody != true && !knownRestrictedForAllAccounts(postID: postID) {
            fetchError = await RequestContext.$priority.withValue(.interactiveRead) {
                await engine.refreshPost(postID: postID, priority: .interactiveRead)
            }
        }
        guard let post = store.post(id: postID) else {
            AppLog.media.error("offline save: post not found locally")
            let summary = OfflineSaveSummary(postID: postID, textAvailable: false, mediaRequested: 0, mediaSaved: 0, mediaBlocked: 0,
                                             mediaFailed: 0, finishedAt: .now, failureReason: .bodyUnavailable(fetchError))
            lastSummaries[postID] = summary
            return summary
        }
        guard post.hasCachedBody else {
            let reason: OfflineSaveFailure = Self.isRestricted(post) && fetchError == nil ? .restricted : .bodyUnavailable(fetchError)
            let summary = OfflineSaveSummary(postID: postID, textAvailable: false, mediaRequested: 0, mediaSaved: 0, mediaBlocked: 0,
                                             mediaFailed: 0, finishedAt: .now, failureReason: reason)
            lastSummaries[postID] = summary
            return summary
        }
        post.offlineState = .saved
        store.save()

        // 2. Media (explicit user action ⇒ manual trigger; policy may still block, e.g. Offline).
        let requests = Self.mediaRequests(for: post, trigger: .manual, priority: .foregroundMedia, pin: true,
                                          includeAttachments: true)
        var summary = OfflineSaveSummary(postID: postID, textAvailable: true, mediaRequested: requests.count,
                                         mediaSaved: 0, mediaBlocked: 0, mediaFailed: 0, finishedAt: .now)
        for (index, request) in requests.enumerated() {
            do {
                _ = try await media.load(request)
                summary.mediaSaved += 1
            } catch RemoteError.blockedByPolicy {
                summary.mediaBlocked += 1
            } catch {
                summary.mediaFailed += 1
            }
            saveProgress[postID] = Double(index + 1) / Double(max(requests.count, 1))
        }
        // Anything already cached for this post (e.g. viewed earlier) is kept as well.
        media.pin(postID: postID)
        summary.finishedAt = .now
        lastSummaries[postID] = summary
        return summary
    }

    /// True when every enabled account has a PostAccess row saying it cannot view the post.
    func knownRestrictedForAllAccounts(postID: String) -> Bool {
        let accountIDs = store.accounts().map(\.id)
        guard !accountIDs.isEmpty else { return false }
        let accesses = Dictionary(store.postAccesses(postID: postID).map { ($0.accountID, $0.canView) }, uniquingKeysWith: { a, _ in a })
        return accountIDs.allSatisfy { accesses[$0] == false }
    }

    func remove(postID: String) {
        if let post = store.post(id: postID) {
            post.offlineState = .none
        }
        media.unpin(postID: postID)
        lastSummaries[postID] = nil
        store.save()
    }

    // MARK: - Creator の最近 N 件

    /// Sets the creator's "recent N" rule and applies it now: one refresh of the creator's latest page (never a deep
    /// history crawl, SPEC §3.7 / §31), then the newest N readable posts are saved (explicit action ⇒ manual trigger,
    /// attachments included). `count == 0` removes the rule and releases the posts it saved.
    func saveRecent(creatorID: String, count: Int) async {
        let count = max(0, count)
        setRecentRule(creatorID: creatorID, count: count)
        guard count > 0, !activeCreatorSaves.contains(creatorID) else { return }
        activeCreatorSaves.insert(creatorID)
        defer { activeCreatorSaves.remove(creatorID) }

        await RequestContext.$priority.withValue(.interactiveRead) {
            _ = await engine.refreshCreator(creatorID: creatorID)
        }
        await applyRule(creatorID: creatorID, count: count, trigger: .manual)
    }

    /// Changes the rule's N without any network access: posts that fall out of the newest N (or all of them, for 0)
    /// are released right away; newly covered posts are saved by the next sync or "今すぐ保存".
    func setRecentRule(creatorID: String, count: Int) {
        let count = max(0, count)
        if let creator = store.creator(id: creatorID), creator.offlineRecentCount != count {
            creator.offlineRecentCount = count
        }
        releaseRuleSaved(creatorID: creatorID, keeping: count > 0 ? Set(ruleWindow(creatorID: creatorID, count: count)) : [])
        store.save()
    }

    /// Re-applies every creator's "recent N" rule (one refresh per creator). Pull-to-refresh in the Offline Library.
    func refreshCreatorRules() async {
        let creators = store.fetch(FetchDescriptor<Creator>(predicate: #Predicate { $0.offlineRecentCount > 0 }))
        for creator in creators {
            await saveRecent(creatorID: creator.creatorID, count: creator.offlineRecentCount)
        }
    }

    /// Hook for `SyncEngine.onSyncFinished`: after a successful foreground timeline / creator-posts sync, the rules of
    /// all creators (or of the synced creator) are re-applied to what is now known locally — no extra listing request.
    /// Media follows the prefetch policy (Wi-Fi only / Low Data / Extreme); text is fetched only for newly covered posts.
    func syncFinished(_ outcome: SyncOutcome, reason: SyncReason) {
        guard outcome.error == nil, Self.appliesRules(after: outcome.resource, reason: reason), !isAppInBackground() else { return }
        // Polling only saves newly covered posts; launch / pull-to-refresh / a creator page also fill in media that an
        // earlier pass could not fetch (e.g. Wi-Fi-only prefetch on cellular).
        let refill = reason != .foregroundPolling
        if outcome.resource == .creatorPosts {
            guard !outcome.scope.isEmpty else { return }       // my own managed posts: not a reader rule
            scheduleRules(creatorIDs: [outcome.scope], refillMedia: refill)
        } else {
            scheduleRules(creatorIDs: nil, refillMedia: refill)
        }
    }

    static func appliesRules(after resource: SyncResource, reason: SyncReason) -> Bool {
        switch resource {
        case .timeline, .supportingTimeline, .creatorPosts: break
        default: return false
        }
        switch reason {
        case .appLaunch, .userRefresh, .foregroundPolling, .onDemand: return true
        case .backgroundRefresh, .notification, .afterWrite: return false
        }
    }

    /// Debounced rule pass. `nil` = every creator with a rule.
    func scheduleRules(creatorIDs: Set<String>?, refillMedia: Bool = true) {
        if let creatorIDs { pendingRuleCreators.formUnion(creatorIDs) } else { pendingAllRules = true }
        if refillMedia { pendingRefill = true }
        guard ruleTask == nil else { return }     // picked up by the running pass (or the one it re-schedules)
        let delay = ruleDebounce
        ruleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            let targets: Set<String>? = self.pendingAllRules ? nil : self.pendingRuleCreators
            let refill = self.pendingRefill
            self.pendingAllRules = false
            self.pendingRuleCreators = []
            self.pendingRefill = false
            await self.applyRules(creatorIDs: targets, refillMedia: refill)
            self.ruleTask = nil
            if self.pendingAllRules || !self.pendingRuleCreators.isEmpty { self.scheduleRules(creatorIDs: [], refillMedia: self.pendingRefill) }
        }
    }

    /// Waits for a scheduled rule pass (tests).
    func waitForScheduledRules() async {
        while let task = ruleTask { await task.value }
    }

    /// Applies the rules of `creatorIDs` (nil = all rule creators) with the automatic (prefetch) policy.
    /// `refillMedia == false` only fetches media for posts the rule newly covers.
    func applyRules(creatorIDs: Set<String>?, refillMedia: Bool = true) async {
        var creators = store.fetch(FetchDescriptor<Creator>(predicate: #Predicate { $0.offlineRecentCount > 0 }))
        if let creatorIDs { creators = creators.filter { creatorIDs.contains($0.creatorID) } }
        for creator in creators where !activeCreatorSaves.contains(creator.creatorID) {
            let id = creator.creatorID
            activeCreatorSaves.insert(id)
            await applyRule(creatorID: id, count: creator.offlineRecentCount, trigger: .prefetch, refillMedia: refillMedia)
            activeCreatorSaves.remove(id)
        }
    }

    /// Saves the newest `count` readable posts of the creator and releases rule-saved posts outside that window.
    /// `.manual` = explicit "今すぐ保存" (attachments included, allowed in Extreme); `.prefetch` = automatic re-application.
    func applyRule(creatorID: String, count: Int, trigger: MediaTrigger, refillMedia: Bool = true) async {
        let window = ruleWindow(creatorID: creatorID, count: count)
        releaseRuleSaved(creatorID: creatorID, keeping: Set(window))
        store.save()
        let manual = trigger == .manual
        var mediaBlocked = false
        for postID in window {
            // Text first; a body this rule already failed to fetch recently is not re-requested on every sync.
            if store.post(id: postID)?.hasCachedBody != true {
                if !manual, let last = ruleBodyAttempts[postID], Date.now.timeIntervalSince(last) < ruleRetryInterval { continue }
                ruleBodyAttempts[postID] = .now
                let priority: RequestPriority = manual ? .interactiveRead : .backgroundSync
                _ = await RequestContext.$priority.withValue(priority) {
                    await engine.refreshPost(postID: postID, priority: priority)
                }
            }
            guard let post = store.post(id: postID), post.hasCachedBody, post.isVisibleToReaders else { continue }
            let newlyCovered = post.offlineState == .none
            if newlyCovered {
                post.offlineState = .ruleSaved
                store.save()
            }
            // Media of newly covered posts, and (refill passes) of every post in the window: cache hits are cheap, files
            // missing because the policy blocked them earlier (e.g. cellular with Wi-Fi-only prefetch) are filled in.
            guard !mediaBlocked, newlyCovered || refillMedia else { continue }
            let requests = Self.mediaRequests(for: post, trigger: trigger, priority: manual ? .foregroundMedia : .mediaPrefetch,
                                              pin: true, includeAttachments: manual)
            for request in requests {
                do {
                    _ = try await media.load(request)
                } catch RemoteError.blockedByPolicy {
                    mediaBlocked = true      // the same policy blocks the rest; text keeps being saved
                    break
                } catch {
                    continue
                }
            }
            media.pin(postID: postID)
        }
    }

    /// Posts covered by the rule: the newest `count` reader-visible posts of the creator that one of my accounts can
    /// read (paid posts nobody can view are skipped instead of being "saved" without text).
    func ruleWindow(creatorID: String, count: Int) -> [String] {
        guard count > 0 else { return [] }
        var descriptor = ReaderPostQueries.byCreator(creatorID)
        descriptor.fetchLimit = count * 3 + 10
        var result: [String] = []
        for post in store.fetch(descriptor) where !Self.isRestricted(post) {
            result.append(post.postID)
            if result.count == count { break }
        }
        return result
    }

    /// Releases `.ruleSaved` posts of the creator that are not in `keeping` (unpins their media). Caller saves.
    private func releaseRuleSaved(creatorID: String, keeping: Set<String>) {
        let rule = OfflineState.ruleSaved.rawValue
        let saved = store.fetch(FetchDescriptor<Post>(predicate: #Predicate { $0.creatorID == creatorID && $0.offlineStateRaw == rule }))
        for post in saved where !keeping.contains(post.postID) {
            post.offlineState = .none
            media.unpin(postID: post.postID)
            lastSummaries[post.postID] = nil
        }
    }

    // MARK: - 今後閲覧した投稿を自動保存

    /// Called whenever a post detail is displayed. With auto-save on, the post becomes `.autoSaved` (once its text is
    /// local) and its display images are fetched with the prefetch policy and pinned like any saved post.
    func postViewed(postID: String) async {
        guard let post = store.post(id: postID) else { return }
        post.lastViewedAt = .now
        guard settings.autoSaveViewedPosts, post.hasCachedBody, post.isVisibleToReaders else {
            store.save()
            return
        }
        // A viewed post outlives the "recent N" window it was saved by (it is now an auto-saved post).
        if post.offlineState == .none || post.offlineState == .ruleSaved {
            post.offlineState = .autoSaved
        }
        store.save()

        // Display images only; prefetch trigger so Low Data / Extreme / Wi-Fi-only rules apply (text-only if blocked).
        let requests = Self.mediaRequests(for: post, trigger: .prefetch, priority: .mediaPrefetch, pin: true,
                                          includeAttachments: false, variants: [.display])
        for request in requests {
            do {
                _ = try await media.load(request)
            } catch RemoteError.blockedByPolicy {
                break
            } catch {
                continue
            }
        }
        media.pin(postID: postID)
    }

    func isSaving(postID: String) -> Bool { activeSaves.contains(postID) }

    // MARK: - Helpers

    /// Paid post that none of my accounts can view.
    static func isRestricted(_ post: Post) -> Bool {
        post.feeRequired > 0 && post.accessAccountIDs.isEmpty
    }

    /// Media to save for a post: cover + image blocks (thumbnail/display), and optionally attachments (file/audio/video).
    static func mediaRequests(for post: Post, trigger: MediaTrigger, priority: RequestPriority, pin: Bool,
                              includeAttachments: Bool, variants: Set<MediaVariant> = [.thumbnail, .display]) -> [MediaRequest] {
        let accountID = post.detailAccountID ?? post.accessAccountIDs.first
        var seen = Set<String>()
        var result: [MediaRequest] = []

        func add(_ url: String?, _ variant: MediaVariant, _ kind: MediaKind) {
            guard let url, !url.isEmpty, isFetchable(url) else { return }
            let key = MediaFileCache.key(url: url, variant: variant)
            guard seen.insert(key).inserted else { return }
            result.append(MediaRequest(url: url, variant: variant, kind: kind, trigger: trigger, priority: priority, postID: post.postID,
                                       creatorID: post.creatorID, accountID: accountID, pin: pin))
        }

        if variants.contains(.display) {
            add(post.coverImageURL, .display, .image)
        }
        for block in post.orderedBlocks {
            switch block.kind {
            case .image:
                if variants.contains(.thumbnail) { add(block.thumbnailURL, .thumbnail, .image) }
                if variants.contains(.display) { add(block.displayURL ?? block.thumbnailURL, .display, .image) }
                if variants.contains(.original) { add(block.originalURL, .original, .image) }
            case .file, .audio, .video:
                guard includeAttachments else { continue }
                // External videos (YouTube etc.) are links, not attachments.
                if block.kind == .video, block.embedProvider != nil { continue }
                let kind: MediaKind = block.kind == .file ? .file : (block.kind == .audio ? .audio : .video)
                add(block.originalURL ?? block.url, .original, kind)
            default:
                continue
            }
        }
        return result
    }

    /// Only http(s) and local demo media are fetched.
    static func isFetchable(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("demo://")
    }
}

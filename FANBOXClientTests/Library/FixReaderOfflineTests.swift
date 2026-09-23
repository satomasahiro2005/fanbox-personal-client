import SwiftData
import XCTest
@testable import FANBOXClient

/// Reader fixes for the Offline Library (SPEC §31): honest saved state, pinned auto-saves, "recent N" rules that keep
/// applying after sync and release what falls out.
@MainActor
final class FixReaderOfflineTests: XCTestCase {
    private var h: MediaTestHarness!
    private var offline: OfflineLibraryService!

    override func setUp() async throws {
        h = MediaTestHarness()
        offline = h.makeOfflineService()
        offline.isAppInBackground = { false }
        offline.ruleDebounce = .milliseconds(1)
    }

    override func tearDown() async throws {
        h.cleanup()
        offline = nil
        h = nil
    }

    private let base = Date(timeIntervalSince1970: 1_760_000_000)

    @discardableResult
    private func rulePost(_ id: String, creator: String = "r1", hour: Double, fee: Int = 0, viewers: [String] = [],
                          body: Bool = true) -> Post {
        let post = h.insertPost(id: id, creatorID: creator, title: id, publishedAt: base.addingTimeInterval(hour * 3600), bodyFetched: body)
        post.feeRequired = fee
        post.accessAccountIDs = viewers
        h.addImageBlock(to: post, index: 0, thumbnail: nil, display: "demo://image/\(id)?w=800&h=600&v=display", original: nil)
        h.env.store.save()
        return post
    }

    private func state(_ id: String) -> OfflineState? { h.env.store.post(id: id)?.offlineState }

    // MARK: - この投稿

    func testSaveWithoutBodyIsNotMarkedSaved() async throws {
        let post = rulePost("nb", hour: 0, body: false)
        h.setMode(.offline)
        let summary = await offline.save(postID: "nb")
        XCTAssertEqual(post.offlineState, OfflineState.none, "no local text ⇒ nothing is claimed")
        XCTAssertFalse(summary.textAvailable)
        XCTAssertEqual(summary.failureReason, .bodyUnavailable(.offline))
        XCTAssertTrue(h.entries.isEmpty, "no media without the text")
        XCTAssertNotNil(summary.failureReason?.message)
    }

    func testRestrictedPostSaveReportsRestricted() async throws {
        let post = rulePost("paid", hour: 0, fee: 500, viewers: [], body: false)
        let summary = await offline.save(postID: "paid")
        XCTAssertEqual(post.offlineState, OfflineState.none)
        // No account in this environment: the engine reports an error before any fetch, so the reason is "unavailable".
        XCTAssertNotNil(summary.failureReason)
        XCTAssertTrue(OfflineLibraryService.isRestricted(post))
        XCTAssertFalse(OfflineLibraryService.isRestricted(rulePost("free", hour: 1)))
        XCTAssertEqual(OfflineSaveFailure.restricted.message, "閲覧できるアカウントがないため、この投稿は保存できません。")
    }

    // MARK: - 今後閲覧した投稿を自動保存

    func testAutoSavedMediaIsPinnedAndSurvivesClearingUnsavedCache() async throws {
        h.env.settings.autoSaveViewedPosts = true
        let post = rulePost("av", hour: 0)
        _ = try await h.media.load(MediaRequest(url: "demo://image/other?v=display", variant: .display, postID: "zz"))
        await offline.postViewed(postID: "av")
        XCTAssertEqual(post.offlineState, .autoSaved)
        XCTAssertTrue(h.entries(postID: "av").allSatisfy(\.isPinned))

        h.media.clearAll(includePinned: false)
        XCTAssertEqual(h.entries(postID: "av").count, 1, "キャッシュを削除（保存済みを除く） keeps auto-saved media")
        XCTAssertTrue(h.entries(postID: "zz").isEmpty)
        XCTAssertEqual(post.offlineState, .autoSaved)
    }

    func testAutoSaveNeedsTextAndSkipsDrafts() async throws {
        h.env.settings.autoSaveViewedPosts = true
        let noBody = rulePost("x1", hour: 0, body: false)
        await offline.postViewed(postID: "x1")
        XCTAssertEqual(noBody.offlineState, OfflineState.none)
        XCTAssertNotNil(noBody.lastViewedAt)

        let draft = rulePost("x2", hour: 1)
        draft.remoteStatusRaw = RemotePostStatus.draft.rawValue
        await offline.postViewed(postID: "x2")
        XCTAssertEqual(draft.offlineState, OfflineState.none)
    }

    func testViewingARuleSavedPostKeepsItBeyondTheRule() async throws {
        h.env.settings.autoSaveViewedPosts = true
        let post = rulePost("rv", hour: 0)
        post.offlineState = .ruleSaved
        await offline.postViewed(postID: "rv")
        XCTAssertEqual(post.offlineState, .autoSaved)
        offline.setRecentRule(creatorID: "r1", count: 0)
        XCTAssertEqual(post.offlineState, .autoSaved, "a rule never releases auto-saved posts")
    }

    // MARK: - Creator の最近 N 件

    func testRuleWindowSkipsRestrictedAndDraftPosts() {
        rulePost("w1", hour: 1)
        rulePost("w2", hour: 2, fee: 500, viewers: [])            // nobody can read
        rulePost("w3", hour: 3, fee: 500, viewers: ["A"])
        let draft = rulePost("w4", hour: 4)
        draft.remoteStatusRaw = RemotePostStatus.scheduled.rawValue
        h.env.store.save()
        XCTAssertEqual(offline.ruleWindow(creatorID: "r1", count: 2), ["w3", "w1"])
    }

    func testRuleIsReappliedAfterTimelineSyncAndReleasesOldPosts() async throws {
        let creator = Creator(creatorID: "r1", name: "Rule creator")
        creator.offlineRecentCount = 2
        h.env.store.context.insert(creator)
        rulePost("a1", hour: 1)
        rulePost("a2", hour: 2)
        let explicit = rulePost("a0", hour: 0)
        explicit.offlineState = .saved
        h.env.store.save()

        await offline.applyRule(creatorID: "r1", count: 2, trigger: .prefetch)
        XCTAssertEqual(state("a2"), .ruleSaved)
        XCTAssertEqual(state("a1"), .ruleSaved)
        XCTAssertTrue(h.entries(postID: "a2").allSatisfy(\.isPinned))

        // A new post arrives through a normal sync: the rule keeps applying without any extra listing request.
        rulePost("a3", hour: 3)
        offline.syncFinished(SyncOutcome(resource: .timeline, accountID: "A", scope: "", newItemIDs: ["a3"], error: nil),
                             reason: .foregroundPolling)
        await offline.waitForScheduledRules()

        XCTAssertEqual(state("a3"), .ruleSaved)
        XCTAssertEqual(state("a2"), .ruleSaved)
        XCTAssertEqual(state("a1"), OfflineState.none, "fell out of the newest 2")
        XCTAssertFalse(h.entries(postID: "a1").contains(where: \.isPinned))
        XCTAssertEqual(state("a0"), .saved, "explicit saves are never touched by a rule")
        XCTAssertFalse(h.entries(postID: "a3").isEmpty)
    }

    func testRuleIsNotAppliedForBackgroundOrFailedSyncs() async throws {
        let creator = Creator(creatorID: "r1", name: "Rule creator")
        creator.offlineRecentCount = 1
        h.env.store.context.insert(creator)
        rulePost("b1", hour: 1)
        h.env.store.save()

        offline.syncFinished(SyncOutcome(resource: .timeline, accountID: "A", scope: "", newItemIDs: ["b1"], error: nil),
                             reason: .backgroundRefresh)
        offline.syncFinished(SyncOutcome(resource: .timeline, accountID: "A", scope: "", newItemIDs: [], error: .offline),
                             reason: .appLaunch)
        offline.syncFinished(SyncOutcome(resource: .notifications, accountID: "A", scope: "", newItemIDs: [], error: nil),
                             reason: .appLaunch)
        await offline.waitForScheduledRules()
        XCTAssertEqual(state("b1"), OfflineState.none)

        offline.isAppInBackground = { true }
        offline.syncFinished(SyncOutcome(resource: .timeline, accountID: "A", scope: "", newItemIDs: ["b1"], error: nil),
                             reason: .appLaunch)
        await offline.waitForScheduledRules()
        XCTAssertEqual(state("b1"), OfflineState.none)

        offline.isAppInBackground = { false }
        offline.syncFinished(SyncOutcome(resource: .creatorPosts, accountID: "A", scope: "r1", newItemIDs: [], error: nil),
                             reason: .onDemand)
        await offline.waitForScheduledRules()
        XCTAssertEqual(state("b1"), .ruleSaved, "opening the creator page re-applies that creator's rule")
    }

    func testAutomaticRuleKeepsTextWhenMediaIsBlockedAndFillsMediaLater() async throws {
        let creator = Creator(creatorID: "r1", name: "Rule creator")
        creator.offlineRecentCount = 1
        h.env.store.context.insert(creator)
        rulePost("m1", hour: 1)
        h.env.store.save()

        h.setMode(.extreme)
        await offline.applyRules(creatorIDs: nil)
        XCTAssertEqual(state("m1"), .ruleSaved, "text is saved even when the prefetch policy blocks media")
        XCTAssertTrue(h.entries(postID: "m1").isEmpty)

        h.setMode(.normal)
        await offline.applyRules(creatorIDs: nil)
        XCTAssertEqual(h.entries(postID: "m1").count, 1, "the next pass fills in the media")
        XCTAssertTrue(h.entries(postID: "m1").allSatisfy(\.isPinned))
    }

    func testLoweringNReleasesImmediately() async throws {
        let creator = Creator(creatorID: "r1", name: "Rule creator")
        h.env.store.context.insert(creator)
        rulePost("n1", hour: 1)
        rulePost("n2", hour: 2)
        rulePost("n3", hour: 3)
        await offline.saveRecent(creatorID: "r1", count: 3)
        XCTAssertEqual([state("n1"), state("n2"), state("n3")], [.ruleSaved, .ruleSaved, .ruleSaved])

        offline.setRecentRule(creatorID: "r1", count: 1)
        XCTAssertEqual(creator.offlineRecentCount, 1)
        XCTAssertEqual([state("n1"), state("n2"), state("n3")], [OfflineState.none, OfflineState.none, .ruleSaved])
    }

    func testAppliesRulesTable() {
        XCTAssertTrue(OfflineLibraryService.appliesRules(after: .timeline, reason: .appLaunch))
        XCTAssertTrue(OfflineLibraryService.appliesRules(after: .supportingTimeline, reason: .userRefresh))
        XCTAssertTrue(OfflineLibraryService.appliesRules(after: .creatorPosts, reason: .onDemand))
        XCTAssertFalse(OfflineLibraryService.appliesRules(after: .timeline, reason: .backgroundRefresh))
        XCTAssertFalse(OfflineLibraryService.appliesRules(after: .notifications, reason: .appLaunch))
    }

    // MARK: - Offline Library view helpers

    func testGalleryItemsDedupeAndChunk() {
        func item(_ key: String, _ url: String, _ variant: MediaVariant, _ post: String) -> OfflineImageItem {
            OfflineImageItem(key: key, url: url, variant: variant, postID: post, isPinned: false)
        }
        let items = [
            item("1", "u1", .display, "p1"), item("2", "u1", .thumbnail, "p1"), item("3", "u2", .thumbnail, "p2"),
            item("4", "u3", .original, "p1"), item("5", "u1", .original, "p1"),
        ]
        XCTAssertEqual(OfflineImageItem.gallery(items).map(\.key), ["1", "4", "3"])
        let rows = OfflineImageItem.rows(Array(repeating: item("x", "u", .display, "p"), count: 7), columns: 3)
        XCTAssertEqual(rows.map(\.count), [3, 3, 1])
        XCTAssertTrue(OfflineImageItem.rows([], columns: 3).isEmpty)
    }

    func testBytesIndexUsesOneFetch() async throws {
        _ = try await h.media.load(MediaRequest(url: "demo://image/i1?v=display", variant: .display, postID: "pp"))
        _ = try await h.media.load(MediaRequest(url: "demo://image/i2?v=thumb", variant: .thumbnail, postID: "pp"))
        _ = try await h.media.load(MediaRequest(url: "demo://image/i3?v=thumb", variant: .thumbnail))
        let bytes = OfflineLibraryIndex.bytesByPost(store: h.env.store)
        XCTAssertEqual(bytes["pp"], h.entries(postID: "pp").reduce(Int64(0)) { $0 + Int64($1.byteSize) })
        XCTAssertEqual(bytes.count, 1)
    }
}

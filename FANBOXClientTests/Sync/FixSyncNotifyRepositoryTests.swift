import SwiftData
import XCTest
@testable import FANBOXClient

/// SPEC §43 repository façade: local-first reads, errors only when nothing is cached.
@MainActor
final class FixSyncNotifyRepositoryTests: XCTestCase {
    private func makeRepository(_ h: SyncHarness) -> DefaultFanboxRepository {
        DefaultFanboxRepository(store: h.store, engine: h.engine)
    }

    func testPostReturnsCachedBodyWithoutARequest() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.upsertPostDetail(SyncFixtures.detail("p1", text: "キャッシュ済み"), account: a.context)
        let post = try await makeRepository(h).post(id: "p1", account: a.id)
        XCTAssertEqual(post.bodyText, "キャッシュ済み")
        XCTAssertTrue(h.mock.calls.isEmpty, "local-first: no network when the body is cached")
    }

    func testPostFetchesThenFallsBackToTheLocalSummaryOnError() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let repository = makeRepository(h)

        h.mock.update { $0.details[a.id] = ["p1": SyncFixtures.detail("p1", text: "取得した本文")] }
        let fetched = try await repository.post(id: "p1", account: nil, priority: .notificationPrefetch)
        XCTAssertEqual(fetched.bodyText, "取得した本文")
        XCTAssertEqual(h.mock.priority(of: "post|"), .notificationPrefetch)

        h.store.upsertPostSummaries([SyncFixtures.summary("p2", title: "概要だけ")], account: a.context, source: .home)
        h.mock.update { $0.postErrors[a.id] = ["p2": .network(code: -1001, detail: "timeout")] }
        let summaryOnly = try await repository.post(id: "p2", account: a.id)
        XCTAssertEqual(summaryOnly.title, "概要だけ")
        XCTAssertFalse(summaryOnly.hasCachedBody)

        do {
            _ = try await repository.post(id: "p404", account: a.id)
            XCTFail("nothing cached: the error surfaces")
        } catch {
            XCTAssertEqual(error as? RemoteError, .notFound)
        }
    }

    func testSupportsAndTimelineAnswerFromTheLocalStore() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let repository = makeRepository(h)
        h.mock.update {
            $0.supports[a.id] = [SyncFixtures.support("c1", plan: "p1", fee: 500)]
            $0.homePages[a.id] = ["": SyncFixtures.page(["t1", "t2"])]
        }
        let supports = try await repository.supports(account: a.id)
        XCTAssertEqual(supports.map(\.creatorID), ["c1"])
        let timeline = try await repository.timeline(account: a.id)
        XCTAssertEqual(Set(timeline.map(\.postID)), ["t1", "t2"])

        // Offline: cached answers, no error.
        h.setOffline(true)
        let cached = try await repository.supports(account: a.id)
        XCTAssertEqual(cached.count, 1)
        let cachedTimeline = try await repository.timeline(account: a.id)
        XCTAssertEqual(cachedTimeline.count, 2)

        // Offline with nothing cached for another account: the error surfaces.
        let b = h.addAccount("B", pixivUserID: "pB")
        do {
            _ = try await repository.timeline(account: b.id)
            XCTFail("expected offline")
        } catch {
            XCTAssertEqual(error as? RemoteError, .offline)
        }
    }

    func testCreatorFallsBackToLocalRow() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let repository = makeRepository(h)
        let creator = try await repository.creator(id: "c7", account: a.id)
        XCTAssertEqual(creator.name, "Creator c7")
        h.mock.update { $0.accountErrors[a.id] = .server(status: 503) }
        let cached = try await repository.creator(id: "c7", account: a.id)
        XCTAssertEqual(cached.creatorID, "c7")
    }

    func testNotificationServiceReadsPostsThroughTheRepository() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.upsertPostDetail(SyncFixtures.detail("p1"), account: a.context)
        let ids = h.store.upsertNotifications([SyncFixtures.notification("r1", type: .newPost, postID: "p1")], account: a.context)
        await h.notifications.prefetch(eventID: ids[0])
        XCTAssertEqual(h.store.notificationEvent(id: ids[0])?.prefetchState, .textReady)
        XCTAssertEqual(h.mock.count("post|"), 0, "a cached body is answered locally by the repository")
    }
}

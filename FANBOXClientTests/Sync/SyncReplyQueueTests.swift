import SwiftData
import XCTest
@testable import FANBOXClient

@MainActor
final class SyncReplyQueueTests: XCTestCase {
    func testOfflineSubmitStaysQueuedLocally() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.setOffline(true)

        let id = h.replies.submit(postID: "p1", body: "  オフラインで書いた返信  ", parentCommentID: "c1", rootCommentID: "c1", accountID: a.id)
        await h.replies.flush()
        let item = try XCTUnwrap(h.replies.item(id: id))
        XCTAssertEqual(item.state, .queued)
        XCTAssertNotNil(item.queuedAt)
        XCTAssertEqual(item.body, "オフラインで書いた返信")
        XCTAssertEqual(item.attemptCount, 0)
        XCTAssertEqual(h.mock.count("addComment"), 0)
        XCTAssertEqual(h.replies.pendingCount, 1)

        // Connectivity returns → sent.
        h.setOffline(false)
        await h.replies.flush()
        XCTAssertEqual(item.state, .sent)
        XCTAssertEqual(h.replies.pendingCount, 0)
    }

    func testSuccessfulSendMarksSentAndInsertsLocalComment() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.upsertPostSummaries([SyncFixtures.summary("p1")], account: a.context, source: .home)
        let before = h.store.post(id: "p1")?.commentCount ?? 0

        let id = h.replies.submit(postID: "p1", body: "ありがとうございます", parentCommentID: "c1", rootCommentID: "c0", accountID: a.id)
        await h.replies.flush()

        let item = try XCTUnwrap(h.replies.item(id: id))
        XCTAssertEqual(item.state, .sent)
        XCTAssertNotNil(item.sentAt)
        XCTAssertEqual(item.attemptCount, 1)
        let sentID = try XCTUnwrap(item.sentCommentID)
        XCTAssertEqual(h.mock.count("addComment|\(a.id)|p1"), 1, "sent exactly once even with concurrent flushes")

        let local = try XCTUnwrap(h.store.comments(postID: "p1").first { $0.commentID == sentID })
        XCTAssertTrue(local.isOwn)
        XCTAssertEqual(local.body, "ありがとうございます")
        XCTAssertEqual(local.parentCommentID, "c1")
        XCTAssertEqual(local.rootCommentID, "c0")
        XCTAssertEqual(h.store.post(id: "p1")?.commentCount, before + 1)
    }

    func testTransientFailureRequeuesThenRetrySends() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update { $0.addCommentResults = [.network(code: -1001, detail: "timeout")] }

        let id = h.replies.submit(postID: "p1", body: "再送テスト", accountID: a.id)
        await h.replies.flush()
        let item = try XCTUnwrap(h.replies.item(id: id))
        XCTAssertEqual(item.state, .queued, "transient failures stay queued for automatic retry")
        XCTAssertEqual(item.attemptCount, 1)
        XCTAssertEqual(item.lastError, RemoteError.network(code: -1001, detail: "timeout").userMessage)

        // Backoff: an immediate flush does not hammer the server.
        await h.replies.flush()
        XCTAssertEqual(h.mock.count("addComment"), 1)

        await h.replies.retry(id: id)
        XCTAssertEqual(item.state, .sent)
        XCTAssertNil(item.lastError)
        XCTAssertEqual(h.mock.count("addComment"), 2)
    }

    func testRepeatedTransientFailuresEndFailedAndNonTransientFailsImmediately() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update { $0.addCommentResults = [.forbidden] }
        let id = h.replies.submit(postID: "p1", body: "権限なし", accountID: a.id)
        await h.replies.flush()
        let item = try XCTUnwrap(h.replies.item(id: id))
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(h.replies.attentionCount, 1)

        // A transient error on the last allowed automatic attempt stops automatic sending. A 5xx does not prove the comment
        // was rejected (it may have been stored), so the item asks the user instead of claiming failure (docs/API.md §9.2).
        h.mock.update { $0.addCommentResults = [.server(status: 503)] }
        item.state = .queued
        item.attemptCount = ReplyQueue.maxAttempts - 1
        h.store.save()
        await h.replies.flush()
        XCTAssertEqual(item.state, .needsConfirmation, "gives up after \(ReplyQueue.maxAttempts) attempts")
        XCTAssertEqual(item.attemptCount, ReplyQueue.maxAttempts)

        // A transient error before the limit keeps it queued.
        h.mock.update { $0.addCommentResults = [.server(status: 503)] }
        item.state = .queued
        item.attemptCount = 0
        h.store.save()
        await h.replies.flush()
        XCTAssertEqual(item.state, .queued)

        h.replies.cancel(id: id)
        XCTAssertNil(h.replies.item(id: id))
        XCTAssertEqual(h.replies.pendingCount, 0)
    }

    func testStaleReplyNeedsConfirmationThenConfirmSends() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.settings.staleReplyThreshold = 60
        h.settings.autoSendStaleReplies = false
        h.setOffline(true)
        let id = h.replies.submit(postID: "p1", body: "昨日書いた返信", accountID: a.id)
        await h.replies.flush()
        let item = try XCTUnwrap(h.replies.item(id: id))
        item.queuedAt = Date(timeIntervalSinceNow: -2 * 60 * 60)
        h.store.save()

        h.setOffline(false)
        await h.replies.flush()
        XCTAssertEqual(item.state, .needsConfirmation, "long-waiting replies are not sent silently")
        XCTAssertEqual(h.mock.count("addComment"), 0)

        await h.replies.confirmAndSend(id: id)
        XCTAssertEqual(item.state, .sent)
        XCTAssertEqual(h.mock.count("addComment"), 1)
    }

    func testStaleReplyAutoSendsWhenEnabled() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.settings.staleReplyThreshold = 60
        h.settings.autoSendStaleReplies = true
        h.setOffline(true)
        let id = h.replies.submit(postID: "p1", body: "自動送信", accountID: a.id)
        let item = try XCTUnwrap(h.replies.item(id: id))
        item.queuedAt = Date(timeIntervalSinceNow: -2 * 60 * 60)
        h.setOffline(false)
        await h.replies.flush()
        XCTAssertEqual(item.state, .sent)
    }

    func testDraftIsNotSentUntilSubmitted() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let id = h.replies.saveDraft(postID: "p1", body: "下書き", accountID: a.id)
        await h.replies.flush()
        XCTAssertEqual(h.replies.item(id: id)?.state, .draft)
        XCTAssertEqual(h.mock.count("addComment"), 0)
        await h.replies.submitDraft(id: id)
        XCTAssertEqual(h.replies.item(id: id)?.state, .sent)
    }
}

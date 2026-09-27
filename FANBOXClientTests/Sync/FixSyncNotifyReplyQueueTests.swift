import SwiftData
import XCTest
@testable import FANBOXClient

/// Reply queue: never a duplicate public comment, user-visible attention states, provisional ids (SPEC §22, docs/API.md §9.2).
@MainActor
final class FixSyncNotifyReplyQueueTests: XCTestCase {
    func testTimeoutAfterTheCommentReachedFanboxIsNotSentTwice() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update {
            $0.addCommentResults = [.network(code: -1001, detail: "timeout")]
            $0.addCommentReachesServerOnError = true
        }
        let id = h.replies.submit(postID: "p1", body: "届いていた返信", parentCommentID: "c1", rootCommentID: "c1", accountID: a.id)
        await h.replies.flush()
        let item = try XCTUnwrap(h.replies.item(id: id))
        XCTAssertEqual(item.state, .queued, "a timeout is retried automatically…")

        await h.replies.retry(id: id)
        XCTAssertEqual(h.mock.count("addComment"), 1, "…but the earlier send is found first: no second POST")
        XCTAssertEqual(item.state, .sent)
        XCTAssertEqual(item.sentCommentID, "sent-1")
        XCTAssertEqual(h.store.comments(postID: "p1").filter { $0.body == "届いていた返信" }.count, 1)
    }

    func testLostConnectionIsCheckedBeforeTheAutomaticResend() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update {
            $0.addCommentResults = [.offline]
            $0.addCommentReachesServerOnError = true
        }
        let id = h.replies.submit(postID: "p1", body: "接続が切れた返信", accountID: a.id)
        await h.replies.flush()
        let item = try XCTUnwrap(h.replies.item(id: id))
        XCTAssertEqual(item.state, .queued)
        XCTAssertEqual(item.attemptCount, 0, "connectivity loss does not consume an attempt")

        h.replies.handleConnectivityRestored()
        await h.replies.flush()
        XCTAssertEqual(item.state, .sent)
        XCTAssertEqual(h.mock.count("addComment"), 1)
        XCTAssertGreaterThanOrEqual(h.mock.count("comments|\(a.id)|p1"), 1, "the thread was checked before re-sending")
    }

    func testResendHappensWhenTheThreadProvesTheFirstAttemptFailed() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update { $0.addCommentResults = [.server(status: 502)] }
        let id = h.replies.submit(postID: "p1", body: "届かなかった返信", accountID: a.id)
        await h.replies.flush()
        await h.replies.retry(id: id)
        XCTAssertEqual(h.replies.item(id: id)?.state, .sent)
        XCTAssertEqual(h.mock.count("addComment"), 2)
    }

    func testUncheckableEarlierSendWaitsForTheUser() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        var attention: [String] = []
        h.replies.onAttentionNeeded = { attention.append($0) }
        h.mock.update { $0.addCommentResults = [.network(code: -1001, detail: "timeout")] }
        let id = h.replies.submit(postID: "p1", body: "確認できない返信", accountID: a.id)
        await h.replies.flush()
        let item = try XCTUnwrap(h.replies.item(id: id))

        // The thread cannot be read (e.g. 5xx) when the automatic retry comes.
        h.mock.update { $0.commentErrors = [.server(status: 500)] }
        item.queuedAt = .now
        h.replies.handleConnectivityRestored()          // clears the backoff
        await h.replies.flush()
        XCTAssertEqual(item.state, .needsConfirmation, "never re-sent blindly")
        XCTAssertEqual(item.lastError, ReplyQueue.unconfirmedSendMessage)
        XCTAssertEqual(h.mock.count("addComment"), 1)
        XCTAssertEqual(h.replies.attentionCount, 1)
        XCTAssertEqual(attention, [id])

        // The user decides: the thread is checked again when possible, then it is sent.
        await h.replies.confirmAndSend(id: id)
        XCTAssertEqual(item.state, .sent)
        XCTAssertEqual(h.mock.count("addComment"), 2)
        XCTAssertEqual(h.replies.attentionCount, 0)
    }

    /// A POST refused by the rate limit (it never left the device) needs no "maybe sent" check, which the same cooldown
    /// would refuse too: it is simply retried.
    func testRateLimitedReplyIsRetriedWithoutAMaybeSentConfirmation() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.mock.update {
            $0.addCommentResults = [.rateLimited(retryAfter: 30)]
            $0.commentErrors = [.rateLimited(retryAfter: 30)]      // a lookup during the cooldown would be refused
        }
        let id = h.replies.submit(postID: "p1", body: "こんにちは", accountID: a.id)
        await h.replies.flush()
        let item = try XCTUnwrap(h.replies.item(id: id))
        XCTAssertEqual(item.state, .queued)
        XCTAssertNil(item.lastAttemptAt, "the refused POST did not land")

        h.replies.handleConnectivityRestored()          // clears the wait
        await h.replies.flush()
        XCTAssertEqual(item.state, .sent)
        XCTAssertEqual(h.mock.count("comments|"), 0, "no lookup for a request that was refused")
        XCTAssertEqual(h.mock.count("addComment"), 2)
    }

    /// A reply of an account turned off meanwhile (a comment screen still showing it) is never posted as that hidden
    /// identity; it waits, queued.
    func testReplyOfADisabledAccountIsNotSent() async throws {
        let h = try SyncHarness()
        _ = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        b.enabled = false
        h.store.save()
        let id = h.replies.submit(postID: "p1", body: "こんにちは", accountID: b.id)
        await h.replies.flush()
        XCTAssertEqual(h.mock.count("addComment"), 0)
        XCTAssertEqual(h.replies.item(id: id)?.state, .queued)
    }

    /// A reply of a quarantined or logged-out account refused with 401 (it has no session) leaves that state alone: only a
    /// verified login ends it, and "expired" would bring back its requests and the re-login notice.
    func testRefusedReplyKeepsAQuarantineAndALogout() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let b = h.addAccount("B", pixivUserID: "pB")
        a.sessionState = .error
        b.sessionState = .loggedOut
        h.store.save()
        h.mock.update { $0.addCommentResults = [.unauthorized, .unauthorized] }
        h.replies.submit(postID: "p1", body: "こんにちは", accountID: a.id)
        h.replies.submit(postID: "p1", body: "こんばんは", accountID: b.id)
        await h.replies.flush()
        XCTAssertEqual(h.mock.count("addComment"), 2)
        XCTAssertEqual(a.sessionState, .error)
        XCTAssertEqual(b.sessionState, .loggedOut)
    }

    /// Removing an account deletes its queue rows outside the queue: the 確認が必要な返信 banner and the 送信キュー count
    /// follow at once (offline, no queue run would refresh them).
    func testRemovingAnAccountClearsItsReplyCounts() async throws {
        let env = AppEnvironment.preview(seedDemo: false)
        _ = env.accounts.addDemoAccount(name: "A")
        let b = env.accounts.addDemoAccount(name: "B")
        env.store.context.insert(OutgoingComment(accountID: b.id, postID: "p1", body: "返信", state: .failed))
        env.store.save()
        env.replies.countsChanged()
        XCTAssertEqual(env.replies.attentionCount, 1)

        await env.accounts.remove(accountID: b.id)
        XCTAssertEqual(env.replies.attentionCount, 0)
        XCTAssertEqual(env.replies.pendingCount, 0)
    }

    /// Cancelling a queued reply while the queue is sending an earlier one: the cancelled row is gone and never sent.
    func testCancellingAQueuedReplyWhileAnotherIsSendingIsSafe() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.setOffline(true)
        let first = h.replies.submit(postID: "p1", body: "一通目", accountID: a.id)
        let second = h.replies.submit(postID: "p1", body: "二通目", accountID: a.id)
        h.mock.update { $0.addCommentDelayNanoseconds = 200_000_000 }
        h.setOffline(false)
        let flush = Task { await h.replies.flush() }
        var spins = 0
        while h.mock.count("addComment") == 0 && spins < 100_000 { spins += 1; await Task.yield() }
        h.replies.cancel(id: second)
        await flush.value
        XCTAssertEqual(h.mock.count("addComment"), 1)
        XCTAssertEqual(h.replies.item(id: first)?.state, .sent)
        XCTAssertNil(h.replies.item(id: second))
    }

    /// Removing an account while a user retry of its reply is being sent: the removal waits for that send, so nothing
    /// writes to the queue row after it is deleted, and nothing is sent for the account afterwards.
    func testAccountRemovalWaitsForAUserRetryBeingSent() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let id = h.replies.saveDraft(postID: "p1", body: "送信中の返信", accountID: a.id)
        let item = try XCTUnwrap(h.replies.item(id: id))
        item.state = .failed
        h.store.save()
        h.mock.update { $0.addCommentDelayNanoseconds = 300_000_000 }
        let retry = Task { await h.replies.retry(id: id) }
        var spins = 0
        while h.mock.count("addComment") == 0 && spins < 100_000 { spins += 1; await Task.yield() }
        XCTAssertEqual(item.state, .sending)

        await h.replies.prepareForRemoval(accountID: a.id)
        XCTAssertEqual(item.state, .sent, "the running send ended before the account's rows go")
        await retry.value

        let later = h.replies.saveDraft(postID: "p1", body: "次の返信", accountID: a.id)
        h.replies.item(id: later)?.state = .failed
        await h.replies.retry(id: later)
        XCTAssertEqual(h.mock.count("addComment"), 1, "nothing is sent for an account being removed")
    }

    func testRejectedRepliesFailAndAmbiguousOnesNeedConfirmation() {
        XCTAssertFalse(ReplyQueue.mayHaveReachedServer(.forbidden))
        XCTAssertFalse(ReplyQueue.mayHaveReachedServer(.rateLimited(retryAfter: 10)))
        XCTAssertFalse(ReplyQueue.mayHaveReachedServer(.invalidRequest("400")))
        XCTAssertFalse(ReplyQueue.mayHaveReachedServer(.unauthorized))
        XCTAssertTrue(ReplyQueue.mayHaveReachedServer(.network(code: -1001, detail: "timeout")))
        XCTAssertTrue(ReplyQueue.mayHaveReachedServer(.server(status: 504)))
        XCTAssertTrue(ReplyQueue.mayHaveReachedServer(.offline))
    }

    func testEarlierSendMatcherRequiresOwnTextParentAndTime() {
        let now = Date.now
        let own = RemoteComment(id: "x1", postID: "p", parentCommentID: "c1", authorUserID: "me", authorName: "Me", body: " ありがとう ",
                                createdAt: now, isOwn: true)
        let other = RemoteComment(id: "x2", postID: "p", parentCommentID: "c1", authorUserID: "fan", authorName: "Fan", body: "ありがとう",
                                  createdAt: now)
        let old = RemoteComment(id: "x3", postID: "p", parentCommentID: "c1", authorUserID: "me", authorName: "Me", body: "ありがとう",
                                createdAt: now.addingTimeInterval(-3600), isOwn: true)
        let root = RemoteComment(id: "x4", postID: "p", authorUserID: "me", authorName: "Me", body: "ありがとう", createdAt: now, isOwn: true)
        let notBefore = now.addingTimeInterval(-600)
        XCTAssertEqual(ReplyQueue.findPostedComment(in: [other, old, own], body: "ありがとう", parentCommentID: "c1", notBefore: notBefore,
                                                    ownUserID: "me")?.id, "x1")
        XCTAssertNil(ReplyQueue.findPostedComment(in: [other, old], body: "ありがとう", parentCommentID: "c1", notBefore: notBefore, ownUserID: "me"))
        XCTAssertEqual(ReplyQueue.findPostedComment(in: [own, root], body: "ありがとう", parentCommentID: nil, notBefore: notBefore,
                                                    ownUserID: "me")?.id, "x4")
        // Authored by my pixiv user id even without `isOwn`.
        var mine = other
        mine.authorUserID = "me"
        XCTAssertEqual(ReplyQueue.findPostedComment(in: [mine], body: "ありがとう", parentCommentID: "c1", notBefore: notBefore, ownUserID: "me")?.id, "x2")

        let nested = RemoteComment(id: "r", postID: "p", authorUserID: "fan", authorName: "Fan", body: "root", createdAt: now,
                                   replies: [RemoteComment(id: "r1", postID: "p", authorUserID: "me", authorName: "Me", body: "hi", createdAt: now)])
        XCTAssertEqual(ReplyQueue.flattenFillingParents([nested]).last?.parentCommentID, "r")
    }

    func testSameTextTwiceIsTwoReplies() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        let first = h.replies.submit(postID: "p1", body: "了解です", parentCommentID: "c1", accountID: a.id)
        await h.replies.flush()
        XCTAssertEqual(h.replies.item(id: first)?.state, .sent)

        // A second, intentional reply with the same text whose first attempt timed out without reaching FANBOX.
        h.mock.update { $0.addCommentResults = [.network(code: -1001, detail: "timeout")] }
        let second = h.replies.submit(postID: "p1", body: "了解です", parentCommentID: "c1", accountID: a.id)
        await h.replies.flush()
        await h.replies.retry(id: second)
        XCTAssertEqual(h.replies.item(id: second)?.state, .sent)
        XCTAssertNotEqual(h.replies.item(id: second)?.sentCommentID, h.replies.item(id: first)?.sentCommentID,
                          "a comment already claimed by another queue item is not taken as this item's earlier send")
        XCTAssertEqual(h.mock.count("addComment"), 3)
    }

    func testRootIsFilledFromTheLocalThreadBeforeSending() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.upsertComments([RemoteComment(id: "root1", postID: "p1", authorUserID: "fan", authorName: "Fan", body: "root", createdAt: .now,
                                              replies: [RemoteComment(id: "child1", postID: "p1", authorUserID: "fan2", authorName: "Fan2",
                                                                      body: "child", createdAt: .now)])],
                               postID: "p1", account: a.context)
        let id = h.replies.submit(postID: "p1", body: "返信", parentCommentID: "child1", rootCommentID: nil, accountID: a.id)
        await h.replies.flush()
        let item = try XCTUnwrap(h.replies.item(id: id))
        XCTAssertEqual(item.rootCommentID, "root1")
        XCTAssertEqual(h.store.comments(postID: "p1").first { $0.commentID == item.sentCommentID }?.rootCommentID, "root1")
    }

    // MARK: Provisional ids

    func testProvisionalSendIsReconciledWithTheRealComment() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.upsertPostSummaries([SyncFixtures.summary("p1")], account: a.context, source: .home)
        let provider = ProvisionalProvider(mock: h.mock)
        let queue = ReplyQueue(store: h.store, remote: provider, settings: h.settings, network: h.network)
        let before = h.store.post(id: "p1")?.commentCount ?? 0

        let id = queue.submit(postID: "p1", body: "仮 ID の返信", parentCommentID: "c1", rootCommentID: "c1", accountID: a.id)
        await queue.flush()
        let item = try XCTUnwrap(queue.item(id: id))
        XCTAssertEqual(item.state, .sent)
        XCTAssertNil(item.sentCommentID, "the provisional id is never stored as a real comment")
        XCTAssertFalse(h.store.comments(postID: "p1").contains { LocalStore.isProvisionalCommentID($0.commentID) })
        XCTAssertEqual(h.store.post(id: "p1")?.commentCount, before)

        // The thread refresh brings the real comment: the queue item points at it and it shows once.
        let real = RemoteComment(id: "real-9", postID: "p1", parentCommentID: "c1", rootCommentID: "c1", authorUserID: "pA",
                                 authorName: "A", body: "仮 ID の返信", createdAt: .now, isOwn: true)
        h.store.upsertCommentsReturningNew([real], postID: "p1", account: a.context)
        XCTAssertEqual(item.sentCommentID, "real-9")
        let known = Set(h.store.comments(postID: "p1").map(\.commentID))
        XCTAssertTrue(CommentThreadBuilder.visiblePending([(item.id, item.state, item.sentCommentID)], knownCommentIDs: known).isEmpty)
    }

    func testLegacyProvisionalRowsAreReplacedByTheRealComment() throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        h.store.upsertPostSummaries([SyncFixtures.summary("p1")], account: a.context, source: .home)
        let provisional = RemoteComment(id: "pending:abc", postID: "p1", parentCommentID: "c1", rootCommentID: "c1", authorUserID: "pA",
                                        authorName: "", body: "本文", createdAt: .now, isOwn: true)
        h.store.upsertOwnComment(provisional, account: a.context)
        let counted = h.store.post(id: "p1")?.commentCount ?? 0
        let real = RemoteComment(id: "777", postID: "p1", parentCommentID: "c1", rootCommentID: "c1", authorUserID: "pA", authorName: "A",
                                 body: "本文", createdAt: .now, isOwn: true)
        h.store.upsertCommentsReturningNew([real], postID: "p1", account: a.context)
        XCTAssertEqual(h.store.comments(postID: "p1").map(\.commentID), ["777"])
        XCTAssertEqual(h.store.post(id: "p1")?.commentCount, counted - 1, "the provisional copy is no longer counted")
    }

    // MARK: Attention notices for notification replies

    func testFailedNotificationReplyPostsANoticeThatOpensTheThread() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        _ = h.notifications
        h.mock.update { $0.addCommentResults = [.forbidden] }
        let id = h.replies.submit(postID: "p1", body: "通知から返信", parentCommentID: "c9", accountID: a.id, origin: .notificationAction)
        await h.replies.flush()
        XCTAssertEqual(h.replies.item(id: id)?.state, .failed)
        let notice = try XCTUnwrap(h.poster.requests.first)
        XCTAssertEqual(notice.content.title, "返信を送信できませんでした")
        XCTAssertEqual(notice.content.userInfo[NotificationService.replyItemIDKey] as? String, id)

        h.notifications.openReplyItem(id: id)
        XCTAssertEqual(h.router.selectedTab, .home)
        XCTAssertEqual(h.router.homePath.count, 1)

        // In-app replies are surfaced by the banner / queue screen, not by a notification.
        h.mock.update { $0.addCommentResults = [.forbidden] }
        _ = h.replies.submit(postID: "p1", body: "アプリ内", accountID: a.id)
        await h.replies.flush()
        XCTAssertEqual(h.poster.requests.count, 1)
        XCTAssertEqual(h.replies.attentionCount, 2)
        XCTAssertEqual(h.replies.attentionItems().count, 2)
    }

    func testStaleNotificationReplyAsksForConfirmation() async throws {
        let h = try SyncHarness()
        let a = h.addAccount("A", pixivUserID: "pA", isMain: true)
        _ = h.notifications
        h.settings.staleReplyThreshold = 60
        h.setOffline(true)
        let id = h.replies.submit(postID: "p1", body: "昨夜の返信", parentCommentID: "c1", accountID: a.id, origin: .notificationAction)
        let item = try XCTUnwrap(h.replies.item(id: id))
        item.queuedAt = Date(timeIntervalSinceNow: -3600)
        h.setOffline(false)
        await h.replies.flush()
        XCTAssertEqual(item.state, .needsConfirmation)
        XCTAssertEqual(h.poster.requests.first?.content.title, "返信の送信確認が必要です")
    }
}

/// Provider whose data source returns a provisional ("pending:") comment from addComment, like FanboxRemoteDataSource
/// when the posted comment is not on the first page.
private struct ProvisionalProvider: RemoteDataSourceProvider {
    let mock: SyncMockRemote
    func dataSource(for account: AccountContext) -> RemoteDataSource { ProvisionalSource(mock: mock) }
}

private struct ProvisionalSource: RemoteDataSource {
    let mock: SyncMockRemote
    func currentUser(account: AccountContext) async throws -> RemoteUser { try await mock.currentUser(account: account) }
    func homeTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { RemotePage(items: []) }
    func supportingTimeline(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { RemotePage(items: []) }
    func creatorPosts(creatorID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { RemotePage(items: []) }
    func post(id: String, account: AccountContext) async throws -> RemotePostDetail { throw RemoteError.notFound }
    func creator(id: String, account: AccountContext) async throws -> RemoteCreator { throw RemoteError.notFound }
    func followingCreators(account: AccountContext) async throws -> [RemoteCreator] { [] }
    func supportingPlans(account: AccountContext) async throws -> [RemoteSupport] { [] }
    func creatorPlans(creatorID: String, account: AccountContext) async throws -> [RemotePlan] { [] }
    func setLike(postID: String, liked: Bool, account: AccountContext) async throws {}
    /// The thread never shows the new comment (it is on a later page).
    func comments(postID: String, account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> { RemotePage(items: []) }
    func addComment(postID: String, body: String, parentCommentID: String?, rootCommentID: String?,
                    account: AccountContext) async throws -> RemoteComment {
        RemoteComment(id: "pending:" + UUID().uuidString, postID: postID, parentCommentID: parentCommentID, rootCommentID: rootCommentID,
                      authorUserID: account.pixivUserID ?? "", authorName: "", body: body, createdAt: .now, isOwn: true)
    }
    func deleteComment(commentID: String, postID: String, account: AccountContext) async throws {}
    func notifications(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteNotification> { RemotePage(items: []) }
    func newsletters(account: AccountContext) async throws -> [RemoteNewsletter] { [] }
    func newsletter(id: String, account: AccountContext) async throws -> RemoteNewsletter { throw RemoteError.notFound }
    func paidRecords(account: AccountContext) async throws -> [RemotePayment] { [] }
    func managedPosts(account: AccountContext, cursor: String?) async throws -> RemotePage<RemotePostSummary> { RemotePage(items: []) }
    func editablePost(id: String, account: AccountContext) async throws -> RemoteEditablePost { throw RemoteError.notFound }
    func createPost(_ draft: RemotePostDraft, account: AccountContext) async throws -> String { throw RemoteError.unsupported(operation: "x") }
    func updatePost(id: String, _ draft: RemotePostDraft, account: AccountContext) async throws {}
    func uploadImage(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        throw RemoteError.unsupported(operation: "x")
    }
    func uploadFile(fileURL: URL, account: AccountContext, progress: @escaping @Sendable (Double) -> Void) async throws -> RemoteUploadResult {
        throw RemoteError.unsupported(operation: "x")
    }
    func fans(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteFan> { RemotePage(items: []) }
    func creatorDashboard(account: AccountContext) async throws -> RemoteCreatorDashboard { RemoteCreatorDashboard(month: "2026-09") }
    func creatorComments(account: AccountContext, cursor: String?) async throws -> RemotePage<RemoteComment> { RemotePage(items: []) }
}

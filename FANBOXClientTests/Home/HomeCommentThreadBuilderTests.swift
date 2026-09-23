import XCTest
import SwiftData
@testable import FANBOXClient

final class HomeCommentThreadBuilderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func node(_ id: String, parent: String? = nil, root: String? = nil, at seconds: TimeInterval,
                      pending: Bool = false) -> CommentThreadNode {
        CommentThreadNode(id: id, parentID: parent, rootID: root, createdAt: t0.addingTimeInterval(seconds), isPending: pending)
    }

    func testRootsAndRepliesAreNestedAndOrdered() {
        let input = [
            node("r2", at: 100),
            node("a1", parent: "r1", root: "r1", at: 50),
            node("r1", at: 10),
            node("a0", parent: "r1", root: "r1", at: 20),
            node("b1", parent: "r2", root: "r2", at: 110),
            // reply to a reply: FANBOX gives root = r1, parent = a0
            node("a2", parent: "a0", root: "r1", at: 60),
        ]
        let threads = CommentThreadBuilder.build(input)
        XCTAssertEqual(threads.map(\.id), ["r1", "r2"])
        XCTAssertEqual(threads[0].replies.map(\.id), ["a0", "a1", "a2"])
        XCTAssertEqual(threads[1].replies.map(\.id), ["b1"])
        XCTAssertFalse(threads[0].isOrphan)
        XCTAssertEqual(threads[0].latestActivity, t0.addingTimeInterval(60))

        let newestFirst = CommentThreadBuilder.build(input, rootsNewestFirst: true)
        XCTAssertEqual(newestFirst.map(\.id), ["r2", "r1"])
        XCTAssertEqual(newestFirst[1].replies.map(\.id), ["a0", "a1", "a2"], "replies stay oldest first")
    }

    func testParentOnlyChainsResolveToRoot() {
        // No rootID: follow parent links up to the root.
        let threads = CommentThreadBuilder.build([
            node("r", at: 0),
            node("c1", parent: "r", at: 1),
            node("c2", parent: "c1", at: 2),
            node("c3", parent: "c2", at: 3),
        ])
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].nodes.map(\.id), ["r", "c1", "c2", "c3"])
    }

    func testOrphanRepliesAreGroupedNotDropped() {
        let threads = CommentThreadBuilder.build([
            node("r", at: 0),
            node("o2", parent: "gone", root: "gone", at: 30),
            node("o1", parent: "gone", root: "gone", at: 20),
            node("x", parent: "other-missing", root: "other-missing", at: 5),
        ])
        XCTAssertEqual(threads.map(\.id), ["r", "x", "o1"])
        let orphan = threads.first { $0.id == "o1" }!
        XCTAssertTrue(orphan.isOrphan)
        XCTAssertEqual(orphan.missingRootID, "gone")
        XCTAssertEqual(orphan.replies.map(\.id), ["o2"])
        XCTAssertEqual(threads.flatMap(\.nodes).count, 4, "every comment is shown exactly once")
    }

    func testReplyToMissingRootButKnownParentAttachesToParentThread() {
        // "d"'s rootID is not local, but its parent "c" is → it joins c's thread instead of becoming an orphan.
        let threads = CommentThreadBuilder.build([
            node("r", at: 0),
            node("c", parent: "r", at: 1),
            node("d", parent: "c", root: "not-loaded", at: 2),
        ])
        XCTAssertEqual(threads.map(\.id), ["r"])
        XCTAssertTrue(threads[0].contains("d"))
        XCTAssertFalse(threads[0].isOrphan)
        XCTAssertEqual(CommentThreadBuilder.upwardCandidates(of: node("x", parent: "p", root: "p", at: 0)), ["p"])
        XCTAssertEqual(CommentThreadBuilder.upwardCandidates(of: node("x", parent: "", root: "x", at: 0)), [])
    }

    func testDuplicatesSelfReferencesAndCycles() {
        let threads = CommentThreadBuilder.build([
            node("r", at: 0),
            node("r", at: 99),                       // duplicate id → first wins
            node("self", parent: "self", root: "self", at: 5),
            node("a", root: "b", at: 10),            // a ↔ b cycle
            node("b", root: "a", at: 11),
        ])
        let all = threads.flatMap(\.nodes).map(\.id)
        XCTAssertEqual(all.sorted(), ["a", "b", "r", "self"])
        XCTAssertEqual(threads.first { $0.id == "r" }?.root.createdAt, t0)
        XCTAssertNotNil(threads.first { $0.id == "self" }, "self reference is a root")
    }

    func testPendingItemsMergeIntoThreads() {
        let threads = CommentThreadBuilder.build([
            node("r", at: 0),
            node("pending-reply", parent: "r", root: "r", at: 5, pending: true),
            node("reply", parent: "r", root: "r", at: 5),
            node("pending-root", at: 100, pending: true),
        ])
        XCTAssertEqual(threads.map(\.id), ["r", "pending-root"])
        XCTAssertEqual(threads[0].replies.map(\.id), ["reply", "pending-reply"], "confirmed before pending at the same time")
        XCTAssertTrue(threads[1].root.isPending)
    }

    func testVisiblePendingHidesSentItemsThatAlreadyArrived() {
        let items: [(id: String, state: ReplyState, sentCommentID: String?)] = [
            ("q", .queued, nil),
            ("s-arrived", .sent, "c9"),
            ("s-not-yet", .sent, "c10"),
            ("s-no-id", .sent, nil),
            ("f", .failed, nil),
            ("n", .needsConfirmation, nil),
        ]
        let visible = CommentThreadBuilder.visiblePending(items, knownCommentIDs: ["c9", "c1"])
        XCTAssertEqual(visible, ["q", "s-not-yet", "s-no-id", "f", "n"])
    }

    func testThreadIDLookupAndEmptyInput() {
        XCTAssertTrue(CommentThreadBuilder.build([]).isEmpty)
        let threads = CommentThreadBuilder.build([node("r", at: 0), node("c", parent: "r", root: "r", at: 1)])
        XCTAssertEqual(CommentThreadBuilder.threadID(containing: "c", in: threads), "r")
        XCTAssertNil(CommentThreadBuilder.threadID(containing: "zzz", in: threads))
    }

    func testNodeFromModels() throws {
        let context = ModelContext(try PersistenceController.makeContainer(inMemory: true))
        let c = Comment(commentID: "c1", postID: "p", fetchedByAccountID: "A", authorUserID: "u", authorName: "n", body: "b",
                        createdAt: t0, parentCommentID: "r", rootCommentID: "r")
        context.insert(c)
        let n = CommentThreadNode(c)
        XCTAssertEqual(n.id, "c1")
        XCTAssertEqual(n.rootID, "r")
        XCTAssertFalse(n.isPending)
        let o = OutgoingComment(id: "o1", accountID: "A", postID: "p", parentCommentID: "c1", rootCommentID: "r", body: "hi",
                                state: .queued, createdAt: t0)
        context.insert(o)
        let on = CommentThreadNode(o)
        XCTAssertTrue(on.isPending)
        XCTAssertEqual(on.parentID, "c1")
    }

    func testReplyStateLabels() {
        XCTAssertEqual(ReplyState.allCases.map(ReplyStateLabel.text), ["下書き", "送信待ち", "送信中", "送信済", "失敗", "要確認"])
    }
}

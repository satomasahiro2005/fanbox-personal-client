import Foundation

/// Minimal, model-independent description of a comment (or a pending outgoing comment) for thread building.
struct CommentThreadNode: Hashable, Sendable, Identifiable {
    var id: String
    var parentID: String?
    var rootID: String?
    var createdAt: Date
    /// Local, not yet confirmed by FANBOX (`OutgoingComment`).
    var isPending: Bool

    init(id: String, parentID: String? = nil, rootID: String? = nil, createdAt: Date, isPending: Bool = false) {
        self.id = id
        self.parentID = parentID
        self.rootID = rootID
        self.createdAt = createdAt
        self.isPending = isPending
    }
}

extension CommentThreadNode {
    init(_ comment: Comment) {
        self.init(id: comment.commentID, parentID: comment.parentCommentID, rootID: comment.rootCommentID, createdAt: comment.createdAt)
    }

    init(_ outgoing: OutgoingComment) {
        self.init(id: outgoing.id, parentID: outgoing.parentCommentID, rootID: outgoing.rootCommentID,
                  createdAt: outgoing.queuedAt ?? outgoing.createdAt, isPending: true)
    }
}

/// One thread: a root comment followed by its replies (oldest first).
struct CommentThread: Hashable, Sendable, Identifiable {
    var root: CommentThreadNode
    var replies: [CommentThreadNode]
    /// The real root is not in the local DB (deleted / not loaded). `root` is then the earliest reply of the group.
    var isOrphan: Bool
    /// When `isOrphan`, the id of the missing root / parent the group points at.
    var missingRootID: String?

    var id: String { root.id }

    /// root + replies, in display order.
    var nodes: [CommentThreadNode] { [root] + replies }

    var latestActivity: Date { replies.map(\.createdAt).max().map { max($0, root.createdAt) } ?? root.createdAt }

    func contains(_ nodeID: String) -> Bool { root.id == nodeID || replies.contains { $0.id == nodeID } }
}

/// Groups comments into root + replies threads (SPEC §21). Pure and deterministic.
///
/// - A node with neither `rootID` nor `parentID` is a root.
/// - A reply is attached to the thread of `rootID` (or, if absent, of `parentID`), following chains up to the root.
/// - Replies whose root is missing are grouped per missing root id into an orphan thread (never dropped).
/// - Replies are ordered oldest first. Threads are ordered by their root's `createdAt` (`rootsNewestFirst` flips it).
/// - Duplicate ids keep the first occurrence; self references and reference cycles are treated as roots.
enum CommentThreadBuilder {
    static func build(_ input: [CommentThreadNode], rootsNewestFirst: Bool = false) -> [CommentThread] {
        var byID: [String: CommentThreadNode] = [:]
        var nodes: [CommentThreadNode] = []
        for node in input where byID[node.id] == nil {
            byID[node.id] = node
            nodes.append(node)
        }

        enum Key: Hashable { case root(String), missing(String) }

        func threadKey(for node: CommentThreadNode) -> Key {
            var current = node
            var visited: Set<String> = [node.id]
            while true {
                let candidates = upwardCandidates(of: current)
                guard let preferred = candidates.first else { return .root(current.id) }
                // Root first; if the root is not local but the parent is, walk through the parent.
                guard let up = candidates.first(where: { byID[$0] != nil }), let next = byID[up] else { return .missing(preferred) }
                if visited.contains(up) {
                    // Cycle: break it at the original node.
                    return .root(node.id)
                }
                visited.insert(up)
                current = next
            }
        }

        var groups: [Key: [CommentThreadNode]] = [:]
        var keyOrder: [Key] = []
        for node in nodes {
            let key = threadKey(for: node)
            if groups[key] == nil { keyOrder.append(key) }
            groups[key, default: []].append(node)
        }

        var threads: [CommentThread] = []
        for key in keyOrder {
            guard let members = groups[key] else { continue }
            switch key {
            case .root(let rootID):
                guard let root = byID[rootID] else { continue }
                let replies = sortedChronologically(members.filter { $0.id != rootID })
                threads.append(CommentThread(root: root, replies: replies, isOrphan: false, missingRootID: nil))
            case .missing(let missingID):
                let sorted = sortedChronologically(members)
                guard let first = sorted.first else { continue }
                threads.append(CommentThread(root: first, replies: Array(sorted.dropFirst()), isOrphan: true, missingRootID: missingID))
            }
        }

        return threads.sorted { a, b in
            if a.root.createdAt != b.root.createdAt {
                return rootsNewestFirst ? a.root.createdAt > b.root.createdAt : a.root.createdAt < b.root.createdAt
            }
            // Pending (local) roots go after confirmed ones at the same instant; then by id for stability.
            if a.root.isPending != b.root.isPending { return !a.root.isPending }
            return a.root.id < b.root.id
        }
    }

    /// References used to walk up, in preference order: root (FANBOX gives it directly), then parent.
    /// Empty ids and self references are ignored.
    static func upwardCandidates(of node: CommentThreadNode) -> [String] {
        var result: [String] = []
        for ref in [node.rootID, node.parentID] {
            if let ref, !ref.isEmpty, ref != node.id, !result.contains(ref) { result.append(ref) }
        }
        return result
    }

    static func sortedChronologically(_ nodes: [CommentThreadNode]) -> [CommentThreadNode] {
        nodes.sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            if a.isPending != b.isPending { return !a.isPending }
            return a.id < b.id
        }
    }

    /// Pending items worth showing inline: everything except `sent` items already present as real comments
    /// (their `sentCommentID` is in `knownCommentIDs`).
    static func visiblePending(_ items: [(id: String, state: ReplyState, sentCommentID: String?)],
                               knownCommentIDs: Set<String>) -> [String] {
        items.compactMap { item in
            if item.state == .sent, let sent = item.sentCommentID, knownCommentIDs.contains(sent) { return nil }
            return item.id
        }
    }

    /// Thread (root) id of the given node inside `threads`, if any.
    static func threadID(containing nodeID: String, in threads: [CommentThread]) -> String? {
        threads.first { $0.contains(nodeID) }?.id
    }
}

/// Display labels for the reply queue states (SPEC §22).
enum ReplyStateLabel {
    static func text(_ state: ReplyState) -> String {
        switch state {
        case .draft: return "下書き"
        case .queued: return "送信待ち"
        case .sending: return "送信中"
        case .sent: return "送信済"
        case .failed: return "失敗"
        case .needsConfirmation: return "要確認"
        }
    }

    static func systemImage(_ state: ReplyState) -> String {
        switch state {
        case .draft: return "square.and.pencil"
        case .queued: return "clock"
        case .sending: return "arrow.up.circle"
        case .sent: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .needsConfirmation: return "questionmark.circle"
        }
    }
}

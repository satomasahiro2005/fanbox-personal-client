import Foundation

/// Finds the comment a comment notification is about (pure; unit-tested).
///
/// FANBOX bell items for comments carry the comment text, the commenter's name and a timestamp but no verified comment id
/// (docs/API.md §2.11), so a threaded reply from the notification needs the id resolved from the post's comment list.
/// The match is conservative: when it is ambiguous nothing is returned and the caller must not guess.
enum NotificationCommentResolver {
    struct Candidate: Equatable, Sendable {
        var id: String
        var parentID: String?
        var authorName: String
        var body: String
        var createdAt: Date
        var isOwn: Bool
    }

    /// Bell time vs. comment time tolerance.
    static let timeWindow: TimeInterval = 10 * 60

    /// - Parameters:
    ///   - message: the notification text (for FANBOX comment bells: the comment body, `postCommentBody`).
    ///   - bellIDs: FANBOX bell ids of the event (some clients treat them as comment ids; accepted when they match exactly).
    ///   - postTitle: used to recognise a message that is only the post title (no comment body available).
    static func resolve(type: NotificationEventType, message: String, actorName: String?, timestamp: Date, bellIDs: [String],
                        postTitle: String?, candidates: [Candidate]) -> String? {
        let others = candidates.filter { !$0.isOwn }
        let body = normalize(message)
        let bodyKnown = !body.isEmpty && body != normalize(postTitle ?? "")
        let actor = actorName.map(normalize).flatMap { $0.isEmpty || $0 == "誰か" ? nil : $0 }

        let matches = others.filter { c in
            if type == .commentReply && c.parentID == nil { return false }
            if abs(c.createdAt.timeIntervalSince(timestamp)) > timeWindow { return false }
            if let actor, normalize(c.authorName) != actor { return false }
            if bodyKnown && normalize(c.body) != body { return false }
            return true
        }
        // A bell id equal to a comment id is accepted only together with the other checks (the id spaces are unverified).
        if let exact = matches.first(where: { bellIDs.contains($0.id) }) { return exact.id }
        // Without the text only a unique author + time match is trusted.
        if !bodyKnown && (actor == nil || matches.count != 1) { return nil }
        return matches.min { abs($0.createdAt.timeIntervalSince(timestamp)) < abs($1.createdAt.timeIntervalSince(timestamp)) }?.id
    }

    /// Bell ids from `NotificationEvent.remoteIDs` ("<accountID>:<remoteID>"); synthesized ids are skipped.
    static func bellIDs(fromRemoteIDs remoteIDs: [String]) -> [String] {
        remoteIDs.compactMap { ref in
            guard let separator = ref.firstIndex(of: ":") else { return nil }
            let id = String(ref[ref.index(after: separator)...])
            return id.hasPrefix("bell:") || id.isEmpty ? nil : id
        }
    }

    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

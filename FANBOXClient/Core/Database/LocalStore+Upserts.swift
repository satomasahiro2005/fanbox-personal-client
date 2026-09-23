import Foundation
import SwiftData

/// Normalizing upserts: Remote* value types → SwiftData models.
/// Rules:
/// - Never delete cached content because of a network error.
/// - Posts are deduplicated by postID across accounts; per-account visibility goes to PostAccess.
/// - User metadata (isRead, isFavorite, isReadLater, memo, tags, offline state) is never overwritten by remote data.
extension LocalStore {
    /// Observed-fact-only reason shown on the Support Dashboard when a support stops appearing (SPEC §15).
    static let supportMissingReason = "支援中一覧から消えました（原因は確認できません）"

    // MARK: - Posts

    @discardableResult
    func upsertPostSummaries(_ items: [RemotePostSummary], account: AccountContext, source: TimelineSource) -> UpsertResult {
        upsertSummariesCore(items, account: account, source: source)
    }

    /// Posts listed in Creator Mode for my own creator page (always `isOwnPost`), with their FANBOX status
    /// (see LocalStore+Managed.swift).
    @discardableResult
    func upsertManagedPosts(_ items: [RemotePostSummary], account: AccountContext) -> UpsertResult {
        let result = upsertSummariesCore(items, account: account, source: .managed)
        applyManagedStatuses(items)
        return result
    }

    func upsertPostDetail(_ detail: RemotePostDetail, account: AccountContext) {
        let summary = detail.summary
        // Metadata + PostAccess (canView = !isRestricted). A detail is not a listing: no seenBy / feed flags.
        upsertSummariesCore([summary], account: account, source: nil)
        guard let post = post(id: summary.id) else { return }
        post.prevPostID = detail.prevPostID ?? post.prevPostID
        post.nextPostID = detail.nextPostID ?? post.nextPostID

        // A restricted detail (no body for THIS account) must never wipe a body cached earlier
        // (possibly via another account). Only the PostAccess row changes.
        if summary.isRestricted {
            save()
            return
        }

        let now = Date.now
        replaceBlocks(of: post, with: detail.blocks)
        upsertMedia(for: post, blocks: detail.blocks)
        post.bodyText = detail.plainText
        post.bodyFetchedAt = now
        post.detailAccountID = account.accountID
        post.fetchedAt = now

        let key = PostAccess.key(postID: post.postID, accountID: account.accountID)
        if let access = first(#Predicate<PostAccess> { $0.key == key }) {
            access.bodyCached = true
            access.canView = true
            access.lastError = nil
        }
        save()
    }

    /// Records a failed detail fetch for one account (shown in Research / account switch UI). Cache is untouched.
    func recordPostAccessError(postID: String, accountID: String, message: String) {
        let key = PostAccess.key(postID: postID, accountID: accountID)
        if let access = first(#Predicate<PostAccess> { $0.key == key }) {
            access.lastError = message
            save()
        }
    }

    // MARK: - Creators

    func upsertCreator(_ creator: RemoteCreator, account: AccountContext?) {
        let row = ensureCreator(id: creator.creatorID, name: creator.name, iconURL: creator.iconURL, pixivUserID: creator.pixivUserID)
        applyProfile(creator, to: row)
        if let account, let followed = creator.isFollowed {
            var set = row.followedByAccountIDs
            if followed { if !set.contains(account.accountID) { set.append(account.accountID) } } else { set.removeAll { $0 == account.accountID } }
            if set != row.followedByAccountIDs { row.followedByAccountIDs = set }
            let wasFollowed = row.isFollowed
            row.isFollowed = !set.isEmpty
            if wasFollowed != row.isFollowed { refreshPostFeedFlags(creatorIDs: [row.creatorID]) }
        }
        save()
    }

    /// Replaces the "followed by <account>" set with `creators`.
    func applyFollowing(_ creators: [RemoteCreator], account: AccountContext) {
        let accountID = account.accountID
        let followedIDs = Set(creators.map(\.creatorID))
        var changedFollow: Set<String> = []

        for remote in creators {
            let row = ensureCreator(id: remote.creatorID, name: remote.name, iconURL: remote.iconURL, pixivUserID: remote.pixivUserID)
            applyProfile(remote, to: row)
            if !row.followedByAccountIDs.contains(accountID) {
                row.followedByAccountIDs.append(accountID)
            }
            if !row.isFollowed { row.isFollowed = true; changedFollow.insert(row.creatorID) }
        }
        // Creators this account no longer follows (array property → filter in memory).
        for row in fetch(FetchDescriptor<Creator>()) where !followedIDs.contains(row.creatorID) && row.followedByAccountIDs.contains(accountID) {
            row.followedByAccountIDs.removeAll { $0 == accountID }
            let now = !row.followedByAccountIDs.isEmpty
            if now != row.isFollowed { row.isFollowed = now; changedFollow.insert(row.creatorID) }
        }
        if !changedFollow.isEmpty { refreshPostFeedFlags(creatorIDs: changedFollow) }
        save()
    }

    // MARK: - Supports (SPEC §10 / §11 / §13 / §15)

    /// Applies the account's current supporting plans, records SupportHistory and flags anomalies.
    @discardableResult
    func applySupports(_ supports: [RemoteSupport], account: AccountContext, source: ObservedSource) -> SupportDiff {
        applySupportsDetailed(supports, account: account, source: source).diff
    }

    /// Same as `applySupports` but also returns the SupportHistory rows created by this call.
    func applySupportsDetailed(_ supports: [RemoteSupport], account: AccountContext,
                               source: ObservedSource) -> (diff: SupportDiff, history: [SupportHistory]) {
        let accountID = account.accountID
        let now = Date.now
        var diff = SupportDiff()
        var history: [SupportHistory] = []
        var existing: [String: Support] = [:]
        for s in self.supports(accountID: accountID) { existing[s.creatorID] = s }

        var remoteByCreator: [String: RemoteSupport] = [:]
        var order: [String] = []
        for r in supports where remoteByCreator[r.creatorID] == nil {
            remoteByCreator[r.creatorID] = r
            order.append(r.creatorID)
        }

        func record(_ kind: SupportHistoryKind, creatorID: String, creatorName: String, oldPlanID: String?, newPlanID: String?,
                    oldPlan: String?, newPlan: String?, oldAmount: Int?, newAmount: Int?) {
            let h = SupportHistory(timestamp: now, creatorID: creatorID, creatorName: creatorName, accountID: accountID, kind: kind,
                                   oldPlanID: oldPlanID, newPlanID: newPlanID, oldPlan: oldPlan, newPlan: newPlan,
                                   oldAmount: oldAmount, newAmount: newAmount, observedSource: source)
            context.insert(h)
            history.append(h)
        }

        for creatorID in order {
            guard let r = remoteByCreator[creatorID] else { continue }
            let planID: String? = r.planID.isEmpty ? nil : r.planID
            if let s = existing[creatorID] {
                switch s.status {
                case .active:
                    if s.planID != planID || s.amount != r.fee {
                        record(.planChanged, creatorID: creatorID, creatorName: r.creatorName, oldPlanID: s.planID, newPlanID: planID,
                               oldPlan: s.planTitle, newPlan: r.planTitle, oldAmount: s.amount, newAmount: r.fee)
                        diff.changed.append(creatorID)
                    }
                case .missing:
                    record(.restored, creatorID: creatorID, creatorName: r.creatorName, oldPlanID: s.planID, newPlanID: planID,
                           oldPlan: s.planTitle, newPlan: r.planTitle, oldAmount: s.amount, newAmount: r.fee)
                    diff.restored.append(creatorID)
                case .ended, .unknown:
                    record(.started, creatorID: creatorID, creatorName: r.creatorName, oldPlanID: s.planID, newPlanID: planID,
                           oldPlan: s.planTitle, newPlan: r.planTitle, oldAmount: s.amount, newAmount: r.fee)
                    diff.started.append(creatorID)
                }
                s.status = .active
                s.missingSince = nil
                s.needsAttention = false
                s.attentionReason = nil
                s.creatorName = r.creatorName.isEmpty ? s.creatorName : r.creatorName
                s.creatorIconURL = r.creatorIconURL ?? s.creatorIconURL
                s.planID = planID
                s.planTitle = r.planTitle
                s.amount = r.fee
                s.reportedPaymentMethod = r.paymentMethod ?? s.reportedPaymentMethod
                s.lastObservedAt = now
            } else {
                let s = Support(accountID: accountID, creatorID: creatorID, creatorName: r.creatorName, planID: planID,
                                planTitle: r.planTitle, amount: r.fee, status: .active, observedAt: now)
                s.creatorIconURL = r.creatorIconURL
                s.reportedPaymentMethod = r.paymentMethod
                context.insert(s)
                existing[creatorID] = s
                record(.started, creatorID: creatorID, creatorName: r.creatorName, oldPlanID: nil, newPlanID: planID,
                       oldPlan: nil, newPlan: r.planTitle, oldAmount: nil, newAmount: r.fee)
                diff.started.append(creatorID)
            }

            // Plan row from the support listing (never deletes other plans).
            if let planID {
                upsertPlanRow(planID: planID, creatorID: creatorID, title: r.planTitle, fee: r.fee, description: r.planDescription,
                              coverImageURL: r.coverImageURL, hasAdultContent: nil, sortOrder: nil)
            }

            // Payment assignment placeholder: verification is UNKNOWN until the user confirms (SPEC §13).
            let assignmentKey = Support.key(accountID: accountID, creatorID: creatorID)
            if let a = first(#Predicate<SupportPaymentAssignment> { $0.key == assignmentKey }) {
                if a.planID != planID { a.planID = planID; a.updatedAt = now }
            } else {
                context.insert(SupportPaymentAssignment(accountID: accountID, creatorID: creatorID, planID: planID, paymentProfileID: nil,
                                                        verificationState: .unknown, updatedAt: now))
            }

            ensureCreator(id: creatorID, name: r.creatorName, iconURL: r.creatorIconURL, pixivUserID: r.pixivUserID)
        }

        // Previously active supports that are no longer returned: observed fact only, never an asserted cause.
        for (creatorID, s) in existing where remoteByCreator[creatorID] == nil && s.status == .active {
            s.status = .missing
            s.missingSince = now
            s.needsAttention = true
            s.attentionReason = Self.supportMissingReason
            record(.disappeared, creatorID: creatorID, creatorName: s.creatorName, oldPlanID: s.planID, newPlanID: nil,
                   oldPlan: s.planTitle, newPlan: nil, oldAmount: s.amount, newAmount: nil)
            diff.disappeared.append(creatorID)
        }

        // Denormalize supportedByAccountIDs / isSupported on Creator and the per-account plan fee on PostAccess.
        let affected = Set(existing.keys).union(remoteByCreator.keys)
        var supportFlagChanged: Set<String> = []
        for creatorID in affected {
            let isActive = existing[creatorID]?.status == .active || remoteByCreator[creatorID] != nil
            let name = remoteByCreator[creatorID]?.creatorName ?? existing[creatorID]?.creatorName ?? creatorID
            let creator = ensureCreator(id: creatorID, name: name, iconURL: nil, pixivUserID: nil)
            var set = creator.supportedByAccountIDs
            if isActive { if !set.contains(accountID) { set.append(accountID) } } else { set.removeAll { $0 == accountID } }
            if set != creator.supportedByAccountIDs { creator.supportedByAccountIDs = set }
            let supported = !set.isEmpty
            if creator.isSupported != supported { creator.isSupported = supported; supportFlagChanged.insert(creatorID) }
        }
        let feeChanged = Set(diff.started + diff.changed + diff.restored + diff.disappeared)
        if !feeChanged.isEmpty {
            refreshAccountPlanFees(accountID: accountID, creatorIDs: feeChanged,
                                   fee: { cid in existing[cid].flatMap { $0.isActive ? $0.amount : nil } })
        }
        if !supportFlagChanged.isEmpty { refreshPostFeedFlags(creatorIDs: supportFlagChanged) }
        save()
        return (diff, history)
    }

    func upsertPlans(_ plans: [RemotePlan], creatorID: String) {
        for (index, p) in plans.enumerated() {
            upsertPlanRow(planID: p.planID, creatorID: p.creatorID.isEmpty ? creatorID : p.creatorID, title: p.title, fee: p.fee,
                          description: p.description, coverImageURL: p.coverImageURL, hasAdultContent: p.hasAdultContent, sortOrder: index)
        }
        // The creator's plan list is authoritative when non-empty; an empty answer never wipes local rows.
        if !plans.isEmpty {
            let keep = Set(plans.map(\.planID))
            for stale in self.plans(creatorID: creatorID) where !keep.contains(stale.planID) {
                context.delete(stale)
            }
        }
        save()
    }

    // MARK: - Comments

    func upsertComments(_ comments: [RemoteComment], postID: String, account: AccountContext) {
        upsertCommentsCore(comments, postID: postID, account: account, forceOwnPostCreatorID: nil, forceOwn: false)
    }

    /// Upserts and returns the ids of comments that were not known before.
    @discardableResult
    func upsertCommentsReturningNew(_ comments: [RemoteComment], postID: String, account: AccountContext) -> [String] {
        upsertCommentsCore(comments, postID: postID, account: account, forceOwnPostCreatorID: nil, forceOwn: false)
    }

    /// Comments on my own creator posts (Creator Mode listing). Groups by post.
    @discardableResult
    func upsertCreatorComments(_ comments: [RemoteComment], account: AccountContext) -> [String] {
        var byPost: [String: [RemoteComment]] = [:]
        var order: [String] = []
        for c in comments {
            if byPost[c.postID] == nil { order.append(c.postID) }
            byPost[c.postID, default: []].append(c)
        }
        var inserted: [String] = []
        for postID in order {
            inserted += upsertCommentsCore(byPost[postID] ?? [], postID: postID, account: account,
                                           forceOwnPostCreatorID: account.creatorID, forceOwn: false)
        }
        return inserted
    }

    /// A comment my account just posted (reply queue): visible locally immediately, marked own + read.
    func upsertOwnComment(_ comment: RemoteComment, account: AccountContext) {
        let inserted = upsertCommentsCore([comment], postID: comment.postID, account: account, forceOwnPostCreatorID: nil, forceOwn: true)
        if !inserted.isEmpty, let post = post(id: comment.postID) {
            post.commentCount += 1
            save()
        }
    }

    /// Removes a comment that was deleted on FANBOX from the local DB.
    /// NOTE: `Comment.isDeleted` (now renamed to `isRemoved`) collided with SwiftData's `PersistentModel.isDeleted` (context deletion flag) and does not
    /// persist a soft-delete reliably, so the row is removed instead. Replies keep their parent / root ids (thread keys).
    func deleteLocalComment(commentID: String) {
        guard let c = first(#Predicate<Comment> { $0.commentID == commentID }) else { return }
        if let post = post(id: c.postID), post.commentCount > 0 { post.commentCount -= 1 }
        context.delete(c)
        save()
    }

    // MARK: - Notifications / おたより

    /// Returns ids of NotificationEvents that are new (not previously known).
    @discardableResult
    func upsertNotifications(_ items: [RemoteNotification], account: AccountContext) -> [String] {
        let accountID = account.accountID
        let keyed: [(String, RemoteNotification)] = items.map { n in
            (NotificationEvent.dedupeKey(type: n.type, creatorID: n.creatorID, postID: n.postID, commentID: n.commentID,
                                         newsletterID: n.newsletterID, fallbackRemoteID: n.remoteID), n)
        }
        let ids = Array(Set(keyed.map(\.0)))
        var known: [String: NotificationEvent] = [:]
        if !ids.isEmpty {
            for e in fetch(FetchDescriptor<NotificationEvent>(predicate: #Predicate { ids.contains($0.id) })) { known[e.id] = e }
        }
        var newIDs: [String] = []
        for (key, n) in keyed {
            let remoteRef = "\(accountID):\(n.remoteID)"
            if let e = known[key] {
                if !e.accountIDs.contains(accountID) { e.accountIDs.append(accountID) }
                if !e.remoteIDs.contains(remoteRef) { e.remoteIDs.append(remoteRef) }
                if e.creatorID == nil { e.creatorID = n.creatorID }
                if e.postID == nil { e.postID = n.postID }
                if e.commentID == nil { e.commentID = n.commentID }
                if e.newsletterID == nil { e.newsletterID = n.newsletterID }
                if e.actorName == nil { e.actorName = n.actorName }
                if e.actorIconURL == nil { e.actorIconURL = n.actorIconURL }
                if e.message.isEmpty && !n.message.isEmpty { e.message = n.message }
                if e.title.isEmpty && !n.title.isEmpty { e.title = n.title }
                continue
            }
            let e = NotificationEvent(id: key, type: n.type, accountIDs: [accountID], title: n.title, message: n.message,
                                      timestamp: n.createdAt, creatorID: n.creatorID, postID: n.postID, commentID: n.commentID,
                                      newsletterID: n.newsletterID)
            e.remoteIDs = [remoteRef]
            e.actorName = n.actorName
            e.actorIconURL = n.actorIconURL
            // Already read on FANBOX → do not surface as unread / do not notify again.
            e.isRead = n.isUnread == false
            e.prefetchState = .pending
            context.insert(e)
            known[key] = e
            newIDs.append(key)

            if let creatorID = n.creatorID, let name = n.creatorName, !name.isEmpty {
                _ = ensureCreator(id: creatorID, name: name, iconURL: nil, pixivUserID: nil)
            }
        }
        save()
        return newIDs
    }

    /// Returns ids of newsletters that are new.
    @discardableResult
    func upsertNewsletters(_ items: [RemoteNewsletter], account: AccountContext) -> [String] {
        let accountID = account.accountID
        let ids = Array(Set(items.map(\.id)))
        var known: [String: Newsletter] = [:]
        if !ids.isEmpty {
            for n in fetch(FetchDescriptor<Newsletter>(predicate: #Predicate { ids.contains($0.newsletterID) })) { known[n.newsletterID] = n }
        }
        var newIDs: [String] = []
        let now = Date.now
        for item in items {
            if let n = known[item.id] {
                if !n.accountIDs.contains(accountID) { n.accountIDs.append(accountID) }
                if !item.creatorName.isEmpty { n.creatorName = item.creatorName }
                n.creatorIconURL = item.creatorIconURL ?? n.creatorIconURL
                if let title = item.title, !title.isEmpty { n.title = title }
                if !item.body.isEmpty {
                    n.body = item.body
                    n.bodyFetched = true
                }
                n.fetchedAt = now
                continue
            }
            let n = Newsletter(newsletterID: item.id, creatorID: item.creatorID, creatorName: item.creatorName, body: item.body,
                               createdAt: item.createdAt, accountIDs: [accountID], fetchedAt: now)
            n.title = item.title
            n.creatorIconURL = item.creatorIconURL
            n.isRead = item.isRead
            context.insert(n)
            known[item.id] = n
            newIDs.append(item.id)
            if !item.creatorID.isEmpty {
                _ = ensureCreator(id: item.creatorID, name: item.creatorName, iconURL: item.creatorIconURL, pixivUserID: nil)
            }
        }
        save()
        return newIDs
    }

    /// Ensures a `.newsletter` NotificationEvent exists for each newsletter id (dedupe key shared with FANBOX notifications).
    /// Returns ids of events created by this call.
    @discardableResult
    func ensureNewsletterEvents(newsletterIDs: [String], account: AccountContext) -> [String] {
        var created: [String] = []
        for id in newsletterIDs {
            guard let n = newsletter(id: id) else { continue }
            let key = NotificationEvent.dedupeKey(type: .newsletter, creatorID: n.creatorID, postID: nil, commentID: nil, newsletterID: id,
                                                  fallbackRemoteID: id)
            if let e = notificationEvent(id: key) {
                if !e.accountIDs.contains(account.accountID) { e.accountIDs.append(account.accountID) }
                continue
            }
            let e = NotificationEvent(id: key, type: .newsletter, accountIDs: [account.accountID],
                                      title: "\(n.creatorName) からおたより", message: n.title ?? String(n.body.prefix(80)),
                                      timestamp: n.createdAt, creatorID: n.creatorID, newsletterID: id)
            e.isRead = n.isRead
            e.prefetchState = n.bodyFetched ? .textReady : .pending
            context.insert(e)
            created.append(key)
        }
        save()
        return created
    }

    /// Creates local `.supportChanged` events for observed support changes (detected by sync, not by FANBOX notifications).
    /// Messages state observed facts only (SPEC §15). Returns created event ids.
    @discardableResult
    func recordSupportChangeEvents(_ history: [SupportHistory], account: AccountContext, accountName: String) -> [String] {
        var created: [String] = []
        for h in history {
            let key = NotificationEvent.dedupeKey(type: .supportChanged, creatorID: h.creatorID, postID: nil, commentID: nil, newsletterID: nil,
                                                  fallbackRemoteID: "local:\(account.accountID):\(h.id)")
            guard notificationEvent(id: key) == nil else { continue }
            let fact: String
            switch h.kind {
            case .started: fact = "支援開始 \(Self.yenText(h.newAmount))"
            case .planChanged: fact = "\(Self.yenText(h.oldAmount)) → \(Self.yenText(h.newAmount))"
            case .ended: fact = "支援終了"
            case .disappeared: fact = Self.supportMissingReason
            case .restored: fact = "支援中一覧に再び表示されました \(Self.yenText(h.newAmount))"
            }
            let e = NotificationEvent(id: key, type: .supportChanged, accountIDs: [account.accountID],
                                      title: "\(h.creatorName)（\(accountName)）", message: fact, timestamp: h.timestamp,
                                      creatorID: h.creatorID)
            e.prefetchState = .textReady
            context.insert(e)
            created.append(key)
        }
        save()
        return created
    }

    // MARK: - Payments / Creator Mode

    func upsertPayments(_ items: [RemotePayment], account: AccountContext) {
        let accountID = account.accountID
        let keys = items.map { "\(accountID)|\($0.id)" }
        var known: [String: PaymentRecord] = [:]
        if !keys.isEmpty {
            for p in fetch(FetchDescriptor<PaymentRecord>(predicate: #Predicate { keys.contains($0.key) })) { known[p.key] = p }
        }
        let now = Date.now
        for item in items {
            let key = "\(accountID)|\(item.id)"
            if let p = known[key] {
                p.creatorID = item.creatorID ?? p.creatorID
                p.creatorName = item.creatorName ?? p.creatorName
                p.amount = item.amount
                p.paidAt = item.paidAt
                p.reportedPaymentMethod = item.paymentMethod ?? p.reportedPaymentMethod
                p.fetchedAt = now
            } else {
                let p = PaymentRecord(paymentID: item.id, accountID: accountID, creatorID: item.creatorID, creatorName: item.creatorName,
                                      amount: item.amount, paidAt: item.paidAt, reportedPaymentMethod: item.paymentMethod, fetchedAt: now)
                context.insert(p)
                known[key] = p
            }
        }
        save()
    }

    func upsertFans(_ fans: [RemoteFan], account: AccountContext) {
        let accountID = account.accountID
        let keys = fans.map { "\(accountID)|\($0.userID)" }
        var known: [String: Fan] = [:]
        if !keys.isEmpty {
            for f in fetch(FetchDescriptor<Fan>(predicate: #Predicate { keys.contains($0.key) })) { known[f.key] = f }
        }
        let now = Date.now
        for r in fans {
            let key = "\(accountID)|\(r.userID)"
            let f: Fan
            if let existing = known[key] {
                f = existing
            } else {
                f = Fan(accountID: accountID, userID: r.userID, name: r.name, state: r.state, updatedAt: now)
                context.insert(f)
                known[key] = f
            }
            if !r.name.isEmpty { f.name = r.name }
            f.iconURL = r.iconURL ?? f.iconURL
            f.planID = r.planID ?? f.planID
            f.planTitle = r.planTitle ?? f.planTitle
            f.fee = r.fee ?? f.fee
            f.supportStartedAt = r.supportStartedAt ?? f.supportStartedAt
            f.supportMonths = r.supportMonths ?? f.supportMonths
            f.state = r.state
            f.updatedAt = now
            // `note` is local-only and never touched here.
        }
        save()
    }

    /// After a COMPLETE fan listing: supporters that are no longer listed are marked `.ended` (observed fact).
    func markMissingFansEnded(presentUserIDs: Set<String>, account: AccountContext) {
        let accountID = account.accountID
        let rows = fetch(FetchDescriptor<Fan>(predicate: #Predicate { $0.accountID == accountID }))
        let now = Date.now
        for f in rows where !presentUserIDs.contains(f.userID) && f.state == .supporting {
            f.state = .ended
            f.updatedAt = now
        }
        save()
    }

    func upsertDashboard(_ dashboard: RemoteCreatorDashboard, account: AccountContext) {
        let key = "\(account.accountID)|\(dashboard.month)"
        let snap: CreatorDashboardSnapshot
        if let existing = first(#Predicate<CreatorDashboardSnapshot> { $0.key == key }) {
            snap = existing
        } else {
            snap = CreatorDashboardSnapshot(accountID: account.accountID, month: dashboard.month)
            context.insert(snap)
        }
        // Each metric is actual when FANBOX provided it, otherwise unavailable — never guessed (SPEC §17).
        snap.supporterCount = dashboard.supporterCount
        snap.supporterCountSourceRaw = (dashboard.supporterCount == nil ? MetricSource.unavailable : .actual).rawValue
        snap.earnings = dashboard.earnings
        snap.earningsSourceRaw = (dashboard.earnings == nil ? MetricSource.unavailable : .actual).rawValue
        snap.postCount = dashboard.postCount
        snap.postCountSourceRaw = (dashboard.postCount == nil ? MetricSource.unavailable : .actual).rawValue
        snap.commentCount = dashboard.commentCount
        snap.commentCountSourceRaw = (dashboard.commentCount == nil ? MetricSource.unavailable : .actual).rawValue
        snap.fetchedAt = .now
        save()
    }
}

// MARK: - Internals

extension LocalStore {
    /// Map creatorID → local account id owning that creator page (includes disabled accounts).
    func ownedCreatorAccountMap() -> [String: String] {
        var map: [String: String] = [:]
        for a in accounts(includeDisabled: true) {
            if let cid = a.creatorID, map[cid] == nil { map[cid] = a.id }
        }
        return map
    }

    /// `source == nil` → detail / notification upsert: no seenBy and no feed-origin flags.
    @discardableResult
    fileprivate func upsertSummariesCore(_ items: [RemotePostSummary], account: AccountContext, source: TimelineSource?) -> UpsertResult {
        guard !items.isEmpty else { return UpsertResult() }
        let accountID = account.accountID
        let now = Date.now
        var result = UpsertResult()

        let postIDs = Array(Set(items.map(\.id)))
        var posts: [String: Post] = [:]
        for p in fetch(FetchDescriptor<Post>(predicate: #Predicate { postIDs.contains($0.postID) })) { posts[p.postID] = p }

        var accesses: [String: [PostAccess]] = [:]
        for a in fetch(FetchDescriptor<PostAccess>(predicate: #Predicate { postIDs.contains($0.postID) })) {
            accesses[a.postID, default: []].append(a)
        }

        let creatorIDs = Array(Set(items.map(\.creatorID)))
        var creators: [String: Creator] = [:]
        for c in fetch(FetchDescriptor<Creator>(predicate: #Predicate { creatorIDs.contains($0.creatorID) })) { creators[c.creatorID] = c }

        var activeFee: [String: Int] = [:]
        for s in supports(accountID: accountID) where s.isActive { activeFee[s.creatorID] = s.amount }
        let owned = ownedCreatorAccountMap()

        for item in items {
            // Creator row from the summary.
            let creator: Creator
            if let c = creators[item.creatorID] {
                creator = c
                if !item.creatorName.isEmpty && c.name != item.creatorName { c.name = item.creatorName }
                if let icon = item.creatorIconURL, c.iconURL != icon { c.iconURL = icon }
                if let pid = item.pixivUserID, c.pixivUserID != pid { c.pixivUserID = pid }
            } else {
                creator = Creator(creatorID: item.creatorID, name: item.creatorName.isEmpty ? item.creatorID : item.creatorName,
                                  pixivUserID: item.pixivUserID, iconURL: item.creatorIconURL, updatedAt: now)
                context.insert(creator)
                creators[item.creatorID] = creator
            }
            if !creator.hasKnownPosts { creator.hasKnownPosts = true }
            if creator.latestPostAt.map({ $0 < item.publishedAt }) ?? true { creator.latestPostAt = item.publishedAt }
            if let owner = owned[item.creatorID], creator.ownedByAccountID != owner { creator.ownedByAccountID = owner }

            // Post (deduplicated by postID).
            let post: Post
            if let p = posts[item.id] {
                post = p
                if !result.updatedIDs.contains(item.id) && !result.insertedIDs.contains(item.id) { result.updatedIDs.append(item.id) }
            } else {
                post = Post(postID: item.id, creatorID: item.creatorID, creatorName: item.creatorName, title: item.title,
                            excerpt: item.excerpt, type: item.type, feeRequired: item.feeRequired, coverImageURL: item.coverImageURL,
                            publishedAt: item.publishedAt, updatedAt: item.updatedAt, fetchedAt: now)
                context.insert(post)
                posts[item.id] = post
                result.insertedIDs.append(item.id)
            }
            applySummary(item, to: post, accountID: accountID)
            post.fetchedAt = now

            // PostAccess per (post, account).
            var list = accesses[item.id] ?? []
            let access: PostAccess
            if let a = list.first(where: { $0.accountID == accountID }) {
                access = a
            } else {
                access = PostAccess(postID: item.id, accountID: accountID, canView: !item.isRestricted, feeRequired: item.feeRequired,
                                    fetchedAt: now)
                context.insert(access)
                list.append(access)
                accesses[item.id] = list
            }
            access.canView = source == .managed ? true : !item.isRestricted
            access.feeRequired = item.feeRequired
            access.accountPlanFee = activeFee[item.creatorID]
            access.fetchedAt = now
            let viewers = list.filter(\.canView).map(\.accountID).sorted()
            if post.accessAccountIDs.sorted() != viewers { post.accessAccountIDs = viewers }

            if source != nil, !post.seenByAccountIDs.contains(accountID) { post.seenByAccountIDs.append(accountID) }

            // Feed-origin flags. Upserts only raise them; applySupports / applyFollowing lower them when the relation ends.
            if source == .supporting || creator.isSupported || activeFee[item.creatorID] != nil {
                if !post.isFromSupportedCreator { post.isFromSupportedCreator = true }
            }
            if source == .home || creator.isFollowed {
                if !post.isFromFollowedCreator { post.isFromFollowedCreator = true }
            }
            // Own post: listed in Creator Mode, or its creator page belongs to one of my accounts. Only raised here.
            if (source == .managed || owned[item.creatorID] != nil) && !post.isOwnPost { post.isOwnPost = true }
            if source == .managed, creator.ownedByAccountID == nil { creator.ownedByAccountID = accountID }
        }
        save()
        return result
    }

    /// Remote-owned fields only. isRead / isFavorite / isReadLater / memo / offlineState / lastViewedAt are NEVER touched.
    fileprivate func applySummary(_ item: RemotePostSummary, to post: Post, accountID: String) {
        if post.creatorID != item.creatorID { post.creatorID = item.creatorID }
        if !item.creatorName.isEmpty { post.creatorName = item.creatorName }
        if let icon = item.creatorIconURL { post.creatorIconURL = icon }
        if !item.title.isEmpty || post.title.isEmpty { post.title = item.title }
        // A restricted listing may carry a shorter excerpt; keep the richer one.
        if !item.excerpt.isEmpty && (!item.isRestricted || post.excerpt.isEmpty) { post.excerpt = item.excerpt }
        if item.type != .unknown || post.type == .unknown { post.type = item.type }
        post.feeRequired = item.feeRequired
        if let cover = item.coverImageURL { post.coverImageURL = cover }
        post.publishedAt = item.publishedAt
        post.updatedAt = item.updatedAt
        if post.fanboxTags != item.tags { post.fanboxTags = item.tags }
        let tagsText = SearchService.tagsSearchText(item.tags)
        if post.fanboxTagsText != tagsText { post.fanboxTagsText = tagsText }
        post.likeCount = item.likeCount
        post.commentCount = max(item.commentCount, 0)
        // isLiked is per account on FANBOX; follow the account whose body we show (or the first one seen).
        if post.detailAccountID == nil || post.detailAccountID == accountID { post.isLiked = item.isLiked }
        post.hasAdultContent = item.hasAdultContent
    }

    /// Replaces PostBlocks in place: rows keyed "postID#index" are reused, extra rows deleted.
    fileprivate func replaceBlocks(of post: Post, with blocks: [RemoteBlock]) {
        let postID = post.postID
        var existing: [Int: PostBlock] = [:]
        for b in fetch(FetchDescriptor<PostBlock>(predicate: #Predicate { $0.postID == postID })) {
            if existing[b.index] != nil { context.delete(b) } else { existing[b.index] = b }
        }
        let encoder = JSONEncoder()
        for (index, r) in blocks.enumerated() {
            let block: PostBlock
            if let b = existing.removeValue(forKey: index) {
                block = b
            } else {
                block = PostBlock(postID: postID, index: index, kind: r.kind)
                context.insert(block)
            }
            block.kind = r.kind
            block.text = r.text
            block.stylesJSON = r.styles.isEmpty ? nil : (try? encoder.encode(r.styles)).flatMap { String(data: $0, encoding: .utf8) }
            block.mediaID = r.mediaID
            block.thumbnailURL = r.thumbnailURL
            block.displayURL = r.displayURL
            block.originalURL = r.originalURL
            block.width = r.width
            block.height = r.height
            block.fileName = r.fileName
            block.fileExtension = r.fileExtension
            block.fileSize = r.fileSize
            block.url = r.url
            block.embedProvider = r.embedProvider
            block.embedContentID = r.embedContentID
            block.title = r.title
            block.subtitle = r.subtitle
            if block.post == nil { block.post = post }
        }
        for (_, stale) in existing { context.delete(stale) }
    }

    fileprivate func upsertMedia(for post: Post, blocks: [RemoteBlock]) {
        var wanted: [(String, MediaKind, RemoteBlock)] = []
        for (index, b) in blocks.enumerated() {
            let kind: MediaKind
            switch b.kind {
            case .image: kind = .image
            case .file: kind = .file
            case .audio: kind = .audio
            case .video: kind = .video
            default: continue
            }
            // External videos (YouTube etc.) are links, not media files.
            if b.embedProvider != nil && b.originalURL == nil && b.displayURL == nil { continue }
            guard b.mediaID != nil || b.originalURL != nil || b.displayURL != nil || b.thumbnailURL != nil else { continue }
            wanted.append((b.mediaID ?? "\(post.postID)#\(index)", kind, b))
        }
        guard !wanted.isEmpty else { return }
        let ids = wanted.map(\.0)
        var known: [String: Media] = [:]
        for m in fetch(FetchDescriptor<Media>(predicate: #Predicate { ids.contains($0.id) })) { known[m.id] = m }
        for (id, kind, b) in wanted {
            let m: Media
            if let existing = known[id] {
                m = existing
            } else {
                m = Media(id: id, kind: kind, postID: post.postID, creatorID: post.creatorID)
                context.insert(m)
                known[id] = m
            }
            m.kind = kind
            m.postID = post.postID
            m.creatorID = post.creatorID
            m.thumbnailURL = b.thumbnailURL ?? m.thumbnailURL
            m.displayURL = b.displayURL ?? m.displayURL
            m.originalURL = b.originalURL ?? m.originalURL
            m.fileName = b.fileName.map { name in b.fileExtension.map { ext in name.hasSuffix(".\(ext)") ? name : "\(name).\(ext)" } ?? name }
                ?? m.fileName
            m.fileSize = b.fileSize ?? m.fileSize
            m.width = b.width ?? m.width
            m.height = b.height ?? m.height
        }
    }

    @discardableResult
    fileprivate func upsertCommentsCore(_ comments: [RemoteComment], postID: String, account: AccountContext,
                                        forceOwnPostCreatorID: String?, forceOwn: Bool) -> [String] {
        // Flatten nested replies, filling parent / root ids that the listing leaves implicit.
        var flat: [RemoteComment] = []
        func walk(_ c: RemoteComment, parent: String?, root: String?) {
            var copy = c
            if copy.postID.isEmpty { copy.postID = postID }
            if copy.parentCommentID == nil { copy.parentCommentID = parent }
            if copy.rootCommentID == nil { copy.rootCommentID = root }
            flat.append(copy)
            for r in c.replies { walk(r, parent: c.id, root: copy.rootCommentID ?? c.id) }
        }
        for c in comments { walk(c, parent: nil, root: nil) }
        guard !flat.isEmpty else { return [] }

        let localUserIDs = Set(accounts(includeDisabled: true).compactMap(\.pixivUserID))
        let owned = ownedCreatorAccountMap()
        let postCreatorID = post(id: postID)?.creatorID ?? forceOwnPostCreatorID
        let onOwnPost = forceOwnPostCreatorID != nil || postCreatorID.map { owned[$0] != nil } == true

        let ids = Array(Set(flat.map(\.id)))
        var known: [String: Comment] = [:]
        for c in fetch(FetchDescriptor<Comment>(predicate: #Predicate { ids.contains($0.commentID) })) { known[c.commentID] = c }

        var inserted: [String] = []
        let now = Date.now
        for r in flat {
            let isOwn = forceOwn || r.isOwn || localUserIDs.contains(r.authorUserID)
            let c: Comment
            if let existing = known[r.id] {
                c = existing
            } else {
                c = Comment(commentID: r.id, postID: r.postID, fetchedByAccountID: account.accountID, authorUserID: r.authorUserID,
                            authorName: r.authorName, body: r.body, createdAt: r.createdAt, parentCommentID: r.parentCommentID,
                            rootCommentID: r.rootCommentID, fetchedAt: now)
                // New comments from others on my own posts start unread (Creator Mode 未読). Existing isRead is kept.
                c.isRead = isOwn || !onOwnPost
                context.insert(c)
                known[r.id] = c
                inserted.append(r.id)
            }
            c.postID = r.postID
            c.creatorID = postCreatorID ?? c.creatorID
            c.parentCommentID = r.parentCommentID ?? c.parentCommentID
            c.rootCommentID = r.rootCommentID ?? c.rootCommentID
            c.authorUserID = r.authorUserID
            if !r.authorName.isEmpty { c.authorName = r.authorName }
            c.authorIconURL = r.authorIconURL ?? c.authorIconURL
            c.body = r.body
            c.createdAt = r.createdAt
            c.likeCount = r.likeCount
            c.isLiked = r.isLiked
            c.isOwn = isOwn
            c.isOnOwnPost = onOwnPost
            c.fetchedAt = now
            if forceOwn { c.isRead = true }
        }
        save()
        return inserted
    }

    @discardableResult
    fileprivate func ensureCreator(id: String, name: String, iconURL: String?, pixivUserID: String?) -> Creator {
        if let c = creator(id: id) {
            if !name.isEmpty && c.name != name && name != id { c.name = name }
            if let iconURL, c.iconURL != iconURL { c.iconURL = iconURL }
            if let pixivUserID, c.pixivUserID != pixivUserID { c.pixivUserID = pixivUserID }
            return c
        }
        let c = Creator(creatorID: id, name: name.isEmpty ? id : name, pixivUserID: pixivUserID, iconURL: iconURL)
        if let owner = ownedCreatorAccountMap()[id] { c.ownedByAccountID = owner }
        context.insert(c)
        return c
    }

    fileprivate func applyProfile(_ r: RemoteCreator, to c: Creator) {
        if !r.name.isEmpty { c.name = r.name }
        c.pixivUserID = r.pixivUserID ?? c.pixivUserID
        c.iconURL = r.iconURL ?? c.iconURL
        c.coverImageURL = r.coverImageURL ?? c.coverImageURL
        if !r.profileText.isEmpty || c.profileText.isEmpty { c.profileText = r.profileText }
        if !r.profileLinks.isEmpty && c.profileLinks != r.profileLinks { c.profileLinks = r.profileLinks }
        c.hasAdultContent = r.hasAdultContent
        if let owner = ownedCreatorAccountMap()[r.creatorID] { c.ownedByAccountID = owner }
        c.fetchedAt = .now
        c.updatedAt = .now
    }

    fileprivate func upsertPlanRow(planID: String, creatorID: String, title: String, fee: Int, description: String?, coverImageURL: String?,
                                   hasAdultContent: Bool?, sortOrder: Int?) {
        let plan: Plan
        if let p = first(#Predicate<Plan> { $0.planID == planID }) {
            plan = p
        } else {
            plan = Plan(planID: planID, creatorID: creatorID, title: title, fee: fee)
            context.insert(plan)
        }
        plan.creatorID = creatorID
        if !title.isEmpty { plan.title = title }
        plan.fee = fee
        if let description, !description.isEmpty { plan.planDescription = description }
        plan.coverImageURL = coverImageURL ?? plan.coverImageURL
        if let hasAdultContent { plan.hasAdultContent = hasAdultContent }
        if let sortOrder { plan.sortOrder = sortOrder }
        plan.updatedAt = .now
    }

    /// Re-derives feed flags of all posts of the given creators from the Creator relation flags.
    fileprivate func refreshPostFeedFlags(creatorIDs: Set<String>) {
        for creatorID in creatorIDs {
            guard let c = creator(id: creatorID) else { continue }
            for p in fetch(FetchDescriptor<Post>(predicate: #Predicate { $0.creatorID == creatorID })) {
                if p.isFromSupportedCreator != c.isSupported { p.isFromSupportedCreator = c.isSupported }
                if p.isFromFollowedCreator != c.isFollowed { p.isFromFollowedCreator = c.isFollowed }
            }
        }
    }

    fileprivate func refreshAccountPlanFees(accountID: String, creatorIDs: Set<String>, fee: (String) -> Int?) {
        for creatorID in creatorIDs {
            let postIDs = fetch(FetchDescriptor<Post>(predicate: #Predicate { $0.creatorID == creatorID })).map(\.postID)
            guard !postIDs.isEmpty else { continue }
            let keys = postIDs.map { PostAccess.key(postID: $0, accountID: accountID) }
            let value = fee(creatorID)
            for a in fetch(FetchDescriptor<PostAccess>(predicate: #Predicate { keys.contains($0.key) })) where a.accountPlanFee != value {
                a.accountPlanFee = value
            }
        }
    }

    fileprivate static func yenText(_ amount: Int?) -> String {
        guard let amount else { return "—" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "ja_JP")
        return "¥" + (f.string(from: NSNumber(value: amount)) ?? "\(amount)")
    }
}

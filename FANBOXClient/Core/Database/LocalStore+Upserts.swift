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

    /// Metadata of one post without a body (post.get, when post.info is edge-blocked): updates the summary and the
    /// account's PostAccess, never the cached body, and does not count as a feed listing.
    func upsertPostMetadata(_ summary: RemotePostSummary, account: AccountContext) {
        upsertSummariesCore([summary], account: account, source: nil)
        save()
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

    /// Post metadata without a body (post.get fallback): updates title / excerpt / counts, never touches a cached body.

    // MARK: - Creators

    func upsertCreator(_ creator: RemoteCreator, account: AccountContext?) {
        let row = ensureCreator(id: creator.creatorID, name: creator.name, iconURL: creator.iconURL, pixivUserID: creator.pixivUserID)
        applyProfile(creator, to: row)
        if let account, let followed = creator.isFollowed {
            var set = row.followedByAccountIDs
            if followed { if !set.contains(account.accountID) { set.append(account.accountID) } } else { set.removeAll { $0 == account.accountID } }
            if set != row.followedByAccountIDs { row.followedByAccountIDs = set }
            let wasFollowed = row.isFollowed
            let enabled = enabledAccountIDs()
            row.isFollowed = set.contains(where: enabled.contains)
            if wasFollowed != row.isFollowed { refreshPostFeedFlags(creatorIDs: [row.creatorID]) }
        }
        save()
    }

    /// Replaces the "followed by <account>" set with `creators`.
    func applyFollowing(_ creators: [RemoteCreator], account: AccountContext) {
        let accountID = account.accountID
        let followedIDs = Set(creators.map(\.creatorID))
        let enabled = enabledAccountIDs()
        var changedFollow: Set<String> = []

        for remote in creators {
            let row = ensureCreator(id: remote.creatorID, name: remote.name, iconURL: remote.iconURL, pixivUserID: remote.pixivUserID)
            applyProfile(remote, to: row)
            if !row.followedByAccountIDs.contains(accountID) {
                row.followedByAccountIDs.append(accountID)
            }
            let now = row.followedByAccountIDs.contains(where: enabled.contains)
            if now != row.isFollowed { row.isFollowed = now; changedFollow.insert(row.creatorID) }
        }
        // `isSupported && isStopped` → 停止予定 on this account's Support rows (SPEC §10.3 来月予定).
        applyStopObservations(creators, account: account)
        // Creators this account no longer follows (array property → filter in memory).
        for row in fetch(FetchDescriptor<Creator>()) where !followedIDs.contains(row.creatorID) && row.followedByAccountIDs.contains(accountID) {
            row.followedByAccountIDs.removeAll { $0 == accountID }
            let now = row.followedByAccountIDs.contains(where: enabled.contains)
            if now != row.isFollowed { row.isFollowed = now; changedFollow.insert(row.creatorID) }
        }
        if !changedFollow.isEmpty { refreshPostFeedFlags(creatorIDs: changedFollow) }
        save()
    }

    /// Re-derives `Creator.isSupported` / `isFollowed` from the account id arrays, counting enabled accounts only, and the
    /// feed flags of the posts of every creator whose flags changed. Called at launch and when an account is enabled or
    /// disabled: the disabled account's relations stay stored (re-enabling shows them again) but no longer count anywhere.
    func refreshRelationFlags() {
        let enabled = enabledAccountIDs()
        var changed: Set<String> = []
        for creator in fetch(FetchDescriptor<Creator>()) {
            let supported = creator.supportedByAccountIDs.contains(where: enabled.contains)
            let followed = creator.followedByAccountIDs.contains(where: enabled.contains)
            if creator.isSupported != supported { creator.isSupported = supported; changed.insert(creator.creatorID) }
            if creator.isFollowed != followed { creator.isFollowed = followed; changed.insert(creator.creatorID) }
        }
        if !changed.isEmpty { refreshPostFeedFlags(creatorIDs: changed) }
        save()
    }

    // MARK: - Supports (SPEC §10 / §11 / §13 / §15)

    /// Observed-fact-only reason for supports FANBOX lists as unpaid (docs/API.md §12.2). Never asserts a payment failure.
    static let paymentAttentionReason = "決済状態を確認できません（FANBOXで未払いの項目が表示されています）"
    /// Earlier spellings of `paymentAttentionReason` still stored in `Support.attentionReason`.
    static let legacyPaymentAttentionReasons: Set<String> = ["決済状態を確認できません（FANBOX で未払いの項目が表示されています）"]

    /// True for the unpaid flag's reason, current or earlier spelling (the reason is stored and recognised by value).
    static func isPaymentAttentionReason(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return reason == paymentAttentionReason || legacyPaymentAttentionReasons.contains(reason)
    }

    /// Sub-scope of the supports SyncState that remembers a pending "everything disappeared at once" observation.
    static let massDisappearanceScope = "massDisappearance"
    /// A mass disappearance must be seen again within this window to be recorded (two-strike rule).
    static let massDisappearanceConfirmWindow: TimeInterval = 3 * 24 * 60 * 60

    /// Applies the account's current supporting plans, records SupportHistory and flags anomalies.
    @discardableResult
    func applySupports(_ supports: [RemoteSupport], account: AccountContext, source: ObservedSource,
                       isBaseline: Bool = false, listingIsComplete: Bool = true) -> SupportDiff {
        applySupportsDetailed(supports, account: account, source: source, isBaseline: isBaseline, listingIsComplete: listingIsComplete).diff
    }

    /// Same as `applySupports` but also returns the SupportHistory rows created by this call.
    /// - `isBaseline`: the account's first successful supports sync. Supports found then are imported without a
    ///   "支援開始" history row (their real start date is unknown; SPEC §11 records observed changes only).
    /// - `listingIsComplete == false`: the listing could not be read completely (shape drift). Listed supports are
    ///   upserted, but nothing is marked as disappeared.
    /// - When every previously active support (2 or more) vanishes at once, the disappearance is recorded only if the
    ///   next sync observes it again (a single suspicious empty listing is not an observed fact).
    func applySupportsDetailed(_ supports: [RemoteSupport], account: AccountContext, source: ObservedSource,
                               isBaseline: Bool = false, listingIsComplete: Bool = true) -> (diff: SupportDiff, history: [SupportHistory]) {
        let accountID = account.accountID
        let now = Date.now
        var diff = SupportDiff()
        var history: [SupportHistory] = []
        var existing: [String: Support] = [:]
        for s in self.supports(accountID: accountID) { existing[s.creatorID] = s }
        let previouslyActive = Set(existing.filter { $0.value.status == .active }.map(\.key))

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

        /// Creators whose user-verified payment assignment is contradicted by this observation (SPEC §13).
        var contradicted: Set<String> = []

        for creatorID in order {
            guard let r = remoteByCreator[creatorID] else { continue }
            let planID: String? = r.planID.isEmpty ? nil : r.planID
            if let s = existing[creatorID] {
                let previousMethod = s.reportedPaymentMethod
                switch s.status {
                case .active:
                    if s.planID != planID || s.amount != r.fee {
                        record(.planChanged, creatorID: creatorID, creatorName: r.creatorName, oldPlanID: s.planID, newPlanID: planID,
                               oldPlan: s.planTitle, newPlan: r.planTitle, oldAmount: s.amount, newAmount: r.fee)
                        diff.changed.append(creatorID)
                        if s.planID != planID { contradicted.insert(creatorID) }
                    }
                case .missing:
                    record(.restored, creatorID: creatorID, creatorName: r.creatorName, oldPlanID: s.planID, newPlanID: planID,
                           oldPlan: s.planTitle, newPlan: r.planTitle, oldAmount: s.amount, newAmount: r.fee)
                    diff.restored.append(creatorID)
                    contradicted.insert(creatorID)
                case .ended, .unknown:
                    if !isBaseline {
                        record(.started, creatorID: creatorID, creatorName: r.creatorName, oldPlanID: s.planID, newPlanID: planID,
                               oldPlan: s.planTitle, newPlan: r.planTitle, oldAmount: s.amount, newAmount: r.fee)
                    }
                    diff.started.append(creatorID)
                    contradicted.insert(creatorID)
                }
                if let method = r.paymentMethod, let previousMethod,
                   method.caseInsensitiveCompare(previousMethod) != .orderedSame {
                    contradicted.insert(creatorID)
                }
                if s.status != .active {
                    // A restored / restarted support starts clean: a later disappearance is a NEW anomaly for 要確認.
                    s.missingSince = nil
                    if !Self.isPaymentAttentionReason(s.attentionReason) {
                        s.needsAttention = false
                        s.attentionReason = nil
                        s.acknowledgedAt = nil
                    }
                } else if s.needsAttention, s.attentionReason == Self.supportMissingReason {
                    s.needsAttention = false
                    s.attentionReason = nil
                    s.acknowledgedAt = nil
                }
                if s.status != .active {
                    // A new support period: stop signals of the previous one no longer apply.
                    s.stoppingObservedAt = nil
                    s.userStopMarkedAt = nil
                }
                s.status = .active
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
                if !isBaseline {
                    record(.started, creatorID: creatorID, creatorName: r.creatorName, oldPlanID: nil, newPlanID: planID,
                           oldPlan: nil, newPlan: r.planTitle, oldAmount: nil, newAmount: r.fee)
                }
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
                if contradicted.contains(creatorID) { downgradeVerification(a, now: now) }
            } else {
                context.insert(SupportPaymentAssignment(accountID: accountID, creatorID: creatorID, planID: planID, paymentProfileID: nil,
                                                        verificationState: .unknown, updatedAt: now))
            }

            ensureCreator(id: creatorID, name: r.creatorName, iconURL: r.creatorIconURL, pixivUserID: r.pixivUserID)
        }

        // Previously active supports that are no longer returned: observed fact only, never an asserted cause.
        let disappearing = previouslyActive.filter { remoteByCreator[$0] == nil }.sorted()
        // Only a complete listing can show that something is gone. Stops that FANBOX reported (isStopped) or that the
        // user recorded end the support (支援終了) instead of raising an anomaly (SPEC §10.3 / §15).
        var unexplained: [String] = []
        if listingIsComplete {
            for creatorID in disappearing {
                guard let s = existing[creatorID] else { continue }
                if Self.explainedStop(s, now: now) != nil {
                    markEndedByStop(s, now: now, source: source, recordHistory: false)
                    record(.ended, creatorID: creatorID, creatorName: s.creatorName, oldPlanID: s.planID, newPlanID: nil,
                           oldPlan: s.planTitle, newPlan: nil, oldAmount: s.amount, newAmount: nil)
                    diff.ended.append(creatorID)
                } else {
                    unexplained.append(creatorID)
                }
            }
        }
        if listingIsComplete, !unexplained.isEmpty, confirmDisappearance(unexplained, previouslyActive: previouslyActive,
                                                                           accountID: accountID, now: now) {
            for creatorID in unexplained {
                guard let s = existing[creatorID] else { continue }
                s.status = .missing
                s.missingSince = now
                s.needsAttention = true
                s.attentionReason = Self.supportMissingReason
                // A new disappearance is a new anomaly even if an earlier one was acknowledged (SPEC §15).
                s.acknowledgedAt = nil
                record(.disappeared, creatorID: creatorID, creatorName: s.creatorName, oldPlanID: s.planID, newPlanID: nil,
                       oldPlan: s.planTitle, newPlan: nil, oldAmount: s.amount, newAmount: nil)
                diff.disappeared.append(creatorID)
                let assignmentKey = Support.key(accountID: accountID, creatorID: creatorID)
                if let a = first(#Predicate<SupportPaymentAssignment> { $0.key == assignmentKey }) { downgradeVerification(a, now: now) }
            }
        } else if listingIsComplete, unexplained.isEmpty {
            clearMassDisappearanceStrike(accountID: accountID)
        }

        // Denormalize supportedByAccountIDs / isSupported on Creator and the per-account plan fee on PostAccess.
        // isSupported counts enabled accounts only (a disabled account's supports stay stored but hidden).
        let affected = Set(existing.keys).union(remoteByCreator.keys)
        let enabled = enabledAccountIDs()
        var supportFlagChanged: Set<String> = []
        for creatorID in affected {
            let isActive = existing[creatorID]?.status == .active || remoteByCreator[creatorID] != nil
            let name = remoteByCreator[creatorID]?.creatorName ?? existing[creatorID]?.creatorName ?? creatorID
            let creator = ensureCreator(id: creatorID, name: name, iconURL: nil, pixivUserID: nil)
            var set = creator.supportedByAccountIDs
            if isActive { if !set.contains(accountID) { set.append(accountID) } } else { set.removeAll { $0 == accountID } }
            if set != creator.supportedByAccountIDs { creator.supportedByAccountIDs = set }
            let supported = set.contains(where: enabled.contains)
            if creator.isSupported != supported { creator.isSupported = supported; supportFlagChanged.insert(creatorID) }
        }
        let feeChanged = Set(diff.observedCreatorIDs)
        if !feeChanged.isEmpty {
            refreshAccountPlanFees(accountID: accountID, creatorIDs: feeChanged,
                                   fee: { cid in existing[cid].flatMap { $0.isActive ? $0.amount : nil } })
        }
        if !supportFlagChanged.isEmpty { refreshPostFeedFlags(creatorIDs: supportFlagChanged) }
        save()
        return (diff, history)
    }

    /// Two-strike rule for "every active support (2+) vanished at once": the first observation is remembered, and only a
    /// second consecutive observation of the same set within `massDisappearanceConfirmWindow` is recorded.
    private func confirmDisappearance(_ disappearing: [String], previouslyActive: Set<String>, accountID: String, now: Date) -> Bool {
        guard disappearing.count >= 2, disappearing.count == previouslyActive.count else {
            clearMassDisappearanceStrike(accountID: accountID)
            return true
        }
        let strike = syncState(accountID: accountID, resource: .supports, scope: Self.massDisappearanceScope)
        let marker = disappearing.joined(separator: ",")
        if strike.lastKnownItemID == marker, let first = strike.lastAttemptAt,
           now.timeIntervalSince(first) <= Self.massDisappearanceConfirmWindow {
            strike.lastKnownItemID = nil
            strike.lastAttemptAt = nil
            strike.error = nil
            return true
        }
        strike.lastKnownItemID = marker
        strike.lastAttemptAt = now
        strike.error = "全ての支援が一覧から消えました（次回の同期で再確認します）"
        AppLog.sync.notice("supports: every active support missing in one listing; waiting for a second observation")
        return false
    }

    private func clearMassDisappearanceStrike(accountID: String) {
        let key = SyncState.key(accountID: accountID, resource: .supports, scope: Self.massDisappearanceScope)
        if let strike = first(#Predicate<SyncState> { $0.key == key }), strike.lastKnownItemID != nil {
            strike.lastKnownItemID = nil
            strike.lastAttemptAt = nil
            strike.error = nil
        }
    }

    /// A user verification is no longer trusted once FANBOX shows a different plan / payment method, or the support
    /// disappeared or restarted: it drops back to "manual" (the chosen profile is kept, the verified date is cleared).
    private func downgradeVerification(_ a: SupportPaymentAssignment, now: Date) {
        guard a.verificationState == .verified else { return }
        a.verificationState = .manual
        a.lastVerifiedAt = nil
        a.updatedAt = now
    }

    /// Result of applying observed payment signals.
    struct PaymentStatusChange: Equatable {
        /// The account flag switched from "not unpaid" (observed false) to "unpaid".
        var becameUnpaid = false
        /// No earlier observation existed (baseline: flags are stored, nothing is announced).
        var firstObservation = false
        /// Supports newly flagged by this call (creator ids, sorted).
        var newlyFlaggedCreatorIDs: [String] = []
    }

    /// Applies observed payment signals (docs/API.md §2.14 / §12.2) to the account and its supports.
    /// Supports of creators listed as unpaid get `paymentAttentionReason` (observed fact only, SPEC §15); the flag is lifted
    /// again once FANBOX no longer lists them.
    @discardableResult
    func applyPaymentStatus(_ status: RemotePaymentStatus, account: AccountContext, now: Date = .now) -> PaymentStatusChange {
        var change = PaymentStatusChange()
        guard let row = self.account(id: account.accountID) else { return change }
        let previous = row.hasUnpaidPayments
        let indicates = status.indicatesUnpaid
        change.firstObservation = previous == nil
        change.becameUnpaid = previous == false && indicates == true
        if let indicates { row.hasUnpaidPayments = indicates }
        row.unpaidPaymentsCheckedAt = now

        if let records = status.unpaidRecords {
            let unpaidCreators = Set(records.compactMap(\.creatorID).filter { !$0.isEmpty })
            for s in supports(accountID: account.accountID) {
                let flagged = s.needsAttention && Self.isPaymentAttentionReason(s.attentionReason)
                if unpaidCreators.contains(s.creatorID) {
                    if flagged {
                        // Same flag in an earlier spelling: reworded only, the acknowledgment stays.
                        if s.attentionReason != Self.paymentAttentionReason { s.attentionReason = Self.paymentAttentionReason }
                    } else {
                        // Keep a disappearance reason if one is pending: it is the stronger observed fact.
                        if !(s.needsAttention && s.attentionReason == Self.supportMissingReason) {
                            s.needsAttention = true
                            s.attentionReason = Self.paymentAttentionReason
                            s.acknowledgedAt = nil
                        }
                        change.newlyFlaggedCreatorIDs.append(s.creatorID)
                    }
                } else if Self.isPaymentAttentionReason(s.attentionReason) {
                    s.needsAttention = false
                    s.attentionReason = nil
                }
            }
        } else if indicates == false {
            for s in supports(accountID: account.accountID) where Self.isPaymentAttentionReason(s.attentionReason) {
                s.needsAttention = false
                s.attentionReason = nil
            }
        }
        change.newlyFlaggedCreatorIDs.sort()
        save()
        return change
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
        upsertCommentsCore(comments, postID: postID, account: account, forceOwnPostCreatorID: nil, forceOwn: false, readCutoff: nil)
    }

    /// Upserts and returns the ids of comments that were not known before.
    /// `readCutoff`: comments by others on my own posts created at or before this date are imported as read (history
    /// discovered late is not "未読"), unless an unread notification points at them. nil = every new one is unread.
    @discardableResult
    func upsertCommentsReturningNew(_ comments: [RemoteComment], postID: String, account: AccountContext,
                                    readCutoff: Date? = nil) -> [String] {
        upsertCommentsCore(comments, postID: postID, account: account, forceOwnPostCreatorID: nil, forceOwn: false, readCutoff: readCutoff)
    }

    /// Comments on my own creator posts (Creator Mode listing). Groups by post. See `upsertCommentsReturningNew` for `readCutoff`.
    @discardableResult
    func upsertCreatorComments(_ comments: [RemoteComment], account: AccountContext, readCutoff: Date? = nil) -> [String] {
        var byPost: [String: [RemoteComment]] = [:]
        var order: [String] = []
        for c in comments {
            if byPost[c.postID] == nil { order.append(c.postID) }
            byPost[c.postID, default: []].append(c)
        }
        var inserted: [String] = []
        for postID in order {
            inserted += upsertCommentsCore(byPost[postID] ?? [], postID: postID, account: account,
                                           forceOwnPostCreatorID: account.creatorID, forceOwn: false, readCutoff: readCutoff)
        }
        return inserted
    }

    /// A comment my account just posted (reply queue): visible locally immediately, marked own + read.
    func upsertOwnComment(_ comment: RemoteComment, account: AccountContext) {
        let inserted = upsertCommentsCore([comment], postID: comment.postID, account: account, forceOwnPostCreatorID: nil, forceOwn: true,
                                          readCutoff: nil)
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

    /// Events older than this are not kept in the inbox (see `maintenancePruneNotificationEvents`); unknown remote items
    /// older than this are not (re)imported, so a pruned event never comes back as "new".
    static let notificationRetention: TimeInterval = 90 * 24 * 60 * 60
    /// Two comment notifications from different accounts within this interval (same post, text and author) are one event.
    static let commentEventMergeWindow: TimeInterval = 120

    /// Returns ids of NotificationEvents that are new (not previously known).
    @discardableResult
    func upsertNotifications(_ items: [RemoteNotification], account: AccountContext, now: Date = .now) -> [String] {
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
        let horizon = now.addingTimeInterval(-Self.notificationRetention)
        var newIDs: [String] = []
        for (key, n) in keyed {
            let remoteRef = "\(accountID):\(n.remoteID)"
            if let e = known[key] ?? sameCommentEvent(as: n, from: accountID) {
                known[key] = e
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
                if n.isRestricted == false, n.type == .newPost, e.prefetchState == .notNeeded { e.prefetchState = .pending }
                continue
            }
            // Older than the inbox retention: pruned locally on purpose, never re-imported as new.
            if n.createdAt < horizon && n.createdAt > .distantPast { continue }
            let e = NotificationEvent(id: key, type: n.type, accountIDs: [accountID], title: n.title, message: n.message,
                                      timestamp: n.createdAt, creatorID: n.creatorID, postID: n.postID, commentID: n.commentID,
                                      newsletterID: n.newsletterID)
            e.remoteIDs = [remoteRef]
            e.actorName = n.actorName
            e.actorIconURL = n.actorIconURL
            // Already read on FANBOX → do not surface as unread / do not notify again.
            e.isRead = n.isUnread == false
            // A post this account cannot view is not prefetched: post.info would only spend the request budget
            // (docs/API.md §1.8). Another account's unrestricted copy re-arms it below.
            e.prefetchState = n.isRestricted == true && n.type == .newPost ? .notNeeded : .pending
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

    /// FANBOX comment bells carry no comment id (docs/API.md §2.11), so their keys contain the per-account bell id.
    /// The same comment notified to another local account is recognized by post + text + author + time instead (SPEC §27).
    private func sameCommentEvent(as n: RemoteNotification, from accountID: String) -> NotificationEvent? {
        guard n.type == .comment || n.type == .commentReply, n.commentID == nil, let postID = n.postID else { return nil }
        let candidates = fetch(FetchDescriptor<NotificationEvent>(predicate: #Predicate { $0.postID == postID }))
        // A bell merged into another account's event earlier is recognized by its remote reference.
        let remoteRef = "\(accountID):\(n.remoteID)"
        if let merged = candidates.first(where: { $0.remoteIDs.contains(remoteRef) }) { return merged }
        let body = n.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return candidates.first { e in
            (e.type == .comment || e.type == .commentReply)
                && !e.accountIDs.contains(accountID)
                && e.message.trimmingCharacters(in: .whitespacesAndNewlines) == body
                && e.actorName == n.actorName
                && abs(e.timestamp.timeIntervalSince(n.createdAt)) <= Self.commentEventMergeWindow
        }
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
                                      title: "\(n.creatorName)からおたより", message: n.title ?? String(n.body.prefix(80)),
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
            case .started: fact = "支援開始\(Self.yenText(h.newAmount))"
            case .planChanged: fact = "\(Self.yenText(h.oldAmount)) → \(Self.yenText(h.newAmount))"
            case .ended: fact = "支援終了"
            case .disappeared: fact = Self.supportMissingReason
            case .restored: fact = "支援中一覧に再び表示されました（\(Self.yenText(h.newAmount))）"
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

    /// Why a `.paymentAttention` event was created. Each reason is announced at most once per account / creator / month.
    enum PaymentAttentionTrigger: String, Sendable {
        /// Page metadata `hasUnpaidPayments` switched to true.
        case unpaidFlag
        /// payment.listUnpaid lists the creator.
        case unpaidRecord
        /// A supported plan disappeared during the 1st–5th of the month (docs/API.md §18.8 B).
        case disappearedEarlyInMonth
    }

    /// Creates `.paymentAttention` events (SPEC §24.1 決済要確認, Critical). Observed facts only: the text never states that a
    /// payment failed (SPEC §15). `creatorIDs` empty = one account-level event. Returns the created event ids.
    @discardableResult
    func recordPaymentAttentionEvents(_ trigger: PaymentAttentionTrigger, creatorIDs: [String], account: AccountContext,
                                      accountName: String, now: Date = .now) -> [String] {
        let month = Self.monthKey(now)
        var created: [String] = []
        let targets: [String?] = creatorIDs.isEmpty ? [nil] : creatorIDs.map(Optional.some)
        for creatorID in targets {
            let fallback = "local:\(account.accountID):\(month):\(trigger.rawValue):\(creatorID ?? "account")"
            let key = NotificationEvent.dedupeKey(type: .paymentAttention, creatorID: creatorID, postID: nil, commentID: nil,
                                                  newsletterID: nil, fallbackRemoteID: fallback)
            guard notificationEvent(id: key) == nil else { continue }
            let creatorName = creatorID.flatMap { cid in supports(accountID: account.accountID).first { $0.creatorID == cid }?.creatorName }
                ?? creatorID.flatMap { creator(id: $0)?.name }
            let title = creatorName.map { "\($0)（\(accountName)）" } ?? "決済要確認（\(accountName)）"
            let message: String
            switch trigger {
            case .unpaidFlag:
                message = "FANBOXで未払いの項目があると表示されています。決済状態を確認できません"
            case .unpaidRecord:
                message = Self.paymentAttentionReason
            case .disappearedEarlyInMonth:
                message = "月初（1〜5日）に支援中一覧から消えました。決済状態を確認できません（原因は確認できません）"
            }
            let e = NotificationEvent(id: key, type: .paymentAttention, accountIDs: [account.accountID], title: title, message: message,
                                      timestamp: now, creatorID: creatorID)
            e.prefetchState = .textReady
            context.insert(e)
            created.append(key)
        }
        if !created.isEmpty { save() }
        return created
    }

    /// Creates `.newSupporter` events (SPEC §24.1 Creator 側の新規支援) for supporters newly observed in the fan list.
    @discardableResult
    func recordNewSupporterEvents(userIDs: [String], account: AccountContext, accountName: String, now: Date = .now) -> [String] {
        guard !userIDs.isEmpty else { return [] }
        let accountID = account.accountID
        let keys = userIDs.map { "\(accountID)|\($0)" }
        var fans: [String: Fan] = [:]
        for f in fetch(FetchDescriptor<Fan>(predicate: #Predicate { keys.contains($0.key) })) { fans[f.userID] = f }
        var created: [String] = []
        for userID in userIDs {
            guard let fan = fans[userID] else { continue }
            let started = fan.supportStartedAt.map { String(Int($0.timeIntervalSince1970)) } ?? Self.dayKey(now)
            let key = NotificationEvent.dedupeKey(type: .newSupporter, creatorID: account.creatorID, postID: nil, commentID: nil,
                                                  newsletterID: nil, fallbackRemoteID: "local:\(accountID):\(userID):\(started)")
            guard notificationEvent(id: key) == nil else { continue }
            var detail = ""
            if let plan = fan.planTitle, !plan.isEmpty { detail = "「\(plan)」" }
            if let fee = fan.fee { detail += (detail.isEmpty ? "" : " ") + Self.yenText(fee) }
            let message = detail.isEmpty ? "\(fan.name)さんが支援者一覧に加わりました"
                : "\(fan.name)さんが支援者一覧に加わりました（\(detail)）"
            let e = NotificationEvent(id: key, type: .newSupporter, accountIDs: [accountID], title: "新規支援（\(accountName)）",
                                      message: message, timestamp: fan.supportStartedAt.map { min($0, now) } ?? now,
                                      creatorID: account.creatorID)
            e.actorName = fan.name
            e.actorIconURL = fan.iconURL
            e.prefetchState = .textReady
            context.insert(e)
            created.append(key)
        }
        if !created.isEmpty { save() }
        return created
    }

    static func monthKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Day of month in Japan time (FANBOX bills on the 1st; docs/API.md §18.8 B uses the 1st–5th window).
    static func dayOfMonthJST(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return calendar.component(.day, from: date)
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
                if item.isAmountReported {
                    p.amount = item.amount
                    p.amountUnknown = nil
                }   // else: keep an amount reported earlier; a record never seen with one stays flagged
                p.paidAt = item.paidAt
                p.reportedPaymentMethod = item.paymentMethod ?? p.reportedPaymentMethod
                p.fetchedAt = now
            } else {
                let p = PaymentRecord(paymentID: item.id, accountID: accountID, creatorID: item.creatorID, creatorName: item.creatorName,
                                      amount: item.isAmountReported ? item.amount : 0, paidAt: item.paidAt,
                                      reportedPaymentMethod: item.paymentMethod, fetchedAt: now)
                if !item.isAmountReported { p.amountUnknown = true }
                context.insert(p)
                known[key] = p
            }
        }
        save()
    }

    /// Upserts fans and returns the user ids that are newly observed as supporters (no row before, or a row that was not
    /// `.supporting`).
    @discardableResult
    func upsertFans(_ fans: [RemoteFan], account: AccountContext) -> [String] {
        let accountID = account.accountID
        var newSupporters: [String] = []
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
                if r.state == .supporting && existing.state != .supporting { newSupporters.append(r.userID) }
            } else {
                f = Fan(accountID: accountID, userID: r.userID, name: r.name, state: r.state, updatedAt: now)
                context.insert(f)
                known[key] = f
                if r.state == .supporting { newSupporters.append(r.userID) }
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
        return newSupporters
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

            // Seen = listed in a feed of this account. Posts embedded in notifications are not a listing (differential feed
            // paging stops at known ids, so marking them seen would skip the feed pages around them).
            if let source, source != .notification, !post.seenByAccountIDs.contains(accountID) { post.seenByAccountIDs.append(accountID) }

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
                                        forceOwnPostCreatorID: String?, forceOwn: Bool, readCutoff: Date?) -> [String] {
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

        // Comments that an unread notification points at stay unread even when imported as history.
        var unreadNotified: Set<String> = []
        if readCutoff != nil, onOwnPost {
            let eventPostIDs = Set(flat.map(\.postID))
            let events = fetch(FetchDescriptor<NotificationEvent>(predicate: #Predicate { !$0.isRead }))
            unreadNotified = Set(events.filter { $0.postID.map(eventPostIDs.contains) == true }.compactMap(\.commentID))
        }

        var inserted: [String] = []
        var insertedOwn: [RemoteComment] = []
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
                // History discovered late (at or before `readCutoff`) is imported as read so a first import does not flood 未読.
                let historical = readCutoff.map { r.createdAt <= $0 } ?? false
                c.isRead = isOwn || !onOwnPost || (historical && !unreadNotified.contains(r.id))
                context.insert(c)
                known[r.id] = c
                inserted.append(r.id)
                if isOwn && !Self.isProvisionalCommentID(r.id) { insertedOwn.append(r) }
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
        if !insertedOwn.isEmpty { reconcileProvisionalComments(with: insertedOwn) }
        save()
        return inserted
    }

    /// Ids FANBOX never issued: the reply queue's placeholder for a sent comment whose real id is not known yet.
    static func isProvisionalCommentID(_ id: String) -> Bool { id.hasPrefix("pending:") }

    /// A real own comment arrived: drop provisional "pending:" copies of it (same post, parent and text) and point
    /// matching sent queue items at the real id, so the reply shows once and deletes use a real id.
    fileprivate func reconcileProvisionalComments(with own: [RemoteComment]) {
        let postIDs = Array(Set(own.map(\.postID)))
        let provisional = fetch(FetchDescriptor<Comment>(predicate: #Predicate { postIDs.contains($0.postID) }))
            .filter { Self.isProvisionalCommentID($0.commentID) }
        let sentRaw = ReplyState.sent.rawValue
        let outgoing = fetch(FetchDescriptor<OutgoingComment>(predicate: #Predicate { postIDs.contains($0.postID) && $0.stateRaw == sentRaw }))
        func normalized(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        for r in own {
            let body = normalized(r.body)
            for p in provisional where p.postID == r.postID && normalized(p.body) == body && p.parentCommentID == r.parentCommentID {
                if let post = post(id: p.postID), post.commentCount > 0 { post.commentCount -= 1 }
                context.delete(p)
            }
            for o in outgoing where o.postID == r.postID && normalized(o.body) == body
                && (o.parentCommentID ?? o.rootCommentID) == (r.parentCommentID ?? r.rootCommentID) {
                if o.sentCommentID == nil || Self.isProvisionalCommentID(o.sentCommentID ?? "") { o.sentCommentID = r.id }
            }
        }
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

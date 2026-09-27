import Foundation
import SwiftData

/// Stop observations for 来月予定 (SPEC §10.3) and the anomaly rules around them (SPEC §15).
/// Rules: `SupportStopRule`. Only existing `Support` rows are touched — the following list carries no plan or fee.
extension LocalStore {
    /// Records FANBOX's `isSupported && isStopped` (creator.listFollowing, docs/API.md §7.2 / §18.10) on this account's
    /// supports. Called by `applyFollowing`; creators without an `isStopped` value are left alone.
    /// - active + stopped → `stoppingObservedAt = now` (excluded from 来月予定 this billing month).
    /// - active + `isSupported && isStopped == false` → the observation is cleared (resumed, or never stopped). A creator
    ///   that is no longer supported (`isSupported == false`, the state after a stop took effect) keeps the observation:
    ///   it is what explains the support leaving plan.listSupporting at month end.
    /// - missing (recent, unexplained) + stopped → the disappearance is explained by FANBOX: recorded as 支援終了 and
    ///   removed from "要確認".
    func applyStopObservations(_ creators: [RemoteCreator], account: AccountContext, now: Date = .now) {
        let flagged = creators.filter { $0.isStopped != nil }
        guard !flagged.isEmpty else { return }
        var rows: [String: Support] = [:]
        for s in supports(accountID: account.accountID) { rows[s.creatorID] = s }
        for creator in flagged {
            guard let s = rows[creator.creatorID] else { continue }
            let stopped = creator.isSupported == true && creator.isStopped == true
            switch s.status {
            case .active:
                if stopped {
                    s.stoppingObservedAt = now
                } else if creator.isSupported == true, creator.isStopped == false, s.stoppingObservedAt != nil {
                    s.stoppingObservedAt = nil
                }
            case .missing:
                guard stopped, SupportStopRule.explainsDisappearance(s.missingSince, now: now) else { continue }
                s.stoppingObservedAt = now
                markEndedByStop(s, now: now, source: account.kind == .demo ? .demo : .sync)
            case .ended, .unknown:
                continue
            }
        }
    }

    /// True when at least one support of the account that is active locally is absent from `listed`
    /// (the next `applySupportsDetailed` would record a disappearance).
    func hasActiveSupports(absentFrom listed: [RemoteSupport], accountID: String) -> Bool {
        let listedIDs = Set(listed.map(\.creatorID))
        return supports(accountID: accountID).contains { $0.isActive && !listedIDs.contains($0.creatorID) }
    }

    /// Stop signal (observed or user-entered) that explains `support` leaving FANBOX's supporting list at `now`.
    static func explainedStop(_ support: Support, now: Date) -> SupportStopSource? {
        if SupportStopRule.explainsDisappearance(support.stoppingObservedAt, now: now) { return .observed }
        if SupportStopRule.explainsDisappearance(support.userStopMarkedAt, now: now) { return .userMarked }
        return nil
    }

    /// Converts a vanished / missing support into 支援終了 because a stop explains it (no "要確認" anomaly) and records a
    /// `.ended` history row. Per-account plan fees / Creator support flags are refreshed by the caller
    /// (`applySupportsDetailed`) or were already refreshed when the support went missing.
    @discardableResult
    func markEndedByStop(_ s: Support, now: Date, source: ObservedSource, recordHistory: Bool = true) -> SupportHistory? {
        s.status = .ended
        s.missingSince = nil
        s.needsAttention = false
        s.attentionReason = nil
        guard recordHistory else { return nil }
        let h = SupportHistory(timestamp: now, creatorID: s.creatorID, creatorName: s.creatorName, accountID: s.accountID,
                               kind: .ended, oldPlanID: s.planID, newPlanID: nil, oldPlan: s.planTitle, newPlan: nil,
                               oldAmount: s.amount, newAmount: nil, observedSource: source)
        context.insert(h)
        return h
    }
}

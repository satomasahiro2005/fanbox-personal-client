import Foundation
import SwiftData

/// Editable, unsaved Payment Profile values. Nothing is persisted until `SupportMutations.saveProfile` validates it.
struct PaymentProfileDraft: Sendable, Equatable {
    var id: String?
    var nickname: String = ""
    var type: PaymentProfileType = .creditCard
    /// nil = not set.
    var brand: String?
    var last4: String = ""
    var memo: String = ""

    init(id: String? = nil, nickname: String = "", type: PaymentProfileType = .creditCard, brand: String? = nil, last4: String = "", memo: String = "") {
        self.id = id
        self.nickname = nickname
        self.type = type
        self.brand = brand
        self.last4 = last4
        self.memo = memo
    }

    init(_ profile: PaymentProfile) {
        self.init(id: profile.id, nickname: profile.nickname, type: profile.type, brand: profile.brand,
                  last4: profile.last4 ?? "", memo: profile.memo)
    }

    /// Trimmed values; brand / last4 only kept for card types.
    var normalized: PaymentProfileDraft {
        var d = self
        d.nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        d.memo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCard = SupportText.isCardType(type)
        let b = brand?.trimmingCharacters(in: .whitespacesAndNewlines)
        d.brand = isCard && b?.isEmpty == false ? b : nil
        d.last4 = isCard ? last4.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return d
    }

    /// Validation of exactly what would be stored.
    var issues: [PaymentProfileIssue] {
        let n = normalized
        return PaymentProfileValidator.validate(nickname: n.nickname, brand: n.brand, last4: n.last4.isEmpty ? nil : n.last4, memo: n.memo)
    }
}

/// Local-only writes of the Support feature (acknowledge, assignments, payment profiles).
/// None of these touch FANBOX; payment itself is always delegated to the account-aware web (SPEC §14).
@MainActor
enum SupportMutations {
    // MARK: Anomalies

    /// "確認済みにする" (SPEC §15). The anomaly stays recorded; it just leaves the 要確認 list.
    static func acknowledge(_ support: Support, store: LocalStore, now: Date = .now) {
        support.acknowledgedAt = now
        store.save()
    }

    // MARK: Scheduled stop (SPEC §10.3 来月予定)

    /// Records or clears the user's own "停止予定" for a support. USER-ENTERED: shown as "自分で記録", never as a FANBOX
    /// observation, and only for the current billing month (`SupportStopRule`). Only an active support can be marked.
    /// Returns false when nothing was written.
    @discardableResult
    static func setUserStopMark(_ support: Support, marked: Bool, store: LocalStore, now: Date = .now) -> Bool {
        if marked {
            guard support.isActive else { return false }
            support.userStopMarkedAt = now
        } else {
            guard support.userStopMarkedAt != nil else { return false }
            support.userStopMarkedAt = nil
        }
        store.save()
        return true
    }

    @discardableResult
    static func setUserStopMark(store: LocalStore, accountID: String, creatorID: String, marked: Bool, now: Date = .now) -> Bool {
        let key = Support.key(accountID: accountID, creatorID: creatorID)
        guard let support = store.first(#Predicate<Support> { $0.key == key }) else { return false }
        return setUserStopMark(support, marked: marked, store: store, now: now)
    }

    /// True when the user's stop record applies to the billing month of `now`.
    static func hasEffectiveUserStopMark(_ support: Support, now: Date = .now) -> Bool {
        guard support.isActive, let marked = support.userStopMarkedAt else { return false }
        return SupportBilling.isSameMonth(marked, now)
    }

    // MARK: Assignments (SPEC §13)

    static func assignment(store: LocalStore, accountID: String, creatorID: String) -> SupportPaymentAssignment? {
        let key = Support.key(accountID: accountID, creatorID: creatorID)
        return store.first(#Predicate<SupportPaymentAssignment> { $0.key == key })
    }

    static func assignments(store: LocalStore, profileID: String) -> [SupportPaymentAssignment] {
        store.fetch(FetchDescriptor<SupportPaymentAssignment>(predicate: #Predicate { $0.paymentProfileID == profileID }))
    }

    /// Creates or updates the assignment for (account, creator).
    /// - `.verified` stamps `lastVerifiedAt = now` ("Web で確認した"); other states clear it.
    /// - A nil profile always means `.unknown` (nothing to verify).
    @discardableResult
    static func setAssignment(store: LocalStore, accountID: String, creatorID: String, planID: String?,
                              profileID: String?, state: VerificationState, now: Date = .now) -> SupportPaymentAssignment {
        let effectiveState: VerificationState = profileID == nil ? .unknown : state
        let a: SupportPaymentAssignment
        if let existing = assignment(store: store, accountID: accountID, creatorID: creatorID) {
            a = existing
        } else {
            a = SupportPaymentAssignment(accountID: accountID, creatorID: creatorID, planID: planID, paymentProfileID: nil,
                                         verificationState: .unknown, updatedAt: now)
            store.context.insert(a)
        }
        if let planID { a.planID = planID }
        a.paymentProfileID = profileID
        a.verificationState = effectiveState
        a.lastVerifiedAt = effectiveState == .verified ? now : nil
        a.updatedAt = now
        store.save()
        return a
    }

    /// Payment flow hand-off (SPEC §14): remember the intended plan and, if chosen, the profile as `.manual`.
    /// Without a chosen profile the existing profile / state are kept (only the plan is updated).
    @discardableResult
    static func recordPaymentIntent(store: LocalStore, accountID: String, creatorID: String, planID: String?,
                                    profileID: String?, now: Date = .now) -> SupportPaymentAssignment {
        if let profileID {
            return setAssignment(store: store, accountID: accountID, creatorID: creatorID, planID: planID,
                                 profileID: profileID, state: .manual, now: now)
        }
        if let existing = assignment(store: store, accountID: accountID, creatorID: creatorID) {
            if let planID { existing.planID = planID }
            existing.updatedAt = now
            store.save()
            return existing
        }
        return setAssignment(store: store, accountID: accountID, creatorID: creatorID, planID: planID,
                             profileID: nil, state: .unknown, now: now)
    }

    // MARK: Payment profiles (SPEC §12)

    /// Validates and saves. Returns the issues (nothing is written) when the draft violates the storage policy.
    static func saveProfile(_ draft: PaymentProfileDraft, store: LocalStore, now: Date = .now) -> Result<PaymentProfile, PaymentProfileIssues> {
        let issues = draft.issues
        guard issues.isEmpty else { return .failure(PaymentProfileIssues(issues: issues)) }
        let d = draft.normalized
        let profile: PaymentProfile
        if let id = d.id, let existing = store.first(#Predicate<PaymentProfile> { $0.id == id }) {
            profile = existing
        } else {
            let nextOrder = (store.fetch(FetchDescriptor<PaymentProfile>()).map(\.sortOrder).max() ?? -1) + 1
            profile = PaymentProfile(id: d.id ?? UUID().uuidString, nickname: d.nickname, type: d.type, sortOrder: nextOrder, createdAt: now)
            store.context.insert(profile)
        }
        profile.nickname = d.nickname
        profile.type = d.type
        profile.brand = d.brand
        profile.last4 = d.last4.isEmpty ? nil : d.last4
        profile.memo = d.memo
        store.save()
        return .success(profile)
    }

    /// Deletes a profile. Assignments that pointed to it lose the profile and become `.unknown`.
    /// Returns how many assignments were reset.
    @discardableResult
    static func deleteProfile(id: String, store: LocalStore, now: Date = .now) -> Int {
        let affected = assignments(store: store, profileID: id)
        for a in affected {
            a.paymentProfileID = nil
            a.verificationState = .unknown
            a.lastVerifiedAt = nil
            a.updatedAt = now
        }
        if let profile = store.first(#Predicate<PaymentProfile> { $0.id == id }) {
            store.context.delete(profile)
        }
        store.save()
        return affected.count
    }

    /// Persists a new order (index = sortOrder).
    static func reorderProfiles(_ ordered: [PaymentProfile], store: LocalStore) {
        for (i, p) in ordered.enumerated() where p.sortOrder != i { p.sortOrder = i }
        store.save()
    }
}

struct PaymentProfileIssues: Error, Equatable, Sendable {
    var issues: [PaymentProfileIssue]
}

/// Counting helper: how many supports use each profile (assignments whose support is still active).
enum PaymentProfileUsage {
    static func counts(assignments: [AssignmentSnapshot], activeSupportKeys: Set<String>) -> [String: Int] {
        var result: [String: Int] = [:]
        for a in assignments {
            guard let pid = a.paymentProfileID, activeSupportKeys.contains(a.key) else { continue }
            result[pid, default: 0] += 1
        }
        return result
    }
}

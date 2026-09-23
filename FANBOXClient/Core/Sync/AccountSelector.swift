import Foundation

/// Input for automatic account selection of one post.
struct AccountCandidate: Sendable, Equatable {
    var accountID: String
    /// Body already cached from this account.
    var isCached: Bool
    /// nil = unknown.
    var canView: Bool?
    var sessionValid: Bool
    /// Fee of the plan this account supports for the post's creator (higher = more viewing rights).
    var planFee: Int
    var isMain: Bool
    var enabled: Bool
}

/// Automatic account choice when opening a post (SPEC §8):
/// 1. cached  2. can view  3. session OK  4. higher viewing permission  5. main account.
/// The user can always override manually.
enum AccountSelector {
    static func select(_ candidates: [AccountCandidate]) -> String? {
        let usable = candidates.filter(\.enabled)
        return usable.sorted(by: isPreferred).first?.accountID
    }

    /// Strict ordering used by `select` (and by the engine's cross-account fallback order).
    static func isPreferred(_ a: AccountCandidate, over b: AccountCandidate) -> Bool {
        if a.isCached != b.isCached { return a.isCached }
        // Tri-state: can view > unknown > known restricted. An account that never listed the post may well be able to
        // read it; one that got a restricted copy cannot.
        let av = viewScore(a.canView), bv = viewScore(b.canView)
        if av != bv { return av > bv }
        if a.sessionValid != b.sessionValid { return a.sessionValid }
        if a.planFee != b.planFee { return a.planFee > b.planFee }
        if a.isMain != b.isMain { return a.isMain }
        return a.accountID < b.accountID
    }

    /// true = 2, unknown = 1, false = 0.
    static func viewScore(_ canView: Bool?) -> Int {
        switch canView {
        case true?: return 2
        case nil: return 1
        case false?: return 0
        }
    }

    @MainActor
    static func candidates(postID: String, store: LocalStore) -> [AccountCandidate] {
        let post = store.post(id: postID)
        let accesses = Dictionary(store.postAccesses(postID: postID).map { ($0.accountID, $0) }, uniquingKeysWith: { a, _ in a })
        return store.accounts().map { account in
            let access = accesses[account.id]
            let supportFee = post.flatMap { p in
                store.supports(accountID: account.id).first { $0.creatorID == p.creatorID && $0.isActive }?.amount
            } ?? 0
            return AccountCandidate(
                accountID: account.id,
                isCached: access?.bodyCached == true || (post?.detailAccountID == account.id && post?.hasCachedBody == true),
                canView: access?.canView,
                sessionValid: account.kind == .demo || account.sessionState == .valid,
                planFee: access?.accountPlanFee ?? supportFee,
                isMain: account.isMain,
                enabled: account.enabled
            )
        }
    }

    @MainActor
    static func bestAccount(postID: String, store: LocalStore) -> String? {
        select(candidates(postID: postID, store: store))
    }
}

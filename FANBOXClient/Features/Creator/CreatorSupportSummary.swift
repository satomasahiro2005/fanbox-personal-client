import Foundation

/// Value snapshot of one `Support` row (keeps the aggregation pure / testable).
struct CreatorSupportInput: Sendable, Equatable {
    var accountID: String
    var creatorID: String
    var planID: String?
    var planTitle: String
    var amount: Int
    var status: SupportStatus
    var needsAttention: Bool = false
    var attentionReason: String? = nil
}

extension CreatorSupportInput {
    @MainActor
    init(_ support: Support) {
        self.init(accountID: support.accountID, creatorID: support.creatorID, planID: support.planID, planTitle: support.planTitle,
                  amount: support.amount, status: support.status, needsAttention: support.needsAttention,
                  attentionReason: support.attentionReason)
    }
}

/// One "支援中" line of the SPEC §9 block: `Account A  ¥500`.
struct CreatorSupportLine: Identifiable, Sendable, Equatable {
    var accountID: String
    var planID: String?
    var planTitle: String
    var amount: Int

    var id: String { accountID }
    var amountText: String { Formatters.yen(amount) }
}

/// Observed anomaly for a creator (SPEC §15): shown as an observed fact, never as an asserted cause.
struct CreatorSupportAttention: Identifiable, Sendable, Equatable {
    var accountID: String
    var status: SupportStatus
    var reason: String

    var id: String { accountID }
}

/// Creator-level support aggregation (SPEC §9 / §10.1):
///
///     支援中
///     Account A    ¥500
///     Account B  ¥1,000
///     合計       ¥1,500 / 月
struct CreatorSupportSummary: Sendable, Equatable {
    var creatorID: String
    /// Active supports only, in account display order.
    var lines: [CreatorSupportLine]
    var attentions: [CreatorSupportAttention]

    var monthlyTotal: Int { lines.reduce(0) { $0 + $1.amount } }
    var accountIDs: [String] { lines.map(\.accountID) }
    var isSupporting: Bool { !lines.isEmpty }
    /// "¥6,500 / 月"
    var monthlyTotalText: String { Self.monthlyText(monthlyTotal) }

    static func monthlyText(_ amount: Int) -> String { "\(Formatters.yen(amount)) / 月" }

    /// - Parameters:
    ///   - supports: rows of any creators; only `creatorID`'s rows are used.
    ///   - accountOrder: account ids in display order (e.g. `Account.sortOrder`). Unknown accounts go last.
    ///   - knownAccountIDs: when given, rows of accounts that no longer exist locally are ignored.
    static func make(creatorID: String, supports: [CreatorSupportInput], accountOrder: [String] = [],
                     knownAccountIDs: Set<String>? = nil) -> CreatorSupportSummary {
        let rank = Dictionary(accountOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var bestByAccount: [String: CreatorSupportInput] = [:]
        var attentions: [CreatorSupportAttention] = []
        for s in supports where s.creatorID == creatorID {
            if let knownAccountIDs, !knownAccountIDs.contains(s.accountID) { continue }
            if s.status == .active {
                // One support per (account, creator) is the model invariant; keep the larger amount defensively.
                if let existing = bestByAccount[s.accountID], existing.amount >= s.amount { continue }
                bestByAccount[s.accountID] = s
            }
            if s.needsAttention || s.status == .missing {
                attentions.append(CreatorSupportAttention(accountID: s.accountID, status: s.status,
                                                          reason: attentionText(status: s.status, reason: s.attentionReason)))
            }
        }
        let order: (String, String) -> Bool = { a, b in
            let ra = rank[a] ?? Int.max, rb = rank[b] ?? Int.max
            return ra != rb ? ra < rb : a < b
        }
        let lines = bestByAccount.values
            .map { CreatorSupportLine(accountID: $0.accountID, planID: $0.planID, planTitle: $0.planTitle, amount: max(0, $0.amount)) }
            .sorted { order($0.accountID, $1.accountID) }
        attentions.sort { order($0.accountID, $1.accountID) }
        return CreatorSupportSummary(creatorID: creatorID, lines: lines, attentions: attentions)
    }

    /// creatorID → sum of active amounts, for list rows / sort.
    /// Same de-duplication rule as `make` (one line per account, larger amount wins).
    static func totalsByCreator(_ supports: [CreatorSupportInput], knownAccountIDs: Set<String>? = nil) -> [String: Int] {
        var perAccount: [String: (creatorID: String, amount: Int)] = [:]
        for s in supports where s.status == .active {
            if let knownAccountIDs, !knownAccountIDs.contains(s.accountID) { continue }
            let key = "\(s.accountID)|\(s.creatorID)"
            let amount = max(0, s.amount)
            if let existing = perAccount[key], existing.amount >= amount { continue }
            perAccount[key] = (s.creatorID, amount)
        }
        var result: [String: Int] = [:]
        for entry in perAccount.values { result[entry.creatorID, default: 0] += entry.amount }
        return result
    }

    /// creatorID → supporting account ids (display order).
    static func accountsByCreator(_ supports: [CreatorSupportInput], accountOrder: [String] = []) -> [String: [String]] {
        let rank = Dictionary(accountOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: Set<String>] = [:]
        for s in supports where s.status == .active { result[s.creatorID, default: []].insert(s.accountID) }
        return result.mapValues { ids in
            ids.sorted { (rank[$0] ?? Int.max, $0) < (rank[$1] ?? Int.max, $1) }
        }
    }

    /// Observed-fact wording (SPEC §15: never assert a payment failure).
    static func attentionText(status: SupportStatus, reason: String?) -> String {
        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return reason }
        switch status {
        case .missing: return "支援が一覧から見つかりません"
        case .ended: return "支援は終了しています"
        case .unknown: return "支援状態を確認できません"
        case .active: return "要確認"
        }
    }
}

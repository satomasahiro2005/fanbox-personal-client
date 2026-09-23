import Foundation

/// Demo values for the optional sync signals (`RemoteDataSource.paymentStatus`). Deterministic and offline:
/// by default no demo account has unpaid payments; tests and debug tools can inject one with `DemoSyncSignals`.
extension DemoRemoteDataSource {
    func paymentStatus(account: AccountContext) async throws -> RemotePaymentStatus? {
        if let snapshot = policy?.current, snapshot.mode == .offline || !snapshot.pathSatisfied { throw RemoteError.offline }
        return await DemoSyncSignals.shared.paymentStatus(accountID: account.accountID)
    }
}

/// Injectable demo payment signals (per local account id). Synthetic values only; never derived from real data.
actor DemoSyncSignals {
    static let shared = DemoSyncSignals()

    private var unpaid: [String: [RemotePayment]] = [:]

    func paymentStatus(accountID: String) -> RemotePaymentStatus {
        let records = unpaid[accountID] ?? []
        return RemotePaymentStatus(hasUnpaidPayments: !records.isEmpty, unpaidRecords: records)
    }

    /// Simulates an outstanding payment for a demo creator (observed-fact testing of 決済要確認).
    func simulateUnpaidPayment(accountID: String, creatorID: String, creatorName: String, amount: Int, at date: Date = .now) {
        let record = RemotePayment(id: "demo-unpaid-\(creatorID)-\(Int(date.timeIntervalSince1970))", creatorID: creatorID,
                                   creatorName: creatorName, amount: amount, paidAt: date, paymentMethod: nil)
        unpaid[accountID, default: []].append(record)
    }

    func clearUnpaidPayments(accountID: String) {
        unpaid[accountID] = nil
    }
}

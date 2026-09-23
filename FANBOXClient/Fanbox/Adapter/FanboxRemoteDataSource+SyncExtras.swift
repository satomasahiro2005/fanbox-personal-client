import Foundation

/// FANBOX implementations of the optional `RemoteDataSource` signals used by sync (see `RemoteDataSource.swift`).
///
/// - `unreadNotificationCount(account:)` and `postMetadata(id:account:)` are implemented in `FanboxRemoteDataSource.swift`
///   with matching signatures and satisfy the protocol requirements directly.
/// - Everything here reads endpoints that are already modeled (docs/API.md); no new endpoint is introduced.
extension FanboxRemoteDataSource {
    /// plan.listSupporting with a completeness audit (docs/API.md §1.10 / §8.1). The listing is used to detect supports
    /// that disappeared, so a partially readable response must never look like "these supports are gone":
    /// a `null` / non-array list, an element that is not an object, or an item without id / creatorId marks the listing
    /// incomplete. The readable items are still returned (they are real observations).
    func supportingPlanListing(account: AccountContext) async throws -> RemoteSupportListing {
        let body = try await api.send(.planListSupporting(), as: FanboxSupportingPlanAudit.self, accountID: account.accountID)
        let supports = body.items.compactMap(FanboxAdapter.support)
        var problems: [String] = []
        if let shape = body.shapeProblem { problems.append(shape) }
        if body.undecodableCount > 0 { problems.append("解釈できない項目 \(body.undecodableCount) 件") }
        let unmapped = body.items.count - supports.count
        if unmapped > 0 { problems.append("id / creatorId のない項目 \(unmapped) 件") }
        return RemoteSupportListing(supports: supports, problem: problems.isEmpty ? nil : problems.joined(separator: " / "))
    }

    /// Page metadata `hasUnpaidPayments` (docs/API.md §2.14), plus payment.listUnpaid (§12.2, medium confidence) when the
    /// flag is set or unknown. Both are best effort: a failure of one signal leaves it nil instead of failing the check.
    func paymentStatus(account: AccountContext) async throws -> RemotePaymentStatus? {
        var flag: Bool?
        var firstError: Error?
        do {
            flag = try await sessionSummary(account: account).hasUnpaidPayments
        } catch {
            firstError = error
        }
        var records: [RemotePayment]?
        if flag != false {
            do {
                records = try await unpaidRecords(account: account)
            } catch {
                firstError = firstError ?? error
            }
        }
        if flag == nil, records == nil, let firstError { throw FanboxAPIClient.normalize(firstError) }
        return RemotePaymentStatus(hasUnpaidPayments: flag, unpaidRecords: records)
    }

    /// bell.list page plus the post summaries embedded in `on_post_published` items (docs/API.md §2.11), so the post
    /// row exists locally before the (possibly edge-blocked) detail endpoint is ever called.
    func notificationBatch(account: AccountContext, cursor: String?) async throws -> RemoteNotificationBatch {
        var page = 1
        if let cursor {
            guard case .page(let p)? = FanboxCursor(encoded: cursor) else { throw RemoteError.invalidRequest("カーソルが不正です") }
            page = p
        }
        let body = try await api.send(.bellList(page: page), as: FanboxBellListBody.self, accountID: account.accountID)
        let items = body.items.compactMap(FanboxAdapter.notification)
        var next: String?
        if let nextURL = body.nextUrl {
            let nextPage = FanboxCursor.queryValue("page", in: nextURL).flatMap(Int.init) ?? page + 1
            if nextPage > page { next = FanboxCursor.page(nextPage).encoded }
        }
        var seen = Set<String>()
        let posts = body.items.compactMap { $0.post }.compactMap { FanboxAdapter.postSummary($0) }
            .filter { !$0.creatorID.isEmpty && seen.insert($0.id).inserted }
        return RemoteNotificationBatch(page: RemotePage(items: items, nextCursor: next), posts: posts)
    }
}

/// plan.listSupporting body read with an element count so dropped items are detectable (the shared
/// `FanboxWrappedList` silently skips them, which is right for display lists but not for disappearance detection).
struct FanboxSupportingPlanAudit: FanboxResponseBody {
    var items: [FanboxPlanDTO]
    /// Elements that were present but could not be decoded as an object.
    var undecodableCount: Int
    /// Non-nil when the list itself was not readable (e.g. `plans: null`).
    var shapeProblem: String?

    init(items: [FanboxPlanDTO], undecodableCount: Int = 0, shapeProblem: String? = nil) {
        self.items = items
        self.undecodableCount = undecodableCount
        self.shapeProblem = shapeProblem
    }

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            (items, undecodableCount) = Self.decodeCounting(&array)
            shapeProblem = nil
            return
        }
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        for key in FanboxPlansKey.keys {
            let codingKey = AnyCodingKey(key)
            guard container.contains(codingKey) else { continue }
            if var nested = try? container.nestedUnkeyedContainer(forKey: codingKey) {
                (items, undecodableCount) = Self.decodeCounting(&nested)
                shapeProblem = nil
            } else {
                items = []
                undecodableCount = 0
                shapeProblem = "\(key) が配列ではありません"
            }
            return
        }
        let found = container.allKeys.map(\.stringValue).sorted()
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                debugDescription: "Expected an array or one of \(FanboxPlansKey.keys) (found keys: \(found))"))
    }

    private static func decodeCounting(_ container: inout UnkeyedDecodingContainer) -> ([FanboxPlanDTO], Int) {
        var items: [FanboxPlanDTO] = []
        var failed = 0
        while !container.isAtEnd {
            if let value = try? container.decode(FanboxPlanDTO.self) {
                items.append(value)
            } else if (try? container.decode(JSONValue.self)) != nil {
                failed += 1
            } else {
                // Could not even skip the element; count the rest as unreadable and stop.
                failed += 1
                break
            }
        }
        return (items, failed)
    }

    static var responseSchema: [String: Set<String>] { FanboxPlanListBody.responseSchema }
}

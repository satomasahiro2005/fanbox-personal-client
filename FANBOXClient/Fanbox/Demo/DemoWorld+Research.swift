import Foundation

/// A おたより published while the app runs (Research Mode demo tools), visible to `audience` profiles.
struct DemoDynamicNewsletter: Sendable, Hashable {
    var audience: Set<DemoProfile>
    var letter: RemoteNewsletter
}

// MARK: - Simulation hooks for Research Mode "Demo tools" (SPEC §45 新着投稿通知 / おたより通知 in the simulator)

extension DemoWorld {
    /// Default creator of simulated items: supported by every demo profile, so every demo account receives them.
    static let simulationCreatorID = "demo-aoi"

    /// Publishes a new おたより from `creatorID` to every profile that supports the creator (every viewer profile when none
    /// does). The next `.notifications` sync picks it up through `newsletters(account:)`, which creates a `.newsletter`
    /// NotificationEvent and — after the first sync of an account — a local iOS notification. Returns the newsletter id.
    @discardableResult
    func simulateIncomingNewsletter(creatorID: String = DemoWorld.simulationCreatorID, title: String? = nil,
                                    body: String? = nil) -> String {
        let number = dynamicNewsletters.count + 1
        let id = "demo-nl-live-\(number)"
        let creator = DemoFixtures.creatorsByID[creatorID] ?? DemoFixtures.creators[0]
        let supporters = Set(DemoProfile.allCases.filter { profile in
            DemoFixtures.profile(profile).supports.contains { $0.creatorID == creator.id }
        })
        let audience = supporters.isEmpty ? Set(DemoProfile.allCases.filter(\.isViewer)) : supporters
        // Strictly increasing and newer than every fixture (fixture dates are relative to `anchor`).
        let createdAt = max(Date(), anchor).addingTimeInterval(Double(number) * 0.001)
        let letter = RemoteNewsletter(
            id: id, creatorID: creator.id, creatorName: creator.name, creatorIconURL: creator.iconURL,
            title: title ?? "Demo おたより #\(number)",
            body: body ?? "支援者の皆さまへ。\n\nデモ用に生成されたおたよりです（#\(number)）。実在のサービスとは関係ありません。",
            createdAt: createdAt, isRead: false)
        dynamicNewsletters.append(DemoDynamicNewsletter(audience: audience, letter: letter))
        return id
    }
}

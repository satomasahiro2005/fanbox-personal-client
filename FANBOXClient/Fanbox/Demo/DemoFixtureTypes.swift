import Foundation

// Value types describing the static demo fixtures. All content is synthetic and fictional ("Demo").
// Dates are expressed relative to the world's anchor date (`DemoTime`) so the world is deterministic for a given anchor.

/// A point in time relative to `DemoWorld.anchor`.
enum DemoTime: Sendable, Hashable {
    case minutesAgo(Int)
    /// Fraction (0...1) of the time elapsed between the start of the anchor's month and the anchor.
    case thisMonth(Double)
    /// `months` calendar months before the anchor's month, at day/hour (day is clamped to 28).
    case monthsAgo(Int, day: Int, hour: Int)

    static func hoursAgo(_ h: Int) -> DemoTime { .minutesAgo(h * 60) }
    static func daysAgo(_ d: Int, hours: Int = 0) -> DemoTime { .minutesAgo(d * 1440 + hours * 60) }

    func resolve(anchor: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .minutesAgo(let m):
            return anchor.addingTimeInterval(-Double(m) * 60)
        case .thisMonth(let fraction):
            let start = DemoTime.startOfMonth(anchor, calendar: calendar)
            let f = min(1, max(0, fraction))
            return start.addingTimeInterval(anchor.timeIntervalSince(start) * f)
        case .monthsAgo(let months, let day, let hour):
            let start = DemoTime.startOfMonth(anchor, calendar: calendar)
            let month = calendar.date(byAdding: .month, value: -months, to: start) ?? start
            let offset = Double(max(1, min(28, day)) - 1) * 86_400 + Double(max(0, min(23, hour))) * 3_600
            return month.addingTimeInterval(offset)
        }
    }

    static func startOfMonth(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }
}

struct DemoPlanFixture: Sendable, Hashable {
    var fee: Int
    var title: String
    var description: String
}

struct DemoCreatorFixture: Sendable, Hashable {
    var id: String
    var pixivUserID: String
    var name: String
    var profileText: String
    var links: [String]
    var plans: [DemoPlanFixture]

    func planID(fee: Int) -> String { "\(id)-plan-\(fee)" }
    func plan(fee: Int) -> DemoPlanFixture? { plans.first { $0.fee == fee } }
    var iconURL: String { DemoMedia.iconURL(seed: "icon-\(id)") }
    var coverURL: String { DemoMedia.imageURL(seed: "cover-\(id)", width: 1200, height: 400, variant: .display) }
}

struct DemoSupportFixture: Sendable, Hashable {
    var creatorID: String
    var fee: Int
    /// Raw FANBOX-style payment method kind.
    var paymentMethod: String
}

struct DemoProfileFixture: Sendable, Hashable {
    var profile: DemoProfile
    var userName: String
    var supports: [DemoSupportFixture]
    /// Creators followed without a support.
    var followOnly: [String]
    /// Support that is returned by the first `supportingPlans` call only (SPEC §15 "要確認" scenario).
    var disappearingSupportCreatorID: String?

    var iconURL: String { DemoMedia.iconURL(seed: "avatar-\(profile.tag)") }
}

/// Compact description of a post body block; expanded into `RemoteBlock`s by `DemoWorld`.
enum DemoBlockSpec: Sendable, Hashable {
    case paragraph(String)
    /// Paragraph with bold ranges (`bold`) and enlarged ranges (`large`, font size 24). Ranges are found by substring.
    case styled(String, bold: [String], large: [String])
    case header(String)
    case images(count: Int, width: Int, height: Int)
    case file(name: String, ext: String, size: Int)
    case audio(name: String, size: Int)
    case videoFile(name: String, size: Int)
    case externalVideo(provider: String, id: String)
    case link(url: String, title: String, subtitle: String)
    case embed(provider: String, id: String)
}

struct DemoPostFixture: Sendable, Hashable {
    var id: String
    var creatorID: String
    var time: DemoTime
    var type: PostType
    var title: String
    var fee: Int
    var tags: [String]
    var likes: Int
    var body: [DemoBlockSpec]
    /// Creator-side status (managed posts of the self creator); reader fixtures are always published.
    var status: RemotePostStatus = .published
}

/// Who wrote a comment.
enum DemoAuthor: Sendable, Hashable {
    /// `DemoFixtures.fans[index]`.
    case fan(Int)
    /// The creator of the post the comment belongs to.
    case postCreator
    /// The fixture user of a demo profile (resolved to the matching demo account when known).
    case profile(DemoProfile)
    /// Written at runtime through `addComment` by a demo account.
    case user(id: String, name: String, iconURL: String?)
}

struct DemoCommentFixture: Sendable, Hashable {
    var id: String
    var postID: String
    var parentID: String?
    var author: DemoAuthor
    var time: DemoTime
    var body: String
    var likes: Int = 0
}

struct DemoNotificationFixture: Sendable, Hashable {
    /// Unique per profile; combined with an account hash into the per-account remote id.
    var key: String
    var type: NotificationEventType
    var rawType: String
    var time: DemoTime
    var creatorID: String?
    var postID: String?
    var commentID: String?
    var newsletterID: String?
    var actorName: String?
    var actorIconURL: String?
    var title: String
    var message: String
    var unread: Bool
}

struct DemoNewsletterFixture: Sendable, Hashable {
    var id: String
    var creatorID: String
    var title: String
    var body: String
    var time: DemoTime
    var isRead: Bool
}

struct DemoPaymentFixture: Sendable, Hashable {
    var id: String
    var creatorID: String
    var amount: Int
    var time: DemoTime
    var paymentMethod: String
}

struct DemoFanFixture: Sendable, Hashable {
    var userID: String
    var name: String
    /// Plan fee of the self creator (nil = following only).
    var fee: Int?
    var state: FanState
    var startedMinutesAgo: Int?
    /// Months supported; nil = derive from the start date.
    var months: Int?

    var iconURL: String { DemoMedia.iconURL(seed: "fan-\(userID)", size: 96) }
}

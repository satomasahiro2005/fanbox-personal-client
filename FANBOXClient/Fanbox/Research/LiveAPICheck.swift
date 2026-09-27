import Foundation
import Observation

/// Live API check (Research Mode): calls every READ endpoint the app uses, once, against the real FANBOX with one of the
/// user's own accounts, through the app's real stack (transport routing, DTO decoding, adapter mapping).
///
/// The API reference (docs/API.md) was compiled from other people's clients and archived web code; this check is how the
/// app confirms it against the live service. For every step it reports whether the call worked, what the adapter made of
/// it (counts and kinds only), and the schema differences the inspector saw: fields the DTOs know that were missing, and
/// fields they do not know. The exportable report contains only masked structure (`LiveAPIShape`) — no names, texts,
/// ids or secrets — so it can be shared to turn into contract fixtures (`LiveContractTests`).
///
/// Read-only: no step writes anything. Steps run one at a time, `stepDelay` apart, at interactiveRead priority, and all
/// transport rules (RateGate budgets, edge-block cooldowns, Offline) still apply.
@MainActor
@Observable
final class LiveAPICheck {
    enum StepStatus: String, Codable, Sendable {
        case pending, running, passed, warning, failed, skipped
    }

    struct Step: Identifiable, Sendable {
        let id: String
        let title: String
        var status: StepStatus = .pending
        var summary: String = ""
        var error: String?
        var durationMs: Int?
        var endpointKeys: [String] = []
        /// path → field names, union over this step's responses.
        var newFields: [String: [String]] = [:]
        var missingFields: [String: [String]] = [:]
    }

    struct EndpointResult: Sendable {
        var endpointKey: String
        var samples: Int
        var newFields: [String: [String]]
        var missingFields: [String: [String]]
        /// Masked structure of the first response (pretty JSON text).
        var shapeJSON: String
    }

    private(set) var steps: [Step] = []
    private(set) var endpoints: [EndpointResult] = []
    private(set) var isRunning = false
    private(set) var finishedAt: Date?
    private(set) var isCreatorAccount = false

    @ObservationIgnored let remote: RemoteDataSourceProvider
    @ObservationIgnored let inspector: SchemaInspector
    @ObservationIgnored var stepDelay: Duration = .seconds(2)
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var shaper = LiveAPIShape()

    init(remote: RemoteDataSourceProvider, inspector: SchemaInspector) {
        self.remote = remote
        self.inspector = inspector
    }

    /// Everything the steps learned about the account's data (ids stay in memory only).
    private struct Context {
        var postID: String?
        var viewablePostID: String?
        var creatorID: String?
        var managedPostID: String?
        var isCreator = false
    }

    private struct StepSpec {
        let id: String
        let title: String
        let creatorOnly: Bool
        let run: (FanboxRemoteDataSource, AccountContext, inout Context) async throws -> String?
    }

    // MARK: - Run

    func start(account: AccountContext) {
        guard !isRunning else { return }
        task = Task { await run(account: account) }
    }

    func cancel() {
        task?.cancel()
    }

    func run(account: AccountContext) async {
        guard !isRunning else { return }
        isRunning = true
        finishedAt = nil
        endpoints = []
        shaper = LiveAPIShape()
        let specs = Self.specs
        steps = specs.map { Step(id: $0.id, title: $0.title) }
        defer {
            isRunning = false
            finishedAt = .now
        }

        guard account.kind == .fanbox, let fanbox = remote.dataSource(for: account) as? FanboxRemoteDataSource else {
            for i in steps.indices { steps[i].status = .skipped; steps[i].summary = "FANBOXアカウントではありません" }
            return
        }

        inspector.beginCapture()
        var captured: [SchemaInspector.CapturedResponse] = []
        var context = Context(isCreator: account.creatorID != nil)
        for (index, spec) in specs.enumerated() {
            if Task.isCancelled {
                for i in index..<steps.count where steps[i].status == .pending { steps[i].status = .skipped; steps[i].summary = "中止" }
                break
            }
            if spec.creatorOnly && !context.isCreator {
                steps[index].status = .skipped
                steps[index].summary = "クリエイターアカウントではないためスキップ"
                continue
            }
            steps[index].status = .running
            let start = ContinuousClock.now
            do {
                let summary = try await RequestContext.$priority.withValue(.interactiveRead) {
                    try await spec.run(fanbox, account, &context)
                }
                if let summary {
                    steps[index].status = .passed
                    steps[index].summary = summary
                } else {
                    steps[index].status = .skipped
                    steps[index].summary = "前のステップで対象が見つからなかったためスキップ"
                }
            } catch {
                steps[index].status = .failed
                steps[index].error = Self.describe(error)
            }
            steps[index].durationMs = Self.milliseconds(ContinuousClock.now - start)

            // Responses observed during this step (the capture is appended synchronously by the API client).
            let mine = inspector.endCapture()
            captured += mine
            inspector.beginCapture()
            apply(mine, toStep: index)

            if index < specs.count - 1, steps[index].status != .skipped {
                try? await Task.sleep(for: stepDelay)
            }
        }
        captured += inspector.endCapture()
        isCreatorAccount = context.isCreator
        endpoints = summarize(captured)
    }

    private func apply(_ responses: [SchemaInspector.CapturedResponse], toStep index: Int) {
        guard !responses.isEmpty else { return }
        var keys: [String] = []
        for response in responses where !keys.contains(response.endpointKey) { keys.append(response.endpointKey) }
        steps[index].endpointKeys = keys
        let diff = Self.diff(responses)
        steps[index].newFields = diff.new
        steps[index].missingFields = diff.missing
        // Missing / new fields are shown as information: many known fields are optional, so their absence in one sample
        // is not an error. A decoding failure makes the step fail on its own.
    }

    private func summarize(_ captured: [SchemaInspector.CapturedResponse]) -> [EndpointResult] {
        var order: [String] = []
        var grouped: [String: [SchemaInspector.CapturedResponse]] = [:]
        for c in captured {
            if grouped[c.endpointKey] == nil { order.append(c.endpointKey) }
            grouped[c.endpointKey, default: []].append(c)
        }
        return order.map { key in
            let responses = grouped[key] ?? []
            let diff = Self.diff(responses)
            let shape = responses.first.flatMap { shaper.maskedJSON($0.rawJSON) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return EndpointResult(endpointKey: key, samples: responses.count, newFields: diff.new, missingFields: diff.missing,
                                  shapeJSON: shape)
        }
    }

    /// New / missing fields per path, united over the responses. A field counts as missing only if no response had it.
    static func diff(_ responses: [SchemaInspector.CapturedResponse]) -> (new: [String: [String]], missing: [String: [String]]) {
        var observed: [String: Set<String>] = [:]
        var known: [String: Set<String>] = [:]
        for response in responses where !response.known.isEmpty {
            for observation in SchemaInspector.analyze(rawJSON: response.rawJSON, known: response.known) {
                observed[observation.path, default: []].formUnion(observation.observed)
                known[observation.path, default: []].formUnion(observation.known)
            }
        }
        var new: [String: [String]] = [:]
        var missing: [String: [String]] = [:]
        for (path, fields) in observed {
            let knownFields = known[path] ?? []
            let n = fields.subtracting(knownFields)
            let m = knownFields.subtracting(fields)
            if !n.isEmpty { new[path] = n.sorted() }
            if !m.isEmpty { missing[path] = m.sorted() }
        }
        return (new, missing)
    }

    // MARK: - Report

    /// Shareable report: masked structure and outcomes only (no account names, ids, texts or secrets).
    func reportJSON(appVersion: String) -> Data? {
        let formatter = ISO8601DateFormatter()
        let stepRecords: [[String: Any]] = steps.map { step in
            var r: [String: Any] = ["id": step.id, "title": step.title, "status": step.status.rawValue, "summary": step.summary,
                                    "endpointKeys": step.endpointKeys, "newFields": step.newFields, "missingFields": step.missingFields]
            if let error = step.error { r["error"] = error }
            if let ms = step.durationMs { r["durationMs"] = ms }
            return r
        }
        var endpointRecords: [String: Any] = [:]
        for e in endpoints {
            var r: [String: Any] = ["samples": e.samples, "newFields": e.newFields, "missingFields": e.missingFields]
            if let data = e.shapeJSON.data(using: .utf8), let shape = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                r["shape"] = shape
            }
            endpointRecords[e.endpointKey] = r
        }
        let report: [String: Any] = [
            "format": "fanbox-live-api-report/1",
            "generatedAt": formatter.string(from: finishedAt ?? .now),
            "appVersion": appVersion,
            "isCreatorAccount": isCreatorAccount,
            "steps": stepRecords,
            "endpoints": endpointRecords,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        // Defense in depth: the report never carries secrets.
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return Data(SecretRedactor.redact(text).utf8)
    }

    /// Writes the report to a protected temporary file for the share sheet.
    func writeReport(appVersion: String) -> URL? {
        guard let data = reportJSON(appVersion: appVersion) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: finishedAt ?? .now).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-report-\(stamp).json")
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    static func describe(_ error: Error) -> String {
        if let remote = error as? RemoteError {
            return "\(remote.userMessage) — \(SecretRedactor.redact(String(describing: remote)))"
        }
        return SecretRedactor.redact(String(describing: error))
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let c = duration.components
        return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
    }

    private static func count<T>(_ items: [T], _ label: String) -> String { "\(label)\(items.count)件" }

    private static func kinds(_ blocks: [RemoteBlock]) -> String {
        var counts: [String: Int] = [:]
        for b in blocks { counts[b.kind.rawValue, default: 0] += 1 }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    }

    // MARK: - Steps (read-only)

    private static let specs: [StepSpec] = [
        StepSpec(id: "session", title: "ログイン状態（www.fanbox.cc metadata）", creatorOnly: false) { ds, account, ctx in
            let s = try await ds.sessionSummary(account: account)
            ctx.isCreator = ctx.isCreator || s.isCreator
            return "creator: \(s.isCreator ? "yes" : "no") / supporter: \(s.isSupporter.map { $0 ? "yes" : "no" } ?? "?") / "
                + "planCount: \(s.planCount.map(String.init) ?? "?") / unpaid: \(s.hasUnpaidPayments.map { $0 ? "yes" : "no" } ?? "?")"
        },
        StepSpec(id: "bell.countUnread", title: "通知の未読数（bell.countUnread）", creatorOnly: false) { ds, account, _ in
            let n = try await ds.unreadNotificationCount(account: account)
            return "未読\(n.map(String.init) ?? "取得不可")"
        },
        StepSpec(id: "bell.list", title: "通知一覧（bell.list）", creatorOnly: false) { ds, account, _ in
            let batch = try await ds.notificationBatch(account: account, cursor: nil)
            var types: [String: Int] = [:]
            for n in batch.page.items { types[n.rawType, default: 0] += 1 }
            let typeText = types.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
            return "\(batch.page.items.count)件（\(typeText.isEmpty ? "なし" : typeText)）/ 埋め込み投稿\(batch.posts.count)"
        },
        StepSpec(id: "newsletter.list", title: "おたより一覧（newsletter.list）", creatorOnly: false) { ds, account, _ in
            LiveAPICheck.count(try await ds.newsletters(account: account), "おたより")
        },
        StepSpec(id: "post.listHome", title: "ホームタイムライン（post.listHome）", creatorOnly: false) { ds, account, ctx in
            let page = try await ds.homeTimeline(account: account, cursor: nil)
            ctx.postID = ctx.postID ?? page.items.first?.id
            ctx.viewablePostID = ctx.viewablePostID ?? page.items.first { !$0.isRestricted }?.id
            ctx.creatorID = ctx.creatorID ?? page.items.first?.creatorID
            return "\(page.items.count)件（閲覧不可\(page.items.filter(\.isRestricted).count)）/ 次ページ: \(page.nextCursor == nil ? "なし" : "あり")"
        },
        StepSpec(id: "post.listSupporting", title: "支援中タイムライン（post.listSupporting）", creatorOnly: false) { ds, account, ctx in
            let page = try await ds.supportingTimeline(account: account, cursor: nil)
            if let viewable = page.items.first(where: { !$0.isRestricted }) {
                ctx.viewablePostID = viewable.id
                ctx.creatorID = viewable.creatorID
            }
            ctx.postID = ctx.postID ?? page.items.first?.id
            return "\(page.items.count)件（閲覧不可\(page.items.filter(\.isRestricted).count)）"
        },
        StepSpec(id: "creator.listFollowing", title: "フォロー中クリエイター（creator.listFollowing）", creatorOnly: false) { ds, account, ctx in
            let creators = try await ds.followingCreators(account: account)
            ctx.creatorID = ctx.creatorID ?? creators.first?.creatorID
            return LiveAPICheck.count(creators, "クリエイター")
        },
        StepSpec(id: "plan.listSupporting", title: "支援中プラン（plan.listSupporting）", creatorOnly: false) { ds, account, ctx in
            let listing = try await ds.supportingPlanListing(account: account)
            ctx.creatorID = ctx.creatorID ?? listing.supports.first?.creatorID
            let methods = Set(listing.supports.compactMap(\.paymentMethod)).sorted().joined(separator: ",")
            return "\(listing.supports.count)件 / 完全: \(listing.isComplete ? "yes" : "no（\(listing.problem ?? "")）") / paymentMethod: \(methods.isEmpty ? "-" : methods)"
        },
        StepSpec(id: "payment.listPaid", title: "支払い履歴（payment.listPaid）", creatorOnly: false) { ds, account, _ in
            let payments = try await ds.paidRecords(account: account)
            return "\(payments.count)件 / 金額あり\(payments.filter { $0.amount > 0 }.count)"
        },
        StepSpec(id: "payment.status", title: "未払い（payment.listUnpaid）", creatorOnly: false) { ds, account, _ in
            let status = try await ds.paymentStatus(account: account)
            return "未払い: \(status?.indicatesUnpaid.map { $0 ? "あり" : "なし" } ?? "不明") / 件数\(status?.unpaidRecords?.count.description ?? "?")"
        },
        StepSpec(id: "post.info", title: "投稿本文（post.info）", creatorOnly: false) { ds, account, ctx in
            guard let id = ctx.viewablePostID ?? ctx.postID else { return nil }
            let detail = try await ds.post(id: id, account: account)
            return "type: \(detail.summary.type.rawValue) / 閲覧不可: \(detail.summary.isRestricted ? "yes" : "no") / ブロック: \(LiveAPICheck.kinds(detail.blocks).isEmpty ? "なし" : LiveAPICheck.kinds(detail.blocks))"
        },
        StepSpec(id: "post.get", title: "投稿メタデータ（post.get）", creatorOnly: false) { ds, account, ctx in
            guard let id = ctx.viewablePostID ?? ctx.postID else { return nil }
            let summary = try await ds.postMetadata(id: id, account: account)
            return "type: \(summary.type.rawValue) / コメント数\(summary.commentCount)"
        },
        StepSpec(id: "post.getComments", title: "コメント（post.getComments）", creatorOnly: false) { ds, account, ctx in
            guard let id = ctx.viewablePostID ?? ctx.postID else { return nil }
            let page = try await ds.comments(postID: id, account: account, cursor: nil)
            let all = page.items.flatMap(\.flattened)
            return "ルート\(page.items.count)件 / 返信込み\(all.count)件"
        },
        StepSpec(id: "creator.get", title: "クリエイター（creator.get）", creatorOnly: false) { ds, account, ctx in
            guard let id = ctx.creatorID else { return nil }
            let c = try await ds.creator(id: id, account: account)
            return "リンク\(c.profileLinks.count) / フォロー: \(c.isFollowed.map { $0 ? "yes" : "no" } ?? "?") / 支援: \(c.isSupported.map { $0 ? "yes" : "no" } ?? "?")"
        },
        StepSpec(id: "plan.listCreator", title: "クリエイターのプラン（plan.listCreator）", creatorOnly: false) { ds, account, ctx in
            guard let id = ctx.creatorID else { return nil }
            return LiveAPICheck.count(try await ds.creatorPlans(creatorID: id, account: account), "プラン")
        },
        StepSpec(id: "post.listCreator", title: "クリエイターの投稿（post.paginateCreator → post.listCreator）", creatorOnly: false) { ds, account, ctx in
            guard let id = ctx.creatorID else { return nil }
            let page = try await ds.creatorPosts(creatorID: id, account: account, cursor: nil)
            return "\(page.items.count)件 / 次ページ: \(page.nextCursor == nil ? "なし" : "あり")"
        },
        StepSpec(id: "post.listManaged", title: "自分の投稿（post.listManaged）", creatorOnly: true) { ds, account, ctx in
            let page = try await ds.managedPosts(account: account, cursor: nil)
            ctx.managedPostID = page.items.first?.id
            var statuses: [String: Int] = [:]
            for p in page.items { statuses[p.remoteStatus?.rawValue ?? "?", default: 0] += 1 }
            return "\(page.items.count)件（\(statuses.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " "))）"
        },
        StepSpec(id: "post.getEditable", title: "編集用の投稿（post.getEditable）", creatorOnly: true) { ds, account, ctx in
            guard let id = ctx.managedPostID else { return nil }
            let post = try await ds.editablePost(id: id, account: account)
            return "status: \(post.status.rawValue) / ブロック: \(LiveAPICheck.kinds(post.blocks).isEmpty ? "なし" : LiveAPICheck.kinds(post.blocks))"
        },
        StepSpec(id: "relationship.listFans", title: "ファン（relationship.listFans）", creatorOnly: true) { ds, account, _ in
            LiveAPICheck.count(try await ds.fans(account: account, cursor: nil).items, "ファン")
        },
        StepSpec(id: "dashboard", title: "ダッシュボード（支援者数・支援額）", creatorOnly: true) { ds, account, _ in
            let d = try await ds.creatorDashboard(account: account)
            return "month: \(d.month) / 支援者数: \(d.supporterCount == nil ? "取得不可" : "取得") / 支援額: \(d.earnings == nil ? "取得不可" : "取得") / 投稿数: \(d.postCount == nil ? "取得不可" : "取得")"
        },
    ]
}

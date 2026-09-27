import SwiftData
import SwiftUI
import UserNotifications
import XCTest
@testable import FANBOXClient

/// Research detail rendering (off-main, chunked, cached) and the Research Mode demo tools (SPEC §36 / §45).
@MainActor
final class FixSecurityResearchViewTests: XCTestCase {
    // MARK: - Detail rendering

    func testChunksKeepLinesAndCutLongLines() {
        XCTAssertEqual(ResearchLogRendering.chunks("a\nb\nc", limit: 3).map(\.text), ["a\nb", "c"])
        XCTAssertEqual(ResearchLogRendering.chunks("", limit: 10).map(\.text), [""])
        XCTAssertEqual(ResearchLogRendering.chunks("x\n\ny", limit: 100).map(\.text), ["x\n\ny"])

        let long = String(repeating: "0123456789", count: 500)   // one 5,000-character line (minified HTML)
        let pieces = ResearchLogRendering.chunks("head\n" + long + "\ntail", limit: 2_000)
        XCTAssertTrue(pieces.allSatisfy { $0.text.count <= 2_000 })
        XCTAssertEqual(pieces.map(\.text).joined(), "head" + long + "\ntail")
        XCTAssertEqual(Set(pieces.map(\.id)).count, pieces.count, "stable unique ids")

        let lines = (1...300).map { "line \($0)" }.joined(separator: "\n")
        let grouped = ResearchLogRendering.chunks(lines, limit: 200)
        XCTAssertGreaterThan(grouped.count, 1)
        XCTAssertEqual(grouped.map(\.text).joined(separator: "\n"), lines)
    }

    func testRenderingOfLargeSingleLineHTMLIsRedactedTruncatedAndChunked() {
        let token = "deadbeef1234cafe"
        let filler = String(repeating: "<div class=\"c\">本文テキスト</div>", count: 2_500)
        let html = "<html><head><meta name=\"metadata\" content=\"{&#34;csrfToken&#34;:&#34;\(token)&#34;}\"></head><body>"
            + "<script>var h={cookie:e.cookie};</script>" + filler + "</body></html>"
        let entry = ResearchLogSnapshot(kind: .request, accountID: "acc", method: "GET", endpoint: "https://www.fanbox.cc/",
                                        statusCode: 200, requestHeaders: "Cookie: FANBOXSESSID=\(token)\nAccept: text/html",
                                        responseHeaders: "Content-Type: text/html", responseBody: html)
        let r = ResearchLogRendering.make(entry)
        let everything = (r.summary.map(\.value) + r.headerBlocks.flatMap { $0.chunks.map(\.text) }
            + r.plainBody.chunks.map(\.text) + [r.shareText]).joined(separator: "\n")
        XCTAssertFalse(everything.contains(token))
        XCTAssertNil(r.prettyBody, "HTML is not JSON")
        XCTAssertTrue(r.hasBody)
        XCTAssertGreaterThan(r.plainBody.truncatedCount, 0, "display limit applies")
        XCTAssertGreaterThan(r.plainBody.chunks.count, 10)
        XCTAssertTrue(r.plainBody.chunks.allSatisfy { $0.text.count <= ResearchLogRendering.chunkCharacterLimit })
        XCTAssertTrue(r.plainBody.chunks.map(\.text).joined().contains("本文テキスト</div><div class=\"c\">"),
                      "single-line HTML after a mid-line cookie: stays readable")
        XCTAssertEqual(r.headerBlocks.map(\.label), ["Request Headers", "Response Headers"])
        XCTAssertTrue(r.summary.contains { $0.label == "HTTP Status" && $0.value == "200" })
        XCTAssertTrue(r.shareText.contains("Safe Response Body:"))
    }

    func testRenderingCachesPlainAndPrettyJSON() throws {
        let body = #"{"body":{"title":"t","csrfToken":"LEAK","items":[1,2]}}"#
        let entry = ResearchLogSnapshot(kind: .request, endpoint: "https://api.fanbox.cc/post.info?postId=1", statusCode: 200,
                                        responseBody: body)
        let r = ResearchLogRendering.make(entry)
        let pretty = try XCTUnwrap(r.prettyBody).chunks.map(\.text).joined(separator: "\n")
        XCTAssertTrue(pretty.contains("\n  \"body\" : {"), pretty)
        XCTAssertFalse(pretty.contains("LEAK"))
        XCTAssertFalse(r.plainBody.chunks.map(\.text).joined().contains("LEAK"))
        XCTAssertEqual(r.plainBody.truncatedCount, 0)
        // Same redaction as the plain formatter output.
        XCTAssertEqual(r.shareText, ResearchLogFormatter.text(for: entry, bodyLimit: ResearchLogFormatter.displayBodyLimit))
    }

    func testEmptyBodyRendersPlaceholder() {
        let r = ResearchLogRendering.make(ResearchLogSnapshot(kind: .navigation, endpoint: "https://www.fanbox.cc/"))
        XCTAssertFalse(r.hasBody)
        XCTAssertEqual(r.plainBody.chunks.map(\.text), ["(なし)"])
    }

    func testDetailViewRendersFromStore() {
        let env = AppEnvironment.preview(seedDemo: false)
        let log = ResearchLog(kind: .request, method: "GET", endpoint: "https://api.fanbox.cc/post.info?postId=1", statusCode: 200,
                              responseBody: #"{"body":{"title":"t"}}"#)
        env.store.context.insert(log)
        env.store.save()
        for view in [AnyView(NavigationStack { ResearchLogDetailView(logID: log.id, focus: .responses) }),
                     AnyView(NavigationStack { ResearchLogDetailView(logID: "missing") }),
                     AnyView(NavigationStack { ResearchModeView() })] {
            let host = UIHostingController(rootView: view.environment(env).environment(env.router).environment(env.settings)
                .modelContainer(env.container))
            host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            host.view.layoutIfNeeded()
            XCTAssertNotNil(host.view)
        }
    }

    // MARK: - Demo tools

    private struct DemoOnlyProvider: RemoteDataSourceProvider {
        let demo: DemoRemoteDataSource
        func dataSource(for account: AccountContext) -> RemoteDataSource { demo }
    }

    @MainActor
    private final class Harness {
        let store: LocalStore
        let settings: AppSettings
        let engine: SyncEngine
        let coordinator: SyncCoordinator
        let notifications: NotificationService
        let poster = SyncRecordingPoster()
        let world = DemoWorld(now: Date(), latencyScale: 0)

        init() throws {
            store = LocalStore(container: try PersistenceController.makeContainer(inMemory: true))
            settings = AppSettings(defaults: UserDefaults(suiteName: "fixsecurity-demo-\(UUID().uuidString)")!)
            let network = NetworkModeController(settings: settings, policyStore: NetworkPolicyStore())
            let provider = DemoOnlyProvider(demo: DemoRemoteDataSource(policy: nil, world: world))
            engine = SyncEngine(store: store, remote: provider, settings: settings, network: network)
            let replies = ReplyQueue(store: store, remote: provider, settings: settings, network: network)
            coordinator = SyncCoordinator(engine: engine, settings: settings, network: network, replies: replies)
            notifications = NotificationService(store: store, engine: engine, replies: replies, router: AppRouter(), settings: settings)
            notifications.poster = poster
            engine.onNewNotificationEvents = { [notifications] ids in await notifications.process(newEventIDs: ids) }
        }

        @discardableResult
        func addDemoAccount(_ name: String, creatorID: String? = nil) -> Account {
            let account = Account(kind: .demo, displayName: name, pixivUserID: "demo-\(name)", creatorID: creatorID,
                                  isMain: store.accounts(includeDisabled: true).isEmpty,
                                  sortOrder: store.accounts(includeDisabled: true).count, sessionState: .valid)
            store.context.insert(account)
            store.save()
            return account
        }

        func run(_ action: ResearchDemoTools.Action) async -> ResearchDemoTools.Outcome {
            await ResearchDemoTools.run(action, world: world, store: store, engine: engine,
                                        poll: { [coordinator] in await coordinator.pollOnce() })
        }
    }

    func testNewPostReachesLocalNotificationThroughPolling() async throws {
        let h = try Harness()
        h.addDemoAccount("A")
        let outcome = await h.run(.newPost)
        XCTAssertGreaterThanOrEqual(outcome.createdEvents, 1, outcome.message)
        let request = try XCTUnwrap(h.poster.requests.first { $0.content.categoryIdentifier == NotificationService.postCategoryID },
                                    "requests: \(h.poster.requests.map(\.content.title))")
        XCTAssertTrue(request.content.body.contains("Demo新着投稿"), request.content.body)
        let eventID = try XCTUnwrap(request.content.userInfo[NotificationService.eventIDKey] as? String)
        let event = try XCTUnwrap(h.store.notificationEvent(id: eventID))
        XCTAssertEqual(event.type, .newPost)
        XCTAssertEqual(event.prefetchState, .textReady, "post text prefetched before the notification")
        XCTAssertTrue(event.deliveredLocally)
        // The simulated items only arrive once: a second poll delivers nothing new.
        let before = h.poster.requests.count
        await h.coordinator.pollOnce()
        XCTAssertEqual(h.poster.requests.count, before)
    }

    func testNewsletterReachesLocalNotificationThroughPolling() async throws {
        let h = try Harness()
        h.addDemoAccount("A")
        let outcome = await h.run(.newsletter)
        XCTAssertGreaterThanOrEqual(outcome.createdEvents, 1, outcome.message)
        let request = try XCTUnwrap(h.poster.requests.first { $0.content.title.contains("おたより") },
                                    "requests: \(h.poster.requests.map(\.content.title))")
        XCTAssertTrue(request.content.subtitle.contains("Demoおたより"), request.content.subtitle)
        XCTAssertTrue(request.content.body.contains("デモ用に生成されたおたより"), request.content.body)
        let letters = h.store.fetch(FetchDescriptor<Newsletter>()).filter { $0.newsletterID.hasPrefix("demo-nl-live-") }
        XCTAssertEqual(letters.count, 1)
    }

    func testCommentReachesDemoCreator() async throws {
        let h = try Harness()
        h.addDemoAccount("A")
        let creator = h.addDemoAccount("Creator", creatorID: DemoFixtures.selfCreatorID)
        let outcome = await h.run(.comment)
        XCTAssertGreaterThanOrEqual(outcome.createdEvents, 1, outcome.message)
        let request = try XCTUnwrap(h.poster.requests.first { $0.content.categoryIdentifier == NotificationService.commentCategoryID },
                                    "requests: \(h.poster.requests.map(\.content.title))")
        let eventID = try XCTUnwrap(request.content.userInfo[NotificationService.eventIDKey] as? String)
        XCTAssertEqual(h.store.notificationEvent(id: eventID)?.accountIDs, [creator.id])
    }

    func testDemoToolsGuards() async throws {
        let h = try Harness()
        var outcome = await h.run(.newPost)
        XCTAssertEqual(outcome.createdEvents, 0)
        XCTAssertTrue(outcome.message.contains("デモアカウント"))
        h.addDemoAccount("A")
        outcome = await h.run(.comment)
        XCTAssertEqual(outcome.createdEvents, 0, "no Demo Creator account to receive the comment")
        XCTAssertTrue(h.poster.requests.isEmpty)
    }

    func testDemoWorldNewsletterHookIsScopedToSupporters() async {
        let world = DemoWorld(now: Date(), latencyScale: 0)
        let viewer = AccountContext(accountID: "a", kind: .demo, pixivUserID: "demo-x", fanboxUserID: nil, creatorID: nil)
        let before = await world.newsletters(account: viewer).count
        let id = await world.simulateIncomingNewsletter()
        let letters = await world.newsletters(account: viewer)
        XCTAssertEqual(letters.count, before + 1)
        XCTAssertEqual(letters.first?.id, id, "newest first")
        let fetched = try? await world.newsletter(id: id, account: viewer)
        XCTAssertEqual(fetched?.id, id)
        XCTAssertTrue(ResearchDemoTools.world(of: DefaultRemoteDataSourceProvider(
            fanbox: FanboxTestHarness().source, demo: DemoRemoteDataSource(policy: nil, world: world))) === world)
    }
}

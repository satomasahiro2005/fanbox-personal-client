import SwiftData
import SwiftUI
import XCTest
@testable import FANBOXClient

@MainActor
final class SettingsModuleTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "settings-tests-\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    // MARK: - AppSettings persistence

    func testAppSettingsDefaults() {
        let settings = AppSettings(defaults: makeDefaults())
        XCTAssertEqual(settings.networkModePreference, .automatic)
        XCTAssertEqual(settings.cacheCapacity, .gb5)
        XCTAssertTrue(settings.mediaPrefetchWiFiOnly)
        XCTAssertFalse(settings.extremeShowsThumbnails)
        XCTAssertFalse(settings.autoSaveViewedPosts)
        XCTAssertFalse(settings.autoSendStaleReplies, "SPEC §22: stale replies need re-confirmation by default")
        XCTAssertFalse(settings.researchModeEnabled)
        XCTAssertFalse(settings.remoteRelayEnabled, "SPEC §28: relay is optional and off by default")
        XCTAssertEqual(settings.remoteRelayURL, "")
        XCTAssertTrue(settings.localNotificationsEnabled)
    }

    func testAppSettingsPersistenceRoundTrip() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.networkModePreference = .extreme
        settings.cacheCapacity = .unlimited
        settings.mediaPrefetchWiFiOnly = false
        settings.extremeShowsThumbnails = true
        settings.autoSaveViewedPosts = true
        settings.creatorRecentCount = 23
        settings.autoSendStaleReplies = true
        settings.staleReplyThreshold = 3 * 3600
        settings.foregroundPollingInterval = 300
        settings.localNotificationsEnabled = false
        settings.researchModeEnabled = true
        settings.remoteRelayEnabled = true
        settings.remoteRelayURL = "https://relay.example.com/v1"
        settings.showAdultContent = false

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.networkModePreference, .extreme)
        XCTAssertEqual(reloaded.cacheCapacity, .unlimited)
        XCTAssertFalse(reloaded.mediaPrefetchWiFiOnly)
        XCTAssertTrue(reloaded.extremeShowsThumbnails)
        XCTAssertTrue(reloaded.autoSaveViewedPosts)
        XCTAssertEqual(reloaded.creatorRecentCount, 23)
        XCTAssertTrue(reloaded.autoSendStaleReplies)
        XCTAssertEqual(reloaded.staleReplyThreshold, 3 * 3600)
        XCTAssertEqual(reloaded.foregroundPollingInterval, 300)
        XCTAssertFalse(reloaded.localNotificationsEnabled)
        XCTAssertTrue(reloaded.researchModeEnabled)
        XCTAssertTrue(reloaded.remoteRelayEnabled)
        XCTAssertEqual(reloaded.remoteRelayURL, "https://relay.example.com/v1")
        XCTAssertFalse(reloaded.showAdultContent)

        // Every capacity option survives a round trip.
        for capacity in CacheCapacity.allCases {
            settings.cacheCapacity = capacity
            XCTAssertEqual(AppSettings(defaults: defaults).cacheCapacity, capacity)
        }
        for mode in NetworkModePreference.allCases {
            settings.networkModePreference = mode
            XCTAssertEqual(AppSettings(defaults: defaults).networkModePreference, mode)
        }
    }

    // MARK: - Research log formatting is redacted (SPEC §38 / §44)

    func testResearchDetailFormattingRedactsCookieSecrets() {
        let entry = ResearchLogSnapshot(
            kind: .request, accountID: "acc-1", accountName: "Main", method: "GET",
            endpoint: "https://api.fanbox.cc/post.info?postId=1&token=abc",
            statusCode: 200, durationMs: 1234, priorityRaw: RequestPriority.interactiveRead.rawValue,
            requestHeaders: "Cookie: FANBOXSESSID=abc\nX-CSRF-Token: abc\nAccept: application/json",
            responseHeaders: "Set-Cookie: FANBOXSESSID=abc; path=/; secure\nContent-Type: application/json",
            responseBody: #"{"body":{"title":"ok","csrfToken":"abc"},"note":"Cookie: FANBOXSESSID=abc"}"#,
            bytes: 2048, errorDescription: "Cookie: FANBOXSESSID=abc")

        let text = ResearchLogFormatter.text(for: entry)
        XCTAssertFalse(text.contains("abc"), text)
        XCTAssertFalse(text.contains("FANBOXSESSID=abc"))

        for field in ResearchLogFormatter.fields(for: entry) {
            XCTAssertFalse(field.value.contains("abc"), "\(field.label) leaked: \(field.value)")
        }
        XCTAssertFalse(ResearchLogFormatter.summaryLine(entry).contains("abc"))
        XCTAssertFalse(ResearchLogFormatter.displayBody(entry.responseBody, prettyJSON: true).text.contains("abc"))

        let export = ResearchLogFormatter.export([entry, entry], schemaLines: ["post.info: known 3"], researchModeEnabled: true,
                                                 appVersion: "1.0.0 (1)")
        XCTAssertFalse(export.contains("abc"))
    }

    func testDisplayRedactionPatterns() {
        let cases = [
            "Cookie: FANBOXSESSID=abc",
            "cookie:FANBOXSESSID=abc; p_ab_id=1",
            "X-CSRF-Token: abc",
            "Authorization: Bearer abc",
            "see bearer abc here",
            "FANBOXSESSID: abc",
            "https://example.com/?a=1&csrf_token=abc&b=2",
            #"{"password": "abc", "cardNumber": "abc"}"#,
            "\"Cookie\": \"FANBOXSESSID=abc\"",
            "form: password=abc&cvc=abc",
        ]
        for input in cases {
            let output = ResearchDisplayRedaction.apply(input)
            XCTAssertFalse(output.contains("abc"), "\(input) → \(output)")
            XCTAssertTrue(output.contains(SecretRedactor.placeholder), output)
            XCTAssertEqual(ResearchDisplayRedaction.apply(output), output, "redaction must be idempotent")
        }

        // Luhn-valid card numbers are masked, ordinary ids are not.
        XCTAssertEqual(ResearchDisplayRedaction.apply("card 4111 1111 1111 1111 end"), "card <REDACTED> end")
        XCTAssertEqual(ResearchDisplayRedaction.apply("card 4111-1111-1111-1111"), "card <REDACTED>")
        XCTAssertEqual(ResearchDisplayRedaction.apply("postId=1234567 creatorId=abcdef"), "postId=1234567 creatorId=abcdef")
        XCTAssertEqual(ResearchDisplayRedaction.apply("GET 200 https://api.fanbox.cc/post.info?postId=987654"),
                       "GET 200 https://api.fanbox.cc/post.info?postId=987654")
        XCTAssertFalse(ResearchDisplayRedaction.luhnValid("4111111111111112"))
        XCTAssertTrue(ResearchDisplayRedaction.luhnValid("4111111111111111"))
    }

    func testResearchExportFromStoreIsRedacted() throws {
        let env = AppEnvironment.preview(seedDemo: true)
        let account = try XCTUnwrap(env.store.accounts().first)
        env.store.context.insert(ResearchLog(kind: .request, accountID: account.id, method: "POST",
                                             endpoint: "https://api.fanbox.cc/post.addComment",
                                             statusCode: 403, durationMs: 88, priorityRaw: 100,
                                             requestHeaders: "Cookie: FANBOXSESSID=abc", responseHeaders: "",
                                             responseBody: "{\"error\":\"general_error\"}"))
        env.store.context.insert(ResearchLog(kind: .navigation, accountID: account.id, endpoint: "https://www.fanbox.cc/"))
        env.store.save()

        let counts = ResearchLogCounts.load(store: env.store)
        XCTAssertEqual(counts.requests, 1)
        XCTAssertEqual(counts.navigation, 1)

        let snapshots = ResearchExportBuilder.snapshots(store: env.store)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.first { $0.kind == .request }?.accountName, account.displayName)

        let text = ResearchExportBuilder.exportText(store: env.store, researchModeEnabled: false)
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("abc"))

        ResearchMaintenance.clearLogs(store: env.store)
        XCTAssertEqual(ResearchLogCounts.load(store: env.store), ResearchLogCounts())
    }

    // MARK: - Pure helpers

    func testNetworkModeGuideFollowsMediaPolicy() {
        func cell(_ label: String, _ mode: NetworkMode, thumbs: Bool = false) -> NetworkModeGuide.Cell {
            let row = NetworkModeGuide.rows.first { $0.label == label }!
            return NetworkModeGuide.cell(row, mode: mode, extremeShowsThumbnails: thumbs)
        }
        // Normal: 本文 / Thumbnail / Display ON, Prefetch ON.
        XCTAssertEqual(cell("本文 / JSON", .normal), .on)
        XCTAssertEqual(cell("Thumbnail", .normal), .on)
        XCTAssertEqual(cell("Display Image", .normal), .on)
        XCTAssertEqual(cell("Image Prefetch", .normal), .on)
        // Low Data: Original Prefetch OFF, Video Prefetch OFF.
        XCTAssertEqual(cell("Thumbnail", .lowData), .on)
        XCTAssertEqual(cell("Original Prefetch", .lowData), .off)
        XCTAssertEqual(cell("Video Prefetch", .lowData), .off)
        // Extreme: text ON, media manual, thumbnail optional.
        XCTAssertEqual(cell("本文 / JSON", .extreme), .on)
        XCTAssertEqual(cell("Display Image", .extreme), .manual)
        XCTAssertEqual(cell("Video", .extreme), .manual)
        XCTAssertEqual(cell("Thumbnail", .extreme, thumbs: false), .manual)
        XCTAssertEqual(cell("Thumbnail", .extreme, thumbs: true), .on)
        // Offline: everything stops.
        for row in NetworkModeGuide.rows {
            XCTAssertEqual(NetworkModeGuide.cell(row, mode: .offline, extremeShowsThumbnails: true), .off, row.label)
        }
        for mode in NetworkModePreference.allCases {
            XCTAssertFalse(NetworkModeGuide.summary(mode).isEmpty)
        }
        XCTAssertEqual(NetworkPathText.describe(pathSatisfied: false, isOnWiFi: true, isConstrained: false, isExpensive: false), "未接続")
        XCTAssertEqual(NetworkPathText.describe(pathSatisfied: true, isOnWiFi: false, isConstrained: true, isExpensive: true),
                       "Wi-Fi 以外 / 省データモード / 従量制")
    }

    func testSettingsChoices() {
        XCTAssertEqual(SettingsChoices.durationLabel(30), "30秒")
        XCTAssertEqual(SettingsChoices.durationLabel(60), "1分")
        XCTAssertEqual(SettingsChoices.durationLabel(30 * 60), "30分")
        XCTAssertEqual(SettingsChoices.durationLabel(5400), "1時間30分")
        XCTAssertEqual(SettingsChoices.durationLabel(86400), "24時間")
        XCTAssertEqual(SettingsChoices.options([30, 60], including: 60), [30, 60])
        XCTAssertEqual(SettingsChoices.options([30, 60], including: 45), [30, 45, 60])
        XCTAssertTrue(SettingsChoices.staleReplyThresholds.contains(AppSettings(defaults: makeDefaults()).staleReplyThreshold))
        XCTAssertTrue(SettingsChoices.pollingIntervals.contains(AppSettings(defaults: makeDefaults()).foregroundPollingInterval))
        XCTAssertTrue(SettingsChoices.creatorRecentCountRange.contains(AppSettings(defaults: makeDefaults()).creatorRecentCount))
    }

    func testRelaySettingsSupport() {
        XCTAssertEqual(RelaySettingsSupport.validate(""), .empty)
        XCTAssertEqual(RelaySettingsSupport.validate("   "), .empty)
        XCTAssertEqual(RelaySettingsSupport.validate("http://relay.example.com"), .notHTTPS)
        XCTAssertEqual(RelaySettingsSupport.validate("https://relay.example.com/v1"), .valid(URL(string: "https://relay.example.com/v1")!))
        XCTAssertEqual(RelaySettingsSupport.validate("https://user:pw@relay.example.com"), .invalid)
        XCTAssertEqual(RelaySettingsSupport.validate("not a url"), .invalid)
        XCTAssertEqual(RelaySettingsSupport.validate("https://"), .invalid)

        XCTAssertEqual(RelaySettingsSupport.tokenHint(nil), "未取得")
        let token = String(repeating: "ab", count: 32)
        let hint = RelaySettingsSupport.tokenHint(token)
        XCTAssertTrue(hint.hasPrefix("abababab…"))
        XCTAssertFalse(hint.contains(token))

        XCTAssertEqual(RelaySettingsSupport.registrationState(enabled: false, urlText: "https://r.example", token: token, lastError: nil),
                       .disabled)
        XCTAssertEqual(RelaySettingsSupport.registrationState(enabled: true, urlText: "", token: nil, lastError: nil), .urlMissing)
        XCTAssertEqual(RelaySettingsSupport.registrationState(enabled: true, urlText: "https://r.example", token: nil, lastError: nil),
                       .waitingForToken)
        XCTAssertEqual(RelaySettingsSupport.registrationState(enabled: true, urlText: "https://r.example", token: nil, lastError: "x"),
                       .failed)
        XCTAssertEqual(RelaySettingsSupport.registrationState(enabled: true, urlText: "https://r.example", token: token, lastError: nil),
                       .tokenReady)
    }

    func testAPISchemaGrouping() {
        XCTAssertEqual(APISchemaGrouping.split("post.info").endpoint, "post.info")
        XCTAssertEqual(APISchemaGrouping.split("post.info").path, "")
        XCTAssertEqual(APISchemaGrouping.split("post.info:body.body.blocks[]").endpoint, "post.info")
        XCTAssertEqual(APISchemaGrouping.split("post.info:body.body.blocks[]").path, "body.body.blocks[]")
        XCTAssertEqual(APISchemaGrouping.pathLabel(""), "(root)")

        let keys = ["post.info:body", "creator.get:body", "post.info:body.body.blocks[]", "post.listHome:body[]"]
        let groups = APISchemaGrouping.group(keys, key: { $0 })
        XCTAssertEqual(groups.map(\.endpoint), ["creator.get", "post.info", "post.listHome"])
        XCTAssertEqual(groups[1].items, ["post.info:body", "post.info:body.body.blocks[]"])

        let changedFirst = APISchemaGrouping.group(keys, key: { $0 }, hasChanges: { $0.hasPrefix("post.listHome") }, changedFirst: true)
        XCTAssertEqual(changedFirst.first?.endpoint, "post.listHome")

        let line = APISchemaGrouping.summaryLine(endpointKey: "post.info:body", known: 3, newFields: ["zeta", "alpha"], missingFields: ["id"])
        XCTAssertEqual(line, "post.info:body: known 3, NEW [alpha, zeta], MISSING [id]")
    }

    func testCacheUsageText() {
        var usage = CacheUsage()
        usage.totalBytes = 500_000_000
        XCTAssertEqual(CacheUsageText.fraction(usage: usage, capacity: .gb1) ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertNil(CacheUsageText.fraction(usage: usage, capacity: .unlimited))
        XCTAssertTrue(CacheUsageText.usageLine(usage: usage, capacity: .unlimited).hasSuffix("/ 無制限"))
        usage.totalBytes = 5_000_000_000
        XCTAssertEqual(CacheUsageText.fraction(usage: usage, capacity: .gb1), 1)
    }

    func testLegalNoticeMatchesSpec() {
        let expected = """
        Copyright © 2026 Masahiro Sato. All rights reserved.

        No license is granted for this source code.
        The source code is publicly available for inspection only.
        Permission to use, copy, modify, distribute, sublicense, or create
        derivative works is not granted unless separately authorized by
        the copyright holder.
        """
        XCTAssertEqual(LegalNotice.copyrightBlock, expected)
        XCTAssertTrue(LegalNotice.policyPoints.joined().contains("Public Source ≠ Open Source"))
    }

    // MARK: - View smoke tests (render without crashing)

    func testSettingsViewsRender() {
        let env = AppEnvironment.preview(seedDemo: true)
        env.store.context.insert(APISchemaSnapshot(endpointKey: "post.info:body", knownFields: ["id", "title"]))
        env.store.save()
        let views: [AnyView] = [
            AnyView(NavigationStack { SettingsRootView() }),
            AnyView(NavigationStack { ResearchModeView() }),
            AnyView(NavigationStack { ResearchLogListView(mode: .requests) }),
            AnyView(NavigationStack { APIInspectorView() }),
            AnyView(NavigationStack { ResearchAccountStateView() }),
            AnyView(NavigationStack { ResearchSupportStateView() }),
            AnyView(NavigationStack { NetworkModeGuideView() }),
            AnyView(NavigationStack { LegalView() }),
        ]
        for view in views {
            let host = UIHostingController(rootView: view
                .environment(env)
                .environment(env.router)
                .environment(env.settings)
                .modelContainer(env.container))
            host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            host.view.layoutIfNeeded()
            XCTAssertNotNil(host.view)
        }
    }
}

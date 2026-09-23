import XCTest
@testable import FANBOXClient

/// SPEC §14: post-payment re-sync schedule, web destination fallbacks, replaced web sessions.
@MainActor
final class FixSupportWebFlowTests: XCTestCase {
    private final class Recorder {
        var calls: [String] = []
        var outcomes: [SyncOutcome] = []
    }

    private func scheduler(_ recorder: Recorder, delays: [Duration] = [.seconds(60), .seconds(240), .seconds(600)]) -> PaymentResyncScheduler {
        PaymentResyncScheduler(delays: delays, sleep: { _ in await Task.yield() }) { accountID in
            recorder.calls.append(accountID)
            return recorder.outcomes.isEmpty ? .skipped(.supports, accountID: accountID) : recorder.outcomes.removeFirst()
        }
    }

    private func changed(_ accountID: String) -> SyncOutcome {
        SyncOutcome(resource: .supports, accountID: accountID, scope: "", newItemIDs: ["c1"], error: nil)
    }

    // MARK: PaymentResyncScheduler

    func testFollowUpsRunUntilAChangeIsObserved() async {
        let recorder = Recorder()
        recorder.outcomes = [.skipped(.supports, accountID: "A"), changed("A")]
        let s = scheduler(recorder)
        await s.start(accountID: "A").value
        XCTAssertEqual(recorder.calls, ["A", "A"], "immediate + first follow-up, which saw the change")
        XCTAssertFalse(s.isScheduled(accountID: "A"))
    }

    func testAllFollowUpsRunWhenNothingChanges() async {
        let recorder = Recorder()
        let s = scheduler(recorder)
        await s.start(accountID: "A").value
        XCTAssertEqual(recorder.calls.count, 1 + PaymentResyncScheduler.followUpDelays.count)
    }

    func testFailedSyncIsRetriedByTheFollowUps() async {
        let recorder = Recorder()
        recorder.outcomes = [.failed(.supports, accountID: "A", error: .offline), changed("A")]
        let s = scheduler(recorder)
        await s.start(accountID: "A").value
        XCTAssertEqual(recorder.calls.count, 2)
    }

    func testImmediateChangeSkipsFollowUps() async {
        let recorder = Recorder()
        recorder.outcomes = [changed("A")]
        await scheduler(recorder).start(accountID: "A").value
        XCTAssertEqual(recorder.calls, ["A"])
    }

    func testOnlySupportPagesGetFollowUps() async {
        let recorder = Recorder()
        let s = scheduler(recorder)
        await s.handleDismissedPaymentSession(WebSessionRequest(accountID: "A", destination: .paymentSettings, purpose: .payment))?.value
        XCTAssertEqual(recorder.calls, ["A"], "payment settings: immediate re-sync only")
        XCTAssertNil(s.handleDismissedPaymentSession(WebSessionRequest(accountID: "A", destination: .plan(creatorID: "c", planID: "1"),
                                                                       purpose: .browse)), "not a payment session")
        XCTAssertTrue(PaymentResyncScheduler.expectsSupportChange(.plan(creatorID: "c", planID: "1")))
        XCTAssertTrue(PaymentResyncScheduler.expectsSupportChange(.creatorPlans(creatorID: "c")))
        XCTAssertTrue(PaymentResyncScheduler.expectsSupportChange(.supportingPlans))
        XCTAssertFalse(PaymentResyncScheduler.expectsSupportChange(.paymentHistory))
    }

    func testRestartCancelsThePreviousSchedule() async {
        let recorder = Recorder()
        let s = PaymentResyncScheduler(delays: [.seconds(60)], sleep: { _ in try await Task.sleep(for: .seconds(3600)) }) { accountID in
            recorder.calls.append(accountID)
            return .skipped(.supports, accountID: accountID)
        }
        let first = s.start(accountID: "A")
        await Task.yield()
        let second = s.start(accountID: "A")
        await first.value
        XCTAssertTrue(s.isScheduled(accountID: "A"), "the replaced task must not clear the new schedule")
        s.cancelAll()
        await second.value
        XCTAssertFalse(s.isScheduled(accountID: "A"))
    }

    func testFollowUpDelaysCoverTheActivationWindow() {
        let total = PaymentResyncScheduler.followUpDelays.reduce(Duration.zero, +)
        XCTAssertGreaterThanOrEqual(total, .seconds(10 * 60))
        XCTAssertLessThanOrEqual(total, .seconds(20 * 60))
    }

    // MARK: Web fallbacks

    func testPaymentDestinationsFallBackToVerifiedPages() {
        XCTAssertEqual(WebDestination.plan(creatorID: "alice", planID: "7").fallbackSteps.map(\.url.absoluteString),
                       ["https://www.fanbox.cc/@alice/plans", "https://www.fanbox.cc/@alice"])
        XCTAssertEqual(WebDestination.paymentSettings.fallbackSteps.first?.url.absoluteString, "https://payment.pixiv.net/cards")
        XCTAssertEqual(WebDestination.paymentHistory.fallbackSteps.first?.url.absoluteString, "https://www.fanbox.cc/invoices")
        XCTAssertEqual(WebDestination.supportingPlans.fallbackSteps.map(\.url), [WebDestination.home.url])
        XCTAssertTrue(WebDestination.home.fallbackSteps.isEmpty)
        XCTAssertTrue(WebDestination.login.fallbackSteps.isEmpty)
        for destination: WebDestination in [.plan(creatorID: "a", planID: "1"), .creatorPlans(creatorID: "a"), .supportingPlans,
                                            .paymentSettings, .paymentHistory] {
            XCTAssertFalse(destination.fallbackSteps.isEmpty, "\(destination)")
            XCTAssertTrue(destination.fallbackSteps.allSatisfy { !$0.title.isEmpty && $0.url.scheme == "https" })
        }
    }

    func testMissingInitialPageSwitchesToTheNextFallbackOnce() {
        let controller = AccountWebController()
        controller.fallbackSteps = WebDestination.plan(creatorID: "alice", planID: "7").fallbackSteps
        XCTAssertTrue(controller.handleMainFrameResponse(status: 404))
        XCTAssertEqual(controller.activeFallback?.title, "プラン一覧")
        XCTAssertTrue(controller.handleMainFrameResponse(status: 410), "the fallback itself is missing too")
        XCTAssertEqual(controller.activeFallback?.title, "クリエイターページ")
        XCTAssertFalse(controller.handleMainFrameResponse(status: 404), "chain exhausted: show FANBOX's own page")
        XCTAssertFalse(controller.handleMainFrameResponse(status: 404), "later navigations are the user's")
    }

    func testFoundOrOtherErrorsKeepTheRequestedPage() {
        let ok = AccountWebController()
        ok.fallbackSteps = WebDestination.paymentSettings.fallbackSteps
        XCTAssertFalse(ok.handleMainFrameResponse(status: 200))
        XCTAssertFalse(ok.handleMainFrameResponse(status: 404), "only the first response of the requested page counts")
        XCTAssertNil(ok.activeFallback)

        let serverError = AccountWebController()
        serverError.fallbackSteps = WebDestination.paymentSettings.fallbackSteps
        XCTAssertFalse(serverError.handleMainFrameResponse(status: 503), "a server error is not a missing page")
        XCTAssertFalse(WebDestination.isMissingPageStatus(nil))
    }

    func testManualFallbackChoice() {
        let controller = AccountWebController()
        controller.fallbackSteps = WebDestination.paymentHistory.fallbackSteps
        controller.openFallback(WebFallbackStep.userSettings)
        XCTAssertEqual(controller.activeFallback, WebFallbackStep.userSettings)
        XCTAssertFalse(controller.handleMainFrameResponse(status: 404), "a manual choice is not chained automatically")
    }

    // MARK: WebBridge

    func testReplacingAPaymentSessionStillRunsItsDismissalWork() {
        let bridge = WebBridge()
        var dismissed: [WebSessionRequest] = []
        bridge.onDismiss = { dismissed.append($0) }
        bridge.openWeb(account: "A", destination: .plan(creatorID: "c", planID: "1"), purpose: .payment)
        let first = bridge.presented
        bridge.openWeb(account: "B", destination: .paymentHistory, purpose: .browse)
        XCTAssertEqual(dismissed.map(\.id), [first?.id].compactMap { $0 })
        XCTAssertEqual(bridge.presented?.accountID, "B")
        bridge.dismiss()
        XCTAssertEqual(dismissed.map(\.accountID), ["A", "B"])
    }
}

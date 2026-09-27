import SwiftUI
import SwiftData

// Shared building blocks of the Support feature (SPEC §10–§15).

/// Verification label for a payment assignment. Only "確認済み" looks like a fact;
/// inferred / manual / unknown are visibly tentative (SPEC §13).
struct VerificationLabel: View {
    let state: VerificationState
    var lastVerifiedAt: Date? = nil

    var body: some View {
        HStack(spacing: 4) {
            PillLabel(text: SupportText.verificationLabel(state), systemImage: SupportText.verificationSymbol(state), tint: tint)
            if state == .verified, let lastVerifiedAt {
                Text(Formatters.shortDate(lastVerifiedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("verification-\(state.rawValue)")
    }

    private var tint: Color {
        switch state {
        case .verified: return .green
        case .inferred: return .orange
        case .manual: return .blue
        case .unknown: return .secondary
        }
    }
}

/// One line of payment facts for a support, shared by every support row:
/// `楽天Visa•••1234 [既定] 前回9/2 ¥500 次回10/1〜5予定`. Without a profile the card label is FANBOX's payment type in
/// Japanese (カード / PayPal / コンビニ). When the line is too narrow it drops, in this order, the 前回 amount, the card
/// icon, the 予定 suffix, the pill of the support's own link, 次回 and 前回; the card label truncates last. The 既定 and
/// 推定 pills always stay: they tell an inherited default or a guess from the support's own link (SPEC §13).
struct SupportPaymentLine: View {
    let summary: SupportPaymentSummary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(dropping: 0)
            line(dropping: 1)
            line(dropping: 2)
            line(dropping: 3)
            line(dropping: 4)
            line(dropping: 5)
            line(dropping: 6)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    /// The line with the first `dropped` compaction steps applied.
    private func line(dropping dropped: Int) -> some View {
        let showsIcon = dropped < 2
        let keepsPill = dropped < 4 || summary.resolution.source != .support
        return HStack(spacing: showsIcon ? 6 : 4) {
            if showsIcon {
                Image(systemName: "creditcard")
                    .foregroundStyle(.secondary)
            }
            Text(summary.resolution.source == .inferred ? "\(summary.cardLabel)?" : summary.cardLabel)
                .foregroundStyle(SupportText.isFact(summary.resolution.verificationState) ? .primary : .secondary)
                .italic(summary.resolution.source == .inferred)
                .lineLimit(1)
            if keepsPill {
                SupportPaymentPill(resolution: summary.resolution)
                    .fixedSize()
            }
            if let last = summary.lastPayment, dropped < 6 {
                Text(SupportText.lastPaymentText(last, showsAmount: dropped < 1))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if let next = summary.nextCharge, dropped < 5 {
                Text(SupportText.nextChargeText(next, showsPlannedSuffix: dropped < 3))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }
}

/// State pill of a resolved payment: the verification label of the support's own link or of a guess, and 既定 for an
/// inherited account default (with 確認済み only when the user confirmed the default). Nothing when nothing resolved.
struct SupportPaymentPill: View {
    let resolution: ResolvedPayment

    var body: some View {
        switch resolution.source {
        case .support, .inferred:
            VerificationLabel(state: resolution.verificationState)
        case .accountDefault:
            HStack(spacing: 4) {
                PillLabel(text: "既定", systemImage: "person.crop.circle", tint: .blue)
                    .accessibilityIdentifier("paymentDefaultPill")
                if resolution.verificationState == .verified {
                    VerificationLabel(state: .verified)
                }
            }
        case .none:
            EmptyView()
        }
    }
}

/// One money value of the dashboard card. `value == nil` renders "データなし" (never an invented number).
struct SupportMoneyRow: View {
    let title: String
    let value: Int?
    var caption: String? = nil
    var identifier: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline)
                if let caption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let value {
                Text(Formatters.yen(value))
                    .font(.title3.monospacedDigit().weight(.semibold))
            } else {
                Text("データなし")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

/// Status pill for non-active supports.
struct SupportStatusPill: View {
    let status: SupportStatus

    var body: some View {
        switch status {
        case .active:
            EmptyView()
        case .ended:
            PillLabel(text: SupportText.statusLabel(status), systemImage: "minus.circle", tint: .secondary)
        case .missing:
            PillLabel(text: SupportText.statusLabel(status), systemImage: "exclamationmark.triangle", tint: .orange)
        case .unknown:
            PillLabel(text: SupportText.statusLabel(status), systemImage: "questionmark", tint: .secondary)
        }
    }
}

/// "停止予定" pill of an active support. FANBOX-observed and user-entered stops look different (SPEC §13 spirit:
/// what the user typed is never shown as if FANBOX had reported it).
struct StopScheduledPill: View {
    let source: SupportStopSource

    var body: some View {
        switch source {
        case .observed:
            PillLabel(text: SupportStopRule.shortLabel(source), systemImage: "calendar.badge.minus", tint: .orange)
                .accessibilityLabel(SupportStopRule.label(source))
                .accessibilityIdentifier("stopScheduled-observed")
        case .userMarked:
            PillLabel(text: SupportStopRule.shortLabel(source), systemImage: "hand.raised", tint: .blue)
                .accessibilityLabel(SupportStopRule.label(source))
                .accessibilityIdentifier("stopScheduled-userMarked")
        }
    }
}

/// Last sync time + error of the `.supports` resource, for `SyncStatusBanner`.
struct SupportSyncStatus {
    var lastSync: Date?
    var hasStoredError: Bool

    init(states: [SyncState], accountIDs: Set<String>? = nil) {
        let relevant = states.filter { accountIDs?.contains($0.accountID) ?? true }
        lastSync = relevant.compactMap(\.lastSuccessfulSync).max()
        hasStoredError = relevant.contains { $0.error != nil && $0.consecutiveFailures > 0 }
    }

    /// The error of the last refresh started from this screen, else a generic one when sync recorded a failure.
    func bannerError(local: RemoteError?) -> RemoteError? {
        if let local { return local }
        return hasStoredError ? .network(code: 0, detail: "") : nil
    }
}

/// Support-related syncs started from the Support screens. Goes through `SyncEngine` only (SPEC §43).
@MainActor
enum SupportSync {
    /// Syncs supports (and optionally paid-payment records) for the given accounts. Returns the first error.
    /// An explicit refresh (`.userRefresh`) also reads the following list: a stop made on FANBOX keeps the plan in
    /// plan.listSupporting until month end and shows only there (停止予定).
    static func refresh(env: AppEnvironment, accountIDs: [String], includePayments: Bool,
                        priority: RequestPriority = .interactiveRead, reason: SyncReason = .userRefresh) async -> RemoteError? {
        var firstError: RemoteError?
        for accountID in accountIDs {
            let outcome = await RequestContext.$priority.withValue(priority) {
                await env.sync.sync(.supports, accountID: accountID, reason: reason)
            }
            if firstError == nil { firstError = outcome.error }
            if reason == .userRefresh, outcome.error == nil {
                // Best effort: a failing following list never fails the support refresh.
                _ = await RequestContext.$priority.withValue(priority) {
                    await env.sync.sync(.creators, accountID: accountID, reason: reason)
                }
            }
            if includePayments {
                let payments = await RequestContext.$priority.withValue(priority) {
                    await env.sync.sync(.payments, accountID: accountID, reason: reason)
                }
                if firstError == nil { firstError = payments.error }
            }
        }
        return firstError
    }

    /// True when the supports of any account were never synced or not for `maxAge`.
    static func isStale(states: [SyncState], accountIDs: [String], now: Date = .now, maxAge: TimeInterval = 30 * 60) -> Bool {
        !staleAccountIDs(states: states, accountIDs: accountIDs, now: now, maxAge: maxAge).isEmpty
    }

    /// The accounts of `accountIDs` whose supports were never synced or not for `maxAge`.
    static func staleAccountIDs(states: [SyncState], accountIDs: [String], now: Date = .now,
                                maxAge: TimeInterval = 30 * 60) -> [String] {
        accountIDs.filter { id in
            guard let last = states.first(where: { $0.accountID == id })?.lastSuccessfulSync else { return true }
            return now.timeIntervalSince(last) > maxAge
        }
    }

    /// Accounts a screen refreshes on its own when their data is stale. An expired, logged-out or quarantined session
    /// never gets a new successful sync, so counting it would make every visit "stale" and re-sync all accounts.
    static func refreshesAutomatically(kind: AccountKind, state: SessionState) -> Bool {
        kind == .demo || state == .valid || state == .unknown
    }
}

/// A web session to open once the sheet that requested it has been dismissed. The web session is presented above the
/// top-most screen, but it closes together with the sheet below it — so a sheet that hands off to the web must be gone
/// first (see `paymentFlowSheet`).
struct PendingWebOpen: Equatable {
    var accountID: String
    var destination: WebDestination
    var purpose: WebPurpose
}

extension SupportSync {
    /// Opens a pending web request (called from a sheet's `onDismiss`).
    static func open(_ pending: PendingWebOpen?, env: AppEnvironment) {
        guard let pending else { return }
        env.web.openWeb(account: pending.accountID, destination: pending.destination, purpose: pending.purpose)
    }
}

/// Identifiable payload for presenting `PaymentFlowView` as a sheet.
struct PaymentFlowRequest: Identifiable, Hashable {
    let id = UUID()
    var creatorID: String
    var planID: String?
    var accountID: String?

    init(creatorID: String, planID: String? = nil, accountID: String? = nil) {
        self.creatorID = creatorID
        self.planID = planID
        self.accountID = accountID
    }
}

/// Presents `PaymentFlowView` (SPEC §14) as a sheet and opens the account-aware web once the sheet is gone.
/// Every entry point uses this, so the flow is always the sheet's root (it owns its NavigationStack — hosts must NOT
/// wrap it in another one) and the hand-off never races the sheet's dismissal.
struct PaymentFlowSheetModifier: ViewModifier {
    @Binding var request: PaymentFlowRequest?

    @Environment(AppEnvironment.self) private var env
    @State private var pendingWeb: PendingWebOpen?

    func body(content: Content) -> some View {
        content.sheet(item: $request, onDismiss: {
            SupportSync.open(pendingWeb, env: env)
            pendingWeb = nil
        }) { request in
            PaymentFlowView(creatorID: request.creatorID, planID: request.planID, preselectedAccountID: request.accountID) { pending in
                pendingWeb = pending
                self.request = nil
            }
        }
        .closesOnNotificationRoute($request)
    }
}

extension View {
    /// See `PaymentFlowSheetModifier`.
    func paymentFlowSheet(_ request: Binding<PaymentFlowRequest?>) -> some View {
        modifier(PaymentFlowSheetModifier(request: request))
    }
}

/// Identifiable payload for presenting the assignment editor.
struct AssignmentEditRequest: Identifiable, Hashable {
    var accountID: String
    var creatorID: String
    var planID: String?
    var id: String { "\(accountID)|\(creatorID)" }
}

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

/// "楽天カード / Visa •••• 1234 [確認済み]" — the payment method the user believes pays a support.
struct AssignmentSummaryView: View {
    let assignment: AssignmentSnapshot?
    let profile: PaymentProfile?
    /// Display-only guess (never stored as verified) when no assignment exists.
    var inferredProfile: PaymentProfile? = nil
    var reportedPaymentMethod: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let profile, let assignment, assignment.paymentProfileID != nil {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard")
                        .foregroundStyle(.secondary)
                    Text(profile.nickname)
                        .font(.subheadline)
                        .foregroundStyle(SupportText.isFact(assignment.verificationState) ? .primary : .secondary)
                        .italic(!SupportText.isFact(assignment.verificationState))
                    Text(profile.displayDetail).font(.caption).foregroundStyle(.secondary)
                }
                VerificationLabel(state: assignment.verificationState, lastVerifiedAt: assignment.lastVerifiedAt)
            } else if let inferredProfile {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard")
                        .foregroundStyle(.secondary)
                    Text("\(inferredProfile.nickname)?")
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.secondary)
                }
                VerificationLabel(state: .inferred)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard")
                        .foregroundStyle(.tertiary)
                    Text("支払い方法: 未設定").font(.subheadline).foregroundStyle(.secondary)
                }
                VerificationLabel(state: .unknown)
            }
            if let reportedPaymentMethod, !reportedPaymentMethod.isEmpty {
                Text("FANBOX 上の支払い種別: \(reportedPaymentMethod)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
    static func refresh(env: AppEnvironment, accountIDs: [String], includePayments: Bool,
                        priority: RequestPriority = .interactiveRead, reason: SyncReason = .userRefresh) async -> RemoteError? {
        var firstError: RemoteError?
        for accountID in accountIDs {
            let outcome = await RequestContext.$priority.withValue(priority) {
                await env.sync.sync(.supports, accountID: accountID, reason: reason)
            }
            if firstError == nil { firstError = outcome.error }
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
        for id in accountIDs {
            guard let last = states.first(where: { $0.accountID == id })?.lastSuccessfulSync else { return true }
            if now.timeIntervalSince(last) > maxAge { return true }
        }
        return false
    }
}

/// A web session to open once the sheet that requested it has been dismissed
/// (the account-aware web cover is presented from the root and cannot appear on top of a sheet).
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
}

/// Identifiable payload for presenting the assignment editor.
struct AssignmentEditRequest: Identifiable, Hashable {
    var accountID: String
    var creatorID: String
    var planID: String?
    var id: String { "\(accountID)|\(creatorID)" }
}

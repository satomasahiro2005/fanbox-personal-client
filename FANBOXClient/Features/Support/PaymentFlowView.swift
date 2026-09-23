import SwiftUI

/// Placeholder — SPEC §14 flow: Plan → Account → Payment Profile → account-aware WebView → resync.
struct PaymentFlowView: View {
    let creatorID: String
    var planID: String? = nil
    var preselectedAccountID: String? = nil

    var body: some View {
        Text("PaymentFlowView")
    }
}

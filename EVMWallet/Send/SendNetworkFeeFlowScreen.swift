import SwiftUI

private enum SendNetworkFeeRoute: Hashable {
    case custom(SendNetworkFeeQuote?)
}

struct SendNetworkFeeFlowScreen: View {
    let database: WalletDatabase
    let feePreferences: SendNetworkFeePreferenceRepository
    let draft: SendDraft
    let nativeUnitUSDPrice: Decimal?
    let initialPolicy: SendNetworkFeePolicy
    let onPolicyChanged: (SendNetworkFeePolicy) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [SendNetworkFeeRoute] = []

    init(
        database: WalletDatabase,
        feePreferences: SendNetworkFeePreferenceRepository? = nil,
        draft: SendDraft,
        nativeUnitUSDPrice: Decimal?,
        initialPolicy: SendNetworkFeePolicy,
        onPolicyChanged: @escaping (SendNetworkFeePolicy) -> Void
    ) {
        self.database = database
        self.feePreferences = feePreferences
            ?? SendNetworkFeePreferenceRepository(database: database)
        self.draft = draft
        self.nativeUnitUSDPrice = nativeUnitUSDPrice
        self.initialPolicy = initialPolicy
        self.onPolicyChanged = onPolicyChanged
    }

    var body: some View {
        NavigationStack(path: ($path)) {
            SendNetworkFeeSelectionScreen(
                database: database,
                feePreferences: feePreferences,
                draft: estimationDraft,
                nativeUnitUSDPrice: nativeUnitUSDPrice,
                initialPolicy: initialPolicy,
                onPolicyChanged: finish,
                onCustom: { quote in
                    path.append(.custom(quote))
                }
            )
            .navigationDestination(
                for: SendNetworkFeeRoute.self
            ) { route in
                switch route {
                case let .custom(quote):
                    SendCustomNetworkFeeScreen(
                        database: database,
                        feePreferences: feePreferences,
                        draft: estimationDraft,
                        nativeUnitUSDPrice: nativeUnitUSDPrice,
                        initialPolicy: initialPolicy,
                        quote: quote,
                        onPolicyChanged: finish
                    )

                }
            }
        }
    }

    private var estimationDraft: SendDraft {
        draft
            .replacingFeePolicy(initialPolicy)
    }

    private func finish(_ policy: SendNetworkFeePolicy) {
        onPolicyChanged(policy)
        dismiss()
    }

}

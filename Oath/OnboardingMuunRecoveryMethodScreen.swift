import SwiftUI

struct OnboardingMuunRecoveryMethodScreen: View {
    let onEmergencyKit: () -> Void
    let onEncryptedKeys: () -> Void

    var body: some View {
        List {
            Group {
                Section {
                    MuunRecoveryMethodRow(
                        title: "muun.recovery.method.emergency.title",
                        detail: "muun.recovery.method.emergency.detail",
                        action: onEmergencyKit
                    )

                    MuunRecoveryMethodRow(
                        title: "muun.recovery.method.keys.title",
                        detail: "muun.recovery.method.keys.detail",
                        action: onEncryptedKeys
                    )
                } footer: {
                    Text("muun.recovery.bitcoin_only")
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("muun.recovery.title")
        .navigationBarTitleDisplayMode(.inline)
    }
}

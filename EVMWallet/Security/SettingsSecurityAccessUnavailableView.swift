import SwiftUI

struct SettingsSecurityAccessUnavailableView: View {
    let isAwaitingAuthorization: Bool
    let retry: () -> Void

    var body: some View {
        Group {
            if isAwaitingAuthorization {
                Text("settings.security.loading")
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(
                        "settings.security.load.error.title",
                        systemImage: "circle.dashed"
                    )
                } description: {
                    Text("settings.security.load.error.message")
                } actions: {
                    Button("settings.security.load.retry", action: UniHaptic.action(retry))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
            }
        }
        .navigationTitle("settings.security.title")
        .navigationBarTitleDisplayMode(.inline)
    }
}

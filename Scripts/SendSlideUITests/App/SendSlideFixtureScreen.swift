import SwiftUI
import LocalAuthentication

/// Uses the production slider without a wallet, signing, or broadcast.
struct SendSlideFixtureScreen: View {
    @State private var sends = 0
    @State private var enabled = true
    @State private var resetID = UUID()
    @State private var committedAt: TimeInterval = 0
    @State private var simulatedInactive = false
    @State private var authorizationStatus = "Idle"
    @Environment(\.scenePhase) private var scenePhase

    private var simulatesAuthorization: Bool {
        ProcessInfo.processInfo.arguments.contains("--fixture-authorization")
    }
    private var usesFaceID: Bool {
        ProcessInfo.processInfo.arguments.contains("--fixture-face-id")
    }

    var body: some View {
        NavigationStack {
            List {
                Text(verbatim: String(sends)).accessibilityIdentifier("fixture-send-count")
                Text(verbatim: String(committedAt)).accessibilityIdentifier("fixture-committed-at")
                Text(verbatim: authorizationStatus).accessibilityIdentifier("fixture-authorization-status")
                Button("send.review.slide_action") {
                    sends = 0
                    resetForRetry()
                }
                .accessibilityIdentifier("fixture-reset")
                Toggle("send.review.slide_action", isOn: $enabled)
                    .accessibilityIdentifier("fixture-enabled")
                if simulatesAuthorization {
                    Button("Complete authentication") {
                        simulatedInactive = false
                        enabled = true
                        authorizationStatus = "Authenticated"
                    }.accessibilityIdentifier("fixture-auth-success")
                    Button("Cancel authentication") {
                        resetForRetry()
                    }.accessibilityIdentifier("fixture-auth-cancel")
                }
            }
            .navigationTitle("send.review.title")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(WalletTheme.groupedBackground)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                SendSlideControl(isEnabled: enabled, resetID: resetID) {
                    sends += 1
                    committedAt = Date().timeIntervalSince1970
                    if simulatesAuthorization {
                        enabled = false
                        authorizationStatus = "Authenticating"
                        simulatedInactive = true
                    } else if usesFaceID {
                        authenticateWithFaceID()
                    }
                }
                    .environment(\.scenePhase, simulatedInactive ? .inactive : scenePhase)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    private func resetForRetry() {
        simulatedInactive = false
        enabled = true
        authorizationStatus = "Ready to retry"
        resetID = UUID()
    }

    private func authenticateWithFaceID() {
        enabled = false
        authorizationStatus = "Authenticating"
        Task { @MainActor in
            let context = LAContext()
            context.localizedFallbackTitle = ""
            do {
                if try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Verify the completed slider remains checked during Face ID.") {
                    authorizationStatus = "Authenticated"
                    enabled = true
                } else {
                    resetForRetry()
                }
            } catch {
                resetForRetry()
            }
        }
    }
}

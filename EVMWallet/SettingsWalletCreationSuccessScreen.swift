import SwiftUI

struct SettingsWalletCreationSuccessScreen: View {
    let isReady: Bool
    let onPrepare: () -> Void
    let onDone: () -> Void

    @State private var didRequestPreparation = false
    @State private var didAnnounceSuccess = false

    private let backupContext: WalletSuccessBackupContext?

    init(
        isReady: Bool = true,
        backupContext: WalletSuccessBackupContext? = nil,
        onPrepare: @escaping () -> Void = {},
        onDone: @escaping () -> Void
    ) {
        self.isReady = isReady
        self.backupContext = backupContext
        self.onPrepare = onPrepare
        self.onDone = onDone
    }

    var body: some View {
        WalletSuccessPresentation(
            isPreparing: !isReady,
            backupContext: backupContext
        ) {
            actions
        }
        // Keeping the bar in place, with nothing in it, lets the push keep the
        // system's own transition instead of dropping the bar mid-animation.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .background {
            WalletHomeFirstFrameObserver(
                onFirstRenderedFrame: handleFirstRenderedFrame
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onChange(of: isReady) { _, ready in
            if ready { announceSuccess() }
        }
    }

    private var actions: some View {
        PrimaryWalletButton(
            title: "success.open",
            hapticPolicy: .silent,
            action: onDone
        )
        .disabled(!isReady)
        .walletActionScreenMargins()
        .frame(maxWidth: .infinity)
    }

    @MainActor
    private func handleFirstRenderedFrame() {
        if isReady {
            announceSuccess()
        } else if !didRequestPreparation {
            didRequestPreparation = true
            onPrepare()
        }
    }

    private func announceSuccess() {
        guard !didAnnounceSuccess else { return }
        didAnnounceSuccess = true
        UniHaptic.play(.walletCreated)
    }
}

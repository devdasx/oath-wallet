import SwiftUI

struct WalletSuccessView: View {
    private let isReady: Bool
    private let onPrepare: () -> Void
    private let onContinue: () -> Void

    @State private var didRequestPreparation = false
    @State private var didAnnounceSuccess = false

    private let kind: WalletSuccessKind

    private let backupContext: WalletSuccessBackupContext?
    private let allowsManualBackup: Bool

    init(
        kind: WalletSuccessKind = .created,
        isReady: Bool = true,
        backupContext: WalletSuccessBackupContext? = nil,
        allowsManualBackup: Bool = true,
        onPrepare: @escaping () -> Void = {},
        onContinue: @escaping () -> Void
    ) {
        self.kind = kind
        self.isReady = isReady
        self.backupContext = backupContext
        self.allowsManualBackup = allowsManualBackup
        self.onPrepare = onPrepare
        self.onContinue = onContinue
    }

    var body: some View {
        WalletSuccessPresentation(
            kind: kind,
            isPreparing: !isReady,
            backupContext: backupContext,
            allowsManualBackup: allowsManualBackup
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
            action: onContinue
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

#Preview("Wallet Ready") {
    NavigationStack {
        WalletSuccessView(
            onContinue: {}
        )
    }
}

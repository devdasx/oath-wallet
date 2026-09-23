import SwiftUI

struct DeviceMigrationScannerScreen: View {
    let onInvitation: (DeviceMigrationInvitation) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var errorKey: String?
    @State private var review: DeviceMigrationInvitation?
    @State private var countdownNow = Date()

    var body: some View {
        ZStack {
            if let review {
                SmartScannerReviewPanel(
                    presentation: reviewPresentation(review),
                    onConfirm: {
                        confirm(review)
                    },
                    onCancel: cancelReview
                )
            } else {
                scannerContent
            }
        }
        .background(WalletBackground())
        .navigationTitle("device_migration.scan.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                WalletCloseButton { dismiss() }
                    .accessibilityIdentifier("qrScannerClose")
            }
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.24),
            value: review
        )
        .task(id: review?.sessionID) {
            await updateCountdown()
        }
    }

    private var scannerContent: some View {
        GeometryReader { proxy in
            VStack(spacing: 18) {
                Text("device_migration.scan.instruction")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                scannerViewport
                    .frame(
                        height: min(
                            560,
                            max(300, proxy.size.height * 0.70)
                        )
                    )

                if let errorKey {
                    Text(LocalizedStringKey(errorKey))
                        .font(.footnote)
                        .foregroundStyle(WalletTheme.danger)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: 700)
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: errorKey
        )
    }

    private var scannerViewport: some View {
        NativeQRCodeScannerView(
            unavailableTitle:
                "device_migration.scan.unavailable.title",
            unavailableMessage:
                "device_migration.scan.unavailable.message",
            onPayload: handleScannedPayload
        )
        .walletSensitiveGraphic(cornerRadius: 26)
        .clipShape(
            WalletConcentricRectangle(minimumCornerRadius: 26)
        )
        .overlay {
            WalletConcentricRectangle(minimumCornerRadius: 26)
            .stroke(.secondary.opacity(0.18), lineWidth: 1)
        }
    }

    private func handleScannedPayload(_ payload: String) -> Bool {
        do {
            let invitation = try ScannerPayloadPolicy
                .deviceMigrationInvitation(
                    from: payload
                )
            errorKey = nil
            UniHaptic.play(.successQuiet)
            review = invitation
            return true
        } catch let error as DeviceMigrationError {
            UniHaptic.play(.error)
            errorKey = error.userMessageKey
            return false
        } catch {
            UniHaptic.play(.error)
            errorKey = DeviceMigrationError.invalidInvitation
                .userMessageKey
            return false
        }
    }

    private func reviewPresentation(
        _ invitation: DeviceMigrationInvitation
    ) -> SmartScannerReviewPresentation {
        let remainingDuration = max(
            invitation.expiresAt.timeIntervalSince(countdownNow),
            0
        )
        let remaining = Int64(
            remainingDuration.rounded(.up)
        )
        let progressFraction = min(
            remainingDuration
                / DeviceMigrationProtocol.invitationLifetime,
            1
        )
        return SmartScannerReviewPresentation(
            kind: .deviceTransfer,
            titleKey: "device_migration.scan.review.title",
            detailKey: "device_migration.scan.review.detail",
            rows: [
                SmartScannerReviewRow(
                    id: "type",
                    titleKey: "smart_scanner.review.field.type",
                    value: WalletLocalization.string(
                        "smart_scanner.review.value.full_app_transfer"
                    )
                ),
                SmartScannerReviewRow(
                    id: "source",
                    titleKey: "smart_scanner.review.field.source",
                    value: WalletLocalization.string(
                        "smart_scanner.review.value.nearby_iphone"
                    )
                ),
                SmartScannerReviewRow(
                    id: "valid_for",
                    titleKey: "smart_scanner.review.field.valid_for",
                    value: EnglishNumbers.localized(
                        "smart_scanner.review.value.seconds",
                        remaining
                    ),
                    progressFraction: progressFraction
                )
            ],
            warningKey: nil,
            primaryActionKey:
                "device_migration.scan.review.action",
            isPrimaryActionDisabled: remaining == 0
        )
    }

    @MainActor
    private func confirm(
        _ invitation: DeviceMigrationInvitation
    ) {
        guard !invitation.isExpired else {
            review = nil
            errorKey = DeviceMigrationError.expiredInvitation
                .userMessageKey
            UniHaptic.play(.error)
            return
        }
        onInvitation(invitation)
    }

    @MainActor
    private func cancelReview() {
        review = nil
        errorKey = nil
        UniHaptic.play(.selection)
    }

    @MainActor
    private func updateCountdown() async {
        guard let expiresAt = review?.expiresAt else { return }

        while !Task.isCancelled {
            countdownNow = Date()
            guard countdownNow < expiresAt else { return }

            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }
}

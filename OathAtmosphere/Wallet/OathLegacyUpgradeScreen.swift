import SwiftUI

/// Upgrade routing lives above Home/onboarding. No wallet content is mounted
/// until authentication, account verification and both durable commits finish.
struct OathLegacyUpgradeScreen: View {
    let session: OathWalletSession
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @State private var digits: [UInt8] = []

    var body: some View {
        Group {
            if session.legacyPhase == .passcode {
                // Use the ordinary unlock prompt and its normal subtitle spacing.
                // Authentication and migration remain owned by the session.
                OathPasscodeEntry(title: strings.text(.unlockPasscodeTitle),
                    filledCount: digits.count, isEnabled: !session.busy && scenePhase == .active,
                    isDeleteEnabled: !digits.isEmpty, errorMessage: session.notice.map { strings.text($0) },
                    titleIdentifier: "legacy.upgrade.passcode", onKey: handleKey)
            } else {
                VStack(spacing: 22) {
                    Spacer()
                    if session.legacyPhase == .migrating {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: session.legacyPhase == .biometrics ? "faceid" : "lock.shield")
                            .font(.system(size: 42)).foregroundStyle(.secondary)
                    }
                    Text(strings.text(session.legacyPhase == .biometrics ? .legacyUpgradeBiometrics : .unlockWallet))
                        .font(.title2.weight(.semibold))
                    if session.legacyPhase == .biometrics {
                        Text(strings.format(.enableBiometrics, strings.text(.biometricsName)))
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else if session.legacyPhase == .failed {
                        // Keep actionable recovery errors, while using the same
                        // generic failure wording as the normal unlock screen.
                        Text(strings.text(session.notice == .legacyUpgradeUnsupported ? .legacyUpgradeUnsupported : .walletUnavailable))
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Spacer()
                }
                .padding(.horizontal, 28)
                .oathBottomActions(isPresented: session.legacyPhase == .biometrics || session.legacyPhase == .failed) {
                    VStack(spacing: OathActionMetrics.spacing) {
                        if session.legacyPhase == .biometrics {
                            OathActionButton(title: strings.text(.legacyUpgradeEnableBiometrics), appearance: .primary) {
                                Task { await session.finishLegacyProtection(enableBiometrics: true) }
                            }
                            OathActionButton(title: strings.text(.legacyUpgradePasscodeOnly), appearance: .secondary) {
                                Task { await session.finishLegacyProtection(enableBiometrics: false) }
                            }
                        } else if session.legacyPhase == .failed {
                            OathActionButton(title: strings.text(.tryAgain), appearance: .secondary) { session.retryLegacyUpgrade() }
                        }
                    }
                }
                .disabled(session.busy)
                .accessibilityIdentifier("legacy.upgrade.progress")
            }
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .onChange(of: scenePhase) { _, phase in if phase != .active { clearDigits() } }
        .onDisappear { clearDigits() }
    }

    private func handleKey(_ key: OathNumericKeypad.Key) {
        guard !session.busy, scenePhase == .active else { return }
        switch key {
        case .digit(let digit):
            guard digits.count < 6 else { return }
            session.notice = nil; digits.append(UInt8(digit))
            if digits.count == 6 {
                var entry = digits
                clearDigits()
                Task {
                    await session.upgradeLegacy(digits: entry)
                    _ = entry.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
                }
            }
        case .delete: if !digits.isEmpty { digits.removeLast() }
        case .biometrics: break // The old verifier requires the existing PIN before moving keys.
        }
    }

    private func clearDigits() {
        _ = digits.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        digits.removeAll(keepingCapacity: false)
    }
}

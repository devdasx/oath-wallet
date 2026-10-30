import SwiftUI
import Observation
import OathWalletHandoff
import OathDiagnostics

/// Only opaque references cross the scene/navigation boundary. Secret reads
/// start after unlock (or during first-time passcode setup).
@MainActor @Observable final class OathVaultImportInbox {
    static let shared = OathVaultImportInbox()
    private(set) var pending: HandoffReference?
    private(set) var active: HandoffReference?
    func receive(_ url: URL) -> Bool {
        guard let reference = HandoffReference(url: url) else { return false }
        guard active != reference else { return true }
        // The sender replaces an unconsumed Keychain item on every new tap.
        // Follow its newest reference while unlock or another flow is pending.
        pending = reference
        return true
    }
    func take() -> HandoffReference? {
        guard active == nil, let pending else { return nil }
        self.pending = nil; active = pending
        return pending
    }
    func finish(_ reference: HandoffReference) {
        guard active == reference else { return }
        active = nil
    }
    func clear() {
        let references = [pending, active].compactMap { $0 }
        pending = nil; active = nil
        guard !references.isEmpty else { return }
        Task {
            do {
                let mailbox = try HandoffKeychain.mailbox()
                for reference in references { try await mailbox.discard(reference) }
            } catch {
                OathDiagnostics.record(DiagnosticFailure("vault_handoff_cleanup"), component: "wallet_import", operation: "vault_handoff")
            }
        }
    }
}

extension View {
    func oathVaultImport(session: OathWalletSession, canPresent: Bool) -> some View {
        modifier(OathVaultImportPresentation(session: session, canPresent: canPresent))
    }
}
private struct OathVaultImportPresentation: ViewModifier {
    let session: OathWalletSession
    let canPresent: Bool
    @State private var presented: HandoffReference?
    @Environment(\.scenePhase) private var scenePhase
    private var ready: Bool {
        canPresent && scenePhase == .active && !session.resetting && !session.isUpgrading &&
        !session.isLocked && OathVaultImportInbox.shared.pending != nil && OathVaultImportInbox.shared.active == nil && presented == nil
    }
    func body(content: Content) -> some View {
        content.fullScreenCover(item: $presented) { reference in
            OathVaultImportFlow(session: session, reference: reference)
        }
        .onChange(of: ready, initial: true) { _, value in
            if value { presented = OathVaultImportInbox.shared.take() }
        }
    }
}

private struct OathVaultImportFlow: View {
    let session: OathWalletSession
    let reference: HandoffReference
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings
    @State private var prepared: OathRestoredWallet?
    @State private var walletID: String?
    @State private var failed = false
    @State private var working = false
    @State private var consumed = false
    @State private var retry = 0
    private var ready: Bool { !session.isLocked && !session.resetting && !session.isUpgrading }

    var body: some View {
        NavigationStack {
            Group {
                if let walletID {
                    OathWalletCustomizationScreen(session: session, walletID: walletID, mode: .setup) {
                        session.finishInitialCustomization()
                        dismiss()
                    }.oathWalletCustomizationNavigation().navigationBarBackButtonHidden()
                } else if let prepared, session.presentsOnboarding, !session.isUnlocked {
                    OathPasscodeSetupScreen(store: OathRestoredWalletSetupStore(vault: session.vault, restoration: prepared),
                        biometrics: OathDeviceBiometrics(credentialStore: session.vault.biometricStore,
                            credentialProvider: { try await session.vault.biometricCredential() })) {
                        // Keep the original host alive until customization ends.
                        working = true
                        Task {
                            await session.finishedSetup()
                            walletID = session.displayedProfile?.id.uuidString
                            if walletID != nil { self.prepared = nil }
                            working = false
                        }
                    }
                } else if failed {
                    ContentUnavailableView {
                        Label(strings.text(.walletChangeFailed), systemImage: "exclamationmark.triangle")
                    } description: { Text(strings.text(.walletChangeFailedDetail)) }
                    actions: {
                        if prepared != nil { OathActionButton(title: strings.text(.tryAgain)) { failed = false; retry += 1 } }
                    }
                } else {
                    ProgressView().accessibilityLabel(strings.text(.importAction))
                }
            }
            .navigationTitle(walletID == nil ? strings.text(.importWallet) : "")
            .toolbar {
                if walletID == nil && !working {
                    ToolbarItem(placement: .topBarLeading) { OathCloseButton { dismiss() } }
                }
            }
        }
        .interactiveDismissDisabled()
        .disabled(session.isLocked || session.resetting)
        .task(id: "\(ready)-\(session.isUnlocked)-\(retry)") {
            guard ready, !working, walletID == nil, !failed else { return }
            working = true
            defer { working = false }
            do {
                if prepared == nil {
                    guard !consumed else { throw HandoffError.unavailable }
                    let mailbox = try HandoffKeychain.mailbox()
                    let payload = try await mailbox.consume(reference)
                    consumed = true
                    let task = Task.detached(priority: .userInitiated) {
                        try OathRestoredWallet(handoff: payload, requestID: reference.id)
                    }
                    prepared = try await task.value
                }
                guard ready, session.isUnlocked, let prepared else { return }
                try await session.restoreWallet(prepared)
                // The local commit may finish as the lock appears. Retain the
                // committed ID, so unlocking never repeats the handoff/import.
                walletID = session.displayedProfile?.id.uuidString
                if walletID != nil { self.prepared = nil }
            } catch is CancellationError { } // Lock/navigation cancellation; local commits remain durable.
            catch {
                OathDiagnostics.record(DiagnosticFailure("vault_handoff_import"), component: "wallet_import", operation: "vault_handoff")
                failed = true
            }
        }
        .onDisappear {
            prepared = nil
            // First-time setup replaces the onboarding root when completed.
            // Release the active reference even when that removes its presenter.
            OathVaultImportInbox.shared.finish(reference)
        }
    }
}

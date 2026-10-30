import SwiftUI
import OathDiagnostics

/// The same chain/key editors as onboarding, committed as an additional wallet
/// under the existing app lock rather than running first-wallet passcode setup.
struct OathAdditionalMultisigPages: View {
    let session: OathWalletSession
    @Binding var path: NavigationPath
    let onCreated: (String) -> Void
    @Environment(\.oathLocalizer) private var strings
    @State private var draft = OathMultisigDraft()
    @State private var requestID = UUID()
    @State private var work: Task<Void, Never>?
    @State private var failed = false
    private enum Route: Hashable { case evmNetworks, setup }

    var body: some View {
        OathMultisigChainScreen(
            onBitcoin: { choose(.bitcoin) }, onLitecoin: { choose(.litecoin) },
            onDogecoin: { choose(.dogecoin) }, onBitcoinCash: { choose(.bitcoincash) },
            onTron: { choose(.tron) }, onSolana: { choose(.solana) },
            onEVM: { path.append(Route.evmNetworks) }, onTon: { choose(.ton) },
            onThorchain: { choose(.thorchain) }, onNear: { choose(.near) },
            onSui: { choose(.sui) }, onAptos: { choose(.aptos) },
            onStellar: { choose(.stellar) }, onXrpl: { choose(.xrpl) })
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .evmNetworks:
                    OathEVMMultisigNetworkScreen { network in
                        draft.clear(); draft.chain = .evm; draft.evmNetwork = network
                        requestID = UUID(); path.append(Route.setup)
                    }
                case .setup:
                    OathMultisigSetupScreen(draft: draft,
                        onReady: { create(.bitcoin($0)) }, onTronReady: { create(.tron($0)) },
                        onEVMReady: { create(.evm($0)) }, onTonReady: { create(.ton($0)) },
                        onThorchainReady: { create(.thorchain($0)) }, onNearReady: { create(.near($0)) },
                        onSuiReady: { create(.sui($0)) }, onAptosReady: { create(.aptos($0)) },
                        onStellarReady: { create(.stellar($0)) }, onXrplReady: { create(.xrpl($0)) },
                        onSolanaReady: { create(.solana($0)) })
                        .navigationBarBackButtonHidden(work != nil)
                        .onDisappear { work?.cancel() }
                }
            }
        .disabled(work != nil || !session.isUnlocked)
        .interactiveDismissDisabled()
        .oathNativeLocalization()
        .alert(strings.text(.walletChangeFailed), isPresented: $failed) {
            OathButton(strings.text(.tryAgain)) { failed = false }
        } message: { Text(strings.text(.walletChangeFailedDetail)) }
        .onChange(of: session.isUnlocked) { _, unlocked in
            if !unlocked {
                work?.cancel(); draft.clear()
            } else if let id = session.pendingCustomizationID {
                onCreated(id)
            }
        }
    }

    private func choose(_ chain: OathMultisigDraft.Chain) {
        guard work == nil, session.isUnlocked else { return }
        draft.clear(); draft.chain = chain; requestID = UUID(); path.append(Route.setup)
    }

    private func create(_ material: OathMultisigMaterial) {
        guard work == nil, session.isUnlocked else { return }
        let id = requestID
        work = Task {
            defer { work = nil }
            do {
                let walletID = try await session.addWallet(requestID: id, multisig: material)
                guard !Task.isCancelled, session.isUnlocked else { return }
                draft.clear(); onCreated(walletID)
            } catch is CancellationError {
                // diagnostics: task-cancelled -- dismissal/locking preserves the vault commit, if any.
            } catch {
                OathDiagnostics.record(error, component: "multisig_creation", operation: "add_wallet")
                if !Task.isCancelled, session.isUnlocked { failed = true }
            }
        }
    }
}

/// Standalone presentation used outside the wallet switcher.
struct OathAdditionalMultisigFlow: View {
    let session: OathWalletSession
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()
    private struct Customize: Hashable { let walletID: String }

    var body: some View {
        NavigationStack(path: $path) {
            OathAdditionalMultisigPages(session: session, path: $path) { id in
                path = NavigationPath([Customize(walletID: id)])
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    OathCloseButton { dismiss() }
                        .accessibilityIdentifier("multisig.additional.close")
                }
            }
            .navigationDestination(for: Customize.self) { route in
                OathWalletCustomizationScreen(session: session, walletID: route.walletID, mode: .setup) { dismiss() }
                    .oathWalletCustomizationNavigation()
                    .navigationBarBackButtonHidden()
            }
        }
        .interactiveDismissDisabled()
    }
}

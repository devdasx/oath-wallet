import SwiftUI

private enum WalletPrivateKeyExportRoute: Hashable, Identifiable {
    case display(String)
    case bitcoinTypes

    var id: String {
        switch self {
        case let .display(itemID):
            "display:\(itemID)"
        case .bitcoinTypes:
            "bitcoin:types"
        }
    }
}

enum WalletPrivateKeyExportPublicationDecision: Equatable, Sendable {
    case publish
    case deferUntilActive
    case reject
}

enum WalletPrivateKeyExportPublicationPolicy {
    static func decision(
        for lifecycle: WalletSensitiveContentLifecycleState
    ) -> WalletPrivateKeyExportPublicationDecision {
        if lifecycle.isProtected {
            return .reject
        }
        if !lifecycle.isSceneActive {
            return .deferUntilActive
        }
        return .publish
    }
}

struct WalletPrivateKeyExportFlow: View {
    let wallet: ManagedWallet

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var privateKeyRoute: WalletPrivateKeyExportRoute?
    @State private var items: [WalletPrivateKeyExportItem]
    @State private var sensitiveLifecycle =
        WalletSensitiveContentLifecycleState()

    init(
        wallet: ManagedWallet,
        items: [WalletPrivateKeyExportItem]
    ) {
        self.wallet = wallet
        _items = State(initialValue: items)
        var lifecycle = WalletSensitiveContentLifecycleState()
        _ = lifecycle.acceptLoadedContent()
        _sensitiveLifecycle = State(initialValue: lifecycle)
    }

    var body: some View {
        rootContent
        .navigationDestination(item: $privateKeyRoute) { route in
            destination(for: route)
        }
        .walletSensitiveContentMask(
            isProtected: sensitiveLifecycle.isMasked,
            requiresProtection: sensitiveLifecycle.isMasked || sensitiveLifecycle.hasExpired
        )
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .inactive:
                protectSensitiveContent(for: .sceneInactive)
            case .background:
                protectSensitiveContent(for: .sceneBackground)
            case .active:
                resumeSensitiveContentAfterInactive()
            @unknown default:
                protectSensitiveContent(for: .sceneInactive)
            }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if wallet.kind.hasRecoveryPhrase {
            WalletPrivateKeyExportSelectionScreen(
                items: items,
                onSelect: {
                    privateKeyRoute = $0.bitcoinCatalog == nil
                        ? .display($0.id)
                        : .bitcoinTypes
                }
            )
        } else if let firstItem = items.first {
            protectedDisplayScreen(firstItem)
        } else {
            List {
                Group {
                    Section {
                        Text(
                            "settings.wallets.private_key.export.load.error"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .walletListRowSurface()
            }
            .walletListAppearance()
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private func destination(
        for route: WalletPrivateKeyExportRoute
    ) -> some View {
        switch route {
        case let .display(itemID):
            if let item = item(withID: itemID) {
                protectedDisplayScreen(item)
            } else {
                unavailableContent
            }
        case .bitcoinTypes:
            if let catalog = bitcoinCatalog {
                WalletBitcoinPrivateKeyTypeSelectionScreen(
                    wallet: wallet,
                    catalog: catalog,
                    isSensitiveContentProtected:
                        sensitiveLifecycle.isMasked
                )
            } else {
                unavailableContent
            }
        }
    }

    private var bitcoinCatalog: WalletBitcoinPrivateKeyExportCatalog? {
        items.lazy.compactMap(\.bitcoinCatalog).first
    }

    private var unavailableContent: some View {
        ContentUnavailableView(
            "settings.wallets.private_key.export.load.error",
            systemImage: "exclamationmark.triangle"
        )
    }

    private func protectedDisplayScreen(
        _ item: WalletPrivateKeyExportItem
    ) -> some View {
        WalletPrivateKeyExportDisplayScreen(
            wallet: wallet,
            item: item
        )
            .walletSensitiveContentMask(
                isProtected: sensitiveLifecycle.isMasked
            )
    }

    private func item(
        withID itemID: String
    ) -> WalletPrivateKeyExportItem? {
        items.first { $0.id == itemID }
    }

    @MainActor
    private func protectSensitiveContent(
        for trigger: WalletSensitiveContentLifecycleTrigger
    ) {
        _ = sensitiveLifecycle.protect(for: trigger)
    }

    @MainActor
    private func resumeSensitiveContentAfterInactive() {
        guard sensitiveLifecycle.resumeAfterInactive() else {
            if sensitiveLifecycle.hasExpired {
                privateKeyRoute = nil
                items.removeAll()
                dismiss()
            }
            return
        }
        _ = sensitiveLifecycle.acceptLoadedContent()
    }
}

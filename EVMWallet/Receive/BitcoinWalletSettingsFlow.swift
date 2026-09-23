import SwiftUI

enum BitcoinWalletSettingsRoute: Hashable {
    case addressType(BitcoinHDAddressType)
    case addresses(BitcoinHDAddressType, BitcoinHDAddressBranch)
    case address(BitcoinHDAddressType, BitcoinHDAddressBranch, Int)
    case generate(BitcoinHDAddressType, BitcoinHDAddressBranch)
    case silentPayments
    case silentOutput(String, Int)
}

struct BitcoinWalletSettingsFlow: View {
    @State private var navigationPath = NavigationPath()
    let walletID: String
    let database: WalletDatabase

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $navigationPath) {
            BitcoinWalletSettingsScreen(
                walletID: walletID,
                database: database
            )
            .navigationDestination(
                for: BitcoinWalletSettingsRoute.self,
                destination: destination
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    WalletCloseButton {
                        dismiss()
                    }
                }
            }
        }
        .walletSheetPresentation(nativeGlass: false)
    }

    @ViewBuilder
    private func destination(
        _ route: BitcoinWalletSettingsRoute
    ) -> some View {
        switch route {
        case let .addressType(type):
            BitcoinAddressTypeSettingsScreen(
                walletID: walletID,
                addressType: type,
                database: database
            )
        case let .addresses(type, branch):
            BitcoinGeneratedAddressListScreen(
                walletID: walletID,
                addressType: type,
                branch: branch,
                database: database
            )
        case let .address(type, branch, index):
            BitcoinGeneratedAddressDetailScreen(
                walletID: walletID,
                addressType: type,
                branch: branch,
                index: index,
                database: database
            )
        case let .generate(type, branch):
            BitcoinAddressGenerationScreen(
                walletID: walletID,
                addressType: type,
                initialBranch: branch,
                database: database
            )
        case .silentPayments:
            BitcoinSilentPaymentSettingsScreen(
                walletID: walletID,
                database: database
            )
        case let .silentOutput(transactionHash, outputIndex):
            BitcoinSilentPaymentOutputDetailScreen(
                walletID: walletID,
                transactionHash: transactionHash,
                outputIndex: outputIndex,
                database: database
            )
        }
    }
}

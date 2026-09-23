import Foundation

extension BitcoinFamilySyncService {
    func bitcoinHDOutcomeIfSupported(
        walletID: String,
        onProgress: WalletSyncProgressHandler?
    ) async -> WalletChainSyncOutcome? {
        do {
            if try await MuunRecoveryWalletSyncService.shared.supports(
                walletID: walletID
            ) {
                return await MuunRecoveryWalletSyncService.shared.sync(
                    walletID: walletID,
                    onProgress: onProgress
                )
            }
            if try await BitcoinHDWalletSyncService.shared.supports(
                walletID: walletID
            ) {
                return await BitcoinHDWalletSyncService.shared.sync(
                    walletID: walletID,
                    onProgress: onProgress
                )
            }
            guard try await BitcoinHDWalletSyncService.shared
                .supportsSingleKey(walletID: walletID) else { return nil }
            return await BitcoinHDWalletSyncService.shared.syncSingleKey(
                walletID: walletID,
                onProgress: onProgress
            )
        } catch is CancellationError {
            return .cancelled(.bitcoinFamily)
        } catch {
            return .failure(
                .bitcoinFamily,
                stage: .accountPreparation,
                error: error,
                networkID: BitcoinFamilyChain.bitcoin.networkID
            )
        }
    }
}

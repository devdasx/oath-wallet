import Foundation

extension WalletDatabase {
    func recoveryCredential(
        walletID: String,
        authorization: XRPSecretDerivationAuthorization,
        vault: WalletSecretVault = .shared
    ) async throws -> WalletRecoveryCredential {
        guard authorization.permits(walletID: walletID) else {
            throw WalletCreationPersistenceError.missingSecret
        }
        return try await loadRecoveryCredential(
            walletID: walletID,
            vault: vault
        )
    }

    func privateKeyData(
        walletID: String,
        authorization: XRPSecretDerivationAuthorization,
        vault: WalletSecretVault = .shared
    ) async throws -> Data {
        guard authorization.permits(walletID: walletID) else {
            throw WalletCreationPersistenceError.missingSecret
        }
        return try await loadPrivateKeyData(
            walletID: walletID,
            requiresSecp256k1: true,
            vault: vault
        )
    }
}

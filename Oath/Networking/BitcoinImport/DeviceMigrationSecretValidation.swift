import Foundation
import WalletCore

extension WalletDatabase {
    static func validateSecretCoverage(
        wallets: [DBWalletRecord],
        muunRecoveryWalletIDs: Set<String>,
        bitcoinImportedWalletIDs: Set<String> = [],
        secrets: [DeviceMigrationWalletSecret]
    ) throws {
        let secretByWalletID = Dictionary(
            grouping: secrets,
            by: \.walletID
        )
        guard secretByWalletID.values.allSatisfy({
            $0.count == 1
        }) else {
            throw DeviceMigrationError.incompleteSecretSet
        }

        var expectedWalletIDs = Set<String>()
        let walletIDs = Set(wallets.map(\.id))
        guard muunRecoveryWalletIDs.isSubset(of: walletIDs),
              bitcoinImportedWalletIDs.isSubset(of: walletIDs),
              bitcoinImportedWalletIDs.isDisjoint(with: muunRecoveryWalletIDs) else {
            throw DeviceMigrationError.invalidDatabase
        }
        for wallet in wallets {
            guard let kind = DatabaseWalletKind(rawValue: wallet.kind)
            else {
                throw DeviceMigrationError.invalidDatabase
            }
            switch kind {
            case .created, .importedRecoveryPhrase:
                expectedWalletIDs.insert(wallet.id)
                guard secretByWalletID[wallet.id]?.first?.kind
                        == .recoveryPhrase else {
                    throw DeviceMigrationError.incompleteSecretSet
                }
            case .importedPrivateKey:
                expectedWalletIDs.insert(wallet.id)
                let expectedKind: DeviceMigrationWalletSecretKind =
                    bitcoinImportedWalletIDs.contains(wallet.id) ? .bitcoinImportedWallet :
                    (muunRecoveryWalletIDs.contains(wallet.id) ? .muunRecovery : .privateKey)
                guard secretByWalletID[wallet.id]?.first?.kind
                        == expectedKind else {
                    throw DeviceMigrationError.incompleteSecretSet
                }
            case .watchOnly, .hardware:
                guard secretByWalletID[wallet.id] == nil else {
                    throw DeviceMigrationError.incompleteSecretSet
                }
            }
        }
        guard expectedWalletIDs == Set(secretByWalletID.keys) else {
            throw DeviceMigrationError.incompleteSecretSet
        }
    }

    static func validateWalletSecret(
        _ data: Data,
        kind: DeviceMigrationWalletSecretKind
    ) throws {
        switch kind {
        case .recoveryPhrase:
            guard (try? WalletRecoveryCredential.decode(data)) != nil else {
                throw DeviceMigrationError.invalidWalletSecret
            }
        case .privateKey:
            guard data.count == 32,
                  PrivateKey(data: data) != nil else {
                throw DeviceMigrationError.invalidWalletSecret
            }
        case .bitcoinImportedWallet:
            guard (try? BitcoinImportedWalletMaterial.decode(data)) != nil else {
                throw DeviceMigrationError.invalidWalletSecret
            }
        case .muunRecovery:
            guard (try? MuunRecoveryKeyMaterial.decode(data)) != nil else {
                throw DeviceMigrationError.invalidWalletSecret
            }
        }
    }

}

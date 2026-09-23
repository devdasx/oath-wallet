import Foundation

enum ICloudWalletRestoreValidator {
    nonisolated static func validate(
        _ payload: WalletCloudBackupPayload
    ) throws -> (
        draft: WalletImportDraft,
        walletName: String
    ) {
        let draft: WalletImportDraft
        switch payload.walletKind {
        case ManagedWalletKind.created.rawValue,
             ManagedWalletKind.importedRecoveryPhrase.rawValue:
            guard let credential = try? WalletRecoveryCredential.decode(
                payload.secret
            ) else {
                throw WalletCloudBackupError.decryptionFailed
            }
            if let declaredHasPassphrase = payload.hasPassphrase,
               declaredHasPassphrase != credential.hasPassphrase {
                throw WalletCloudBackupError.decryptionFailed
            }
            draft = try WalletCoreService.importRecoveryPhrase(
                credential.mnemonic,
                passphrase: credential.passphrase
            )

        case ManagedWalletKind.importedPrivateKey.rawValue:
            guard payload.hasPassphrase == nil,
                  let privateKey = String(
                data: payload.secret,
                encoding: .utf8
            ) else {
                throw WalletCloudBackupError.decryptionFailed
            }
            if payload.privateKeyNetwork == "bitcoin", payload.privateKeyFormat == BitcoinImportedWalletMaterial.accountMarker {
                draft = try BitcoinImportedWalletMaterial.decode(payload.secret).importDraft()
            } else if payload.version == 1 {
                draft = try legacyPrivateKeyDraft(
                    hexadecimal: privateKey,
                    expectedAddress: payload.address
                )
            } else {
                guard
                    let privateKeyData = Data(hexString: privateKey),
                    privateKeyData.count == 32,
                    let networkValue = payload.privateKeyNetwork,
                    let network = PrivateKeyImportNetwork(
                        rawValue: networkValue
                    ),
                    let formatValue = payload.privateKeyFormat,
                    let format = PrivateKeyImportFormat(
                        rawValue: formatValue
                    )
                else {
                    throw WalletCloudBackupError.decryptionFailed
                }
                draft = try PrivateKeyImportService.revalidate(
                    privateKeyData: privateKeyData,
                    network: network,
                    format: format
                )
            }

        default:
            throw WalletCloudBackupError.decryptionFailed
        }

        let addressMatches: Bool
        if case let .privateKey(_, network, _) = draft.secret,
           network == .evm {
            addressMatches = draft.address.caseInsensitiveCompare(
                payload.address
            ) == .orderedSame
        } else {
            addressMatches = draft.address == payload.address
        }
        guard addressMatches,
              let normalizedWalletName =
                WalletDefaultName.normalizedCustomName(
                    payload.walletName
                )
        else {
            throw WalletCloudBackupError.decryptionFailed
        }

        return (draft, normalizedWalletName)
    }

    nonisolated private static func legacyPrivateKeyDraft(
        hexadecimal: String,
        expectedAddress: String
    ) throws -> WalletImportDraft {
        guard let data = Data(hexString: hexadecimal),
              data.count == 32
        else {
            throw WalletCloudBackupError.decryptionFailed
        }

        for network in PrivateKeyImportNetwork.allCases {
            for format in legacyCandidateFormats(for: network) {
                guard let candidate = try? PrivateKeyImportService
                    .revalidate(
                        privateKeyData: data,
                        network: network,
                        format: format
                    )
                else {
                    continue
                }
                let matches = network == .evm
                    ? candidate.address.caseInsensitiveCompare(
                        expectedAddress
                    ) == .orderedSame
                    : candidate.address == expectedAddress
                if matches {
                    return candidate
                }
            }
        }
        throw WalletCloudBackupError.decryptionFailed
    }

    nonisolated private static func legacyCandidateFormats(
        for network: PrivateKeyImportNetwork
    ) -> [PrivateKeyImportFormat] {
        switch network {
        case .evm, .tron, .xrp:
            [.rawSecp256k1]
        case .bitcoin, .litecoin, .dogecoin, .bitcoinCash:
            [
                .wifCompressed,
                .wifUncompressed,
                .extendedLegacy,
                .extendedNestedSegwit,
                .extendedNativeSegwit
            ]
        case .solana:
            [.solanaSeed]
        case .aptos, .ton, .sui, .near, .stellar:
            [.rawEd25519]
        }
    }
}

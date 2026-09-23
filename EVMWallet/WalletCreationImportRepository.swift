import Foundation
import WalletCore

/// Serializes wallet commits on an executor that is independent of the UI.
/// The success screen can render and animate while derivation, Keychain, and
/// database work complete without occupying the main actor.
actor WalletPersistenceWorker {
    static let shared = WalletPersistenceWorker()

    nonisolated func persistCreatedWallet(
        database: WalletDatabase,
        draft: WalletCreationDraft,
        security: WalletPersistenceSecurity
    ) async throws -> PersistedWalletIdentity {
        return try await persistCreatedWalletSerially(
            database: database,
            draft: draft,
            security: security
        )
    }

    private func persistCreatedWalletSerially(
        database: WalletDatabase,
        draft: WalletCreationDraft,
        security: WalletPersistenceSecurity
    ) async throws -> PersistedWalletIdentity {
        do {
            let identity = try await database.persistCreatedWallet(
                draft: draft,
                security: security
            )
            return identity
        } catch {
            throw error
        }
    }

    nonisolated func persistImportedWallet(
        database: WalletDatabase,
        draft: WalletImportDraft,
        security: WalletPersistenceSecurity,
        preferredWalletName: String? = nil,
        cloudBackupIdentity: WalletCloudBackupRemoteIdentity? = nil
    ) async throws -> PersistedWalletIdentity {
        return try await persistImportedWalletSerially(
            database: database,
            draft: draft,
            security: security,
            preferredWalletName: preferredWalletName,
            cloudBackupIdentity: cloudBackupIdentity
        )
    }

    private func persistImportedWalletSerially(
        database: WalletDatabase,
        draft: WalletImportDraft,
        security: WalletPersistenceSecurity,
        preferredWalletName: String?,
        cloudBackupIdentity: WalletCloudBackupRemoteIdentity?
    ) async throws -> PersistedWalletIdentity {
        do {
            let identity = try await database.persistImportedWallet(
                draft: draft,
                security: security,
                preferredWalletName: preferredWalletName,
                cloudBackupIdentity: cloudBackupIdentity
            )
            return identity
        } catch {
            throw error
        }
    }
}

extension WalletDatabase {
    func persistImportedWallet(
        draft: WalletImportDraft,
        security: WalletPersistenceSecurity,
        preferredWalletName: String? = nil,
        cloudBackupIdentity: WalletCloudBackupRemoteIdentity? = nil,
        vault: WalletSecretVault = .shared
    ) async throws -> PersistedWalletIdentity {
        guard WalletCredentialSafetyService.finding(for: draft) == nil else {
            throw invalidImportDraft(
                stage: "reject_unsafe_credential"
            )
        }
        switch draft.secret {
        case let .recoveryPhrase(mnemonic, passphrase, wordCount):
            let credential = try WalletRecoveryCredential(
                mnemonic: mnemonic,
                passphrase: passphrase
            )
            if credential.electrumKind != nil {
                return try await persistElectrumWallet(
                    draft: draft,
                    credential: credential,
                    wordCount: wordCount,
                    security: security,
                    preferredWalletName: preferredWalletName,
                    cloudBackupIdentity: cloudBackupIdentity,
                    vault: vault
                )
            }

            guard credential.mnemonic == mnemonic,
                  credential.passphrase == passphrase,
                  credential.wordCount == wordCount,
                  CoinType.ethereum.validate(address: draft.address),
                  draft.normalizedAddress == draft.address.lowercased(),
                  draft.derivationPath == CoinType.ethereum.derivationPath(),
                  !draft.publicKey.isEmpty else {
                throw invalidImportDraft(
                    stage: "revalidate_recovery_phrase"
                )
            }
            let material = try await Task.detached(
                priority: .userInitiated
            ) {
                try await WalletAccountDerivationService
                    .deriveFullWalletMaterial(
                        credential: credential,
                        expectedEVMAddress: draft.address,
                        expectedEVMPublicKey: draft.publicKey,
                        operation: .importWallet
                    )
            }.value
            let identity = try await persistWallet(
                secretData: try credential.encodedData(),
                secretKind: .recoveryPhrase,
                databaseKind: .importedRecoveryPhrase,
                address: draft.address,
                normalizedAddress: draft.normalizedAddress,
                derivationPath: draft.derivationPath,
                publicKey: draft.publicKey,
                mnemonicWordCount: credential.wordCount,
                backupState: .verified,
                derivedAccounts: material.accounts,
                preferredWalletName: preferredWalletName,
                cloudBackupIdentity: cloudBackupIdentity,
                operation: .importWallet,
                security: security,
                vault: vault
            )
            return identity

        case let .privateKey(privateKeyData, network, format):
            let validatedDraft = try PrivateKeyImportService.revalidate(
                privateKeyData: privateKeyData,
                network: network,
                format: format
            )
            guard validatedDraft == draft else {
                throw invalidImportDraft(
                    stage: "revalidate_private_key"
                )
            }
            let identity = try await persistWallet(
                secretData: privateKeyData,
                secretKind: .privateKey,
                databaseKind: .importedPrivateKey,
                address: draft.address,
                normalizedAddress: draft.normalizedAddress,
                derivationPath: draft.derivationPath,
                publicKey: draft.publicKey,
                mnemonicWordCount: nil,
                backupState: .notVerified,
                preferredWalletName: preferredWalletName,
                cloudBackupIdentity: cloudBackupIdentity,
                privateKeyNetwork: network,
                operation: .importWallet,
                security: security,
                vault: vault
            )
            if network == .bitcoin {
                _ = try await bitcoinSingleKeyWallet(
                    walletID: identity.walletID,
                    vault: vault
                )
            }
            return identity

        case let .bitcoinImportedWallet(material):
            let validated = try material.validated()
            guard try validated.importDraft() == draft else {
                throw invalidImportDraft(stage: "revalidate_bitcoin_collection")
            }
            let bitcoinChain = try validated.bitcoinFamilyChain()
            let privateKeyNetwork: PrivateKeyImportNetwork
            switch bitcoinChain {
            case .bitcoin:
                privateKeyNetwork = .bitcoin
            case .bitcoinCash:
                privateKeyNetwork = .bitcoinCash
            case .litecoin:
                privateKeyNetwork = .litecoin
            case .dogecoin:
                privateKeyNetwork = .dogecoin
            }
            let identity = try await persistWallet(
                secretData: try validated.encoded(), secretKind: .bitcoinImportedWallet,
                databaseKind: .importedPrivateKey, address: draft.address,
                normalizedAddress: draft.normalizedAddress,
                derivationPath: BitcoinImportedWalletMaterial.accountMarker,
                publicKey: draft.publicKey, mnemonicWordCount: nil,
                backupState: .notVerified, preferredWalletName: preferredWalletName,
                cloudBackupIdentity: cloudBackupIdentity, privateKeyNetwork: privateKeyNetwork,
                operation: .importWallet, security: security, vault: vault
            )
            return identity

        case let .muunRecovery(material):
            let validated = try material.validated()
            let validatedDraft = try WalletCoreService.importMuunRecovery(
                validated
            )
            guard validatedDraft == draft else {
                throw invalidImportDraft(
                    stage: "revalidate_muun_recovery"
                )
            }
            let initialAddress = try MuunRecoveryAddressFactory.derive(
                material: validated,
                version: .v5,
                branch: .external,
                addressIndex: 0
            )
            let identity = try await persistWallet(
                secretData: try validated.encodedData(),
                secretKind: .muunRecovery,
                databaseKind: .importedPrivateKey,
                address: initialAddress.address,
                normalizedAddress: initialAddress.address.lowercased(),
                derivationPath: MuunRecoveryKeyMaterial.accountMarker,
                publicKey: Data(
                    initialAddress.scriptPubKey.dropFirst(2)
                ).hexString,
                mnemonicWordCount: nil,
                backupState: .notVerified,
                preferredWalletName: preferredWalletName,
                cloudBackupIdentity: nil,
                privateKeyNetwork: .bitcoin,
                muunRecoverySeed: try MuunRecoveryPersistenceSeed(
                    material: validated,
                    initialAddress: initialAddress
                ),
                operation: .importWallet,
                security: security,
                vault: vault
            )
            try await publishFreshMuunRecoveryReceiveAddress(
                walletID: identity.walletID,
                vault: vault
            )
            return identity
        }
    }

    private func persistElectrumWallet(
        draft: WalletImportDraft,
        credential: WalletRecoveryCredential,
        wordCount: Int,
        security: WalletPersistenceSecurity,
        preferredWalletName: String?,
        cloudBackupIdentity: WalletCloudBackupRemoteIdentity?,
        vault: WalletSecretVault
    ) async throws -> PersistedWalletIdentity {
        let descriptor = try BitcoinHDDerivationService()
            .accountDescriptors(credential: credential)[0]
        let expected = try BitcoinHDDerivationService().deriveAddress(
            descriptor: descriptor,
            branch: .external,
            index: 0
        )
        guard credential.wordCount == wordCount,
              draft.address == expected.address,
              draft.normalizedAddress == expected.address.lowercased(),
              draft.derivationPath == expected.derivationPath,
              draft.publicKey == expected.publicKey.hexString,
              CoinType.bitcoin.validate(address: draft.address) else {
            throw invalidImportDraft(
                stage: "revalidate_electrum_seed"
            )
        }

        let identity = try await persistWallet(
            secretData: try credential.encodedData(),
            secretKind: .recoveryPhrase,
            databaseKind: .importedRecoveryPhrase,
            address: expected.address,
            normalizedAddress: expected.address.lowercased(),
            derivationPath: expected.derivationPath,
            publicKey: expected.publicKey.hexString,
            mnemonicWordCount: credential.wordCount,
            backupState: .verified,
            preferredWalletName: preferredWalletName,
            cloudBackupIdentity: cloudBackupIdentity,
            privateKeyNetwork: .bitcoin,
            operation: .importWallet,
            security: security,
            vault: vault
        )
        _ = try await ensureBitcoinHDWallet(
            walletID: identity.walletID,
            vault: vault
        )
        return identity
    }

    private func invalidImportDraft(
        stage: String
    ) -> WalletCreationPersistenceError {
        let error = WalletCreationPersistenceError.invalidDraft
        return error
    }
}

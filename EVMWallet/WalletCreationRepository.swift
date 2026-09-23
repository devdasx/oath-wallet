import Foundation
import GRDB
import Security
import WalletCore

struct PersistedWalletIdentity: Equatable, Sendable {
    let walletID: String
    let address: String
}

enum WalletCreationPersistenceError: Error {
    case invalidDraft
    case invalidPasscode
    case passcodeDerivationFailed
    case randomGenerationFailed(OSStatus)
    case missingSecret
}

enum WalletPersistenceSecurity: Sendable {
    case establishOrVerify(
        passcode: String,
        biometricEnabled: Bool
    )
    case reuseExistingProfile
}

enum WalletPasscodeAuthenticationResult: Equatable, Sendable {
    case success
    case incorrect
    case locked(until: Date)
}

extension WalletDatabase {
    func persistCreatedWallet(
        draft: WalletCreationDraft,
        security: WalletPersistenceSecurity,
        vault: WalletSecretVault = .shared
    ) async throws -> PersistedWalletIdentity {

        guard let credential = try? WalletRecoveryCredential(
                mnemonic: draft.mnemonic,
                passphrase: draft.passphrase
              ),
              credential.wordCount == draft.words.count,
              credential.mnemonic.split(separator: " ").map(String.init)
                == draft.words,
              credential.passphrase == draft.passphrase,
              CoinType.ethereum.validate(address: draft.address),
              draft.address.lowercased() == draft.normalizedAddress,
              draft.derivationPath == CoinType.ethereum.derivationPath()
        else {
            let error = WalletCreationPersistenceError.invalidDraft
            throw error
        }

        let material = try await Task.detached(
            priority: .userInitiated
        ) {
            try await WalletAccountDerivationService
                .deriveFullWalletMaterial(
                    credential: credential,
                    expectedEVMAddress: draft.address,
                    expectedEVMPublicKey: draft.publicKey,
                    operation: .create
                )
        }.value

        let identity = try await persistWallet(
            secretData: try credential.encodedData(),
            secretKind: .recoveryPhrase,
            databaseKind: .created,
            address: draft.address,
            normalizedAddress: draft.normalizedAddress,
            derivationPath: draft.derivationPath,
            publicKey: draft.publicKey,
            mnemonicWordCount: credential.wordCount,
            backupState: .notVerified,
            derivedAccounts: material.accounts,
            operation: .create,
            security: security,
            vault: vault
        )
        return identity
    }

    func persistWallet(
        secretData: Data,
        secretKind: WalletSecretKind,
        databaseKind: DatabaseWalletKind,
        address: String,
        normalizedAddress: String,
        derivationPath: String?,
        publicKey: String,
        mnemonicWordCount: Int?,
        backupState: DatabaseWalletBackupState,
        derivedAccounts: [WalletDerivedAccount]? = nil,
        preferredWalletName: String? = nil,
        cloudBackupIdentity: WalletCloudBackupRemoteIdentity? = nil,
        privateKeyNetwork: PrivateKeyImportNetwork? = nil,
        muunRecoverySeed: MuunRecoveryPersistenceSeed? = nil,
        operation: WalletPersistenceOperation,
        security: WalletPersistenceSecurity,
        vault: WalletSecretVault
    ) async throws -> PersistedWalletIdentity {


        let normalizedPreferredWalletName: String?
        if let preferredWalletName {
            guard let normalizedName =
                WalletDefaultName.normalizedCustomName(
                    preferredWalletName
                )
            else {
                let error = WalletCreationPersistenceError.invalidDraft
                throw error
            }
            normalizedPreferredWalletName = normalizedName
        } else {
            normalizedPreferredWalletName = nil
        }

        guard !secretData.isEmpty,
              Self.isValidPersistedAddress(
                  address,
                  normalizedAddress: normalizedAddress,
                  privateKeyNetwork: privateKeyNetwork
              ),
              !publicKey.isEmpty,
              muunRecoverySeed.map({ seed in
                  databaseKind == .importedPrivateKey
                      && privateKeyNetwork == .bitcoin
                      && derivationPath
                          == MuunRecoveryKeyMaterial.accountMarker
                      && seed.initialAddress.address == address
                      && seed.initialAddress.scriptPubKey.count == 34
                      && Data(seed.initialAddress.scriptPubKey.dropFirst(2))
                          .hexString == publicKey
              }) ?? true
        else {
            let error = WalletCreationPersistenceError.invalidDraft
            throw error
        }

        var createdPasscodeReference: String?
        var referencesToDeleteOnFailure: [String] = []

        do {
            let existingPasscodeReference = try await pool.read { database in
                try DBProfileSecurityRecord.fetchOne(
                    database,
                    key: Self.defaultProfileID
                )?.passcodeKeychainReference
            }
            var verifiedPasscodeReference: String?

            let shouldUpdateBiometricSetting: Bool
            let biometricEnabled: Bool
            switch security {
            case let .establishOrVerify(passcode, enablesBiometrics):
                shouldUpdateBiometricSetting = true
                biometricEnabled = enablesBiometrics
                if existingPasscodeReference == nil {
                    let credential = try WalletPasscodeCredential.make(
                        passcode: passcode
                    )
                    let reference = try vault.storePasscodeCredential(
                        JSONEncoder().encode(credential)
                    )
                    createdPasscodeReference = reference
                } else if let existingPasscodeReference {
                    let credential =
                        try vault.validatedPasscodeCredential(
                            reference: existingPasscodeReference,
                            decode:
                                WalletPasscodeCredential.decodeStoredData
                        )
                    guard credential.matches(passcode: passcode) else {
                        throw WalletCreationPersistenceError.invalidPasscode
                    }
                    verifiedPasscodeReference =
                        existingPasscodeReference
                }

            case .reuseExistingProfile:
                shouldUpdateBiometricSetting = false
                biometricEnabled = false
            }

            let proposedPasscodeReference = createdPasscodeReference
            let preverifiedPasscodeReference =
                verifiedPasscodeReference
            let secretReference = try vault.store(
                secretData,
                kind: secretKind
            )
            referencesToDeleteOnFailure.append(secretReference)

            let walletID = UUID().uuidString.lowercased()
            let now = Date().timeIntervalSince1970
            let committedPasscodeReference = try await pool.write { database in
                let currentSecurity =
                    try DBProfileSecurityRecord.fetchOne(
                        database,
                        key: Self.defaultProfileID
                    )
                let passcodeReference: String?
                switch security {
                case .establishOrVerify:
                    if let currentSecurity {
                        guard
                            currentSecurity.passcodeKeychainReference
                                == preverifiedPasscodeReference
                        else {
                            throw WalletCreationPersistenceError.missingSecret
                        }
                        passcodeReference =
                            currentSecurity.passcodeKeychainReference
                    } else if let proposedPasscodeReference {
                        passcodeReference = proposedPasscodeReference
                    } else {
                        throw WalletCreationPersistenceError.missingSecret
                    }

                case .reuseExistingProfile:
                    // A transferred installation intentionally has no
                    // passcode record when the destination was unprotected.
                    // Reusing that profile means preserving the absence of
                    // protection, not failing wallet persistence.
                    passcodeReference =
                        currentSecurity?.passcodeKeychainReference
                }

                try database.execute(
                    sql: "UPDATE wallets SET isSelected = 0 WHERE profileID = ?",
                    arguments: [Self.defaultProfileID]
                )

                let walletName: String
                if let normalizedPreferredWalletName {
                    walletName = normalizedPreferredWalletName
                } else {
                    walletName = try WalletDefaultName.next(
                        for: databaseKind,
                        privateKeyNetwork: privateKeyNetwork,
                        profileID: Self.defaultProfileID,
                        database: database
                    )
                }
                try DBWalletRecord(
                    id: walletID,
                    profileID: Self.defaultProfileID,
                    name: walletName,
                    kind: databaseKind.rawValue,
                    secretKeyReference: secretReference,
                    isSelected: true,
                    sortOrder: try Int.fetchOne(
                        database,
                        sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM wallets WHERE profileID = ?",
                        arguments: [Self.defaultProfileID]
                    ) ?? 0,
                    createdAt: now,
                    updatedAt: now,
                    lastOpenedAt: now,
                    archivedAt: nil,
                    backupState: backupState.rawValue,
                    backupVerifiedAt:
                        backupState == .verified ? now : nil,
                    mnemonicWordCount: mnemonicWordCount,
                    iCloudBackupUpdatedAt: cloudBackupIdentity?
                        .receipt.serverModifiedAt.timeIntervalSince1970,
                    iCloudBackupVerificationVersion:
                        cloudBackupIdentity == nil ? 0 : 1,
                    iCloudBackupRecordChangeTag:
                        cloudBackupIdentity?.receipt.serverChangeTag,
                    iCloudBackupWalletID: cloudBackupIdentity?.walletID,
                    appearanceColorID: try Self
                        .nextWalletAppearanceColor(
                            profileID: Self.defaultProfileID,
                            database: database
                        ).rawValue,
                    accountDerivationVersion: derivedAccounts == nil
                        ? 0
                        : WalletAccountDerivationService
                            .currentPersistenceVersion
                ).insert(database)

                let networks = try DBNetworkRecord
                    .filter(Column("isMainnet") == true)
                    .order(Column("sortOrder"))
                    .fetchAll(database)

                if let derivedAccounts {
                    let persistedNetworkIDs = Set(networks.map(\.id))
                    guard Set(derivedAccounts.map(\.networkID))
                        == WalletAccountDerivationService.requiredNetworkIDs,
                        WalletAccountDerivationService.requiredNetworkIDs
                            .isSubset(of: persistedNetworkIDs),
                        derivedAccounts.count
                            == WalletAccountDerivationService
                                .requiredAccountCount
                    else {
                        throw WalletCreationPersistenceError.invalidDraft
                    }
                    for account in derivedAccounts {
                        try account.record(
                            walletID: walletID,
                            now: now
                        ).insert(database)
                    }
                } else {
                    let accountNetworks = Self.accountNetworks(
                        from: networks.filter(\.isEnabled),
                        privateKeyNetwork: privateKeyNetwork
                    )
                    for network in accountNetworks {
                        let accountID: String
                        let label: String?
                        if privateKeyNetwork == .solana {
                            accountID = Self.solanaAccountID(
                                walletID: walletID,
                                kind: .phantom
                            )
                            label = SolanaDerivationKind.phantom.rawValue
                        } else if let privateKeyNetwork,
                                  privateKeyNetwork != .evm {
                            accountID = "\(walletID):\(network.id):0"
                            label = nil
                        } else {
                            accountID = UUID().uuidString.lowercased()
                            label = nil
                        }
                        try DBWalletAccountRecord(
                            id: accountID,
                            walletID: walletID,
                            networkID: network.id,
                            address: address,
                            normalizedAddress: normalizedAddress,
                            label: label,
                            derivationPath: derivationPath,
                            accountIndex: 0,
                            publicKey: publicKey,
                            isWatchOnly: false,
                            isEnabled: true,
                            createdAt: now,
                            updatedAt: now,
                            lastSyncedAt: nil
                        ).insert(database)
                    }
                }

                if let muunRecoverySeed {
                    try DBMuunRecoveryWalletRecord(
                        walletID: walletID,
                        birthdayBlock: muunRecoverySeed.birthdayBlock,
                        recoveryScanCursor: 0,
                        fullScanCompleted: false,
                        nextExternalIndex: 0,
                        nextChangeIndex: 0,
                        createdAt: now,
                        updatedAt: now
                    ).insert(database)
                    let initialState = MuunRecoveryAddressState(
                        derived: muunRecoverySeed.initialAddress,
                        isUsed: false,
                        isReserved: false,
                        confirmedBalanceAtomic: .zero,
                        unconfirmedBalanceAtomic: .zero
                    )
                    try Self.muunRecoveryAddressRecord(
                        initialState,
                        walletID: walletID,
                        now: now
                    ).insert(database)
                }

                if let passcodeReference {
                    try DBProfileSecurityRecord(
                        profileID: Self.defaultProfileID,
                        passcodeKeychainReference: passcodeReference,
                        failedAttemptCount: 0,
                        lockedUntil: nil,
                        updatedAt: now
                    ).save(database)
                }

                if shouldUpdateBiometricSetting || passcodeReference == nil {
                    guard var settings =
                        try DBUserSettingsRecord.fetchOne(
                            database,
                            key: Self.defaultProfileID
                        )
                    else {
                        throw WalletSecurityPersistenceError.missingSettings
                    }
                    settings.appLockEnabled = passcodeReference != nil
                    settings.biometricEnabled =
                        passcodeReference != nil && biometricEnabled
                    settings.updatedAt = now
                    try settings.update(database)
                }
                return passcodeReference
            }

            referencesToDeleteOnFailure.removeAll()
            var successCleanupFailures = 0
            let shouldDeleteUncommittedPasscode =
                createdPasscodeReference != nil
                && createdPasscodeReference
                    != committedPasscodeReference
            if shouldDeleteUncommittedPasscode,
               let createdPasscodeReference {
                do {
                    try vault.deletePasscodeCredential(
                        reference: createdPasscodeReference
                    )
                } catch {
                    successCleanupFailures += 1
                }
            }
            return PersistedWalletIdentity(
                walletID: walletID,
                address: address
            )
        } catch {
            var cleanupAttempts = 0
            var cleanupFailures = 0
            for reference in referencesToDeleteOnFailure {
                cleanupAttempts += 1
                do {
                    try vault.deleteIfPresent(reference: reference)
                } catch {
                    cleanupFailures += 1
                }
            }
            if let createdPasscodeReference {
                cleanupAttempts += 1
                do {
                    try vault.deletePasscodeCredential(
                        reference: createdPasscodeReference
                    )
                } catch {
                    cleanupFailures += 1
                }
            }
            throw error
        }
    }

    private static func isValidPersistedAddress(
        _ address: String,
        normalizedAddress: String,
        privateKeyNetwork: PrivateKeyImportNetwork?
    ) -> Bool {
        let expectedNormalization: String
        let isValidAddress: Bool
        switch privateKeyNetwork {
        case .none, .some(.evm):
            expectedNormalization = address.lowercased()
            isValidAddress = CoinType.ethereum.validate(address: address)
        case .some(.tron):
            expectedNormalization = address
            isValidAddress = CoinType.tron.validate(address: address)
        case .some(.solana):
            expectedNormalization = address
            isValidAddress = CoinType.solana.validate(address: address)
        case .some(.ton):
            guard let raw = TONAddress.rawAddress(from: address) else {
                return false
            }
            expectedNormalization = raw
            isValidAddress = CoinType.ton.validate(address: address)
        case .some(.sui):
            guard let canonical = SuiCoinType
                .validatedAccountAddress(address) else {
                return false
            }
            expectedNormalization = canonical
            isValidAddress = true
        case .some(.stellar):
            expectedNormalization = address
            isValidAddress = StellarAddress.validated(address) != nil
        case let .some(network):
            expectedNormalization = address.lowercased()
            guard let chain = network.bitcoinFamilyChain else {
                return false
            }
            isValidAddress = chain.coin.validate(address: address)
        }
        return isValidAddress
            && normalizedAddress == expectedNormalization
    }

    static func accountNetworks(
        from networks: [DBNetworkRecord],
        privateKeyNetwork: PrivateKeyImportNetwork?
    ) -> [DBNetworkRecord] {
        let requestedNetworkIDs: Set<String>
        switch privateKeyNetwork {
        case .none, .some(.evm):
            requestedNetworkIDs = Set(
                ReceiveNetworkCatalog.all.lazy
                    .filter { $0.blockchain.isEVM }
                    .map(\.id)
            )
        case let .some(network):
            requestedNetworkIDs = [network.networkID]
        }
        return networks.filter {
            requestedNetworkIDs.contains($0.id)
        }
    }

    func selectedWalletIdentity() async throws -> PersistedWalletIdentity? {
        try await pool.read { database in
            guard let wallet = try DBWalletRecord
                .filter(Column("profileID") == Self.defaultProfileID)
                .filter(Column("isSelected") == true)
                .filter(Column("archivedAt") == nil)
                .fetchOne(database)
            else {
                return nil
            }

            let account = try DBWalletAccountRecord
                .filter(Column("walletID") == wallet.id)
                .filter(Column("isEnabled") == true)
                .order(
                    sql: "CASE WHEN networkID = 'eth' THEN 0 ELSE 1 END, createdAt"
                )
                .fetchOne(database)

            guard let account else { return nil }
            return PersistedWalletIdentity(
                walletID: wallet.id,
                address: account.address
            )
        }
    }

    func recoveryCredential(
        walletID: String,
        authorization: BitcoinFamilySecretDerivationAuthorization,
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

    func recoveryCredential(
        walletID: String,
        authorization: TronSecretDerivationAuthorization,
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

    func recoveryCredential(
        walletID: String,
        authorization: SolanaSecretDerivationAuthorization,
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

    func recoveryCredential(
        walletID: String,
        authorization: TONSecretDerivationAuthorization,
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

    func loadRecoveryCredential(
        walletID: String,
        vault: WalletSecretVault
    ) async throws -> WalletRecoveryCredential {
        let reference = try await pool.read { database in
            try DBWalletRecord.fetchOne(database, key: walletID)?
                .secretKeyReference
        }
        guard let reference else {
            throw WalletCreationPersistenceError.missingSecret
        }
        let data = try vault.data(reference: reference)
        guard let credential = try? WalletRecoveryCredential.decode(data)
        else {
            throw WalletCreationPersistenceError.missingSecret
        }
        return credential
    }

    func privateKeyData(
        walletID: String,
        authorization: BitcoinFamilySecretDerivationAuthorization,
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

    func privateKeyData(
        walletID: String,
        authorization: TronSecretDerivationAuthorization,
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

    func privateKeyData(
        walletID: String,
        authorization: SolanaSecretDerivationAuthorization,
        vault: WalletSecretVault = .shared
    ) async throws -> Data {
        guard authorization.permits(walletID: walletID) else {
            throw WalletCreationPersistenceError.missingSecret
        }
        return try await loadPrivateKeyData(
            walletID: walletID,
            requiresSecp256k1: false,
            vault: vault
        )
    }

    func privateKeyData(
        walletID: String,
        authorization: TONSecretDerivationAuthorization,
        vault: WalletSecretVault = .shared
    ) async throws -> Data {
        guard authorization.permits(walletID: walletID) else {
            throw WalletCreationPersistenceError.missingSecret
        }
        return try await loadPrivateKeyData(
            walletID: walletID,
            requiresSecp256k1: false,
            vault: vault
        )
    }

    func loadPrivateKeyData(
        walletID: String,
        requiresSecp256k1: Bool,
        vault: WalletSecretVault
    ) async throws -> Data {
        let wallet = try await pool.read { database in
            try DBWalletRecord.fetchOne(database, key: walletID)
        }
        guard wallet?.kind == DatabaseWalletKind.importedPrivateKey.rawValue,
              let reference = wallet?.secretKeyReference
        else {
            throw WalletCreationPersistenceError.missingSecret
        }

        let data = try vault.data(reference: reference)
        guard data.count == 32 else {
            throw WalletCreationPersistenceError.missingSecret
        }
        if requiresSecp256k1,
           !PrivateKey.isValid(data: data, curve: .secp256k1) {
            throw WalletCreationPersistenceError.missingSecret
        }
        return data
    }

    func verifyPasscode(
        _ passcode: String,
        vault: WalletSecretVault = .shared
    ) async throws -> Bool {
        try await authenticatePasscode(passcode, vault: vault) == .success
    }

    func preparePasscodeCredentialPersistence(
        vault: WalletSecretVault = .shared
    ) async throws {
        let readiness = try await passcodeCredentialReadiness(vault: vault)
        switch readiness {
        case .available:
            return
        case .protectionDisabled:
            throw WalletPasscodeCredentialReadinessError(
                issue: .missingSecurityRecord
            )
        case let .unavailable(issue):
            throw WalletPasscodeCredentialReadinessError(issue: issue)
        }
    }

    func authenticatePasscode(
        _ passcode: String,
        vault: WalletSecretVault = .shared
    ) async throws -> WalletPasscodeAuthenticationResult {
        do {
            for _ in 0..<2 {
                let securitySnapshot = try await pool.read { database in
                    try DBProfileSecurityRecord.fetchOne(
                        database,
                        key: Self.defaultProfileID
                    )
                }
                guard let securitySnapshot else {
                    throw WalletCreationPersistenceError.missingSecret
                }

                let now = Date()
                if let lockedUntil = securitySnapshot.lockedUntil {
                    let lockDate = Date(timeIntervalSince1970: lockedUntil)
                    if lockDate > now {
                        return .locked(until: lockDate)
                    }
                }

                let credential = try vault.validatedPasscodeCredential(
                    reference:
                        securitySnapshot.passcodeKeychainReference,
                    decode: WalletPasscodeCredential.decodeStoredData
                )
                let matches = credential.matches(passcode: passcode)
                let result = try await pool.write {
                    database -> WalletPasscodeAuthenticationResult? in
                    guard var security =
                        try DBProfileSecurityRecord.fetchOne(
                            database,
                            key: Self.defaultProfileID
                        )
                    else {
                        throw WalletCreationPersistenceError.missingSecret
                    }

                    guard security.passcodeKeychainReference
                        == securitySnapshot.passcodeKeychainReference
                    else {
                        return nil
                    }

                    let updateTime = Date()
                    if let lockedUntil = security.lockedUntil {
                        let lockDate = Date(
                            timeIntervalSince1970: lockedUntil
                        )
                        if lockDate > updateTime {
                            return .locked(until: lockDate)
                        }
                    }

                    if matches {
                        security.failedAttemptCount = 0
                        security.lockedUntil = nil
                    } else {
                        if security.failedAttemptCount < Int.max {
                            security.failedAttemptCount += 1
                        }
                        if let duration = WalletPasscodeLockoutPolicy
                            .duration(
                                afterFailedAttemptCount:
                                    security.failedAttemptCount
                            ) {
                            security.lockedUntil = updateTime
                                .addingTimeInterval(
                                    duration
                                )
                                .timeIntervalSince1970
                        } else {
                            security.lockedUntil = nil
                        }
                    }
                    security.updatedAt = updateTime.timeIntervalSince1970
                    try security.update(database)

                    if matches {
                        return .success
                    }
                    if let lockedUntil = security.lockedUntil {
                        return .locked(
                            until: Date(
                                timeIntervalSince1970: lockedUntil
                            )
                        )
                    }
                    return .incorrect
                }
                if let result {
                    return result
                }
            }
            throw WalletCreationPersistenceError.missingSecret
        } catch {
            throw error
        }
    }

    func authorizeSecretExport(
        walletID: String,
        authenticationGrant: WalletAuthenticationGrant
    ) async throws -> WalletSecretExportAuthorization {
        try await WalletSecretExportAuthorization.afterAuthentication(
            walletID: walletID,
            grant: authenticationGrant,
            database: self
        )
    }

    func authorizeUnprotectedSecretExport(
        walletID: String
    ) async throws -> WalletSecretExportAuthorization {
        try await WalletSecretExportAuthorization
            .whenProtectionIsDisabled(
                walletID: walletID,
                database: self
            )
    }

}

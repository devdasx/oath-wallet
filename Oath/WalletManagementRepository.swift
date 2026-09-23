import Foundation
import GRDB
import WalletCore

enum ManagedWalletKind: String, Sendable {
    case created
    case importedRecoveryPhrase
    case importedPrivateKey
    case watchOnly
    case hardware

    var hasRecoveryPhrase: Bool {
        self == .created || self == .importedRecoveryPhrase
    }

    var hasExportableSecret: Bool {
        hasRecoveryPhrase || self == .importedPrivateKey
    }
}

struct ManagedWallet: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: ManagedWalletKind
    let address: String
    let fiatUSDBalance: Decimal
    let isSelected: Bool
    let notificationsEnabledWhenInactive: Bool
    let backupState: DatabaseWalletBackupState
    let backupVerifiedAt: Date?
    let iCloudBackupUpdatedAt: Date?
    var iCloudBackupWalletID: String? = nil
    let mnemonicWordCount: Int?
    let createdAt: Date
    var appearanceColor: WalletAppearanceColor = .blue

    var needsBackup: Bool {
        kind.hasExportableSecret
            && backupState != .verified
            && iCloudBackupUpdatedAt == nil
    }
}

enum WalletSensitiveMaterial: Equatable, Sendable {
    case recoveryPhrase(WalletRecoveryCredential)
    case privateKey(String)
    case bitcoinImportedWallet(BitcoinImportedWalletMaterial)

    var hasPassphrase: Bool? {
        switch self {
        case let .recoveryPhrase(credential):
            credential.hasPassphrase
        case .privateKey, .bitcoinImportedWallet:
            nil
        }
    }

    func encodedData() throws -> Data {
        switch self {
        case let .recoveryPhrase(credential):
            try credential.encodedData()
        case let .privateKey(hex):
            Data(hex.utf8)
        case let .bitcoinImportedWallet(material):
            try material.encoded()
        }
    }
}

struct WalletRemovalResult: Sendable {
    let selectedWallet: PersistedWalletIdentity?
    let hasWallets: Bool
}

struct WalletRemovalPlan: Sendable {
    let walletID: String
    let walletUpdatedAt: Double
    let walletName: String
    let walletAddress: String
    let walletKind: ManagedWalletKind
    let walletSecretReference: String?
    let passcodeReference: String?
    let removesLastWallet: Bool
    let hasICloudBackup: Bool
    var iCloudBackupWalletID: String? = nil
}

enum WalletManagementError: Error {
    case walletNotFound
    case invalidName
    case addressUnavailable
    case secretUnavailable
    case secretAccessDenied
    case removalPlanStale
    case removalVerificationFailed
}

private struct ManagedWalletBalanceRow: Decodable, FetchableRecord {
    let walletID: String
    let fiatUSDValue: String
}

extension WalletDatabase {
    func managedWalletCount() async throws -> Int {
        try await pool.read { database in
            try DBWalletRecord
                .filter(Column("profileID") == Self.defaultProfileID)
                .filter(Column("archivedAt") == nil)
                .fetchCount(database)
        }
    }

    func managedWallets() async throws -> [ManagedWallet] {
        try await pool.read { database in
            try Self.managedWallets(database: database)
        }
    }

    static func managedWallets(
        database: Database
    ) throws -> [ManagedWallet] {
        let wallets = try DBWalletRecord
            .filter(Column("profileID") == Self.defaultProfileID)
            .filter(Column("archivedAt") == nil)
            .order(Column("sortOrder"), Column("createdAt"))
            .fetchAll(database)

        guard !wallets.isEmpty else { return [] }

        let accounts = try DBWalletAccountRecord.fetchAll(
            database,
            sql: """
            SELECT walletAccounts.*
            FROM walletAccounts
            JOIN wallets ON wallets.id = walletAccounts.walletID
            WHERE wallets.profileID = ?
              AND wallets.archivedAt IS NULL
              AND walletAccounts.isEnabled = 1
            ORDER BY
              CASE WHEN walletAccounts.networkID = 'eth'
                THEN 0 ELSE 1 END,
              walletAccounts.createdAt
            """,
            arguments: [Self.defaultProfileID]
        )
        var primaryAccountsByWalletID:
            [String: DBWalletAccountRecord] = [:]
        for account in accounts
        where primaryAccountsByWalletID[account.walletID] == nil {
            primaryAccountsByWalletID[account.walletID] = account
        }

        let balanceRows = try ManagedWalletBalanceRow.fetchAll(
            database,
            sql: """
            SELECT
              walletAccounts.walletID AS walletID,
              COALESCE(accountAssets.fiatUSDValue, '0')
                AS fiatUSDValue
            FROM accountAssets
            JOIN walletAccounts
              ON walletAccounts.id = accountAssets.accountID
            JOIN wallets ON wallets.id = walletAccounts.walletID
            WHERE wallets.profileID = ?
              AND wallets.archivedAt IS NULL
              AND walletAccounts.isEnabled = 1
              AND accountAssets.isEnabled = 1
              AND accountAssets.isHidden = 0
            """,
            arguments: [Self.defaultProfileID]
        )
        let locale = Locale(identifier: "en_US_POSIX")
        var balancesByWalletID: [String: Decimal] = [:]
        for row in balanceRows {
            balancesByWalletID[row.walletID, default: 0] +=
                Decimal(
                    string: row.fiatUSDValue,
                    locale: locale
                ) ?? 0
        }

        return try wallets.map { wallet in
            try Self.makeManagedWallet(
                wallet,
                address:
                    primaryAccountsByWalletID[wallet.id]?.address ?? "",
                fiatUSDBalance:
                    balancesByWalletID[wallet.id] ?? 0
            )
        }
    }

    func managedWallet(walletID: String) async throws -> ManagedWallet {
        try await pool.read { database in
            guard let wallet = try DBWalletRecord
                .filter(Column("id") == walletID)
                .filter(Column("profileID") == Self.defaultProfileID)
                .filter(Column("archivedAt") == nil)
                .fetchOne(database)
            else {
                throw WalletManagementError.walletNotFound
            }
            return try Self.makeManagedWallet(wallet, database: database)
        }
    }

    func existingWallet(
        matching draft: WalletImportDraft,
        vault: WalletSecretVault = .shared
    ) async throws -> ManagedWallet? {
        if case let .bitcoinImportedWallet(material) = draft.secret {
            return try await existingBitcoinImportedWallet(matching: material, vault: vault)
        }
        let networkID: String
        switch draft.secret {
        case .recoveryPhrase:
            // Every recovery-phrase wallet owns its canonical EVM account,
            // which provides a stable identity across created and imported
            // recovery-phrase wallet kinds.
            networkID = PrivateKeyImportNetwork.evm.networkID
        case let .privateKey(_, network, _):
            networkID = network.networkID
        case .muunRecovery, .bitcoinImportedWallet:
            networkID = BitcoinFamilyChain.bitcoin.networkID
        }

        return try await pool.read { database in
            guard let wallet = try DBWalletRecord.fetchOne(
                database,
                sql: """
                SELECT wallets.*
                FROM wallets
                JOIN walletAccounts
                  ON walletAccounts.walletID = wallets.id
                WHERE wallets.profileID = ?
                  AND wallets.archivedAt IS NULL
                  AND wallets.kind IN (?, ?, ?)
                  AND walletAccounts.isEnabled = 1
                  AND walletAccounts.networkID = ?
                  AND walletAccounts.normalizedAddress = ?
                  AND COALESCE(walletAccounts.derivationPath, '') != ?
                ORDER BY wallets.isSelected DESC,
                         wallets.createdAt ASC
                LIMIT 1
                """,
                arguments: [
                    Self.defaultProfileID,
                    ManagedWalletKind.created.rawValue,
                    ManagedWalletKind.importedRecoveryPhrase.rawValue,
                    ManagedWalletKind.importedPrivateKey.rawValue,
                    networkID,
                    draft.normalizedAddress,
                    BitcoinImportedWalletMaterial.accountMarker
                ]
            ) else {
                return nil
            }

            return try Self.makeManagedWallet(
                wallet,
                database: database
            )
        }
    }

    func renameWallet(
        walletID: String,
        name: String
    ) async throws -> ManagedWallet {
        guard let trimmedName = WalletDefaultName.normalizedCustomName(
            name
        ) else {
            throw WalletManagementError.invalidName
        }

        let renamedWallet = try await pool.write { database in
            guard var wallet = try DBWalletRecord
                .filter(Column("id") == walletID)
                .filter(Column("profileID") == Self.defaultProfileID)
                .filter(Column("archivedAt") == nil)
                .fetchOne(database)
            else {
                throw WalletManagementError.walletNotFound
            }

            wallet.name = trimmedName
            wallet.updatedAt = Date().timeIntervalSince1970
            try wallet.update(database)
            return try Self.makeManagedWallet(wallet, database: database)
        }
        return renamedWallet
    }

    func selectWallet(
        walletID: String
    ) async throws -> PersistedWalletIdentity {
        try await pool.write { database in
            guard var wallet = try DBWalletRecord
                .filter(Column("id") == walletID)
                .filter(Column("profileID") == Self.defaultProfileID)
                .filter(Column("archivedAt") == nil)
                .fetchOne(database)
            else {
                throw WalletManagementError.walletNotFound
            }

            guard let account = try Self.primaryAccount(
                walletID: wallet.id,
                database: database
            ) else {
                throw WalletManagementError.addressUnavailable
            }

            let now = Date().timeIntervalSince1970
            try database.execute(
                sql: """
                UPDATE wallets
                SET isSelected = 0, updatedAt = ?
                WHERE profileID = ? AND archivedAt IS NULL
                """,
                arguments: [now, Self.defaultProfileID]
            )
            wallet.isSelected = true
            wallet.updatedAt = now
            wallet.lastOpenedAt = now
            try wallet.update(database)

            return PersistedWalletIdentity(
                walletID: wallet.id,
                address: account.address
            )
        }
    }

    func setNotificationsEnabledWhenInactive(
        walletID: String,
        enabled: Bool
    ) async throws -> ManagedWallet {
        try await pool.write { database in
            guard var wallet = try DBWalletRecord
                .filter(Column("id") == walletID)
                .filter(Column("profileID") == Self.defaultProfileID)
                .filter(Column("archivedAt") == nil)
                .fetchOne(database)
            else {
                throw WalletManagementError.walletNotFound
            }

            wallet.notificationsEnabledWhenInactive = enabled
            wallet.updatedAt = Date().timeIntervalSince1970
            try wallet.update(database)
            return try Self.makeManagedWallet(
                wallet,
                database: database
            )
        }
    }

    func setWalletAppearanceColor(
        walletID: String,
        color: WalletAppearanceColor
    ) async throws -> ManagedWallet {
        try await pool.write { database in
            guard var wallet = try DBWalletRecord
                .filter(Column("id") == walletID)
                .filter(Column("profileID") == Self.defaultProfileID)
                .filter(Column("archivedAt") == nil)
                .fetchOne(database)
            else {
                throw WalletManagementError.walletNotFound
            }

            wallet.appearanceColorID = color.rawValue
            wallet.updatedAt = Date().timeIntervalSince1970
            try wallet.update(database)
            return try Self.makeManagedWallet(
                wallet,
                database: database
            )
        }
    }

    func reorderWallets(_ orderedWalletIDs: [String]) async throws {
        try await pool.write { database in
            let now = Date().timeIntervalSince1970
            var seenWalletIDs: Set<String> = []
            for (index, walletID) in orderedWalletIDs.enumerated() {
                if !seenWalletIDs.insert(walletID).inserted { continue }
                try database.execute(
                    sql: """
                    UPDATE wallets
                    SET sortOrder = ?, updatedAt = ?
                    WHERE id = ?
                      AND profileID = ?
                      AND archivedAt IS NULL
                    """,
                    arguments: [index, now, walletID, Self.defaultProfileID]
                )
            }
        }
    }

    func prepareWalletRemoval(
        walletID: String
    ) async throws -> WalletRemovalPlan {
        try await pool.read { database in
            guard let wallet = try DBWalletRecord
                .filter(Column("id") == walletID)
                .filter(Column("profileID") == Self.defaultProfileID)
                .filter(Column("archivedAt") == nil)
                .fetchOne(database)
            else {
                throw WalletManagementError.walletNotFound
            }

            let remaining = try DBWalletRecord
                .filter(Column("profileID") == Self.defaultProfileID)
                .filter(Column("archivedAt") == nil)
                .filter(Column("id") != walletID)
                .order(Column("sortOrder"), Column("createdAt"))
                .fetchAll(database)

            let passcodeReference = remaining.isEmpty
                ? try DBProfileSecurityRecord.fetchOne(
                    database,
                    key: Self.defaultProfileID
                )?.passcodeKeychainReference
                : nil
            let managedWallet = try Self.makeManagedWallet(
                wallet,
                database: database
            )

            return WalletRemovalPlan(
                walletID: wallet.id,
                walletUpdatedAt: wallet.updatedAt,
                walletName: wallet.name,
                walletAddress: managedWallet.address,
                walletKind: managedWallet.kind,
                walletSecretReference: wallet.secretKeyReference,
                passcodeReference: passcodeReference,
                removesLastWallet: remaining.isEmpty,
                hasICloudBackup: wallet.iCloudBackupUpdatedAt != nil,
                iCloudBackupWalletID: wallet.iCloudBackupWalletID
            )
        }
    }

    func executeWalletRemoval(
        _ plan: WalletRemovalPlan,
        vault: any WalletSecureCleanupVault = WalletSecretVault.shared,
        onProgress: WalletRemovalProgressHandler? = nil
    ) async throws -> WalletRemovalResult {
        await onProgress?(.preparing)
        let operationID = UUID()
        let result: WalletRemovalResult
        do {
            await onProgress?(.removingWalletData)
            result = try await pool.write {
                database -> WalletRemovalResult in
                guard let wallet = try DBWalletRecord
                    .filter(Column("id") == plan.walletID)
                    .filter(Column("profileID") == Self.defaultProfileID)
                    .filter(Column("archivedAt") == nil)
                    .fetchOne(database)
                else {
                    throw WalletManagementError.walletNotFound
                }
                guard wallet.updatedAt == plan.walletUpdatedAt,
                      wallet.secretKeyReference
                        == plan.walletSecretReference,
                      wallet.kind == plan.walletKind.rawValue else {
                    throw WalletManagementError.removalPlanStale
                }

                let remaining = try DBWalletRecord
                    .filter(Column("profileID") == Self.defaultProfileID)
                    .filter(Column("archivedAt") == nil)
                    .filter(Column("id") != wallet.id)
                    .order(Column("sortOrder"), Column("createdAt"))
                    .fetchAll(database)
                let passcodeReference = remaining.isEmpty
                    ? try DBProfileSecurityRecord.fetchOne(
                        database,
                        key: Self.defaultProfileID
                    )?.passcodeKeychainReference
                    : nil
                var cleanupJobs: [
                    (
                        kind: WalletSecureCleanupJobKind,
                        opaqueReference: String?
                    )
                ] = []
                if let reference = wallet.secretKeyReference {
                    cleanupJobs.append(
                        (
                            kind: .walletSecret,
                            opaqueReference: reference
                        )
                    )
                }
                let bitcoinChildKeyReferences = try String.fetchAll(
                    database,
                    sql: """
                    SELECT keychainReference
                    FROM bitcoinHDKeyCaches
                    WHERE walletID = ?
                    """,
                    arguments: [wallet.id]
                )
                cleanupJobs.append(contentsOf:
                    bitcoinChildKeyReferences.map {
                        (kind: .walletSecret, opaqueReference: $0)
                    }
                )
                let silentPaymentReferences = try String.fetchAll(
                    database,
                    sql: """
                    SELECT keychainReference
                    FROM bitcoinSilentPaymentAccounts
                    WHERE walletID = ?
                    UNION ALL
                    SELECT keychainReference
                    FROM bitcoinSilentPaymentOutputs
                    WHERE walletID = ?
                    """,
                    arguments: [wallet.id, wallet.id]
                )
                cleanupJobs.append(contentsOf:
                    silentPaymentReferences.map {
                        (kind: .walletSecret, opaqueReference: $0)
                    }
                )
                cleanupJobs.append(
                    (
                        kind: .walletSecret,
                        opaqueReference:
                            WalletBackupDataKeyStore.reference(
                                walletID:
                                    wallet.iCloudBackupWalletID
                                    ?? wallet.id
                            )
                    )
                )
                if let passcodeReference {
                    cleanupJobs.append(
                        (
                            kind: .passcodeCredential,
                            opaqueReference: passcodeReference
                        )
                    )
                }
                let now = Date().timeIntervalSince1970
                try Self.insertSecureCleanupOperation(
                    in: database,
                    operationID: operationID,
                    scope: .walletRemoval,
                    jobs: cleanupJobs,
                    requiresMaintenance: false,
                    now: now
                )
                try wallet.delete(database)

                var selectedIdentity: PersistedWalletIdentity?
                if let selected = remaining.first(where: \.isSelected)
                    ?? remaining.first {
                    if !selected.isSelected {
                        try database.execute(
                            sql: """
                            UPDATE wallets
                            SET isSelected = CASE WHEN id = ? THEN 1 ELSE 0 END,
                                updatedAt = ?
                            WHERE profileID = ? AND archivedAt IS NULL
                            """,
                            arguments: [
                                selected.id,
                                now,
                                Self.defaultProfileID
                            ]
                        )
                    }

                    if let account = try Self.primaryAccount(
                        walletID: selected.id,
                        database: database
                    ) {
                        selectedIdentity = PersistedWalletIdentity(
                            walletID: selected.id,
                            address: account.address
                        )
                    }
                }

                if remaining.isEmpty {
                    try database.execute(
                        sql: """
                        DELETE FROM profileSecurity WHERE profileID = ?
                        """,
                        arguments: [Self.defaultProfileID]
                    )
                }

                let residualWalletCount = try DBWalletRecord
                    .filter(Column("id") == plan.walletID)
                    .fetchCount(database)
                let residualSecurityCount = remaining.isEmpty
                    ? try DBProfileSecurityRecord
                        .filter(
                            Column("profileID")
                                == Self.defaultProfileID
                        )
                        .fetchCount(database)
                    : 0
                guard residualWalletCount == 0,
                      residualSecurityCount == 0 else {
                    throw WalletManagementError
                        .removalVerificationFailed
                }

                return WalletRemovalResult(
                    selectedWallet: selectedIdentity,
                    hasWallets: !remaining.isEmpty
                )
            }
        } catch {
            throw error
        }
        // The wallet deletion and cleanup jobs committed together. Keychain
        // deletion is idempotent and a failure remains journaled for startup
        // or foreground retry rather than misreporting the database removal.
        await onProgress?(.removingCredentials)
        _ = await retryPendingSecretCleanup(vault: vault)
        await onProgress?(.updatingServices)
        await onProgress?(.complete)
        return result
    }

    func removeWallet(
        walletID: String,
        vault: any WalletSecureCleanupVault = WalletSecretVault.shared,
        onProgress: WalletRemovalProgressHandler? = nil
    ) async throws -> WalletRemovalResult {
        let plan = try await prepareWalletRemoval(walletID: walletID)
        return try await executeWalletRemoval(
            plan,
            vault: vault,
            onProgress: onProgress
        )
    }

    func sensitiveMaterial(
        walletID: String,
        authorization: WalletSecretExportAuthorization,
        vault: WalletSecretVault = .shared
    ) async throws -> WalletSensitiveMaterial {
        guard authorization.permits(walletID: walletID) else {
            throw WalletManagementError.secretAccessDenied
        }
        return try await storedSensitiveMaterial(
            walletID: walletID,
            vault: vault
        )
    }

    func sensitiveMaterialForICloudBackup(
        walletID: String,
        authorization: WalletPasskeyBackupAuthorization,
        vault: WalletSecretVault = .shared
    ) async throws -> WalletSensitiveMaterial {
        guard authorization.permits(walletID: walletID) else {
            throw WalletManagementError.secretAccessDenied
        }
        return try await storedSensitiveMaterial(
            walletID: walletID,
            vault: vault
        )
    }

    private func storedSensitiveMaterial(
        walletID: String,
        vault: WalletSecretVault
    ) async throws -> WalletSensitiveMaterial {
        let wallet = try await pool.read { database in
            try DBWalletRecord
                .filter(Column("id") == walletID)
                .filter(Column("profileID") == Self.defaultProfileID)
                .filter(Column("archivedAt") == nil)
                .fetchOne(database)
        }
        guard let wallet,
              let kind = ManagedWalletKind(rawValue: wallet.kind),
              let reference = wallet.secretKeyReference
        else {
            throw WalletManagementError.secretUnavailable
        }

        let data = try vault.data(reference: reference)
        switch kind {
        case .created, .importedRecoveryPhrase:
            guard let credential = try? WalletRecoveryCredential.decode(data)
            else {
                throw WalletManagementError.secretUnavailable
            }
            return .recoveryPhrase(credential)
        case .importedPrivateKey:
            if let imported = try await bitcoinImportedMaterial(walletID: walletID, vault: vault) {
                return .bitcoinImportedWallet(imported)
            }
            guard data.count == 32, PrivateKey(data: data) != nil else {
                throw WalletManagementError.secretUnavailable
            }
            return .privateKey(data.hexString)
        case .watchOnly, .hardware:
            throw WalletManagementError.secretUnavailable
        }
    }

    func markManualBackupVerified(walletID: String) async throws {
        try await pool.write { database in
            let now = Date().timeIntervalSince1970
            try database.execute(
                sql: """
                UPDATE wallets
                SET backupState = ?, backupVerifiedAt = ?, updatedAt = ?
                WHERE id = ? AND profileID = ? AND archivedAt IS NULL
                """,
                arguments: [
                    DatabaseWalletBackupState.verified.rawValue,
                    now,
                    now,
                    walletID,
                    Self.defaultProfileID
                ]
            )
            guard database.changesCount > 0 else {
                throw WalletManagementError.walletNotFound
            }
        }
    }

    func markICloudBackupRemoteVerified(
        walletID: String,
        cloudWalletID: String? = nil,
        receipt: WalletCloudBackupReceipt
    ) async throws {
        try await pool.write { database in
            let now = Date().timeIntervalSince1970
            try database.execute(
                sql: """
                UPDATE wallets SET
                    iCloudBackupUpdatedAt = ?,
                    iCloudBackupVerificationVersion = 1,
                    iCloudBackupRecordChangeTag = ?,
                    iCloudBackupWalletID = ?,
                    updatedAt = ?
                WHERE id = ? AND profileID = ? AND archivedAt IS NULL
                """,
                arguments: [
                    receipt.serverModifiedAt.timeIntervalSince1970,
                    receipt.serverChangeTag,
                    cloudWalletID ?? walletID,
                    now,
                    walletID,
                    Self.defaultProfileID
                ]
            )
            guard database.changesCount > 0 else {
                throw WalletManagementError.walletNotFound
            }
        }
    }

    func clearICloudBackupRemoteVerification(
        walletID: String
    ) async throws {
        try await pool.write { database in
            let now = Date().timeIntervalSince1970
            try database.execute(
                sql: """
                UPDATE wallets SET
                    iCloudBackupUpdatedAt = NULL,
                    iCloudBackupVerificationVersion = 0,
                    iCloudBackupRecordChangeTag = NULL,
                    iCloudBackupWalletID = NULL,
                    updatedAt = ?
                WHERE (id = ? OR iCloudBackupWalletID = ?)
                    AND profileID = ? AND archivedAt IS NULL
                """,
                arguments: [
                    now,
                    walletID,
                    walletID,
                    Self.defaultProfileID
                ]
            )
        }
    }

    private static func makeManagedWallet(
        _ wallet: DBWalletRecord,
        database: Database
    ) throws -> ManagedWallet {
        let account = try primaryAccount(
            walletID: wallet.id,
            database: database
        )
        let fiatUSDBalance = try walletFiatUSDBalance(
            walletID: wallet.id,
            database: database
        )
        return try makeManagedWallet(
            wallet,
            address: account?.address ?? "",
            fiatUSDBalance: fiatUSDBalance
        )
    }

    private static func makeManagedWallet(
        _ wallet: DBWalletRecord,
        address: String,
        fiatUSDBalance: Decimal
    ) throws -> ManagedWallet {
        guard let kind = ManagedWalletKind(rawValue: wallet.kind),
              let backupState = DatabaseWalletBackupState(
                rawValue: wallet.backupState
              )
        else {
            throw WalletManagementError.walletNotFound
        }

        return ManagedWallet(
            id: wallet.id,
            name: wallet.name,
            kind: kind,
            address: address,
            fiatUSDBalance: fiatUSDBalance,
            isSelected: wallet.isSelected,
            notificationsEnabledWhenInactive:
                wallet.notificationsEnabledWhenInactive,
            backupState: backupState,
            backupVerifiedAt: wallet.backupVerifiedAt.map(
                Date.init(timeIntervalSince1970:)
            ),
            iCloudBackupUpdatedAt:
                wallet.iCloudBackupVerificationVersion == 1
                ? wallet.iCloudBackupUpdatedAt.map(
                    Date.init(timeIntervalSince1970:)
                )
                : nil,
            iCloudBackupWalletID: wallet.iCloudBackupWalletID,
            mnemonicWordCount: wallet.mnemonicWordCount,
            createdAt: Date(timeIntervalSince1970: wallet.createdAt),
            appearanceColor:
                WalletAppearanceColor(
                    rawValue: wallet.appearanceColorID ?? ""
                ) ?? .blue
        )
    }

    private static func walletFiatUSDBalance(
        walletID: String,
        database: Database
    ) throws -> Decimal {
        let storedValues = try String.fetchAll(
            database,
            sql: """
            SELECT COALESCE(accountAssets.fiatUSDValue, '0')
            FROM accountAssets
            JOIN walletAccounts
              ON walletAccounts.id = accountAssets.accountID
            WHERE walletAccounts.walletID = ?
              AND walletAccounts.isEnabled = 1
              AND accountAssets.isEnabled = 1
              AND accountAssets.isHidden = 0
            """,
            arguments: [walletID]
        )
        let locale = Locale(identifier: "en_US_POSIX")
        return storedValues.reduce(into: Decimal.zero) {
            total,
            storedValue in
            total += Decimal(string: storedValue, locale: locale) ?? 0
        }
    }

    private static func primaryAccount(
        walletID: String,
        database: Database
    ) throws -> DBWalletAccountRecord? {
        try DBWalletAccountRecord
            .filter(Column("walletID") == walletID)
            .filter(Column("isEnabled") == true)
            .order(
                sql: "CASE WHEN networkID = 'eth' THEN 0 ELSE 1 END, createdAt"
            )
            .fetchOne(database)
    }
}

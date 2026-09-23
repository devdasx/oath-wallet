import Foundation
import GRDB

extension WalletDatabase {
    static func registerWalletAccountDerivationMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v43_wallet_account_derivation_version"
        ) { database in
            try database.execute(
                sql: """
                ALTER TABLE wallets ADD COLUMN
                    accountDerivationVersion INTEGER NOT NULL DEFAULT 0
                    CHECK (accountDerivationVersion BETWEEN 0 AND 1);
                """
            )
        }
    }
}

extension WalletDatabase {
    /// Repairs wallets created by older builds once, before parallel chain
    /// synchronization. Current wallets take the database-only fast path.
    func ensureFullWalletAccountsPersisted(
        walletID: String,
        vault: WalletSecretVault = .shared
    ) async throws {
        let stored = try await pool.read { database in
            let accounts = try DBWalletAccountRecord
                .filter(Column("walletID") == walletID)
                .fetchAll(database)
            let projectedBitcoinAddresses = accounts
                .filter {
                    $0.networkID == BitcoinFamilyChain.bitcoin.networkID
                }
                .map(\.address)
            return (
                wallet: try DBWalletRecord.fetchOne(
                    database,
                    key: walletID
                ),
                accounts: accounts,
                bitcoinHDAddresses: projectedBitcoinAddresses.isEmpty
                    ? []
                    : try DBBitcoinHDAddressRecord
                        .filter(Column("walletID") == walletID)
                        .filter(
                            projectedBitcoinAddresses.contains(
                                Column("address")
                            )
                        )
                        .fetchAll(database)
            )
        }
        guard let wallet = stored.wallet else {
            throw WalletCreationPersistenceError.missingSecret
        }
        guard WalletAccountDerivationService.supportsFullDerivation(
            walletKind: wallet.kind
        ) else {
            return
        }
        // Current wallets are complete using public database state alone.
        // Do not touch Keychain on every activation.
        if wallet.accountDerivationVersion
                >= WalletAccountDerivationService.currentPersistenceVersion,
           WalletAccountDerivationService.isStructurallyComplete(
                accounts: stored.accounts,
                bitcoinHDAddresses: stored.bitcoinHDAddresses
           ) {
            return
        }
        guard let reference = wallet.secretKeyReference else {
            throw WalletCreationPersistenceError.missingSecret
        }
        let credential = try WalletRecoveryCredential.decode(
            vault.data(reference: reference)
        )
        let material = try await Task.detached(priority: .userInitiated) {
            try await WalletAccountDerivationService
                .deriveFullWalletMaterial(credential: credential)
        }.value
        try await repairFullWalletAccountRows(
            material.accounts,
            walletID: walletID
        )
    }

    private func repairFullWalletAccountRows(
        _ derived: [WalletDerivedAccount],
        walletID: String
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            guard let wallet = try DBWalletRecord.fetchOne(
                database,
                key: walletID
            ), WalletAccountDerivationService.supportsFullDerivation(
                walletKind: wallet.kind
            )
            else {
                throw WalletCreationPersistenceError.invalidDraft
            }

            var stored = try DBWalletAccountRecord
                .filter(Column("walletID") == walletID)
                .fetchAll(database)
            let projectedBitcoinAddresses = stored
                .filter {
                    $0.networkID == BitcoinFamilyChain.bitcoin.networkID
                }
                .map(\.address)
            let bitcoinHDAddresses = projectedBitcoinAddresses.isEmpty
                ? []
                : try DBBitcoinHDAddressRecord
                    .filter(Column("walletID") == walletID)
                    .filter(
                        projectedBitcoinAddresses.contains(Column("address"))
                    )
                    .fetchAll(database)
            for account in derived {
                let sameIdentity = stored.first(where: account.matches)
                if sameIdentity != nil {
                    continue
                }

                let candidates = stored.filter {
                    $0.networkID == account.networkID
                        && (
                            account.networkID != SolanaConstants.networkID
                                || $0.label == account.label
                        )
                }
                if account.networkID
                        == BitcoinFamilyChain.bitcoin.networkID,
                   candidates.contains(where: {
                       BitcoinHDReceiveAccountProjection.matches(
                           $0,
                           addresses: bitcoinHDAddresses
                       )
                   }) {
                    continue
                }

                let canonical = account.record(walletID: walletID, now: now)
                if let retained = candidates.first(where: {
                    $0.id == canonical.id
                }) {
                    for candidate in candidates where candidate.id != retained.id {
                        _ = try DBWalletAccountRecord.deleteOne(
                            database,
                            key: candidate.id
                        )
                    }
                    let repaired = DBWalletAccountRecord(
                        id: retained.id,
                        walletID: retained.walletID,
                        networkID: canonical.networkID,
                        address: canonical.address,
                        normalizedAddress: canonical.normalizedAddress,
                        label: canonical.label,
                        derivationPath: canonical.derivationPath,
                        accountIndex: canonical.accountIndex,
                        publicKey: canonical.publicKey,
                        isWatchOnly: false,
                        isEnabled: true,
                        createdAt: retained.createdAt,
                        updatedAt: now,
                        lastSyncedAt: retained.lastSyncedAt
                    )
                    try repaired.update(database)
                    stored.removeAll { candidate in
                        candidates.contains(where: { $0.id == candidate.id })
                    }
                    stored.append(repaired)
                    continue
                }
                for candidate in candidates {
                    _ = try DBWalletAccountRecord.deleteOne(
                        database,
                        key: candidate.id
                    )
                }
                let record = canonical
                try record.insert(database)
                stored.removeAll { candidate in
                    candidates.contains(where: { $0.id == candidate.id })
                }
                stored.append(record)
            }
            try database.execute(
                sql: """
                UPDATE wallets
                SET accountDerivationVersion = ?, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [
                    WalletAccountDerivationService
                        .currentPersistenceVersion,
                    now,
                    walletID
                ]
            )
        }
    }
}

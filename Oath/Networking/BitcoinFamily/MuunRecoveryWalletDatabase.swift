import Foundation
import GRDB

enum MuunRecoveryWalletDatabaseError: Error, Equatable {
    case walletUnavailable
    case unsupportedWallet
    case invalidState
    case secretUnavailable
}

extension WalletDatabase {
    func muunRecoveryWallet(
        walletID: String
    ) async throws -> MuunRecoveryWalletState? {
        let record = try await pool.read { database in
            try DBMuunRecoveryWalletRecord.fetchOne(
                database,
                key: walletID
            )
        }
        return record.map(Self.muunRecoveryWalletState)
    }

    func muunRecoveryWalletOwnsAddress(
        walletID: String,
        address: String
    ) async throws -> Bool {
        guard !address.isEmpty else { return false }
        return try await pool.read { database in
            try Bool.fetchOne(
                database,
                sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM muunRecoveryAddresses
                    WHERE walletID = ? AND address = ?
                )
                """,
                arguments: [walletID, address]
            ) ?? false
        }
    }

    func muunRecoveryKeyMaterial(
        walletID: String,
        vault: WalletSecretVault = .shared
    ) async throws -> MuunRecoveryKeyMaterial {
        let stored = try await pool.read { database in
            (
                wallet: try DBWalletRecord.fetchOne(
                    database,
                    key: walletID
                ),
                account: try DBWalletAccountRecord
                    .filter(Column("walletID") == walletID)
                    .filter(Column("networkID") == "bitcoin")
                    .filter(
                        Column("derivationPath")
                            == MuunRecoveryKeyMaterial.accountMarker
                    )
                    .fetchOne(database),
                recovery: try DBMuunRecoveryWalletRecord.fetchOne(
                    database,
                    key: walletID
                )
            )
        }
        guard let wallet = stored.wallet,
              wallet.kind == DatabaseWalletKind.importedPrivateKey.rawValue,
              let reference = wallet.secretKeyReference,
              stored.account != nil,
              let recovery = stored.recovery else {
            throw MuunRecoveryWalletDatabaseError.unsupportedWallet
        }
        let material: MuunRecoveryKeyMaterial
        do {
            material = try MuunRecoveryKeyMaterial.decode(
                vault.data(reference: reference)
            )
        } catch {
            throw MuunRecoveryWalletDatabaseError.secretUnavailable
        }
        guard material.birthdayBlock == recovery.birthdayBlock else {
            throw MuunRecoveryWalletDatabaseError.invalidState
        }
        return material
    }

    func muunRecoveryAddresses(
        walletID: String,
        usedOrReservedOnly: Bool = false
    ) async throws -> [MuunRecoveryAddressState] {
        let records = try await pool.read { database in
            var request = DBMuunRecoveryAddressRecord
                .filter(Column("walletID") == walletID)
            if usedOrReservedOnly {
                request = request.filter(
                    Column("isUsed") == true
                        || Column("isReserved") == true
                )
            }
            return try request.order(
                Column("branch"),
                Column("contactIndex"),
                Column("addressIndex"),
                Column("version")
            ).fetchAll(database)
        }
        return try records.map(Self.muunRecoveryAddressState)
    }

    func saveMuunRecoveryScanBatch(
        walletID: String,
        states: [MuunRecoveryAddressState],
        nextCursor: Int,
        fullScanCompleted: Bool
    ) async throws {
        guard nextCursor >= 0 else {
            throw MuunRecoveryWalletDatabaseError.invalidState
        }
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            guard var wallet = try DBMuunRecoveryWalletRecord.fetchOne(
                database,
                key: walletID
            ), nextCursor >= wallet.recoveryScanCursor else {
                throw MuunRecoveryWalletDatabaseError.invalidState
            }
            for state in states {
                try Self.saveMuunRecoveryAddressState(
                    state,
                    walletID: walletID,
                    now: now,
                    database: database
                )
            }
            wallet.recoveryScanCursor = nextCursor
            wallet.fullScanCompleted = wallet.fullScanCompleted
                || fullScanCompleted
            let nextIndices = try Self.muunRecoveryNextIndices(
                walletID: walletID,
                database: database
            )
            wallet.nextExternalIndex = max(
                wallet.nextExternalIndex,
                nextIndices.external
            )
            wallet.nextChangeIndex = max(
                wallet.nextChangeIndex,
                nextIndices.change
            )
            wallet.updatedAt = now
            try wallet.update(database)
        }
    }

    func saveMuunRecoveryAddressStates(
        _ states: [MuunRecoveryAddressState],
        walletID: String
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            guard try DBMuunRecoveryWalletRecord.fetchOne(
                database,
                key: walletID
            ) != nil else {
                throw MuunRecoveryWalletDatabaseError.unsupportedWallet
            }
            for state in states {
                try Self.saveMuunRecoveryAddressState(
                    state,
                    walletID: walletID,
                    now: now,
                    database: database
                )
            }
            let next = try Self.muunRecoveryNextIndices(
                walletID: walletID,
                database: database
            )
            try database.execute(
                sql: """
                UPDATE muunRecoveryWallets
                SET nextExternalIndex = MAX(nextExternalIndex, ?),
                    nextChangeIndex = MAX(nextChangeIndex, ?), updatedAt = ?
                WHERE walletID = ?
                """,
                arguments: [next.external, next.change, now, walletID]
            )
        }
    }

    func freshMuunRecoveryReceiveAddress(
        walletID: String,
        vault: WalletSecretVault = .shared
    ) async throws -> MuunRecoveryDerivedAddress? {
        guard let wallet = try await muunRecoveryWallet(walletID: walletID)
        else { return nil }
        let material = try await muunRecoveryKeyMaterial(
            walletID: walletID,
            vault: vault
        )
        let derived = try MuunRecoveryAddressFactory.derive(
            material: material,
            version: .v5,
            branch: .external,
            addressIndex: wallet.nextExternalIndex
        )
        try await ensureMuunRecoveryAddress(
            derived,
            walletID: walletID
        )
        return derived
    }

    func reserveFreshMuunRecoveryChangeAddress(
        walletID: String,
        vault: WalletSecretVault = .shared
    ) async throws -> MuunRecoveryDerivedAddress? {
        let material = try await muunRecoveryKeyMaterial(
            walletID: walletID,
            vault: vault
        )
        while true {
            guard let wallet = try await muunRecoveryWallet(
                walletID: walletID
            ) else { return nil }
            let index = wallet.nextChangeIndex
            let derived = try MuunRecoveryAddressFactory.derive(
                material: material,
                version: .v5,
                branch: .change,
                addressIndex: index
            )
            try await ensureMuunRecoveryAddress(
                derived,
                walletID: walletID
            )
            let now = Date().timeIntervalSince1970
            let claimed = try await pool.write { database in
                try database.execute(
                    sql: """
                    UPDATE muunRecoveryAddresses
                    SET isReserved = 1, updatedAt = ?
                    WHERE walletID = ? AND version = 5 AND branch = 0
                        AND contactIndex = -1 AND addressIndex = ?
                        AND address = ? AND isUsed = 0 AND isReserved = 0
                    """,
                    arguments: [
                        now, walletID, index, derived.address
                    ]
                )
                guard database.changesCount == 1 else { return false }
                try database.execute(
                    sql: """
                    UPDATE muunRecoveryWallets
                    SET nextChangeIndex = MAX(nextChangeIndex, ?),
                        updatedAt = ?
                    WHERE walletID = ?
                    """,
                    arguments: [index + 1, now, walletID]
                )
                return true
            }
            if claimed { return derived }
        }
    }

    func releaseMuunRecoveryChangeAddressReservation(
        walletID: String,
        address: String
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            try database.execute(
                sql: """
                UPDATE muunRecoveryAddresses
                SET isReserved = 0, updatedAt = ?
                WHERE walletID = ? AND branch = 0 AND address = ?
                    AND isUsed = 0 AND isReserved = 1
                """,
                arguments: [now, walletID, address]
            )
        }
    }

    func publishFreshMuunRecoveryReceiveAddress(
        walletID: String,
        vault: WalletSecretVault = .shared
    ) async throws {
        guard let fresh = try await freshMuunRecoveryReceiveAddress(
            walletID: walletID,
            vault: vault
        ) else { return }
        let now = Date().timeIntervalSince1970
        let publicKey = Data(fresh.scriptPubKey.dropFirst(2)).hexString
        try await pool.write { database in
            try database.execute(
                sql: """
                UPDATE walletAccounts
                SET address = ?, normalizedAddress = ?,
                    derivationPath = ?, publicKey = ?, updatedAt = ?
                WHERE id = ? AND walletID = ? AND networkID = 'bitcoin'
                    AND derivationPath = ?
                """,
                arguments: [
                    fresh.address,
                    fresh.address.lowercased(),
                    MuunRecoveryKeyMaterial.accountMarker,
                    publicKey,
                    now,
                    "\(walletID):bitcoin:0",
                    walletID,
                    MuunRecoveryKeyMaterial.accountMarker,
                ]
            )
            guard database.changesCount == 1 else {
                throw MuunRecoveryWalletDatabaseError.invalidState
            }
        }
    }

    private func ensureMuunRecoveryAddress(
        _ address: MuunRecoveryDerivedAddress,
        walletID: String
    ) async throws {
        let zero = BitcoinFamilyAtomicInteger.zero
        let state = MuunRecoveryAddressState(
            derived: address,
            isUsed: false,
            isReserved: false,
            confirmedBalanceAtomic: zero,
            unconfirmedBalanceAtomic: zero
        )
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            guard try DBMuunRecoveryWalletRecord.fetchOne(
                database,
                key: walletID
            ) != nil else {
                throw MuunRecoveryWalletDatabaseError.unsupportedWallet
            }
            try Self.saveMuunRecoveryAddressState(
                state,
                walletID: walletID,
                now: now,
                database: database
            )
        }
    }

    static func muunRecoveryAddressRecord(
        _ state: MuunRecoveryAddressState,
        walletID: String,
        now: Double
    ) throws -> DBMuunRecoveryAddressRecord {
        let derived = state.derived
        guard derived.addressIndex >= 0,
              (derived.branch == .contacts)
                == (derived.contactIndex != nil),
              !state.confirmedBalanceAtomic.isNegative,
              !state.balanceAtomic.isNegative else {
            throw MuunRecoveryWalletDatabaseError.invalidState
        }
        return DBMuunRecoveryAddressRecord(
            walletID: walletID,
            version: derived.version.rawValue,
            branch: derived.branch.rawValue,
            contactIndex: derived.contactIndex ?? -1,
            addressIndex: derived.addressIndex,
            derivationPath: derived.derivationPath,
            address: derived.address,
            scriptPubKey: derived.scriptPubKey,
            scriptHash: derived.scriptHash,
            isUsed: state.isUsed,
            isReserved: state.isReserved,
            confirmedBalanceAtomic:
                state.confirmedBalanceAtomic.decimalText,
            unconfirmedBalanceAtomic:
                state.unconfirmedBalanceAtomic.decimalText,
            lastCheckedAt: now,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func saveMuunRecoveryAddressState(
        _ state: MuunRecoveryAddressState,
        walletID: String,
        now: Double,
        database: Database
    ) throws {
        let record = try muunRecoveryAddressRecord(
            state,
            walletID: walletID,
            now: now
        )
        try database.execute(
            sql: """
            INSERT INTO muunRecoveryAddresses (
                walletID, version, branch, contactIndex, addressIndex,
                derivationPath, address, scriptPubKey, scriptHash,
                isUsed, isReserved, confirmedBalanceAtomic,
                unconfirmedBalanceAtomic, lastCheckedAt, createdAt, updatedAt
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(
                walletID, version, branch, contactIndex, addressIndex
            ) DO UPDATE SET
                isUsed = MAX(isUsed, excluded.isUsed),
                isReserved = CASE
                    WHEN excluded.isUsed = 1 THEN 0
                    ELSE isReserved
                END,
                confirmedBalanceAtomic = excluded.confirmedBalanceAtomic,
                unconfirmedBalanceAtomic = excluded.unconfirmedBalanceAtomic,
                lastCheckedAt = excluded.lastCheckedAt,
                updatedAt = excluded.updatedAt
            """,
            arguments: [
                record.walletID, record.version, record.branch,
                record.contactIndex, record.addressIndex,
                record.derivationPath, record.address,
                record.scriptPubKey, record.scriptHash,
                record.isUsed, record.isReserved,
                record.confirmedBalanceAtomic,
                record.unconfirmedBalanceAtomic,
                record.lastCheckedAt, record.createdAt, record.updatedAt,
            ]
        )
    }

    private static func muunRecoveryNextIndices(
        walletID: String,
        database: Database
    ) throws -> (external: Int, change: Int) {
        func next(branch: MuunRecoveryAddressBranch) throws -> Int {
            let maximum = try Int.fetchOne(
                database,
                sql: """
                SELECT MAX(addressIndex)
                FROM muunRecoveryAddresses
                WHERE walletID = ? AND branch = ? AND contactIndex = -1
                    AND (isUsed = 1 OR isReserved = 1)
                """,
                arguments: [walletID, branch.rawValue]
            )
            return (maximum ?? -1) + 1
        }
        return (try next(branch: .external), try next(branch: .change))
    }

    private static func muunRecoveryWalletState(
        _ record: DBMuunRecoveryWalletRecord
    ) -> MuunRecoveryWalletState {
        MuunRecoveryWalletState(
            walletID: record.walletID,
            birthdayBlock: record.birthdayBlock,
            recoveryScanCursor: record.recoveryScanCursor,
            fullScanCompleted: record.fullScanCompleted,
            nextExternalIndex: record.nextExternalIndex,
            nextChangeIndex: record.nextChangeIndex
        )
    }

    private static func muunRecoveryAddressState(
        _ record: DBMuunRecoveryAddressRecord
    ) throws -> MuunRecoveryAddressState {
        guard let version = MuunRecoveryAddressVersion(
            rawValue: record.version
        ), let branch = MuunRecoveryAddressBranch(
            rawValue: record.branch
        ), (branch == .contacts) == (record.contactIndex >= 0) else {
            throw MuunRecoveryWalletDatabaseError.invalidState
        }
        let confirmed = try BitcoinFamilyAtomicInteger(
            validating: record.confirmedBalanceAtomic
        )
        let unconfirmed = try BitcoinFamilyAtomicInteger(
            validating: record.unconfirmedBalanceAtomic
        )
        guard !confirmed.isNegative,
              !confirmed.adding(unconfirmed).isNegative else {
            throw MuunRecoveryWalletDatabaseError.invalidState
        }
        return MuunRecoveryAddressState(
            derived: MuunRecoveryDerivedAddress(
                version: version,
                branch: branch,
                contactIndex: record.contactIndex >= 0
                    ? record.contactIndex : nil,
                addressIndex: record.addressIndex,
                derivationPath: record.derivationPath,
                address: record.address,
                scriptPubKey: record.scriptPubKey,
                scriptHash: record.scriptHash
            ),
            isUsed: record.isUsed,
            isReserved: record.isReserved,
            confirmedBalanceAtomic: confirmed,
            unconfirmedBalanceAtomic: unconfirmed
        )
    }
}

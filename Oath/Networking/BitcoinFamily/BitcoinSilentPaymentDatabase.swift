import CryptoKit
import Foundation
import GRDB
import P256K

struct DBBitcoinSilentPaymentAccountRecord: Codable, FetchableRecord,
    PersistableRecord, Sendable {
    static let databaseTableName = "bitcoinSilentPaymentAccounts"

    var walletID: String
    var address: String
    var scanPublicKey: Data
    var spendPublicKey: Data
    var keychainReference: String
    var birthHeight: Int
    var lastScanHeight: Int
    var scanTargetHeight: Int =
        WalletDatabase.bitcoinSilentPaymentActivationHeight - 1
    var balanceIsAuthoritative: Bool
    var createdAt: Double
    var updatedAt: Double
}

struct DBBitcoinSilentPaymentOutputRecord: Codable, FetchableRecord,
    PersistableRecord, Sendable {
    static let databaseTableName = "bitcoinSilentPaymentOutputs"

    var walletID: String
    var transactionHash: String
    var outputIndex: Int
    var valueAtomic: String
    var scriptPubKey: Data
    var outputPublicKey: Data
    var keychainReference: String
    var blockHeight: Int?
    var blockTimestamp: Double?
    var isSpent: Bool
    var spentByTransactionHash: String?
    var createdAt: Double
    var updatedAt: Double
}

struct BitcoinSilentPaymentAccount: Hashable, Sendable {
    let walletID: String
    let address: BitcoinSilentPaymentAddress
    let birthHeight: Int
    let lastScanHeight: Int
    let scanTargetHeight: Int
    let balanceIsAuthoritative: Bool
}

struct BitcoinSilentPaymentScanProgress: Equatable, Sendable {
    let walletID: String
    let birthHeight: Int
    let lastScanHeight: Int
    let targetHeight: Int
    let updatedAt: Double

    init?(_ record: DBBitcoinSilentPaymentAccountRecord) {
        guard record.birthHeight
                >= WalletDatabase.bitcoinSilentPaymentActivationHeight,
              record.lastScanHeight >= record.birthHeight - 1,
              record.scanTargetHeight >= record.lastScanHeight else {
            return nil
        }
        walletID = record.walletID
        birthHeight = record.birthHeight
        lastScanHeight = record.lastScanHeight
        targetHeight = record.scanTargetHeight
        updatedAt = record.updatedAt
    }

    var isScanning: Bool {
        lastScanHeight < targetHeight
    }

    var completionFraction: Double? {
        let initialHeight = birthHeight - 1
        guard targetHeight > initialHeight else { return nil }
        let completed = max(
            0,
            min(lastScanHeight, targetHeight) - initialHeight
        )
        return Double(completed) / Double(targetHeight - initialHeight)
    }
}

struct BitcoinSilentPaymentOutput: Hashable, Sendable {
    let walletID: String
    let transactionHash: String
    let outputIndex: Int
    let valueAtomic: BitcoinFamilyAtomicInteger
    let scriptPubKey: Data
    let outputPublicKey: Data
    let blockHeight: Int?
    let blockTimestamp: Double?
    let isSpent: Bool
    let spentByTransactionHash: String?
}

struct BitcoinSilentPaymentCachedState: Sendable {
    let outputs: [BitcoinSilentPaymentOutput]
    let balanceIsAuthoritative: Bool
}

enum BitcoinSilentPaymentReconciliationMutation: Equatable, Sendable {
    case markSpent(
        transactionHash: String,
        outputIndex: Int,
        spendingTransactionHash: String
    )
    case restoreUnspent(transactionHash: String, outputIndex: Int)
    case markOrphaned(transactionHash: String, outputIndex: Int)
}

private struct BitcoinSilentPaymentOutputSecret: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let walletID: String
    let transactionHash: String
    let outputIndex: Int
    let outputPublicKey: Data
    let privateKey: Data

    func validated() throws -> Self {
        guard version == Self.currentVersion,
              !walletID.isEmpty,
              transactionHash.count == 64,
              outputIndex >= 0,
              outputPublicKey.count == 32,
              privateKey.count == 32 else {
            throw BitcoinSilentPaymentCryptoError.invalidKey
        }
        let key = try P256K.Signing.PrivateKey(
            dataRepresentation: privateKey
        )
        guard Data(key.publicKey.xonly.bytes) == outputPublicKey else {
            throw BitcoinSilentPaymentCryptoError.invalidKey
        }
        return self
    }
}

private actor BitcoinSilentPaymentAccountCoordinator {
    static let shared = BitcoinSilentPaymentAccountCoordinator()

    func ensure(
        database: WalletDatabase,
        walletID: String,
        vault: WalletSecretVault
    ) async throws -> Bool {
        try await database.ensureBitcoinSilentPaymentAccountUncoordinated(
            walletID: walletID,
            vault: vault
        )
    }
}

enum BitcoinSilentPaymentDatabaseError: Error, Equatable {
    case walletUnavailable
    case invalidAccount
    case invalidOutput
}

extension WalletDatabase {
    static let bitcoinSilentPaymentActivationHeight = 709_632

    @discardableResult
    func ensureBitcoinSilentPaymentAccount(
        walletID: String,
        vault: WalletSecretVault = .shared
    ) async throws -> Bool {
        try await BitcoinSilentPaymentAccountCoordinator.shared.ensure(
            database: self,
            walletID: walletID,
            vault: vault
        )
    }

    fileprivate func ensureBitcoinSilentPaymentAccountUncoordinated(
        walletID: String,
        vault: WalletSecretVault
    ) async throws -> Bool {
        let stored = try await pool.read { database in
            (
                wallet: try DBWalletRecord.fetchOne(database, key: walletID),
                account: try DBBitcoinSilentPaymentAccountRecord.fetchOne(
                    database,
                    key: walletID
                )
            )
        }
        guard let wallet = stored.wallet else {
            throw BitcoinSilentPaymentDatabaseError.walletUnavailable
        }
        let supportedKinds = [
            DatabaseWalletKind.created.rawValue,
            DatabaseWalletKind.importedRecoveryPhrase.rawValue,
        ]
        guard supportedKinds.contains(wallet.kind) else { return false }

        if let existing = stored.account,
           let material = try? JSONDecoder().decode(
               BitcoinSilentPaymentKeyMaterial.self,
               from: vault.data(reference: existing.keychainReference)
           ).validated(),
           try Self.account(existing, matches: material) {
            return true
        }

        let credential = try await loadRecoveryCredential(
            walletID: walletID,
            vault: vault
        )
        guard credential.electrumKind == nil else { return false }
        let material = try BitcoinSilentPaymentKeyMaterial.derive(
            walletID: walletID,
            credential: credential
        ).validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(material)
        let reference = stored.account?.keychainReference
            ?? Self.silentPaymentReference(
                namespace: "account",
                value: walletID
            )
        if stored.account == nil {
            _ = try vault.store(
                encoded,
                kind: .bitcoinSilentPaymentAccount,
                reference: reference
            )
        } else {
            try vault.replace(
                encoded,
                kind: .bitcoinSilentPaymentAccount,
                reference: reference
            )
        }

        let address = try BitcoinSilentPaymentAddress(material.address)
        let now = Date().timeIntervalSince1970
        do {
            try await pool.write { database in
                if let existing = stored.account {
                    guard existing.walletID == walletID else {
                        throw BitcoinSilentPaymentDatabaseError.invalidAccount
                    }
                    try database.execute(
                        sql: """
                        UPDATE bitcoinSilentPaymentAccounts
                        SET address = ?, scanPublicKey = ?,
                            spendPublicKey = ?, keychainReference = ?,
                            updatedAt = ?
                        WHERE walletID = ?
                        """,
                        arguments: [
                            address.encoded,
                            address.scanPublicKey,
                            address.spendPublicKey,
                            reference,
                            now,
                            walletID,
                        ]
                    )
                    guard database.changesCount == 1 else {
                        throw BitcoinSilentPaymentDatabaseError.invalidAccount
                    }
                } else {
                    try DBBitcoinSilentPaymentAccountRecord(
                        walletID: walletID,
                        address: address.encoded,
                        scanPublicKey: address.scanPublicKey,
                        spendPublicKey: address.spendPublicKey,
                        keychainReference: reference,
                        birthHeight: Self.bitcoinSilentPaymentActivationHeight,
                        lastScanHeight:
                            Self.bitcoinSilentPaymentActivationHeight - 1,
                        scanTargetHeight:
                            Self.bitcoinSilentPaymentActivationHeight - 1,
                        balanceIsAuthoritative: false,
                        createdAt: now,
                        updatedAt: now
                    ).insert(database)
                }
            }
        } catch {
            if stored.account == nil {
                try? vault.deleteIfPresent(reference: reference)
            }
            throw error
        }
        return true
    }

    func bitcoinSilentPaymentAccount(
        walletID: String
    ) async throws -> BitcoinSilentPaymentAccount? {
        let record = try await pool.read { database in
            try DBBitcoinSilentPaymentAccountRecord.fetchOne(
                database,
                key: walletID
            )
        }
        return try record.map(Self.account)
    }

    func bitcoinSilentPaymentScanProgressObservation(
        walletID: String
    ) -> AsyncValueObservation<BitcoinSilentPaymentScanProgress?> {
        ValueObservation.tracking { database in
            try DBBitcoinSilentPaymentAccountRecord.fetchOne(
                database,
                key: walletID
            ).flatMap(BitcoinSilentPaymentScanProgress.init)
        }
        .removeDuplicates()
        .values(in: pool, bufferingPolicy: .bufferingNewest(1))
    }

    func beginBitcoinSilentPaymentScan(
        walletID: String,
        targetHeight: Int
    ) async throws {
        guard targetHeight >= Self.bitcoinSilentPaymentActivationHeight else {
            throw BitcoinSilentPaymentDatabaseError.invalidAccount
        }
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            guard let account = try DBBitcoinSilentPaymentAccountRecord
                .fetchOne(database, key: walletID),
                  targetHeight >= account.birthHeight else {
                throw BitcoinSilentPaymentDatabaseError.invalidAccount
            }
            let durableTarget = max(account.lastScanHeight, targetHeight)
            try database.execute(
                sql: """
                UPDATE bitcoinSilentPaymentAccounts
                SET scanTargetHeight = ?,
                    balanceIsAuthoritative = CASE
                        WHEN lastScanHeight < ? THEN 0
                        ELSE balanceIsAuthoritative
                    END,
                    updatedAt = ?
                WHERE walletID = ?
                """,
                arguments: [
                    durableTarget,
                    durableTarget,
                    now,
                    walletID,
                ]
            )
            guard database.changesCount == 1 else {
                throw BitcoinSilentPaymentDatabaseError.invalidAccount
            }
        }
    }

    func bitcoinSilentPaymentKeyMaterial(
        walletID: String,
        vault: WalletSecretVault = .shared
    ) async throws -> BitcoinSilentPaymentKeyMaterial {
        guard let record = try await pool.read({ database in
            try DBBitcoinSilentPaymentAccountRecord.fetchOne(
                database,
                key: walletID
            )
        }) else {
            throw BitcoinSilentPaymentDatabaseError.invalidAccount
        }
        let material = try JSONDecoder().decode(
            BitcoinSilentPaymentKeyMaterial.self,
            from: vault.data(reference: record.keychainReference)
        ).validated()
        guard try Self.account(record, matches: material) else {
            throw BitcoinSilentPaymentDatabaseError.invalidAccount
        }
        return material
    }

    func bitcoinUsesSilentPayments(
        walletID: String
    ) async throws -> Bool {
        try await pool.read { database in
            try DBBitcoinHDPreferenceRecord.fetchOne(
                database,
                key: walletID
            )?.usesSilentPayments ?? false
        }
    }

    /// Restores the durable standard-address preference for a newly opened
    /// Receive screen. Earlier builds persisted Silent Payments as if it were
    /// an address-type preference; that marker is cleared without changing
    /// the last selected BIP44/49/84/86 type.
    func restoreBitcoinStandardReceiveAddressType(
        walletID: String
    ) async throws -> BitcoinHDAddressType {
        let addressType = try await bitcoinReceiveAddressType(
            walletID: walletID
        )
        if try await bitcoinUsesSilentPayments(walletID: walletID) {
            let now = Date().timeIntervalSince1970
            try await pool.write { database in
                guard var preference = try DBBitcoinHDPreferenceRecord
                    .fetchOne(database, key: walletID) else {
                    throw BitcoinSilentPaymentDatabaseError.invalidAccount
                }
                preference.usesSilentPayments = false
                preference.updatedAt = now
                try preference.update(database)
            }
        }
        return addressType
    }

    func setBitcoinUsesSilentPayments(
        _ enabled: Bool,
        walletID: String
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            guard var preference = try DBBitcoinHDPreferenceRecord.fetchOne(
                database,
                key: walletID
            ) else {
                throw BitcoinSilentPaymentDatabaseError.invalidAccount
            }
            preference.usesSilentPayments = enabled
            preference.updatedAt = now
            try preference.update(database)
        }
        if !enabled {
            try await publishFreshBitcoinReceiveAddress(walletID: walletID)
        }
    }

    func saveBitcoinSilentPaymentOutput(
        walletID: String,
        transactionHash: String,
        outputIndex: Int,
        valueAtomic: BitcoinFamilyAtomicInteger,
        ownedKey: BitcoinSilentPaymentOwnedOutputKey,
        blockHeight: Int?,
        blockTimestamp: Double?,
        vault: WalletSecretVault = .shared
    ) async throws {
        let hash = transactionHash.lowercased()
        guard hash.count == 64,
              hash.allSatisfy(\.isHexDigit),
              outputIndex == ownedKey.outputIndex,
              outputIndex >= 0,
              !valueAtomic.isNegative,
              ownedKey.scriptPubKey
                == Data([0x51, 0x20]) + ownedKey.outputPublicKey else {
            throw BitcoinSilentPaymentDatabaseError.invalidOutput
        }
        let secret = try BitcoinSilentPaymentOutputSecret(
            version: BitcoinSilentPaymentOutputSecret.currentVersion,
            walletID: walletID,
            transactionHash: hash,
            outputIndex: outputIndex,
            outputPublicKey: ownedKey.outputPublicKey,
            privateKey: ownedKey.privateKey
        ).validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(secret)
        let reference = Self.silentPaymentReference(
            namespace: "output",
            value: "\(walletID):\(hash):\(outputIndex)"
        )
        _ = try vault.store(
            encoded,
            kind: .bitcoinSilentPaymentOutput,
            reference: reference
        )
        let now = Date().timeIntervalSince1970
        do {
            try await pool.write { database in
                if let existing = try DBBitcoinSilentPaymentOutputRecord
                    .fetchOne(
                        database,
                        key: [
                            "walletID": walletID,
                            "transactionHash": hash,
                            "outputIndex": outputIndex,
                        ]
                    ) {
                    guard existing.valueAtomic == valueAtomic.decimalText,
                          existing.scriptPubKey == ownedKey.scriptPubKey,
                          existing.outputPublicKey
                            == ownedKey.outputPublicKey,
                          existing.keychainReference == reference else {
                        throw BitcoinSilentPaymentDatabaseError.invalidOutput
                    }
                    try database.execute(
                        sql: """
                        UPDATE bitcoinSilentPaymentOutputs
                        SET blockHeight = COALESCE(?, blockHeight),
                            blockTimestamp = COALESCE(?, blockTimestamp),
                            updatedAt = ?
                        WHERE walletID = ? AND transactionHash = ?
                            AND outputIndex = ?
                        """,
                        arguments: [
                            blockHeight, blockTimestamp, now,
                            walletID, hash, outputIndex,
                        ]
                    )
                } else {
                    try DBBitcoinSilentPaymentOutputRecord(
                        walletID: walletID,
                        transactionHash: hash,
                        outputIndex: outputIndex,
                        valueAtomic: valueAtomic.decimalText,
                        scriptPubKey: ownedKey.scriptPubKey,
                        outputPublicKey: ownedKey.outputPublicKey,
                        keychainReference: reference,
                        blockHeight: blockHeight,
                        blockTimestamp: blockTimestamp,
                        isSpent: false,
                        spentByTransactionHash: nil,
                        createdAt: now,
                        updatedAt: now
                    ).insert(database)
                }
            }
        } catch {
            let existed = try? await pool.read { database in
                try DBBitcoinSilentPaymentOutputRecord.fetchOne(
                    database,
                    key: [
                        "walletID": walletID,
                        "transactionHash": hash,
                        "outputIndex": outputIndex,
                    ]
                ) != nil
            }
            if existed != true {
                try? vault.deleteIfPresent(reference: reference)
            }
            throw error
        }
    }

    func bitcoinSilentPaymentOutputs(
        walletID: String,
        unspentOnly: Bool = false
    ) async throws -> [BitcoinSilentPaymentOutput] {
        let records = try await pool.read { database in
            var request = DBBitcoinSilentPaymentOutputRecord
                .filter(Column("walletID") == walletID)
            if unspentOnly {
                request = request.filter(Column("isSpent") == false)
            }
            return try request.order(
                Column("blockHeight"),
                Column("transactionHash"),
                Column("outputIndex")
            ).fetchAll(database)
        }
        return try records.map(Self.output)
    }

    func bitcoinSilentPaymentCachedState(
        walletID: String
    ) async throws -> BitcoinSilentPaymentCachedState {
        let stored = try await pool.read { database in
            let account = try DBBitcoinSilentPaymentAccountRecord.fetchOne(
                database,
                key: walletID
            )
            let outputs = try DBBitcoinSilentPaymentOutputRecord
                .filter(Column("walletID") == walletID)
                .order(
                    Column("blockHeight"),
                    Column("transactionHash"),
                    Column("outputIndex")
                )
                .fetchAll(database)
            return (account, outputs)
        }
        return try BitcoinSilentPaymentCachedState(
            outputs: stored.1.map(Self.output),
            // A missing account means Silent Payments are not applicable to
            // this wallet credential, so their zero contribution is final.
            balanceIsAuthoritative: stored.0 == nil
        )
    }

    func invalidateBitcoinSilentPaymentBalanceAuthority(
        walletID: String
    ) async throws {
        try await pool.write { database in
            try database.execute(
                sql: """
                UPDATE bitcoinSilentPaymentAccounts
                SET balanceIsAuthoritative = 0, updatedAt = ?
                WHERE walletID = ?
                """,
                arguments: [Date().timeIntervalSince1970, walletID]
            )
            guard database.changesCount == 1 else {
                throw BitcoinSilentPaymentDatabaseError.invalidAccount
            }
        }
    }

    /// Applies every spend/orphan decision and advances the scan checkpoint
    /// in one transaction. A malformed or incomplete provider read therefore
    /// cannot leave only part of the cached Silent Payment balance changed.
    func completeBitcoinSilentPaymentReconciliation(
        walletID: String,
        scanHeight: Int?,
        mutations: [BitcoinSilentPaymentReconciliationMutation],
        balanceIsAuthoritative: Bool = true
    ) async throws {
        guard scanHeight.map({ $0 >= Self.bitcoinSilentPaymentActivationHeight - 1 }) ?? true
        else {
            throw BitcoinSilentPaymentDatabaseError.invalidAccount
        }
        var outputIDs = Set<String>()
        for mutation in mutations {
            let identity: (String, Int)
            switch mutation {
            case let .markSpent(hash, index, spendingHash):
                identity = (hash, index)
                guard Self.isValidSilentPaymentTransactionHash(spendingHash)
                else {
                    throw BitcoinSilentPaymentDatabaseError.invalidOutput
                }
            case let .restoreUnspent(hash, index),
                 let .markOrphaned(hash, index):
                identity = (hash, index)
            }
            guard identity.1 >= 0,
                  Self.isValidSilentPaymentTransactionHash(identity.0),
                  outputIDs.insert("\(identity.0.lowercased()):\(identity.1)")
                    .inserted else {
                throw BitcoinSilentPaymentDatabaseError.invalidOutput
            }
        }

        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            guard try DBBitcoinSilentPaymentAccountRecord.fetchOne(
                database,
                key: walletID
            ) != nil else {
                throw BitcoinSilentPaymentDatabaseError.invalidAccount
            }
            for mutation in mutations {
                let transactionHash: String
                let outputIndex: Int
                let isSpent: Bool
                let spendingHash: String?
                switch mutation {
                case let .markSpent(hash, index, spentBy):
                    transactionHash = hash.lowercased()
                    outputIndex = index
                    isSpent = true
                    spendingHash = spentBy.lowercased()
                case let .restoreUnspent(hash, index):
                    transactionHash = hash.lowercased()
                    outputIndex = index
                    isSpent = false
                    spendingHash = nil
                case let .markOrphaned(hash, index):
                    transactionHash = hash.lowercased()
                    outputIndex = index
                    isSpent = true
                    spendingHash = nil
                }
                try database.execute(
                    sql: """
                    UPDATE bitcoinSilentPaymentOutputs
                    SET isSpent = ?, spentByTransactionHash = ?,
                        updatedAt = ?
                    WHERE walletID = ? AND transactionHash = ?
                        AND outputIndex = ?
                    """,
                    arguments: [
                        isSpent, spendingHash, now, walletID,
                        transactionHash, outputIndex,
                    ]
                )
                guard database.changesCount == 1 else {
                    throw BitcoinSilentPaymentDatabaseError.invalidOutput
                }
            }
            try database.execute(
                sql: """
                UPDATE bitcoinSilentPaymentAccounts
                SET lastScanHeight = MAX(lastScanHeight, COALESCE(?, lastScanHeight)),
                    scanTargetHeight = MAX(scanTargetHeight, COALESCE(?, scanTargetHeight)),
                    balanceIsAuthoritative = ?, updatedAt = ?
                WHERE walletID = ?
                """,
                arguments: [
                    scanHeight,
                    scanHeight,
                    balanceIsAuthoritative,
                    now,
                    walletID,
                ]
            )
            guard database.changesCount == 1 else {
                throw BitcoinSilentPaymentDatabaseError.invalidAccount
            }
        }
    }

    func bitcoinSilentPaymentOutputPrivateKey(
        walletID: String,
        transactionHash: String,
        outputIndex: Int,
        vault: WalletSecretVault = .shared
    ) async throws -> Data {
        guard let record = try await pool.read({ database in
            try DBBitcoinSilentPaymentOutputRecord.fetchOne(
                database,
                key: [
                    "walletID": walletID,
                    "transactionHash": transactionHash.lowercased(),
                    "outputIndex": outputIndex,
                ]
            )
        }) else {
            throw BitcoinSilentPaymentDatabaseError.invalidOutput
        }
        let secret = try JSONDecoder().decode(
            BitcoinSilentPaymentOutputSecret.self,
            from: vault.data(reference: record.keychainReference)
        ).validated()
        guard secret.walletID == walletID,
              secret.transactionHash == record.transactionHash,
              secret.outputIndex == outputIndex,
              secret.outputPublicKey == record.outputPublicKey else {
            throw BitcoinSilentPaymentDatabaseError.invalidOutput
        }
        return secret.privateKey
    }

    func bitcoinSilentPaymentOutputPrivateKeyForExport(
        walletID: String,
        transactionHash: String,
        outputIndex: Int,
        authorization: WalletSecretExportAuthorization,
        vault: WalletSecretVault = .shared
    ) async throws -> Data {
        guard authorization.permits(walletID: walletID) else {
            throw WalletSecretExportAuthorizationError
                .authenticationRequired
        }
        return try await bitcoinSilentPaymentOutputPrivateKey(
            walletID: walletID,
            transactionHash: transactionHash,
            outputIndex: outputIndex,
            vault: vault
        )
    }

    func markBitcoinSilentPaymentOutputSpent(
        walletID: String,
        transactionHash: String,
        outputIndex: Int,
        spentByTransactionHash: String
    ) async throws {
        let spentBy = spentByTransactionHash.lowercased()
        guard spentBy.count == 64,
              spentBy.allSatisfy(\.isHexDigit) else {
            throw BitcoinSilentPaymentDatabaseError.invalidOutput
        }
        try await pool.write { database in
            try database.execute(
                sql: """
                UPDATE bitcoinSilentPaymentOutputs
                SET isSpent = 1, spentByTransactionHash = ?, updatedAt = ?
                WHERE walletID = ? AND transactionHash = ?
                    AND outputIndex = ?
                """,
                arguments: [
                    spentBy,
                    Date().timeIntervalSince1970,
                    walletID,
                    transactionHash.lowercased(),
                    outputIndex,
                ]
            )
            guard database.changesCount == 1 else {
                throw BitcoinSilentPaymentDatabaseError.invalidOutput
            }
        }
    }

    func restoreBitcoinSilentPaymentOutputUnspent(
        walletID: String,
        transactionHash: String,
        outputIndex: Int
    ) async throws {
        try await pool.write { database in
            try database.execute(
                sql: """
                UPDATE bitcoinSilentPaymentOutputs
                SET isSpent = 0, spentByTransactionHash = NULL,
                    updatedAt = ?
                WHERE walletID = ? AND transactionHash = ?
                    AND outputIndex = ?
                """,
                arguments: [
                    Date().timeIntervalSince1970,
                    walletID,
                    transactionHash.lowercased(),
                    outputIndex,
                ]
            )
            guard database.changesCount == 1 else {
                throw BitcoinSilentPaymentDatabaseError.invalidOutput
            }
        }
    }

    func markBitcoinSilentPaymentOutputOrphaned(
        walletID: String,
        transactionHash: String,
        outputIndex: Int
    ) async throws {
        try await pool.write { database in
            try database.execute(
                sql: """
                UPDATE bitcoinSilentPaymentOutputs
                SET isSpent = 1, spentByTransactionHash = NULL,
                    updatedAt = ?
                WHERE walletID = ? AND transactionHash = ?
                    AND outputIndex = ?
                """,
                arguments: [
                    Date().timeIntervalSince1970,
                    walletID,
                    transactionHash.lowercased(),
                    outputIndex,
                ]
            )
            guard database.changesCount == 1 else {
                throw BitcoinSilentPaymentDatabaseError.invalidOutput
            }
        }
    }

    func updateBitcoinSilentPaymentScanHeight(
        walletID: String,
        height: Int
    ) async throws {
        guard height >= Self.bitcoinSilentPaymentActivationHeight - 1 else {
            throw BitcoinSilentPaymentDatabaseError.invalidAccount
        }
        try await pool.write { database in
            try database.execute(
                sql: """
                UPDATE bitcoinSilentPaymentAccounts
                SET lastScanHeight = MAX(lastScanHeight, COALESCE(?, lastScanHeight)),
                    scanTargetHeight = MAX(scanTargetHeight, COALESCE(?, scanTargetHeight)),
                    updatedAt = ?
                WHERE walletID = ?
                """,
                arguments: [
                    height,
                    height,
                    Date().timeIntervalSince1970,
                    walletID,
                ]
            )
            guard database.changesCount == 1 else {
                throw BitcoinSilentPaymentDatabaseError.invalidAccount
            }
        }
    }

    func prepareAllBitcoinSilentPaymentAccounts(
        vault: WalletSecretVault = .shared
    ) async throws {
        let walletIDs = try await pool.read { database in
            try String.fetchAll(
                database,
                sql: """
                SELECT id FROM wallets
                WHERE archivedAt IS NULL
                    AND kind IN ('created', 'importedRecoveryPhrase')
                ORDER BY sortOrder, createdAt
                """
            )
        }
        for walletID in walletIDs {
            _ = try await ensureBitcoinSilentPaymentAccount(
                walletID: walletID,
                vault: vault
            )
        }
    }

    private static func account(
        _ record: DBBitcoinSilentPaymentAccountRecord
    ) throws -> BitcoinSilentPaymentAccount {
        let address = try BitcoinSilentPaymentAddress(record.address)
        guard address.scanPublicKey == record.scanPublicKey,
              address.spendPublicKey == record.spendPublicKey,
              record.birthHeight >= bitcoinSilentPaymentActivationHeight,
              record.lastScanHeight >= record.birthHeight - 1,
              record.scanTargetHeight >= record.lastScanHeight else {
            throw BitcoinSilentPaymentDatabaseError.invalidAccount
        }
        return BitcoinSilentPaymentAccount(
            walletID: record.walletID,
            address: address,
            birthHeight: record.birthHeight,
            lastScanHeight: record.lastScanHeight,
            scanTargetHeight: record.scanTargetHeight,
            balanceIsAuthoritative: record.balanceIsAuthoritative
        )
    }

    private static func account(
        _ record: DBBitcoinSilentPaymentAccountRecord,
        matches material: BitcoinSilentPaymentKeyMaterial
    ) throws -> Bool {
        let account = try account(record)
        return material.walletID == account.walletID
            && material.address == account.address.encoded
            && material.scanPublicKey == account.address.scanPublicKey
            && material.spendPublicKey == account.address.spendPublicKey
    }

    private static func output(
        _ record: DBBitcoinSilentPaymentOutputRecord
    ) throws -> BitcoinSilentPaymentOutput {
        guard record.transactionHash.count == 64,
              record.transactionHash.allSatisfy(\.isHexDigit),
              record.outputIndex >= 0,
              record.scriptPubKey
                == Data([0x51, 0x20]) + record.outputPublicKey else {
            throw BitcoinSilentPaymentDatabaseError.invalidOutput
        }
        return BitcoinSilentPaymentOutput(
            walletID: record.walletID,
            transactionHash: record.transactionHash,
            outputIndex: record.outputIndex,
            valueAtomic: try BitcoinFamilyAtomicInteger(
                validating: record.valueAtomic
            ),
            scriptPubKey: record.scriptPubKey,
            outputPublicKey: record.outputPublicKey,
            blockHeight: record.blockHeight,
            blockTimestamp: record.blockTimestamp,
            isSpent: record.isSpent,
            spentByTransactionHash: record.spentByTransactionHash
        )
    }

    private static func silentPaymentReference(
        namespace: String,
        value: String
    ) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return "bip352-\(namespace)-" + Data(digest).hexString
    }

    private static func isValidSilentPaymentTransactionHash(
        _ value: String
    ) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            switch $0.value {
            case 48...57, 65...70, 97...102: true
            default: false
            }
        }
    }
}

import Foundation
import GRDB

struct DBBitcoinFamilyHDAccount: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "bitcoinFamilyHDAccounts"
    let walletID: String
    let networkID: String
    let addressType: String
    let extendedPublicKey: String
}

struct DBBitcoinFamilyHDAddress: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "bitcoinFamilyHDAddresses"
    let walletID: String
    let networkID: String
    let addressType: String
    let branch: Int
    let addressIndex: Int
    let derivedJSON: Data
    let address: String
    var isUsed: Bool
    var isReserved: Bool
    var confirmed: String
    var unconfirmed: String

    func state() throws -> BitcoinHDAddressState {
        let derived = try JSONDecoder().decode(BitcoinHDDerivedAddress.self, from: derivedJSON)
        guard derived.addressType.rawValue == addressType, derived.branch.rawValue == branch,
              derived.index == addressIndex, derived.address == address,
              let chain = BitcoinFamilyChain(rawValue: networkID), chain.familyHDTypes.contains(derived.addressType)
        else { throw BitcoinHDWalletDatabaseError.invalidAddressState }
        let confirmedValue = try BitcoinFamilyAtomicInteger(validating: confirmed)
        let unconfirmedValue = try BitcoinFamilyAtomicInteger(validating: unconfirmed)
        guard !confirmedValue.isNegative, !confirmedValue.adding(unconfirmedValue).isNegative else {
            throw BitcoinHDWalletDatabaseError.invalidAddressState
        }
        return BitcoinHDAddressState(derived: derived, isUsed: isUsed, isReserved: isReserved,
            confirmedBalanceAtomic: confirmedValue, unconfirmedBalanceAtomic: unconfirmedValue)
    }
}

extension WalletDatabase {
    static func registerBitcoinFamilyHDMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v81_bitcoin_family_hd") { db in
            try db.execute(sql: """
                CREATE TABLE bitcoinFamilyHDAccounts (
                    walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                    networkID TEXT NOT NULL REFERENCES networks(id) ON DELETE CASCADE,
                    addressType TEXT NOT NULL,
                    extendedPublicKey TEXT NOT NULL,
                    PRIMARY KEY(walletID, networkID, addressType)
                ) WITHOUT ROWID;
                CREATE TABLE bitcoinFamilyHDAddresses (
                    walletID TEXT NOT NULL, networkID TEXT NOT NULL, addressType TEXT NOT NULL,
                    branch INTEGER NOT NULL CHECK(branch IN (0, 1)),
                    addressIndex INTEGER NOT NULL CHECK(addressIndex >= 0 AND addressIndex < 2147483648),
                    derivedJSON BLOB NOT NULL, address TEXT NOT NULL,
                    isUsed INTEGER NOT NULL DEFAULT 0 CHECK(isUsed IN (0, 1)),
                    isReserved INTEGER NOT NULL DEFAULT 0 CHECK(isReserved IN (0, 1)),
                    confirmed TEXT NOT NULL DEFAULT '0', unconfirmed TEXT NOT NULL DEFAULT '0',
                    PRIMARY KEY(walletID, networkID, addressType, branch, addressIndex),
                    UNIQUE(walletID, networkID, address),
                    FOREIGN KEY(walletID, networkID, addressType)
                        REFERENCES bitcoinFamilyHDAccounts(walletID, networkID, addressType) ON DELETE CASCADE
                ) WITHOUT ROWID;
                """)
        }
    }

    @discardableResult
    func ensureBitcoinFamilyHDWallet(walletID: String, chain: BitcoinFamilyChain,
        vault: WalletSecretVault = .shared) async throws -> Bool {
        guard chain.supportsFamilyHD else { return false }
        let stored = try await pool.read { db in
            (try DBWalletRecord.fetchOne(db, key: walletID),
             try DBWalletAccountRecord.filter(Column("walletID") == walletID)
                .filter(Column("networkID") == chain.networkID).filter(Column("isEnabled") == true).fetchOne(db),
             try DBBitcoinFamilyHDAccount.filter(Column("walletID") == walletID)
                .filter(Column("networkID") == chain.networkID).fetchAll(db))
        }
        guard let wallet = stored.0, stored.1 != nil,
              [DatabaseWalletKind.created.rawValue, DatabaseWalletKind.importedRecoveryPhrase.rawValue].contains(wallet.kind)
        else { return false }
        let descriptors: [BitcoinFamilyHDDescriptor]
        if stored.2.isEmpty {
            let credential = try await loadRecoveryCredential(walletID: walletID, vault: vault)
            guard credential.electrumKind == nil else { return false }
            descriptors = try await Task.detached(priority: .userInitiated) {
                try BitcoinFamilyHDDerivation.descriptors(credential: credential, chain: chain)
            }.value
            try await pool.write { db in
                for descriptor in descriptors {
                    let record = DBBitcoinFamilyHDAccount(walletID: walletID, networkID: chain.networkID,
                        addressType: descriptor.type.rawValue, extendedPublicKey: descriptor.extendedPublicKey)
                    try record.insert(db, onConflict: .ignore)
                    let saved = try DBBitcoinFamilyHDAccount.fetchOne(db, key: ["walletID": walletID,
                        "networkID": chain.networkID, "addressType": descriptor.type.rawValue])
                    guard saved?.extendedPublicKey == descriptor.extendedPublicKey else {
                        throw BitcoinHDWalletDatabaseError.invalidDescriptor
                    }
                }
            }
        } else {
            descriptors = try familyHDDescriptors(stored.2, chain: chain)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for descriptor in descriptors {
                for branch in [BitcoinHDAddressBranch.external, .change] {
                    group.addTask {
                        _ = try await self.ensureBitcoinFamilyHDRange(walletID: walletID,
                            descriptor: descriptor, branch: branch, range: 0..<BitcoinFamilyHDDerivation.gapLimit)
                    }
                }
            }
            try await group.waitForAll()
        }
        return true
    }

    private func familyHDDescriptors(_ records: [DBBitcoinFamilyHDAccount], chain: BitcoinFamilyChain) throws
        -> [BitcoinFamilyHDDescriptor] {
        guard Set(records.map(\.addressType)) == Set(chain.familyHDTypes.map(\.rawValue)) else {
            throw BitcoinHDWalletDatabaseError.invalidDescriptor
        }
        return try records.map {
            guard let type = BitcoinHDAddressType(rawValue: $0.addressType), $0.networkID == chain.networkID,
                  !$0.extendedPublicKey.isEmpty else { throw BitcoinHDWalletDatabaseError.invalidDescriptor }
            return BitcoinFamilyHDDescriptor(chain: chain, type: type, extendedPublicKey: $0.extendedPublicKey)
        }
    }

    func bitcoinFamilyHDDescriptors(walletID: String, chain: BitcoinFamilyChain) async throws -> [BitcoinFamilyHDDescriptor] {
        let records = try await pool.read { db in
            try DBBitcoinFamilyHDAccount.filter(Column("walletID") == walletID)
                .filter(Column("networkID") == chain.networkID).fetchAll(db)
        }
        return try familyHDDescriptors(records, chain: chain)
    }

    func bitcoinFamilyHDAddresses(walletID: String, chain: BitcoinFamilyChain) async throws -> [BitcoinHDAddressState] {
        try await pool.read { db in
            try DBBitcoinFamilyHDAddress.filter(Column("walletID") == walletID)
                .filter(Column("networkID") == chain.networkID)
                .order(Column("addressType"), Column("branch"), Column("addressIndex"))
                .fetchAll(db).map { try $0.state() }
        }
    }

    func ensureBitcoinFamilyHDRange(walletID: String, descriptor: BitcoinFamilyHDDescriptor,
        branch: BitcoinHDAddressBranch, range: Range<Int>) async throws -> [BitcoinHDAddressState] {
        let existing = try await pool.read { db in
            try DBBitcoinFamilyHDAddress.filter(Column("walletID") == walletID)
                .filter(Column("networkID") == descriptor.chain.networkID)
                .filter(Column("addressType") == descriptor.type.rawValue).filter(Column("branch") == branch.rawValue)
                .filter(range.contains(Column("addressIndex"))).order(Column("addressIndex")).fetchAll(db)
        }
        let indices = Set(existing.map(\.addressIndex))
        let missing = try range.filter { !indices.contains($0) }.map { index in
            let derived = try BitcoinFamilyHDDerivation.address(descriptor: descriptor, branch: branch, index: index)
            return DBBitcoinFamilyHDAddress(walletID: walletID, networkID: descriptor.chain.networkID,
                addressType: descriptor.type.rawValue, branch: branch.rawValue, addressIndex: index,
                derivedJSON: try JSONEncoder().encode(derived), address: derived.address,
                isUsed: false, isReserved: false, confirmed: "0", unconfirmed: "0")
        }
        if !missing.isEmpty {
            return try await pool.write { db in
                for row in missing { try row.insert(db, onConflict: .ignore) }
                // Another request may already have reserved or refreshed a
                // child while its public key was being derived.
                return try DBBitcoinFamilyHDAddress.filter(Column("walletID") == walletID)
                    .filter(Column("networkID") == descriptor.chain.networkID)
                    .filter(Column("addressType") == descriptor.type.rawValue).filter(Column("branch") == branch.rawValue)
                    .filter(range.contains(Column("addressIndex"))).order(Column("addressIndex"))
                    .fetchAll(db).map { try $0.state() }
            }
        }
        return try existing.map { try $0.state() }
    }

    func saveBitcoinFamilyHDStates(_ states: [BitcoinHDAddressState], walletID: String,
                                  chain: BitcoinFamilyChain) async throws {
        try await pool.write { db in
            for state in states {
                guard !state.confirmedBalanceAtomic.isNegative, !state.balanceAtomic.isNegative else {
                    throw BitcoinHDWalletDatabaseError.invalidAddressState
                }
                try db.execute(sql: """
                    UPDATE bitcoinFamilyHDAddresses SET isUsed = MAX(isUsed, ?),
                        confirmed = ?, unconfirmed = ?
                    WHERE walletID = ? AND networkID = ? AND addressType = ? AND branch = ?
                        AND addressIndex = ? AND address = ?
                    """, arguments: [state.isUsed, state.confirmedBalanceAtomic.decimalText,
                        state.unconfirmedBalanceAtomic.decimalText, walletID, chain.networkID,
                        state.derived.addressType.rawValue, state.derived.branch.rawValue,
                        state.derived.index, state.derived.address])
                guard db.changesCount == 1 else { throw BitcoinHDWalletDatabaseError.invalidAddressState }
            }
        }
    }

    /// Selection and reservation are one database transaction; two sends can
    /// never allocate the same new change address.
    func freshBitcoinFamilyHDAddress(walletID: String, chain: BitcoinFamilyChain,
        branch: BitcoinHDAddressBranch = .external, reserve: Bool = false,
        addressType: BitcoinHDAddressType? = nil) async throws -> BitcoinHDDerivedAddress {
        let descriptors = try await bitcoinFamilyHDDescriptors(walletID: walletID, chain: chain)
        guard let descriptor = descriptors.first(where: { $0.type == (addressType ?? chain.familyHDDefaultType) }) else {
            throw BitcoinHDWalletDatabaseError.invalidDescriptor
        }
        while true {
            try Task.checkCancellation()
            let next = try await pool.read { db in
                (try Int.fetchOne(db, sql: """
                    SELECT MAX(addressIndex) FROM bitcoinFamilyHDAddresses
                    WHERE walletID = ? AND networkID = ? AND addressType = ? AND branch = ?
                        AND (isUsed = 1 OR isReserved = 1)
                    """, arguments: [walletID, chain.networkID, descriptor.type.rawValue, branch.rawValue]) ?? -1) + 1
            }
            _ = try await ensureBitcoinFamilyHDRange(walletID: walletID, descriptor: descriptor,
                branch: branch, range: next..<(next + BitcoinFamilyHDDerivation.gapLimit))
            let selected: BitcoinHDDerivedAddress? = try await pool.write { db in
                let last = try Int.fetchOne(db, sql: """
                    SELECT MAX(addressIndex) FROM bitcoinFamilyHDAddresses
                    WHERE walletID = ? AND networkID = ? AND addressType = ? AND branch = ?
                        AND (isUsed = 1 OR isReserved = 1)
                    """, arguments: [walletID, chain.networkID, descriptor.type.rawValue, branch.rawValue]) ?? -1
                guard last < next,
                      var row = try DBBitcoinFamilyHDAddress.fetchOne(db, key: ["walletID": walletID,
                        "networkID": chain.networkID, "addressType": descriptor.type.rawValue,
                        "branch": branch.rawValue, "addressIndex": next]), !row.isUsed, !row.isReserved else { return nil }
                if reserve { row.isReserved = true; try row.update(db) }
                return try row.state().derived
            }
            if let selected { return selected }
        }
    }

    func releaseBitcoinFamilyHDChange(walletID: String, chain: BitcoinFamilyChain, address: String) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE bitcoinFamilyHDAddresses SET isReserved = 0
                WHERE walletID = ? AND networkID = ? AND address = ? AND branch = 1 AND isUsed = 0
                """, arguments: [walletID, chain.networkID, address])
        }
    }
}

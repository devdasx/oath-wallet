import Foundation
import GRDB

extension WalletDatabase {
    static func registerBitcoinImportedWalletMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v75_bitcoin_imported_collections") { database in
            try database.execute(sql: """
                CREATE TABLE bitcoinImportedAddresses (
                    walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                    sourceIndex INTEGER NOT NULL,
                    branch INTEGER NOT NULL,
                    addressIndex INTEGER NOT NULL,
                    publicAddress BLOB NOT NULL,
                    scriptHash TEXT NOT NULL,
                    isUsed BOOLEAN NOT NULL DEFAULT 0,
                    isReserved BOOLEAN NOT NULL DEFAULT 0,
                    PRIMARY KEY(walletID, sourceIndex, branch, addressIndex)
                );
                CREATE INDEX bitcoinImportedAddresses_script ON bitcoinImportedAddresses(walletID, scriptHash);
                """)
        }
    }

    /// Matching one address is not proof that an existing wallet contains every
    /// key/policy/range from a newly selected backup. Compare the complete secret
    /// collection before treating an import as a duplicate.
    func existingBitcoinImportedWallet(matching material: BitcoinImportedWalletMaterial,
                                       vault: WalletSecretVault = .shared) async throws -> ManagedWallet? {
        let primary = try material.primaryAddress()
        let candidates = try await pool.read { database in
            try String.fetchAll(database, sql: """
                SELECT wallets.id FROM wallets JOIN walletAccounts ON walletAccounts.walletID=wallets.id
                WHERE wallets.profileID=? AND wallets.archivedAt IS NULL
                  AND walletAccounts.isEnabled=1
                  AND walletAccounts.address=? AND walletAccounts.derivationPath=?
                ORDER BY wallets.isSelected DESC, wallets.createdAt ASC
                """, arguments: [Self.defaultProfileID, primary.address, BitcoinImportedWalletMaterial.accountMarker])
        }
        for walletID in candidates {
            if try await bitcoinImportedMaterial(walletID: walletID, vault: vault) == material {
                return try await managedWallet(walletID: walletID)
            }
        }
        return nil
    }

    func bitcoinImportedMaterial(walletID: String, vault: WalletSecretVault = .shared) async throws -> BitcoinImportedWalletMaterial? {
        let stored = try await pool.read { database -> (DBWalletRecord, DBWalletAccountRecord)? in
            guard let wallet = try DBWalletRecord.fetchOne(database, key: walletID),
                  wallet.kind == DatabaseWalletKind.importedPrivateKey.rawValue,
                  let account = try DBWalletAccountRecord.filter(Column("walletID") == walletID)
                    .filter(Column("derivationPath") == BitcoinImportedWalletMaterial.accountMarker)
                    .fetchOne(database) else { return nil }
            return (wallet, account)
        }
        guard let (wallet, account) = stored else { return nil }
        guard let reference = wallet.secretKeyReference else { throw WalletManagementError.secretUnavailable }
        let material = try BitcoinImportedWalletMaterial.decode(vault.data(reference: reference))
        let primary = try material.primaryAddress()
        guard primary.address == account.address, primary.publicKey.hexString == account.publicKey else {
            throw WalletCreationPersistenceError.invalidDraft
        }
        return material
    }

    /// Derives only a bounded batch per source. Callers continue discovery until
    /// both the imported range and the unused-address gap have been examined.
    func bitcoinImportedAddresses(walletID: String, material: BitcoinImportedWalletMaterial,
                                  includesExisting: Bool = true) async throws -> [BitcoinHDDerivedAddress] {
        let stored = try await pool.read { database in
            let groups = try Row.fetchAll(database, sql: """
                SELECT sourceIndex, branch, MAX(addressIndex) AS highest,
                    MAX(CASE WHEN isUsed=1 OR isReserved=1 THEN addressIndex END) AS used
                FROM bitcoinImportedAddresses WHERE walletID=? GROUP BY sourceIndex, branch
                """, arguments: [walletID]).map { row in
                    BitcoinImportedAddressGroup(
                        sourceIndex: row["sourceIndex"], branch: row["branch"],
                        highest: row["highest"], used: row["used"]
                    )
                }
            let addresses = includesExisting ? try Data.fetchAll(database,
                sql: "SELECT publicAddress FROM bitcoinImportedAddresses WHERE walletID=? ORDER BY sourceIndex, branch, addressIndex",
                arguments: [walletID]) : []
            return (groups, addresses)
        }
        var addresses = try stored.1.map { try JSONDecoder().decode(BitcoinHDDerivedAddress.self, from: $0) }
        let grouped = Dictionary(uniqueKeysWithValues: stored.0.map { ("\($0.sourceIndex):\($0.branch)", $0) })
        var additions: [(Int, Int, BitcoinHDDerivedAddress)] = []
        for (id, source) in material.sources.enumerated() {
            for branch in 0..<source.descriptor.branchCount {
                let row = grouped["\(id):\(branch)"]
                let highest = row?.highest ?? (source.rangeStart - 1)
                let used = row?.used ?? (source.rangeStart - 1)
                let gap = source.discoveryGap ?? 20
                let target = source.descriptor.isRanged ? max(source.rangeEnd, source.nextIndex + gap, used + gap + 1) : 1
                let end = min(target, highest + 201, 0x8000_0000)
                guard highest + 1 < end else { continue }
                for index in (highest + 1)..<end {
                    try Task.checkCancellation()
                    let address = try source.descriptor.address(branch: branch, index: index, sourceID: String(id))
                    additions.append((id, branch, address))
                    addresses.append(address)
                }
            }
        }
        if !additions.isEmpty {
            let values = try additions.map { ($0.0, $0.1, $0.2.index, try JSONEncoder().encode($0.2), $0.2.scriptHash) }
            try await pool.write { database in
                for (source, branch, index, encoded, scriptHash) in values {
                    try database.execute(sql: "INSERT OR IGNORE INTO bitcoinImportedAddresses(walletID,sourceIndex,branch,addressIndex,publicAddress,scriptHash) VALUES (?,?,?,?,?,?)",
                                         arguments: [walletID, source, branch, index, encoded, scriptHash])
                }
            }
        }
        // The same script can appear in imported key pools and their parent HD
        // descriptor. Count its balance and UTXOs once, while retaining all sources.
        var scripts = Set<String>()
        return addresses.filter { scripts.insert($0.scriptHash).inserted }
    }

    func markBitcoinImportedUsage(walletID: String, states: [BitcoinHDAddressState]) async throws {
        let used = states.filter(\.isUsed).map(\.derived.scriptHash)
        try await pool.write { database in
            for scriptHash in used {
                try database.execute(sql: "UPDATE bitcoinImportedAddresses SET isUsed=1 WHERE walletID=? AND scriptHash=?",
                                     arguments: [walletID, scriptHash])
            }
        }
    }

    func bitcoinImportedAddressCount(walletID: String) async throws -> Int {
        try await pool.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM bitcoinImportedAddresses WHERE walletID=?", arguments: [walletID]) ?? 0
        }
    }

    func bitcoinImportedReceiveAddress(walletID: String, material: BitcoinImportedWalletMaterial,
                                      type: BitcoinHDAddressType, reserveChange: Bool = false) async throws -> BitcoinHDDerivedAddress {
        let candidates = material.sources.indices.filter {
            material.sources[$0].descriptor.script.addressType == type
                && (reserveChange ? material.sources[$0].internalBranch : !material.sources[$0].internalBranch)
        }
        let sourceID = candidates.first ?? material.sources.indices.first { !material.sources[$0].internalBranch } ?? material.sources.indices.first
        guard let sourceID else { throw BitcoinImportError.noPrivateKeys }
        let source = material.sources[sourceID]
        let branch = reserveChange && source.descriptor.branchCount > 1 ? 1 : 0
        let next = try await pool.write { database -> Int in
            let highest = try Int.fetchOne(database, sql: "SELECT MAX(addressIndex) FROM bitcoinImportedAddresses WHERE walletID=? AND sourceIndex=? AND branch=? AND (isUsed=1 OR isReserved=1)",
                                          arguments: [walletID, sourceID, branch]) ?? (source.rangeStart - 1)
            let index = source.descriptor.isRanged ? max(highest + 1, source.nextIndex) : 0
            guard index < 0x8000_0000 else { throw BitcoinImportError.invalidDescriptor }
            if reserveChange {
                let address = try source.descriptor.address(branch: branch, index: index, sourceID: String(sourceID))
                try database.execute(sql: "INSERT INTO bitcoinImportedAddresses(walletID,sourceIndex,branch,addressIndex,publicAddress,scriptHash,isReserved) VALUES (?,?,?,?,?,?,1) ON CONFLICT(walletID,sourceIndex,branch,addressIndex) DO UPDATE SET isReserved=1",
                    arguments: [walletID, sourceID, branch, index, try JSONEncoder().encode(address), address.scriptHash])
            }
            return index
        }
        return try source.descriptor.address(branch: branch, index: next, sourceID: String(sourceID))
    }
    func bitcoinImportedWalletOwnsAddress(walletID: String, address: String,
                                         vault: WalletSecretVault = .shared) async throws -> Bool {
        guard let material = try await bitcoinImportedMaterial(walletID: walletID, vault: vault) else { return false }
        let records = try await pool.read { database in
            try Data.fetchAll(database, sql: "SELECT publicAddress FROM bitcoinImportedAddresses WHERE walletID=?",
                              arguments: [walletID])
        }
        for record in records {
            let owned = try JSONDecoder().decode(BitcoinHDDerivedAddress.self, from: record)
            guard owned.address == address else { continue }
            let parts = owned.derivationPath.split(separator: ":")
            guard parts.count == 4, parts[0] == "bitcoin-import", let id = Int(parts[1]),
                  material.sources.indices.contains(id), let branch = Int(parts[2]), let index = Int(parts[3]) else { return false }
            return try material.sources[id].descriptor.address(branch: branch, index: index, sourceID: String(id)) == owned
        }
        // A receive address can be offered before its next discovery batch.
        for type in BitcoinHDAddressType.standardTypes {
            if try await bitcoinImportedReceiveAddress(walletID: walletID, material: material, type: type).address == address { return true }
        }
        return false
    }

}

/// Decode on the database queue so GRDB rows never cross the async read boundary.
private struct BitcoinImportedAddressGroup: Sendable {
    let sourceIndex: Int
    let branch: Int
    let highest: Int
    let used: Int?
}

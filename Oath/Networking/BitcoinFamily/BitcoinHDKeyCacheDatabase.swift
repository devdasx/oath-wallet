import Foundation
import GRDB

struct BitcoinHDKeyCacheTarget: Hashable, Sendable {
    let addressType: BitcoinHDAddressType
    let branch: BitcoinHDAddressBranch
    let finalIndex: Int
}

actor BitcoinHDKeyCacheCoordinator {
    static let shared = BitcoinHDKeyCacheCoordinator()

    func ensure(
        database: WalletDatabase,
        walletID: String,
        targets: [BitcoinHDKeyCacheTarget],
        credential: WalletRecoveryCredential?,
        vault: WalletSecretVault
    ) async throws {
        try await database.ensureBitcoinHDKeyCachesUncoordinated(
            walletID: walletID,
            targets: targets,
            credential: credential,
            vault: vault
        )
    }
}

extension WalletDatabase {
    func ensureBitcoinHDKeyCachesUncoordinated(
        walletID: String,
        targets: [BitcoinHDKeyCacheTarget],
        credential suppliedCredential: WalletRecoveryCredential?,
        vault: WalletSecretVault
    ) async throws {
        let stored = try await pool.read { database in
            (
                wallet: try DBWalletRecord.fetchOne(database, key: walletID),
                caches: try DBBitcoinHDKeyCacheRecord
                    .filter(Column("walletID") == walletID)
                    .fetchAll(database)
            )
        }
        guard let walletRecord = stored.wallet else {
            throw BitcoinHDWalletDatabaseError.walletUnavailable
        }
        guard walletRecord.secretKeyReference != nil else {
            return
        }

        var uniqueTargets: [String: BitcoinHDKeyCacheTarget] = [:]
        for target in targets where target.finalIndex >= 0 {
            guard target.finalIndex <= Int(UInt32.max) else {
                throw BitcoinHDWalletDatabaseError.invalidAddressState
            }
            let key = "\(target.addressType.rawValue):\(target.branch.rawValue)"
            if let current = uniqueTargets[key],
               current.finalIndex >= target.finalIndex {
                continue
            }
            uniqueTargets[key] = target
        }
        guard !uniqueTargets.isEmpty else { return }

        var credential = suppliedCredential
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let derivation = BitcoinHDDerivationService()

        for target in uniqueTargets.values.sorted(by: {
            if $0.addressType.rawValue != $1.addressType.rawValue {
                return $0.addressType.rawValue < $1.addressType.rawValue
            }
            return $0.branch.rawValue < $1.branch.rawValue
        }) {
            let current = stored.caches.first {
                $0.addressType == target.addressType.rawValue
                    && $0.branch == target.branch.rawValue
            }
            if let current,
               current.highestCachedIndex >= target.finalIndex,
               let cache = try? decoder.decode(
                   BitcoinHDChildKeyCache.self,
                   from: vault.data(reference: current.keychainReference)
               ).validated(),
               cache.walletID == walletID,
               cache.addressType == target.addressType,
               cache.branch == target.branch,
               cache.highestCachedIndex == current.highestCachedIndex {
                continue
            }

            if credential == nil {
                credential = try await loadRecoveryCredential(
                    walletID: walletID,
                    vault: vault
                )
            }
            guard let credential else {
                throw BitcoinHDDerivationError.invalidWallet
            }
            let finalIndex = max(
                target.finalIndex,
                current?.highestCachedIndex ?? -1
            )
            let publicStates = try await bitcoinHDAddresses(
                walletID: walletID,
                addressType: target.addressType,
                branch: target.branch
            )
            let publicByIndex = Dictionary(
                uniqueKeysWithValues: publicStates.map {
                    ($0.derived.index, $0.derived)
                }
            )
            let entries = try (0...finalIndex).map { index in
                let entry = try derivation.childKeyCacheEntry(
                    credential: credential,
                    addressType: target.addressType,
                    branch: target.branch,
                    index: index
                )
                guard publicByIndex[index]?.address == entry.address else {
                    throw BitcoinHDWalletDatabaseError.invalidDescriptor
                }
                return entry
            }
            let cache = BitcoinHDChildKeyCache(
                version: BitcoinHDChildKeyCache.currentVersion,
                walletID: walletID,
                addressType: target.addressType,
                branch: target.branch,
                entries: entries
            )
            let encoded = try encoder.encode(cache.validated())
            let now = Date().timeIntervalSince1970

            if let current {
                try vault.replace(
                    encoded,
                    kind: .bitcoinHDChildKeyCache,
                    reference: current.keychainReference
                )
                try await pool.write { database in
                    try database.execute(
                        sql: """
                        UPDATE bitcoinHDKeyCaches
                        SET highestCachedIndex = ?, updatedAt = ?
                        WHERE walletID = ? AND addressType = ?
                            AND branch = ? AND keychainReference = ?
                        """,
                        arguments: [
                            finalIndex, now, walletID,
                            target.addressType.rawValue,
                            target.branch.rawValue,
                            current.keychainReference
                        ]
                    )
                    guard database.changesCount == 1 else {
                        throw BitcoinHDWalletDatabaseError
                            .invalidAddressState
                    }
                }
            } else {
                let reference = try vault.store(
                    encoded,
                    kind: .bitcoinHDChildKeyCache
                )
                do {
                    try await pool.write { database in
                        try DBBitcoinHDKeyCacheRecord(
                            walletID: walletID,
                            addressType: target.addressType.rawValue,
                            branch: target.branch.rawValue,
                            keychainReference: reference,
                            highestCachedIndex: finalIndex,
                            createdAt: now,
                            updatedAt: now
                        ).insert(database)
                    }
                } catch {
                    try? vault.deleteIfPresent(reference: reference)
                    throw error
                }
            }
        }
    }
}

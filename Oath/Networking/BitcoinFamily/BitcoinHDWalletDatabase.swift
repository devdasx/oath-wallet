import Foundation
import GRDB
import WalletCore
enum BitcoinHDWalletDatabaseError: Error, Equatable {
    case walletUnavailable
    case unsupportedWallet
    case invalidDescriptor
    case invalidAddressState
}
extension WalletDatabase {
    @discardableResult
    func ensureBitcoinHDWallet(
        walletID: String,
        vault: WalletSecretVault = .shared
    ) async throws -> Bool {
        let stored = try await pool.read { database in
            (
                wallet: try DBWalletRecord.fetchOne(database, key: walletID),
                accounts: try DBBitcoinHDAccountRecord
                    .filter(Column("walletID") == walletID)
                    .fetchAll(database)
            )
        }
        guard let wallet = stored.wallet else {
            throw BitcoinHDWalletDatabaseError.walletUnavailable
        }
        let supportedKinds = [
            DatabaseWalletKind.created.rawValue,
            DatabaseWalletKind.importedRecoveryPhrase.rawValue
        ]
        guard supportedKinds.contains(wallet.kind) else {
            return false
        }

        let derivation = BitcoinHDDerivationService()
        let descriptors: [BitcoinHDAccountDescriptor]
        let loadedCredential: WalletRecoveryCredential?
        // Existing BIP39 wallets gain new derivation families on first use.
        // Electrum seeds retain only their own descriptor and seed algorithm.
        let hasElectrumAccount = stored.accounts.contains {
            ($0.addressType == "bip44" && $0.accountPath == "m")
                || ($0.addressType == "bip84" && $0.accountPath == "m/0'")
        }
        let hasAllTypes = Set(stored.accounts.map(\.addressType))
            == Set(BitcoinHDAddressType.allCases.map(\.rawValue))
        if !stored.accounts.isEmpty && (hasElectrumAccount || hasAllTypes) {
            loadedCredential = nil
            descriptors = try stored.accounts.map {
                guard let addressType = BitcoinHDAddressType(
                    rawValue: $0.addressType
                ), $0.accountIndex == 0,
                   BitcoinHDAccountDescriptor.isValidAccountPath(
                       $0.accountPath,
                       for: addressType
                   ) else {
                    throw BitcoinHDWalletDatabaseError.invalidDescriptor
                }
                return BitcoinHDAccountDescriptor(
                    addressType: addressType,
                    accountIndex: $0.accountIndex,
                    accountPath: $0.accountPath,
                    extendedPublicKey: $0.extendedPublicKey
                )
            }
        } else {
            let credential = try await loadRecoveryCredential(
                walletID: walletID,
                vault: vault
            )
            loadedCredential = credential
            descriptors = try derivation.accountDescriptors(
                credential: credential
            )
        }
        guard let initialReceiveAddressType = descriptors.contains(
            where: { $0.addressType == .bip84 }
        ) ? BitcoinHDAddressType.bip84 : descriptors.first?.addressType else {
            throw BitcoinHDWalletDatabaseError.invalidDescriptor
        }

        // Public derivation is deterministic and safe to perform before the
        // transaction. The resulting rows contain no private wallet material.
        var initialAddresses: [BitcoinHDDerivedAddress] = []
        initialAddresses.reserveCapacity(
            descriptors.count * 2 * BitcoinHDDerivationService.gapLimit
        )
        for descriptor in descriptors {
            for branch in [
                BitcoinHDAddressBranch.external,
                BitcoinHDAddressBranch.change
            ] {
                for index in 0..<BitcoinHDDerivationService.gapLimit {
                    initialAddresses.append(
                        try derivation.deriveAddress(
                            descriptor: descriptor,
                            branch: branch,
                            index: index
                        )
                    )
                }
            }
        }
        let addressesToPersist = initialAddresses

        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            let existingByType = Dictionary(
                stored.accounts.compactMap { record in
                    BitcoinHDAddressType(rawValue: record.addressType).map {
                        ($0, record)
                    }
                },
                uniquingKeysWith: { first, _ in first }
            )
            for descriptor in descriptors {
                if let existing = existingByType[descriptor.addressType] {
                    guard existing.extendedPublicKey
                            == descriptor.extendedPublicKey,
                          existing.accountPath == descriptor.accountPath else {
                        throw BitcoinHDWalletDatabaseError.invalidDescriptor
                    }
                    continue
                }
                try DBBitcoinHDAccountRecord(
                    walletID: walletID,
                    addressType: descriptor.addressType.rawValue,
                    accountIndex: descriptor.accountIndex,
                    accountPath: descriptor.accountPath,
                    extendedPublicKey: descriptor.extendedPublicKey,
                    createdAt: now,
                    updatedAt: now
                ).insert(database, onConflict: .ignore)
            }

            let committedAccounts = try DBBitcoinHDAccountRecord
                .filter(Column("walletID") == walletID)
                .fetchAll(database)
            let committedByType = Dictionary(
                committedAccounts.compactMap {
                    record in
                    BitcoinHDAddressType(
                        rawValue: record.addressType
                    ).map { ($0, record) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            guard committedAccounts.count == descriptors.count,
                  descriptors.allSatisfy({ descriptor in
                      guard let record = committedByType[
                          descriptor.addressType
                      ] else { return false }
                      return record.accountIndex
                              == descriptor.accountIndex
                          && record.accountPath
                              == descriptor.accountPath
                          && record.extendedPublicKey
                              == descriptor.extendedPublicKey
                  }) else {
                throw BitcoinHDWalletDatabaseError.invalidDescriptor
            }

            for derived in addressesToPersist {
                try Self.addressRecord(
                    derived,
                    walletID: walletID,
                    now: now
                ).insert(database, onConflict: .ignore)
            }
            if try DBBitcoinHDPreferenceRecord.fetchOne(
                database,
                key: walletID
            ) == nil {
                try DBBitcoinHDPreferenceRecord(
                    walletID: walletID,
                    receiveAddressType: initialReceiveAddressType.rawValue,
                    usesSilentPayments: false,
                    updatedAt: now
                ).insert(database, onConflict: .ignore)
            }
        }
        let initialFinalIndex = BitcoinHDDerivationService.gapLimit - 1
        try await BitcoinHDKeyCacheCoordinator.shared.ensure(
            database: self,
            walletID: walletID,
            targets: descriptors.flatMap { descriptor in
                [BitcoinHDAddressBranch.external, .change].map { branch in
                    BitcoinHDKeyCacheTarget(
                        addressType: descriptor.addressType,
                        branch: branch,
                        finalIndex: initialFinalIndex
                    )
                }
            },
            credential: loadedCredential,
            vault: vault
        )
        try await publishFreshBitcoinReceiveAddress(
            walletID: walletID,
            vault: vault
        )
        return true
    }

    func bitcoinHDAccountDescriptors(
        walletID: String
    ) async throws -> [BitcoinHDAccountDescriptor] {
        let records = try await pool.read { database in
            try DBBitcoinHDAccountRecord
                .filter(Column("walletID") == walletID)
                .order(Column("addressType"))
                .fetchAll(database)
        }
        return try records.map { record in
            guard let type = BitcoinHDAddressType(
                rawValue: record.addressType
            ), record.accountIndex == 0,
               BitcoinHDAccountDescriptor.isValidAccountPath(
                   record.accountPath,
                   for: type
               ) else {
                throw BitcoinHDWalletDatabaseError.invalidDescriptor
            }
            return BitcoinHDAccountDescriptor(
                addressType: type,
                accountIndex: record.accountIndex,
                accountPath: record.accountPath,
                extendedPublicKey: record.extendedPublicKey
            )
        }
    }

    func bitcoinHDAddresses(
        walletID: String,
        addressType: BitcoinHDAddressType? = nil,
        branch: BitcoinHDAddressBranch? = nil
    ) async throws -> [BitcoinHDAddressState] {
        let records = try await pool.read { database in
            var request = DBBitcoinHDAddressRecord
                .filter(Column("walletID") == walletID)
            if let addressType {
                request = request.filter(
                    Column("addressType") == addressType.rawValue
                )
            }
            if let branch {
                request = request.filter(
                    Column("branch") == branch.rawValue
                )
            }
            return try request
                .order(
                    Column("addressType"),
                    Column("branch"),
                    Column("addressIndex")
                )
                .fetchAll(database)
        }
        return try records.map(Self.addressState)
    }

    func bitcoinHDWalletOwnsAddress(
        walletID: String,
        address: String
    ) async throws -> Bool {
        try await pool.read { database in
            try DBBitcoinHDAddressRecord
                .filter(Column("walletID") == walletID)
                .filter(Column("address") == address)
                .fetchCount(database) == 1
        }
    }

    func ensureBitcoinHDAddressRange(
        walletID: String,
        descriptor: BitcoinHDAccountDescriptor,
        branch: BitcoinHDAddressBranch,
        through finalIndex: Int,
        vault: WalletSecretVault = .shared
    ) async throws -> [BitcoinHDAddressState] {
        guard finalIndex >= 0 else { return [] }
        let existing = try await bitcoinHDAddresses(
            walletID: walletID,
            addressType: descriptor.addressType,
            branch: branch
        )
        let existingByIndex = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.derived.index, $0) }
        )
        let missing = (0...finalIndex).filter {
            existingByIndex[$0] == nil
        }
        if !missing.isEmpty {
            let derivation = BitcoinHDDerivationService()
            let derived = try missing.map {
                try derivation.deriveAddress(
                    descriptor: descriptor,
                    branch: branch,
                    index: $0
                )
            }
            let now = Date().timeIntervalSince1970
            try await pool.write { database in
                for address in derived {
                    try Self.addressRecord(
                        address,
                        walletID: walletID,
                        now: now
                    ).insert(database, onConflict: .ignore)
                }
            }
        }
        let addresses = try await bitcoinHDAddresses(
            walletID: walletID,
            addressType: descriptor.addressType,
            branch: branch
        )
        try await BitcoinHDKeyCacheCoordinator.shared.ensure(
            database: self,
            walletID: walletID,
            targets: [
                BitcoinHDKeyCacheTarget(
                    addressType: descriptor.addressType,
                    branch: branch,
                    finalIndex: finalIndex
                )
            ],
            credential: nil,
            vault: vault
        )
        return addresses.filter { $0.derived.index <= finalIndex }
    }

    func saveBitcoinHDAddressStates(
        _ states: [BitcoinHDAddressState],
        walletID: String, vault: WalletSecretVault = .shared
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            for state in states {
                guard !state.confirmedBalanceAtomic.isNegative,
                      state.derived.index >= 0 else {
                    throw BitcoinHDWalletDatabaseError.invalidAddressState
                }
                try database.execute(
                    sql: """
                    UPDATE bitcoinHDAddresses
                    SET isUsed = ?, isReserved = ?,
                        confirmedBalanceAtomic = ?,
                        unconfirmedBalanceAtomic = ?, lastCheckedAt = ?,
                        updatedAt = ?
                    WHERE walletID = ? AND addressType = ?
                        AND accountIndex = 0 AND branch = ?
                        AND addressIndex = ? AND address = ?
                        AND scriptHash = ?
                    """,
                    arguments: [
                        state.isUsed,
                        state.isUsed ? false : state.isReserved,
                        state.confirmedBalanceAtomic.decimalText,
                        state.unconfirmedBalanceAtomic.decimalText,
                        now,
                        now,
                        walletID,
                        state.derived.addressType.rawValue,
                        state.derived.branch.rawValue,
                        state.derived.index,
                        state.derived.address,
                        state.derived.scriptHash
                    ]
                )
                guard database.changesCount == 1 else {
                    throw BitcoinHDWalletDatabaseError.invalidAddressState
                }
            }
        }
        try await finishBitcoinHDAddressStatePersistence(
            states,
            walletID: walletID,
            vault: vault
        )
    }

    /// Persists the monotonic address-usage facts learned by a full history
    /// discovery without touching balances. Balance-only discovery is the
    /// single writer for `confirmedBalanceAtomic` and
    /// `unconfirmedBalanceAtomic`; keeping that ownership separate prevents
    /// an older, slower history request from rolling a newer balance back.
    func saveBitcoinHDAddressDiscoveryStates(
        _ states: [BitcoinHDAddressState],
        walletID: String,
        vault: WalletSecretVault = .shared
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            for state in states {
                guard !state.confirmedBalanceAtomic.isNegative,
                      !state.balanceAtomic.isNegative,
                      state.derived.index >= 0 else {
                    throw BitcoinHDWalletDatabaseError.invalidAddressState
                }
                try database.execute(
                    sql: """
                    UPDATE bitcoinHDAddresses
                    SET isUsed = CASE WHEN ? THEN 1 ELSE isUsed END,
                        isReserved = CASE WHEN ? THEN 0 ELSE isReserved END,
                        updatedAt = ?
                    WHERE walletID = ? AND addressType = ?
                        AND accountIndex = 0 AND branch = ?
                        AND addressIndex = ? AND address = ?
                        AND scriptHash = ?
                    """,
                    arguments: [
                        state.isUsed,
                        state.isUsed,
                        now,
                        walletID,
                        state.derived.addressType.rawValue,
                        state.derived.branch.rawValue,
                        state.derived.index,
                        state.derived.address,
                        state.derived.scriptHash
                    ]
                )
                guard database.changesCount == 1 else {
                    throw BitcoinHDWalletDatabaseError.invalidAddressState
                }
            }
        }
        try await finishBitcoinHDAddressStatePersistence(
            states,
            walletID: walletID,
            vault: vault
        )
    }

    private func finishBitcoinHDAddressStatePersistence(
        _ states: [BitcoinHDAddressState],
        walletID: String,
        vault: WalletSecretVault
    ) async throws {
        try await removeUnavailableBitcoinHDAddressSelections(
            walletID: walletID
        )
        let affected = Set(states.map {
            BitcoinHDKeyCacheTarget(
                addressType: $0.derived.addressType,
                branch: $0.derived.branch,
                finalIndex: 0
            )
        })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for target in affected {
                group.addTask {
                    try await self.ensureBitcoinHDGap(
                        walletID: walletID,
                        addressType: target.addressType,
                        branch: target.branch, vault: vault
                    )
                }
            }
            try await group.waitForAll()
        }
    }

    func bitcoinReceiveAddressType(
        walletID: String
    ) async throws -> BitcoinHDAddressType {
        let raw = try await pool.read { database in
            try DBBitcoinHDPreferenceRecord.fetchOne(
                database,
                key: walletID
            )?.receiveAddressType
        }
        return raw.flatMap(BitcoinHDAddressType.init(rawValue:)) ?? .bip84
    }

    func setBitcoinReceiveAddressType(
        _ addressType: BitcoinHDAddressType,
        walletID: String
    ) async throws {
        guard try await bitcoinHDAccountDescriptors(walletID: walletID)
            .contains(where: { $0.addressType == addressType }) else {
            throw BitcoinHDWalletDatabaseError.invalidDescriptor
        }
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            try DBBitcoinHDPreferenceRecord(
                walletID: walletID,
                receiveAddressType: addressType.rawValue,
                usesSilentPayments: false,
                updatedAt: now
            ).save(database)
        }
        try await publishFreshBitcoinReceiveAddress(walletID: walletID)
    }

    func freshBitcoinReceiveAddress(
        walletID: String,
        addressType: BitcoinHDAddressType,
        vault: WalletSecretVault = .shared
    ) async throws -> BitcoinHDDerivedAddress? {
        guard let descriptor = try await bitcoinHDAccountDescriptors(
            walletID: walletID
        ).first(where: { $0.addressType == addressType }) else {
            return nil
        }
        let states = try await bitcoinHDAddresses(
            walletID: walletID,
            addressType: addressType,
            branch: .external
        )
        if let preferred = try await bitcoinHDPreferredAddress(
            walletID: walletID,
            addressType: addressType,
            branch: .external
        ) {
            return preferred
        }
        let lastUnavailable = states.lazy
            .filter { $0.isUsed || $0.isReserved }
            .map(\.derived.index)
            .max() ?? -1
        let freshIndex = lastUnavailable + 1
        let requiredFinalIndex = lastUnavailable
            + BitcoinHDDerivationService.gapLimit
        if let prepared = states.first(where: {
            $0.derived.index == freshIndex
                && !$0.isUsed && !$0.isReserved
        }), states.contains(where: {
            $0.derived.index == requiredFinalIndex
        }) {
            return prepared.derived
        }
        let addresses = try await ensureBitcoinHDAddressRange(
            walletID: walletID,
            descriptor: descriptor,
            branch: .external,
            through: requiredFinalIndex,
            vault: vault
        )
        return addresses.first(where: {
            $0.derived.index == freshIndex
                && !$0.isUsed && !$0.isReserved
        })?.derived
    }

    func reserveFreshBitcoinChangeAddress(
        walletID: String,
        addressType: BitcoinHDAddressType
    ) async throws -> BitcoinHDDerivedAddress? {
        guard let descriptor = try await bitcoinHDAccountDescriptors(
            walletID: walletID
        ).first(where: { $0.addressType == addressType }) else {
            return nil
        }
        // The conditional update is the reservation boundary. If two sends
        // are prepared concurrently, only one can claim a given child.
        while true {
            let states = try await bitcoinHDAddresses(
                walletID: walletID,
                addressType: addressType,
                branch: .change
            )
            let preferred = try await bitcoinHDPreferredAddress(
                walletID: walletID,
                addressType: addressType,
                branch: .change
            )
            let lastUnavailable = states.lazy
                .filter { $0.isUsed || $0.isReserved }
                .map(\.derived.index)
                .max() ?? -1
            let freshIndex = preferred?.index ?? (lastUnavailable + 1)
            let addresses = try await ensureBitcoinHDAddressRange(
                walletID: walletID,
                descriptor: descriptor,
                branch: .change,
                through: max(
                    lastUnavailable + BitcoinHDDerivationService.gapLimit,
                    freshIndex + BitcoinHDDerivationService.gapLimit
                )
            )
            guard let fresh = addresses.first(where: {
                $0.derived.index == freshIndex
                    && !$0.isUsed
                    && !$0.isReserved
            })?.derived else {
                continue
            }
            let now = Date().timeIntervalSince1970
            let claimed = try await pool.write { database in
                try database.execute(
                    sql: """
                    UPDATE bitcoinHDAddresses
                    SET isReserved = 1, updatedAt = ?
                    WHERE walletID = ? AND addressType = ?
                        AND accountIndex = 0 AND branch = 1
                        AND addressIndex = ? AND address = ?
                        AND isUsed = 0 AND isReserved = 0
                    """,
                    arguments: [
                        now,
                        walletID,
                        addressType.rawValue,
                        freshIndex,
                        fresh.address
                    ]
                )
                return database.changesCount == 1
            }
            if claimed {
                do {
                    try await clearBitcoinHDPreferredAddress(
                        walletID: walletID,
                        addressType: addressType,
                        branch: .change
                    )
                    _ = try await ensureBitcoinHDAddressRange(
                        walletID: walletID,
                        descriptor: descriptor,
                        branch: .change,
                        through: freshIndex
                            + BitcoinHDDerivationService.gapLimit
                    )
                    return fresh
                } catch {
                    try? await releaseBitcoinHDChangeAddressReservation(
                        walletID: walletID,
                        address: fresh.address
                    )
                    throw error
                }
            }
        }
    }

    func cachedBitcoinHDWIF(
        walletID: String,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        index: Int,
        vault: WalletSecretVault = .shared
    ) async throws -> String? {
        guard index >= 0 else { return nil }
        let record = try await pool.read { database in
            try DBBitcoinHDKeyCacheRecord
                .filter(Column("walletID") == walletID)
                .filter(Column("addressType") == addressType.rawValue)
                .filter(Column("branch") == branch.rawValue)
                .fetchOne(database)
        }
        guard let record, record.highestCachedIndex >= index else {
            return nil
        }
        let cache = try JSONDecoder().decode(
            BitcoinHDChildKeyCache.self,
            from: vault.data(reference: record.keychainReference)
        ).validated()
        guard cache.walletID == walletID,
              cache.addressType == addressType,
              cache.branch == branch,
              cache.highestCachedIndex == record.highestCachedIndex,
              let entry = cache.entries.first(where: { $0.index == index })
        else {
            throw BitcoinHDWalletDatabaseError.invalidAddressState
        }
        let storedAddress = try await bitcoinHDAddresses(
            walletID: walletID,
            addressType: addressType,
            branch: branch
        ).first(where: { $0.derived.index == index })?.derived.address
        guard entry.address == storedAddress else {
            throw BitcoinHDWalletDatabaseError.invalidAddressState
        }
        return entry.wif
    }

    func bitcoinHDWIFForExport(
        walletID: String,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        index: Int,
        authorization: WalletSecretExportAuthorization,
        vault: WalletSecretVault = .shared
    ) async throws -> String? {
        guard authorization.permits(walletID: walletID) else {
            throw WalletSecretExportAuthorizationError
                .authenticationRequired
        }
        return try await cachedBitcoinHDWIF(
            walletID: walletID,
            addressType: addressType,
            branch: branch,
            index: index,
            vault: vault
        )
    }

    func prepareAllBitcoinHDWallets(
        vault: WalletSecretVault = .shared
    ) async throws {
        let walletIDs = try await pool.read { database in
            try String.fetchAll(
                database,
                sql: """
                SELECT id FROM wallets
                WHERE kind IN ('created', 'importedRecoveryPhrase')
                    AND archivedAt IS NULL
                ORDER BY sortOrder, createdAt
                """
            )
        }
        for walletID in walletIDs {
            _ = try await ensureBitcoinHDWallet(
                walletID: walletID,
                vault: vault
            )
        }
    }

    private func ensureBitcoinHDGap(
        walletID: String,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch, vault: WalletSecretVault = .shared
    ) async throws {
        guard let descriptor = try await bitcoinHDAccountDescriptors(
            walletID: walletID
        ).first(where: { $0.addressType == addressType }) else {
            throw BitcoinHDWalletDatabaseError.invalidDescriptor
        }
        let states = try await bitcoinHDAddresses(
            walletID: walletID,
            addressType: addressType,
            branch: branch
        )
        let lastUnavailable = states.lazy
            .filter { $0.isUsed || $0.isReserved }
            .map(\.derived.index)
            .max() ?? -1
        _ = try await ensureBitcoinHDAddressRange(
            walletID: walletID,
            descriptor: descriptor,
            branch: branch,
            through: lastUnavailable + BitcoinHDDerivationService.gapLimit,
            vault: vault
        )
    }

    func releaseBitcoinHDChangeAddressReservation(
        walletID: String,
        address: String
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            try database.execute(
                sql: """
                UPDATE bitcoinHDAddresses
                SET isReserved = 0, updatedAt = ?
                WHERE walletID = ? AND branch = 1 AND address = ?
                    AND isUsed = 0 AND isReserved = 1
                """,
                arguments: [now, walletID, address]
            )
        }
    }

    func publishFreshBitcoinReceiveAddress(
        walletID: String,
        vault: WalletSecretVault = .shared
    ) async throws {
        let type = try await bitcoinReceiveAddressType(walletID: walletID)
        guard let fresh = try await freshBitcoinReceiveAddress(
            walletID: walletID,
            addressType: type,
            vault: vault
        ) else { return }
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            try database.execute(
                sql: """
                UPDATE walletAccounts
                SET address = ?, normalizedAddress = ?,
                    derivationPath = ?, publicKey = ?, updatedAt = ?
                WHERE id = ? AND walletID = ? AND networkID = 'bitcoin'
                """,
                arguments: [
                    fresh.address,
                    fresh.address.lowercased(),
                    fresh.derivationPath,
                    fresh.publicKey.hexString,
                    now,
                    "\(walletID):bitcoin:0",
                    walletID
                ]
            )
        }
    }

    func bitcoinReceiveAddressObservation(
        walletID: String
    ) -> AsyncValueObservation<BitcoinHDDerivedAddress?> {
        ValueObservation.tracking { database in
            let rawType = try DBBitcoinHDPreferenceRecord.fetchOne(
                database,
                key: walletID
            )?.receiveAddressType
            guard let type = rawType.flatMap(
                BitcoinHDAddressType.init(rawValue:)
            ) else { return nil }
            let records = try DBBitcoinHDAddressRecord
                .filter(Column("walletID") == walletID)
                .filter(Column("addressType") == type.rawValue)
                .filter(
                    Column("branch")
                        == BitcoinHDAddressBranch.external.rawValue
                )
                .order(Column("addressIndex"))
                .fetchAll(database)
            if let selection = try DBBitcoinHDAddressSelectionRecord
                .filter(Column("walletID") == walletID)
                .filter(Column("addressType") == type.rawValue)
                .filter(Column("accountIndex") == 0)
                .filter(
                    Column("branch")
                        == BitcoinHDAddressBranch.external.rawValue
                )
                .fetchOne(database),
               let record = records.first(where: {
                   $0.addressIndex == selection.addressIndex
                       && !$0.isUsed && !$0.isReserved
               }) {
                return try Self.addressState(record).derived
            }
            let nextIndex = (records.last(where: {
                $0.isUsed || $0.isReserved
            })?.addressIndex
                ?? -1) + 1
            guard let record = records.first(where: {
                $0.addressIndex == nextIndex
                    && !$0.isUsed && !$0.isReserved
            }) else { return nil }
            return try Self.addressState(record).derived
        }
        .removeDuplicates()
        .values(in: pool, bufferingPolicy: .bufferingNewest(1))
    }

    private static func addressRecord(
        _ derived: BitcoinHDDerivedAddress,
        walletID: String,
        now: Double
    ) -> DBBitcoinHDAddressRecord {
        DBBitcoinHDAddressRecord(
            walletID: walletID,
            addressType: derived.addressType.rawValue,
            accountIndex: 0,
            branch: derived.branch.rawValue,
            addressIndex: derived.index,
            derivationPath: derived.derivationPath,
            address: derived.address,
            publicKey: derived.publicKey,
            scriptPubKey: derived.scriptPubKey,
            scriptHash: derived.scriptHash,
            isUsed: false,
            isReserved: false,
            confirmedBalanceAtomic: "0",
            unconfirmedBalanceAtomic: "0",
            lastCheckedAt: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func addressState(
        _ record: DBBitcoinHDAddressRecord
    ) throws -> BitcoinHDAddressState {
        guard let addressType = BitcoinHDAddressType(
                rawValue: record.addressType
              ),
              let branch = BitcoinHDAddressBranch(rawValue: record.branch),
              record.accountIndex == 0,
              BitcoinHDChildKeyCache.validDerivationPath(
                  record.derivationPath,
                  addressType: addressType,
                  branch: branch,
                  index: record.addressIndex
              ),
              CoinType.bitcoin.validate(address: record.address) else {
            throw BitcoinHDWalletDatabaseError.invalidAddressState
        }
        return BitcoinHDAddressState(
            derived: BitcoinHDDerivedAddress(
                addressType: addressType,
                branch: branch,
                index: record.addressIndex,
                derivationPath: record.derivationPath,
                address: record.address,
                publicKey: record.publicKey,
                scriptPubKey: record.scriptPubKey,
                scriptHash: record.scriptHash
            ),
            isUsed: record.isUsed,
            isReserved: record.isReserved,
            confirmedBalanceAtomic: try BitcoinFamilyAtomicInteger(
                validating: record.confirmedBalanceAtomic
            ),
            unconfirmedBalanceAtomic: try BitcoinFamilyAtomicInteger(
                validating: record.unconfirmedBalanceAtomic
            )
        )
    }
}

import Foundation
import GRDB

extension WalletDatabase {
    static let bitcoinHDMaximumManualAddressAdvance = 1_000

    func bitcoinHDPreferredAddressIndex(
        walletID: String,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch
    ) async throws -> Int? {
        try await pool.read { database in
            try DBBitcoinHDAddressSelectionRecord
                .filter(Column("walletID") == walletID)
                .filter(Column("addressType") == addressType.rawValue)
                .filter(Column("accountIndex") == 0)
                .filter(Column("branch") == branch.rawValue)
                .fetchOne(database)?
                .addressIndex
        }
    }

    func bitcoinHDPreferredAddress(
        walletID: String,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch
    ) async throws -> BitcoinHDDerivedAddress? {
        guard let index = try await bitcoinHDPreferredAddressIndex(
            walletID: walletID,
            addressType: addressType,
            branch: branch
        ) else { return nil }
        let state = try await bitcoinHDAddresses(
            walletID: walletID,
            addressType: addressType,
            branch: branch
        ).first { $0.derived.index == index }
        guard let state, !state.isUsed, !state.isReserved else {
            try await clearBitcoinHDPreferredAddress(
                walletID: walletID,
                addressType: addressType,
                branch: branch
            )
            return nil
        }
        return state.derived
    }

    func setBitcoinHDPreferredAddress(
        walletID: String,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        index: Int
    ) async throws {
        guard index >= 0, index <= Int(UInt32.max) else {
            throw BitcoinHDWalletDatabaseError.invalidAddressState
        }
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            guard let address = try DBBitcoinHDAddressRecord
                .filter(Column("walletID") == walletID)
                .filter(Column("addressType") == addressType.rawValue)
                .filter(Column("accountIndex") == 0)
                .filter(Column("branch") == branch.rawValue)
                .filter(Column("addressIndex") == index)
                .fetchOne(database),
                !address.isUsed,
                !address.isReserved else {
                throw BitcoinHDWalletDatabaseError.invalidAddressState
            }
            try DBBitcoinHDAddressSelectionRecord(
                walletID: walletID,
                addressType: addressType.rawValue,
                accountIndex: 0,
                branch: branch.rawValue,
                addressIndex: index,
                updatedAt: now
            ).save(database)
        }
        if branch == .external,
           try await bitcoinReceiveAddressType(walletID: walletID)
                == addressType,
           !(try await bitcoinUsesSilentPayments(walletID: walletID)) {
            try await publishFreshBitcoinReceiveAddress(walletID: walletID)
        }
    }

    func clearBitcoinHDPreferredAddress(
        walletID: String,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch
    ) async throws {
        _ = try await pool.write { database in
            try DBBitcoinHDAddressSelectionRecord
                .filter(Column("walletID") == walletID)
                .filter(Column("addressType") == addressType.rawValue)
                .filter(Column("accountIndex") == 0)
                .filter(Column("branch") == branch.rawValue)
                .deleteAll(database)
        }
        if branch == .external,
           try await bitcoinReceiveAddressType(walletID: walletID)
                == addressType,
           !(try await bitcoinUsesSilentPayments(walletID: walletID)) {
            try await publishFreshBitcoinReceiveAddress(walletID: walletID)
        }
    }

    @discardableResult
    func generateBitcoinHDAddresses(
        walletID: String,
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        through finalIndex: Int,
        vault: WalletSecretVault = .shared
    ) async throws -> [BitcoinHDAddressState] {
        guard finalIndex >= 0, finalIndex <= Int(UInt32.max) else {
            throw BitcoinHDWalletDatabaseError.invalidAddressState
        }
        var descriptors = try await bitcoinHDAccountDescriptors(
            walletID: walletID
        )
        if descriptors.isEmpty {
            guard try await ensureBitcoinHDWallet(
                walletID: walletID,
                vault: vault
            ) else {
                throw BitcoinHDWalletDatabaseError.unsupportedWallet
            }
            descriptors = try await bitcoinHDAccountDescriptors(
                walletID: walletID
            )
        }
        guard let descriptor = descriptors.first(where: {
            $0.addressType == addressType
        }) else {
            throw BitcoinHDWalletDatabaseError.invalidAddressState
        }
        let existing = try await bitcoinHDAddresses(
            walletID: walletID,
            addressType: addressType,
            branch: branch
        )
        let highest = existing.map(\.derived.index).max() ?? -1
        guard finalIndex <= highest
                + Self.bitcoinHDMaximumManualAddressAdvance else {
            throw BitcoinHDWalletDatabaseError.invalidAddressState
        }
        return try await ensureBitcoinHDAddressRange(
            walletID: walletID,
            descriptor: descriptor,
            branch: branch,
            through: finalIndex,
            vault: vault
        )
    }

    func removeUnavailableBitcoinHDAddressSelections(
        walletID: String
    ) async throws {
        try await pool.write { database in
            try database.execute(
                sql: """
                DELETE FROM bitcoinHDAddressSelections
                WHERE walletID = ? AND EXISTS (
                    SELECT 1 FROM bitcoinHDAddresses AS address
                    WHERE address.walletID =
                            bitcoinHDAddressSelections.walletID
                        AND address.addressType =
                            bitcoinHDAddressSelections.addressType
                        AND address.accountIndex =
                            bitcoinHDAddressSelections.accountIndex
                        AND address.branch =
                            bitcoinHDAddressSelections.branch
                        AND address.addressIndex =
                            bitcoinHDAddressSelections.addressIndex
                        AND (address.isUsed = 1 OR address.isReserved = 1)
                )
                """,
                arguments: [walletID]
            )
        }
    }
}

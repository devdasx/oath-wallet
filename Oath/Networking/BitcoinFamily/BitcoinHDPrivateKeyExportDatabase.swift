import Foundation
import GRDB

struct BitcoinHDPrivateKeyExportEntry: Sendable {
    let state: BitcoinHDAddressState
    let wif: String
}

extension WalletDatabase {
    /// Loads every generated Bitcoin HD address and its matching cached WIF.
    /// Each encrypted branch cache is opened once, then every entry is
    /// cryptographically validated and matched to the public database row.
    func bitcoinHDPrivateKeyExportEntries(
        walletID: String,
        authorization: WalletSecretExportAuthorization,
        vault: WalletSecretVault = .shared
    ) async throws -> [BitcoinHDPrivateKeyExportEntry] {
        guard authorization.permits(walletID: walletID) else {
            throw WalletSecretExportAuthorizationError
                .authenticationRequired
        }
        let states = try await bitcoinHDAddresses(walletID: walletID)
        let cacheRecords = try await pool.read { database in
            try DBBitcoinHDKeyCacheRecord
                .filter(Column("walletID") == walletID)
                .fetchAll(database)
        }
        let statesByLocation = Dictionary(
            uniqueKeysWithValues: states.map {
                (BitcoinHDExportLocation($0.derived), $0)
            }
        )
        var entries: [BitcoinHDPrivateKeyExportEntry] = []
        entries.reserveCapacity(states.count)

        for record in cacheRecords {
            guard
                let addressType = BitcoinHDAddressType(
                    rawValue: record.addressType
                ),
                let branch = BitcoinHDAddressBranch(
                    rawValue: record.branch
                )
            else {
                throw BitcoinHDWalletDatabaseError.invalidAddressState
            }
            let cache = try JSONDecoder().decode(
                BitcoinHDChildKeyCache.self,
                from: vault.data(reference: record.keychainReference)
            ).validated()
            guard cache.walletID == walletID,
                  cache.addressType == addressType,
                  cache.branch == branch,
                  cache.highestCachedIndex == record.highestCachedIndex
            else {
                throw BitcoinHDWalletDatabaseError.invalidAddressState
            }

            for cached in cache.entries {
                let location = BitcoinHDExportLocation(
                    addressType: addressType,
                    branch: branch,
                    index: cached.index
                )
                guard let state = statesByLocation[location],
                      state.derived.address == cached.address,
                      state.derived.derivationPath
                        == cached.derivationPath else {
                    throw BitcoinHDWalletDatabaseError.invalidAddressState
                }
                entries.append(
                    BitcoinHDPrivateKeyExportEntry(
                        state: state,
                        wif: cached.wif
                    )
                )
            }
        }

        guard entries.count == states.count else {
            throw BitcoinHDWalletDatabaseError.invalidAddressState
        }
        return entries.sorted {
            let lhs = $0.state.derived
            let rhs = $1.state.derived
            if lhs.addressType.purposeNumber
                != rhs.addressType.purposeNumber {
                return lhs.addressType.purposeNumber
                    < rhs.addressType.purposeNumber
            }
            if lhs.addressType != rhs.addressType {
                return lhs.addressType.rawValue < rhs.addressType.rawValue
            }
            if lhs.branch.rawValue != rhs.branch.rawValue {
                return lhs.branch.rawValue < rhs.branch.rawValue
            }
            return lhs.index < rhs.index
        }
    }
}

private struct BitcoinHDExportLocation: Hashable {
    let addressType: BitcoinHDAddressType
    let branch: BitcoinHDAddressBranch
    let index: Int

    init(
        addressType: BitcoinHDAddressType,
        branch: BitcoinHDAddressBranch,
        index: Int
    ) {
        self.addressType = addressType
        self.branch = branch
        self.index = index
    }

    init(_ address: BitcoinHDDerivedAddress) {
        self.init(
            addressType: address.addressType,
            branch: address.branch,
            index: address.index
        )
    }
}

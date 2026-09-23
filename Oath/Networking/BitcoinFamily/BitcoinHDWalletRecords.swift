import CryptoKit
import Foundation
import GRDB
import WalletCore

struct DBBitcoinHDAccountRecord: Codable, FetchableRecord,
    PersistableRecord, Sendable {
    static let databaseTableName = "bitcoinHDAccounts"

    var walletID: String
    var addressType: String
    var accountIndex: Int
    var accountPath: String
    var extendedPublicKey: String
    var createdAt: Double
    var updatedAt: Double
}

struct DBBitcoinHDAddressRecord: Codable, FetchableRecord,
    PersistableRecord, Sendable {
    static let databaseTableName = "bitcoinHDAddresses"

    var walletID: String
    var addressType: String
    var accountIndex: Int
    var branch: Int
    var addressIndex: Int
    var derivationPath: String
    var address: String
    var publicKey: Data
    var scriptPubKey: Data
    var scriptHash: String
    var isUsed: Bool
    var isReserved: Bool
    var confirmedBalanceAtomic: String
    var unconfirmedBalanceAtomic: String
    var lastCheckedAt: Double?
    var createdAt: Double
    var updatedAt: Double
}

struct DBBitcoinHDPreferenceRecord: Codable, FetchableRecord,
    PersistableRecord, Sendable {
    static let databaseTableName = "bitcoinHDPreferences"

    var walletID: String
    var receiveAddressType: String
    var usesSilentPayments: Bool
    var updatedAt: Double
}

struct DBBitcoinHDKeyCacheRecord: Codable, FetchableRecord,
    PersistableRecord, Sendable {
    static let databaseTableName = "bitcoinHDKeyCaches"

    var walletID: String
    var addressType: String
    var branch: Int
    var keychainReference: String
    var highestCachedIndex: Int
    var createdAt: Double
    var updatedAt: Double
}

struct DBBitcoinHDAddressSelectionRecord: Codable, FetchableRecord,
    PersistableRecord, Sendable {
    static let databaseTableName = "bitcoinHDAddressSelections"

    var walletID: String
    var addressType: String
    var accountIndex: Int
    var branch: Int
    var addressIndex: Int
    var updatedAt: Double
}

/// Validates the mutable Bitcoin account identity published for Receive.
///
/// A full wallet's canonical Bitcoin account starts at BIP84 index zero, but
/// the public `walletAccounts` row intentionally advances to the next unused
/// external HD address. That projection remains a valid account identity when
/// every field exactly matches an address already derived and persisted for
/// the same wallet.
enum BitcoinHDReceiveAccountProjection {
    static func matches(
        _ account: DBWalletAccountRecord,
        addresses: [DBBitcoinHDAddressRecord]
    ) -> Bool {
        guard account.networkID == BitcoinFamilyChain.bitcoin.networkID,
              account.accountIndex == 0,
              account.label == nil,
              account.isEnabled,
              !account.isWatchOnly,
              let derivationPath = account.derivationPath,
              let publicKey = account.publicKey,
              !publicKey.isEmpty,
              BitcoinFamilyChain.bitcoin.coin.validate(
                  address: account.address
              ),
              account.normalizedAddress == account.address.lowercased()
        else {
            return false
        }
        let lockScript = BitcoinScript.lockScriptForAddress(
            address: account.address,
            coin: BitcoinFamilyChain.bitcoin.coin
        ).data
        guard !lockScript.isEmpty else { return false }
        let scriptHash = Data(SHA256.hash(data: lockScript))
            .reversed()
            .map { String(format: "%02x", $0) }
            .joined()

        return addresses.contains { address in
            guard let type = BitcoinHDAddressType(rawValue: address.addressType),
                  let location = BitcoinHDAddressType.location(for: derivationPath, addressType: type),
                  location.branch == .external else { return false }
            return address.walletID == account.walletID
                && address.accountIndex == 0
                && address.addressType == location.addressType.rawValue
                && address.branch == location.branch.rawValue
                && address.addressIndex == location.index
                && address.derivationPath == derivationPath
                && address.address == account.address
                && address.publicKey.hexString.caseInsensitiveCompare(
                    publicKey
                ) == .orderedSame
                && address.scriptPubKey == lockScript
                && address.scriptHash == scriptHash
        }
    }
}

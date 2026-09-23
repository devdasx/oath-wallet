import Foundation
import GRDB

struct DBMuunRecoveryWalletRecord: Codable, FetchableRecord,
    PersistableRecord, Sendable {
    static let databaseTableName = "muunRecoveryWallets"

    var walletID: String
    var birthdayBlock: Int
    var recoveryScanCursor: Int
    var fullScanCompleted: Bool
    var nextExternalIndex: Int
    var nextChangeIndex: Int
    var createdAt: Double
    var updatedAt: Double
}

struct DBMuunRecoveryAddressRecord: Codable, FetchableRecord,
    PersistableRecord, Sendable {
    static let databaseTableName = "muunRecoveryAddresses"

    var walletID: String
    var version: Int
    var branch: Int
    var contactIndex: Int
    var addressIndex: Int
    var derivationPath: String
    var address: String
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

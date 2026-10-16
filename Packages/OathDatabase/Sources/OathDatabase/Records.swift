import Foundation
import GRDB

// Immutable values may cross actor boundaries. SQL connections and cursors never do.
public struct NetworkRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "networks"
    public var id: String
    public var name: String
    public var family: String
    public var symbol: String
    public var decimals: Int
    public var derivationPath: String
    public var logo: String
    public var sortOrder: Int
    public var enabled: Bool
    public init(id: String, name: String, family: String, symbol: String, decimals: Int, derivationPath: String, logo: String, sortOrder: Int, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.family = family
        self.symbol = symbol
        self.decimals = decimals
        self.derivationPath = derivationPath
        self.logo = logo
        self.sortOrder = sortOrder
        self.enabled = enabled
    }
}

public struct WalletRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "wallets"
    public var id: String
    public var name: String
    public var kind: String
    public var vaultReference: String
    public var createdAt: Double
    public var backedUp: Bool
    public var colorHex: String?
    public var needsCustomization: Bool
    public var nameIndex: Int = 0
    /// Automatic names are localized at display time; `name` is only a custom
    /// label. The group and ordinal are stable across reordering and languages.
    public var nameGroup: String? = nil
    public var sortOrder: Int = 0
    public var deletedAt: Double? = nil
    public init(id: String, name: String, kind: String, vaultReference: String, createdAt: Double, backedUp: Bool = false, colorHex: String? = nil, needsCustomization: Bool = false, nameGroup: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.vaultReference = vaultReference
        self.createdAt = createdAt
        self.backedUp = backedUp
        self.colorHex = colorHex
        self.needsCustomization = needsCustomization
        self.nameGroup = nameGroup
    }

    static func inferredNameGroup(kind: String, networkIDs: [String]) -> String {
        if kind == "privateKey", let network = networkIDs.contains("ethereum") ? "ethereum" : networkIDs.sorted().first {
            return "network:" + network
        }
        return kind == "imported" || kind == "privateKey" ? "imported" : "main"
    }
}

public struct AccountRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "accounts"
    public var id: String
    public var walletID: String
    public var networkID: String
    public var address: String
    public var derivationPath: String
    public var accountIndex: Int
    public var syncGeneration: Int64
    public init(id: String, walletID: String, networkID: String, address: String, derivationPath: String, accountIndex: Int = 0, syncGeneration: Int64 = 0) {
        self.id = id
        self.walletID = walletID
        self.networkID = networkID
        self.address = address
        self.derivationPath = derivationPath
        self.accountIndex = accountIndex
        self.syncGeneration = syncGeneration
    }
}

public struct AssetRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "assets"
    public var id: String
    public var networkID: String
    public var reference: String
    public var name: String
    public var symbol: String
    public var decimals: Int
    public var logo: String?
    public init(id: String, networkID: String, reference: String, name: String, symbol: String, decimals: Int, logo: String? = nil) {
        self.id = id
        self.networkID = networkID
        self.reference = reference
        self.name = name
        self.symbol = symbol
        self.decimals = decimals
        self.logo = logo
    }
}

public struct BalanceRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "balances"
    public var accountID: String
    public var assetID: String
    public var networkID: String
    public var amountAtomic: String
    public var observedAt: Double
    public var blockHeight: Int64?
    public var source: String
    public init(accountID: String, assetID: String, networkID: String, amountAtomic: String, observedAt: Double, blockHeight: Int64? = nil, source: String) {
        self.accountID = accountID
        self.assetID = assetID
        self.networkID = networkID
        self.amountAtomic = amountAtomic
        self.observedAt = observedAt
        self.blockHeight = blockHeight
        self.source = source
    }
}

public struct PriceRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "prices"
    public var assetID: String
    public var currency: String
    public var value: String
    public var observedAt: Double
    public var source: String
    public init(assetID: String, currency: String, value: String, observedAt: Double, source: String) {
        self.assetID = assetID
        self.currency = currency
        self.value = value
        self.observedAt = observedAt
        self.source = source
    }
}

public struct TransactionRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transactions"
    public var id: String
    public var networkID: String
    public var hash: String
    public var state: String
    public var blockHeight: Int64?
    public var blockHash: String?
    public var timestamp: Double
    public var feeAtomic: String?
    public var updatedAt: Double
    public init(id: String, networkID: String, hash: String, state: String, blockHeight: Int64? = nil, blockHash: String? = nil, timestamp: Double, feeAtomic: String? = nil, updatedAt: Double) {
        self.id = id
        self.networkID = networkID
        self.hash = hash
        self.state = state
        self.blockHeight = blockHeight
        self.blockHash = blockHash
        self.timestamp = timestamp
        self.feeAtomic = feeAtomic
        self.updatedAt = updatedAt
    }
}

public struct TransferRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transfers"
    public var id: String
    public var transactionID: String
    public var networkID: String
    public var assetID: String
    public var eventIndex: Int
    public var fromAddress: String
    public var toAddress: String
    public var amountAtomic: String
    public init(id: String, transactionID: String, networkID: String, assetID: String, eventIndex: Int, fromAddress: String, toAddress: String, amountAtomic: String) {
        self.id = id
        self.transactionID = transactionID
        self.networkID = networkID
        self.assetID = assetID
        self.eventIndex = eventIndex
        self.fromAddress = fromAddress
        self.toAddress = toAddress
        self.amountAtomic = amountAtomic
    }
}

public struct ActivityRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "activity"
    public var id: String
    public var walletID: String
    public var accountID: String
    public var networkID: String
    public var transactionID: String
    public var assetID: String
    public var direction: String
    public var amountAtomic: String
    public var counterparty: String
    public var timestamp: Double
    public init(id: String, walletID: String, accountID: String, networkID: String, transactionID: String, assetID: String, direction: String, amountAtomic: String, counterparty: String, timestamp: Double) {
        self.id = id
        self.walletID = walletID
        self.accountID = accountID
        self.networkID = networkID
        self.transactionID = transactionID
        self.assetID = assetID
        self.direction = direction
        self.amountAtomic = amountAtomic
        self.counterparty = counterparty
        self.timestamp = timestamp
    }
}

public struct SendRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sends"
    public var id: String
    public var walletID: String
    public var accountID: String
    public var networkID: String
    public var assetID: String
    /// Derived from the account by saveDraft; callers cannot override ownership.
    public internal(set) var senderAddress: String = ""
    public var idempotencyKey: String
    public var recipient: String
    public var amountAtomic: String
    public var state: String
    public var nonce: String?
    public var signedPayload: Data?
    public var transactionID: String?
    public var failureCode: String?
    public var createdAt: Double
    public var updatedAt: Double
    public init(id: String, walletID: String, accountID: String, networkID: String, assetID: String, idempotencyKey: String, recipient: String, amountAtomic: String, state: String, nonce: String? = nil, signedPayload: Data? = nil, transactionID: String? = nil, failureCode: String? = nil, createdAt: Double, updatedAt: Double) {
        self.id = id
        self.walletID = walletID
        self.accountID = accountID
        self.networkID = networkID
        self.assetID = assetID
        self.idempotencyKey = idempotencyKey
        self.recipient = recipient
        self.amountAtomic = amountAtomic
        self.state = state
        self.nonce = nonce
        self.signedPayload = signedPayload
        self.transactionID = transactionID
        self.failureCode = failureCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A chain output joined with one owning account. The output itself is stored
/// once; accountUTXOs associates it with every wallet that owns the address.
public struct UTXORecord: Codable, Equatable, Sendable, FetchableRecord {
    public static let databaseTableName = "utxos"
    public var networkID: String
    public var transactionHash: String
    public var outputIndex: Int
    public var accountID: String
    public var value: Int64
    public var script: String
    public var blockHeight: Int64?
    public var spent: Bool
    public var reservedBy: String?
    public var updatedAt: Double
    public init(networkID: String, transactionHash: String, outputIndex: Int, accountID: String, value: Int64, script: String, blockHeight: Int64? = nil, spent: Bool = false, reservedBy: String? = nil, updatedAt: Double) {
        self.networkID = networkID
        self.transactionHash = transactionHash
        self.outputIndex = outputIndex
        self.accountID = accountID
        self.value = value
        self.script = script
        self.blockHeight = blockHeight
        self.spent = spent
        self.reservedBy = reservedBy
        self.updatedAt = updatedAt
    }
}

public struct ReceiveRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "receives"
    public var id: String
    public var accountID: String
    public var networkID: String
    public var assetID: String
    public var address: String
    public var amountAtomic: String?
    public var memo: String?
    public var state: String
    public var createdAt: Double
    public var expiresAt: Double?
    public init(id: String, accountID: String, networkID: String, assetID: String, address: String, amountAtomic: String? = nil, memo: String? = nil, state: String, createdAt: Double, expiresAt: Double? = nil) {
        self.id = id
        self.accountID = accountID
        self.networkID = networkID
        self.assetID = assetID
        self.address = address
        self.amountAtomic = amountAtomic
        self.memo = memo
        self.state = state
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct NoteRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "notes"
    public var id: String
    public var walletID: String
    public var subjectType: String
    public var subjectID: String
    public var body: String
    public var updatedAt: Double
    public init(id: String, walletID: String, subjectType: String, subjectID: String, body: String, updatedAt: Double) {
        self.id = id
        self.walletID = walletID
        self.subjectType = subjectType
        self.subjectID = subjectID
        self.body = body
        self.updatedAt = updatedAt
    }
}

public struct LabelRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "labels"
    public var id: String
    public var walletID: String
    public var name: String
    public var color: String
    public var updatedAt: Double
    public init(id: String, walletID: String, name: String, color: String, updatedAt: Double) {
        self.id = id
        self.walletID = walletID
        self.name = name
        self.color = color
        self.updatedAt = updatedAt
    }
}

public struct LabelAssignment: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "labelAssignments"
    public var labelID: String
    public var walletID: String
    public var subjectType: String
    public var subjectID: String
    public init(labelID: String, walletID: String, subjectType: String, subjectID: String) {
        self.labelID = labelID
        self.walletID = walletID
        self.subjectType = subjectType
        self.subjectID = subjectID
    }
}

public struct SyncCursor: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "syncCursors"
    public var accountID: String
    public var stream: String
    public var cursor: String
    public var blockHeight: Int64?
    public var blockHash: String?
    public var updatedAt: Double
    public init(accountID: String, stream: String, cursor: String, blockHeight: Int64? = nil, blockHash: String? = nil, updatedAt: Double) {
        self.accountID = accountID
        self.stream = stream
        self.cursor = cursor
        self.blockHeight = blockHeight
        self.blockHash = blockHash
        self.updatedAt = updatedAt
    }
}

public struct SettingRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "settings"
    public var key: String
    public var value: String
    public var updatedAt: Double
    public init(key: String, value: String, updatedAt: Double) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
    }
}

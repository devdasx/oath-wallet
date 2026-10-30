import Foundation

/// Oath's immutable, equal-weight TRON policy. Both owner and active permissions
/// enforce the same threshold; no bootstrap key or weaker permission survives.
public struct TronMultisigPolicy: Codable, Sendable, Equatable {
    public let version: Int
    public let required: Int
    public let signers: [String]
    public static let maximumKeys = 5
    public init(required: Int, signers: [String]) throws {
        version = 1; self.required = required; self.signers = signers.sorted()
        try validate()
    }
    public func validate() throws {
        guard version == 1, (2...Self.maximumKeys).contains(signers.count),
              (1...signers.count).contains(required), Set(signers).count == signers.count,
              signers == signers.sorted(), signers.allSatisfy(TronIdentity.isAddress) else {
            throw TronSendError.unsupportedAccount
        }
    }
    /// TransferContract, TransferAssetContract, TriggerSmartContract only.
    /// AccountPermissionUpdateContract remains an owner-only operation.
    public static let operations = "06000080" + String(repeating: "00", count: 28)
    private var owner: TronPermissionControl.Permission {
        .init(type: 0, id: 0, name: "owner", threshold: UInt64(required), operations: "",
              keys: signers.map { .init(address: $0, weight: 1) })
    }
    private var active: TronPermissionControl.Permission {
        .init(type: 2, id: 2, name: "active", threshold: UInt64(required), operations: Self.operations,
              keys: signers.map { .init(address: $0, weight: 1) })
    }
    public func matches(_ account: TronJSON) throws -> Bool {
        try validate()
        guard account["witness_permission"].isNull,
              let activeRows = account["active_permission"].array, activeRows.count == 1 else { return false }
        let observedOwner = try TronPermissionControl.Permission.decode(account["owner_permission"], type: 0, id: 0)
        let observedActive = try TronPermissionControl.Permission.decode(activeRows[0], type: 2, id: 2)
        func same(_ lhs: TronPermissionControl.Permission, _ rhs: TronPermissionControl.Permission) -> Bool {
            lhs.type == rhs.type && lhs.id == rhs.id && lhs.threshold == rhs.threshold
                && lhs.operations == rhs.operations && lhs.keys.count == rhs.keys.count
                && lhs.keys.allSatisfy { rhs.keys.contains($0) }
        }
        return same(observedOwner, owner) && same(observedActive, active)
    }
    /// Creation is allowed only from a fresh, normally controlled account.
    /// Never overwrite existing delegated or multisignature permissions.
    public static func validateBootstrap(_ account: TronJSON, address: String) throws {
        try TronSendClient.validateOwner(account, sender: address)
        guard account["witness_permission"].isNull else { throw TronSendError.unsupportedAccount }
        func single(_ value: TronJSON, type: UInt64, id: UInt64) throws {
            let p = try TronPermissionControl.Permission.decode(value, type: type, id: id)
            guard p.threshold == 1, p.keys.count == 1, p.keys[0].address == address, p.keys[0].weight == 1 else {
                throw TronSendError.unsupportedAccount
            }
        }
        if !account["owner_permission"].isNull { try single(account["owner_permission"], type: 0, id: 0) }
        if !account["active_permission"].isNull {
            guard let rows = account["active_permission"].array, rows.count == 1 else { throw TronSendError.unsupportedAccount }
            try single(rows[0], type: 2, id: 2)
        }
    }
    func contract(account: String) throws -> Data {
        try validate()
        guard !signers.contains(account) else { throw TronSendError.unsupportedAccount }
        return try TronSendCrypto.field(1, TronIdentity.bytes(account))
            + TronSendCrypto.field(2, owner.bytes()) + TronSendCrypto.field(4, active.bytes())
    }
}

public struct TronMultisigState: Sendable, Equatable {
    public let configured: Bool
    public let balance: UInt64
    public let permissionFee: UInt64
}

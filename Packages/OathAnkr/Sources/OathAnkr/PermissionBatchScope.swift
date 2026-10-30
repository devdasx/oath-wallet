import Foundation

/// A removal-only, single-use authorization. Public metadata only; never a key,
/// passcode or general signing capability. The vault owns lifetime and consumption.
public struct PermissionBatchScope: Codable, Sendable, Equatable {
    public static let maximumItems = 10_000
    public let sendID: String, walletID: String, accountID: String
    public let network: String, owner: String
    public let removal: PermissionRevocation
    public let maximumFee: UInt64

    public init(sendID: String, walletID: String, accountID: String, network: String,
                owner: String, removal: PermissionRevocation, maximumFee: UInt64) throws {
        guard UUID(uuidString: sendID) != nil, !walletID.isEmpty, !accountID.isEmpty else { throw PermissionError.malformed }
        switch removal {
        case .evm(let value):
            guard let chain = EVMSendNetwork(rawValue: network), !chain.isTestnet,
                  try EVMSendIdentity.address(owner) == owner else { throw PermissionError.malformed }
            try value.validate()
        case .tron(let value):
            guard network == "tron", TronIdentity.isAddress(owner) else { throw PermissionError.malformed }
            try value.validate()
        case .solana(let value):
            guard network == "solana", SolanaIdentity.isAddress(owner) else { throw PermissionError.malformed }
            try value.validate()
        }
        self.sendID = sendID; self.walletID = walletID; self.accountID = accountID
        self.network = network; self.owner = owner; self.removal = removal; self.maximumFee = maximumFee
    }

    public func permits(_ requested: Self) -> Bool {
        sendID == requested.sendID && walletID == requested.walletID && accountID == requested.accountID &&
        network == requested.network && owner == requested.owner && removal == requested.removal &&
        requested.maximumFee <= maximumFee
    }

    public static func evm(sendID: String, walletID: String, accountID: String, plan: EVMSendPlan) throws -> Self {
        try plan.validate()
        guard let removal = plan.removal, plan.call == nil, String(plan.amount) == "0", plan.reference == "native" else { throw PermissionError.changed }
        return try .init(sendID: sendID, walletID: walletID, accountID: accountID, network: plan.network.rawValue,
                         owner: plan.sender, removal: .evm(removal), maximumFee: plan.fee)
    }
    public static func tron(sendID: String, walletID: String, accountID: String, plan: TronSendPlan) throws -> Self {
        try plan.validate()
        guard let removal = plan.removal, String(plan.amount) == "0", plan.reference == "native" else { throw PermissionError.changed }
        return try .init(sendID: sendID, walletID: walletID, accountID: accountID, network: "tron",
                         owner: plan.sender, removal: .tron(removal), maximumFee: plan.fee)
    }
    public static func solana(sendID: String, walletID: String, accountID: String, plan: SolanaSendPlan) throws -> Self {
        try plan.validate()
        guard let removal = plan.removal, String(plan.amount) == "0" else { throw PermissionError.changed }
        return try .init(sendID: sendID, walletID: walletID, accountID: accountID, network: "solana",
                         owner: plan.sender, removal: .solana(removal), maximumFee: plan.fee)
    }
}

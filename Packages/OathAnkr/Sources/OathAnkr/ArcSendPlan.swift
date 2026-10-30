import Foundation

public enum ArcSendError: Error, Sendable, Equatable {
    case configuration, malformed, wrongNetwork, wrongOwner, amount, insufficientFunds, metadataChanged
    case feeTooHigh, expired, changed, signing, busy, transport, http(Int), rpc(Int), simulationFailed, execution
}
public enum ArcSendNetwork: String, Codable, Sendable {
    case mainnet, testnet
    public var chainID: UInt64 { self == .mainnet ? 5042 : 5042002 }
    public var endpoints: [URL] {
        ["https://rpc.blockdaemon.\(rawValue).arc.io", "https://rpc.drpc.\(rawValue).arc.io", "https://rpc.\(rawValue).arc.io"].map { URL(string:$0)! }
    }
}

/// Exact uint256 arithmetic. Native USDC uses 18 decimals; its six-decimal
/// ERC-20 mirror is never treated as a second asset or used for gas accounting.
public enum ArcSendAmount {
    public static func checked(_ value:String) throws -> String {
        guard try AnkrQuantity.decimal(value)==value else { throw ArcSendError.amount }
        _ = try TronSendCrypto.uint256(value); return value
    }
    public static func less(_ a:String,_ b:String) -> Bool { a.count == b.count ? a<b : a.count<b.count }
    public static func add(_ a:String,_ b:String) throws -> String { _ = try checked(a); _ = try checked(b); return try checked(AptosIdentity.add(a,b)) }
    public static func subtract(_ a:String,_ b:String) throws -> String {
        _ = try checked(a); _ = try checked(b)
        guard !less(a,b) else { throw ArcSendError.insufficientFunds }
        return try checked(StellarIdentity.sum(a,"-"+b))
    }
    public static func multiply(_ a:String,_ b:String) throws -> String { try checked(AnkrQuantity.multiply(a,b)) }
    public static func hex(_ value:String) throws -> String {
        _ = try checked(value)
        let hex = TronSendCrypto.hex(try TronSendCrypto.uint256(value)).drop(while:{$0=="0"})
        return "0x"+(hex.isEmpty ? "0":String(hex))
    }
}

public struct ArcSendPlan: Codable, Sendable, Equatable {
    public let network: ArcSendNetwork
    public let sender:String, recipient:String, reference:String
    public let decimals:Int
    public let requestedAmount:String, amount:String, assetBalance:String, nativeBalance:String
    public let nonce:UInt64, gasLimit:UInt64, maxFeePerGas:UInt64, maxPriorityFeePerGas:UInt64, blockHeight:UInt64
    public let createdAt:Date
    public static let maximumGas:UInt64 = 2_000_000
    public static let maximumFee:UInt64 = 1_000_000_000_000_000_000 // 1 USDC maximum authorization.
    // Validation establishes multiplication/subtraction bounds before these values are used.
    public var fee:UInt64 { gasLimit.multipliedReportingOverflow(by:maxFeePerGas).partialValue }
    public var remaining:String { StellarIdentity.sum(assetBalance,"-"+StellarIdentity.sum(amount,reference == "native" ? String(fee):"0")) }
    public var receiver:String { reference == "native" ? recipient:reference }
    public var value:String { reference == "native" ? amount:"0" }
    public init(network:ArcSendNetwork,sender:String,recipient:String,reference:String,decimals:Int,
                requestedAmount:String,amount:String,assetBalance:String,nativeBalance:String,nonce:UInt64,
                gasLimit:UInt64,maxFeePerGas:UInt64,maxPriorityFeePerGas:UInt64,blockHeight:UInt64,createdAt:Date = .now) {
        self.network=network;self.sender=sender;self.recipient=recipient;self.reference=reference;self.decimals=decimals
        self.requestedAmount=requestedAmount;self.amount=amount;self.assetBalance=assetBalance;self.nativeBalance=nativeBalance
        self.nonce=nonce;self.gasLimit=gasLimit;self.maxFeePerGas=maxFeePerGas;self.maxPriorityFeePerGas=maxPriorityFeePerGas
        self.blockHeight=blockHeight;self.createdAt=createdAt
    }
    public func validate(now:Date = .now,checkAge:Bool=true) throws {
        guard createdAt.timeIntervalSince1970.isFinite,createdAt.timeIntervalSince1970>0 else { throw ArcSendError.malformed }
        if checkAge,!(-5...90).contains(now.timeIntervalSince(createdAt)) { throw ArcSendError.expired }
        guard try ArcIdentity.address(sender)==sender,try ArcIdentity.address(recipient)==recipient,
              sender != recipient,recipient != "0x"+String(repeating:"0",count:40),
              try ArcIdentity.reference(reference)==reference,(0...255).contains(decimals),nonce<UInt64.max,
              blockHeight>0,blockHeight<UInt64(Int64.max) else { throw ArcSendError.malformed }
        for n in [requestedAmount,amount,assetBalance,nativeBalance] { _ = try ArcSendAmount.checked(n) }
        let cost=gasLimit.multipliedReportingOverflow(by:maxFeePerGas)
        guard gasLimit>=21_000,gasLimit<=Self.maximumGas,maxFeePerGas>0,maxPriorityFeePerGas<=maxFeePerGas,
              !cost.overflow,cost.partialValue<=Self.maximumFee else { throw ArcSendError.feeTooHigh }
        guard amount != "0",!ArcSendAmount.less(requestedAmount,amount),!ArcSendAmount.less(assetBalance,amount) else { throw ArcSendError.insufficientFunds }
        guard !ArcSendAmount.less(nativeBalance,String(fee)) else { throw SendFeeFundingError.insufficientNativeBalance }
        if reference == "native" {
            guard decimals==18,assetBalance==nativeBalance else { throw ArcSendError.metadataChanged }
            guard try !ArcSendAmount.less(nativeBalance,ArcSendAmount.add(amount,String(fee))) else { throw ArcSendError.insufficientFunds }
        }
    }
}
public struct ArcSignedSend: Codable, Sendable, Equatable {
    public let bytes:Data, signature:Data
    public let hash:String
    public init(bytes:Data,signature:Data,hash:String) { self.bytes=bytes;self.signature=signature;self.hash=hash }
}
public struct ArcSendReceipt: Sendable, Equatable {
    public enum Outcome:String,Sendable { case unknown, accepted, confirmed, failed, replaced, cancelled }
    public let hash:String, outcome:Outcome
    public let fee:UInt64?, height:UInt64?, timestamp:Double?, replacementHash:String?
    /// Actual recipient delivery from ERC-20 Transfer events. Execution status
    /// and delivered value are distinct: a transfer-tax token can succeed while
    /// delivering less than the amount authorized by the sender.
    public let deliveredAmount:String?
    public let inclusion: EVMSendInclusion?
    public init(hash:String,outcome:Outcome,fee:UInt64?=nil,height:UInt64?=nil,timestamp:Double?=nil,replacementHash:String?=nil,deliveredAmount:String?=nil,inclusion:EVMSendInclusion?=nil) {
        self.inclusion = inclusion
        self.hash=hash;self.outcome=outcome;self.fee=fee;self.height=height;self.timestamp=timestamp;self.replacementHash=replacementHash;self.deliveredAmount=deliveredAmount
    }
}

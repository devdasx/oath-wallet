import Foundation

public enum TronSendError: Error, Sendable, Equatable {
    case activationFunds(UInt64), senderInactive
    case configuration, malformed, wrongNetwork, wrongOwner, amount, insufficientFunds, unsupportedAccount
    case feeTooHigh, expired, changed, signing, busy, simulation, execution, transport, http(Int), rpc(String)
}
public enum TronSendNetwork: String, Codable, Sendable {
    case mainnet, nile
    public var endpoint: URL { URL(string:self == .mainnet ? "https://api.trongrid.io":"https://nile.trongrid.io")! }
    public var genesisID: String { self == .mainnet ? "00000000000000001ebf88508a03865c71d452e25f4d51194196a1d22b6653dc":"0000000000000000d698d4192c56cb6be724a558448e2684802de4d6cd8690dc" }
}
/// Immutable, locally constructed one-operation transfer. Only the fee limit is
/// a protocol cap; the bandwidth allowance is a conservative review reservation.
public struct TronSendPlan: Codable, Sendable, Equatable {
    public let network: TronSendNetwork
    public let sender: String, recipient: String, reference: String, amount: String, requestedAmount: String, assetBalance: String
    public let decimals: Int
    public let nativeBalance: UInt64, fee: UInt64, estimatedFee: UInt64, feeLimit: UInt64
    public let energyPrice: UInt64, bandwidthPrice: UInt64
    public let blockID: String, blockNumber: UInt64, timestamp: UInt64, expiration: UInt64
    /// Optional for compatibility with already queued sends; display metadata only.
    public let recipientNeedsActivation: Bool?
    /// Creation plus uncovered creation Bandwidth, already contained in fee.
    public let accountCreationFee: UInt64?
    public let removal: TronPermissionRemoval?
    public let createdAt: Date
    public init(network:TronSendNetwork,sender:String,recipient:String,reference:String,amount:String,requestedAmount:String,assetBalance:String,decimals:Int,nativeBalance:UInt64,fee:UInt64,estimatedFee:UInt64,feeLimit:UInt64,energyPrice:UInt64,bandwidthPrice:UInt64,blockID:String,blockNumber:UInt64,timestamp:UInt64,expiration:UInt64,createdAt:Date = .now,removal:TronPermissionRemoval?=nil,recipientNeedsActivation:Bool?=nil,accountCreationFee:UInt64?=nil) {
        self.network=network;self.sender=sender;self.recipient=recipient;self.reference=reference;self.amount=amount;self.requestedAmount=requestedAmount;self.assetBalance=assetBalance;self.decimals=decimals;self.nativeBalance=nativeBalance;self.fee=fee;self.estimatedFee=estimatedFee;self.feeLimit=feeLimit;self.energyPrice=energyPrice;self.bandwidthPrice=bandwidthPrice;self.blockID=blockID;self.blockNumber=blockNumber;self.timestamp=timestamp;self.expiration=expiration;self.createdAt=createdAt;self.removal=removal;self.recipientNeedsActivation=recipientNeedsActivation;self.accountCreationFee=accountCreationFee
    }
    public var adjusted: Bool { amount != requestedAmount }
    public var remaining: String { StellarIdentity.sum(StellarIdentity.sum(assetBalance,"-"+amount),reference == "native" ? "-"+String(fee):"0") }
    public var isContract: Bool { TronIdentity.isAddress(reference) }
    public static let maximumFee: UInt64 = 500_000_000
    public func validate(now: Date = .now, checkAge: Bool = true) throws {
        if checkAge { guard (-5...90).contains(now.timeIntervalSince(createdAt)), now.timeIntervalSince1970*1000+5_000 < Double(expiration) else { throw TronSendError.expired } }
        guard TronIdentity.isAddress(sender),TronIdentity.isAddress(recipient),(sender != recipient || removal?.control != nil),
              reference == "native" || TronIdentity.isToken(reference), (0...255).contains(decimals),
              fee <= Self.maximumFee,estimatedFee <= fee, feeLimit <= Self.maximumFee, nativeBalance >= fee,nativeBalance<=UInt64(Int64.max),
              energyPrice>0, energyPrice<=100_000, bandwidthPrice>0,bandwidthPrice<=1_000_000,
              TronIdentity.hash(blockID),let height=UInt64(blockID.prefix(16),radix:16),height == blockNumber,blockNumber>0,blockNumber<=UInt64(Int64.max)-121,
              timestamp>0,timestamp<=UInt64(Int64.max)-180_000,expiration>timestamp,expiration-timestamp<=180_000,
              abs(Double(timestamp)/1000-createdAt.timeIntervalSince1970)<=90 else { throw TronSendError.malformed }
        for raw in [amount,requestedAmount,assetBalance] { guard try TronIdentity.quantity(.string(raw)) == raw else { throw TronSendError.amount }; _ = try TronSendCrypto.uint256(raw) }
        if let removal {
            try removal.validate()
            guard reference=="native",decimals==6,recipient==removal.contract,amount=="0",requestedAmount=="0",assetBalance==String(nativeBalance),(removal.control==nil ? feeLimit>0:feeLimit==0) else { throw TronSendError.changed };return
        }
        guard amount != "0", !XrplSendAmount.less(assetBalance,amount),!XrplSendAmount.less(requestedAmount,amount) else { throw TronSendError.insufficientFunds }
        if reference == "native" {
            guard decimals==6, assetBalance==String(nativeBalance),let n=UInt64(amount),n<=nativeBalance-fee,feeLimit==0 else { throw TronSendError.insufficientFunds }
        } else if !isContract { guard Int64(amount) != nil,feeLimit==0 else { throw TronSendError.amount } }
        else { guard feeLimit>0 else { throw TronSendError.changed } }
    }
}
public struct TronSignedSend: Codable, Sendable, Equatable {
    public let bytes: Data, signature: Data, hash: String
    public init(bytes:Data,signature:Data,hash:String) { self.bytes=bytes;self.signature=signature;self.hash=hash }
}
public struct TronSendReceipt: Sendable, Equatable {
    public enum Outcome: String, Sendable { case unknown, submitted, confirmed, failed, expired }
    public let hash: String, outcome: Outcome
    public let fee: UInt64?, block: UInt64?
    /// Broadcast acknowledgement is sufficient for the submitted screen, but
    /// only solid execution/expiry can settle the journal and release resources.
    public var accepted: Bool { outcome == .submitted || outcome == .confirmed }
    public var requiresConfirmation: Bool { outcome == .unknown || outcome == .submitted }
    public init(hash:String,outcome:Outcome,fee:UInt64? = nil,block:UInt64? = nil) { self.hash=hash;self.outcome=outcome;self.fee=fee;self.block=block }
}

import Foundation

public enum AptosSendError: Error, Sendable, Equatable {
    case configuration, malformed, wrongNetwork, wrongOwner, amount, sameRecipient, insufficientFunds, metadataChanged
    case feeTooHigh, expired, changed, signing, busy, transport, http(Int), simulationFailed, execution
}
public enum AptosSendNetwork: String, Codable, Sendable {
    case mainnet, testnet
    public var chainID: UInt8 { self == .mainnet ? 1 : 2 }
    public var endpoint: URL { URL(string:"https://api.\(rawValue).aptoslabs.com/v1")! }
}
/// An immutable authorization. The recipient, payload, sequence, expiry, and maximum
/// gas cost are reconstructed locally; no provider-supplied signing bytes are trusted.
public struct AptosSendPlan: Codable, Sendable, Equatable {
    public let network: AptosSendNetwork
    public let sender: String, recipient: String, reference: String
    public let publicKey: Data
    public let decimals: Int
    public let requestedAmount: UInt64, amount: UInt64, assetBalance: UInt64, nativeBalance: UInt64
    public let sequence: UInt64, gasUnitPrice: UInt64, maxGasAmount: UInt64, expiration: UInt64
    public let createdAt: Date
    public var fee: UInt64 { gasUnitPrice * maxGasAmount }
    public var remaining: UInt64 { assetBalance - amount - (reference == "native" ? fee : 0) }
    public static let gasLimit: UInt64 = 200_000
    public static let feeLimit: UInt64 = 100_000_000 // 1 APT hard authorization ceiling.
    public init(network: AptosSendNetwork, sender: String, recipient: String, reference: String, publicKey: Data,
                decimals: Int, requestedAmount: UInt64, amount: UInt64, assetBalance: UInt64, nativeBalance: UInt64,
                sequence: UInt64, gasUnitPrice: UInt64, maxGasAmount: UInt64, expiration: UInt64, createdAt: Date = .now) {
        self.network=network; self.sender=sender; self.recipient=recipient; self.reference=reference; self.publicKey=publicKey
        self.decimals=decimals; self.requestedAmount=requestedAmount; self.amount=amount; self.assetBalance=assetBalance; self.nativeBalance=nativeBalance
        self.sequence=sequence; self.gasUnitPrice=gasUnitPrice; self.maxGasAmount=maxGasAmount; self.expiration=expiration; self.createdAt=createdAt
    }
    public func validate(now: Date = .now, checkAge: Bool = true) throws {
        guard createdAt.timeIntervalSince1970.isFinite, createdAt.timeIntervalSince1970 > 0,
              expiration > 0, expiration <= UInt64(Int64.max),
              Double(expiration)-createdAt.timeIntervalSince1970 >= 60,
              Double(expiration)-createdAt.timeIntervalSince1970 <= 600 else { throw AptosSendError.malformed }
        if checkAge, !(-5...90).contains(now.timeIntervalSince(createdAt)) || Double(expiration) <= now.timeIntervalSince1970+5 { throw AptosSendError.expired }
        guard try AptosIdentity.address(sender)==sender, try AptosIdentity.address(recipient)==recipient,
              sender != recipient, recipient != (try AptosIdentity.address("0x0")),
              try AptosIdentity.reference(reference)==reference, publicKey.count==32,
              (0...255).contains(decimals), sequence<UInt64.max else { throw AptosSendError.malformed }
        guard try AptosSendCrypto.address(publicKey:publicKey)==sender else { throw AptosSendError.wrongOwner }
        let cost=gasUnitPrice.multipliedReportingOverflow(by:maxGasAmount)
        guard gasUnitPrice>0,maxGasAmount>0,maxGasAmount<=Self.gasLimit,!cost.overflow,cost.partialValue<=Self.feeLimit else { throw AptosSendError.feeTooHigh }
        guard amount>0,amount<=requestedAmount,amount<=assetBalance,cost.partialValue<=nativeBalance else { throw AptosSendError.insufficientFunds }
        if reference == "native" {
            guard decimals==8,assetBalance==nativeBalance,amount<=nativeBalance-cost.partialValue else { throw AptosSendError.insufficientFunds }
        } else if reference.contains("::") { _ = try AptosBCS.typeTag(reference) }
    }
}
public struct AptosSignedSend: Codable, Sendable, Equatable {
    public let bytes: Data, publicKey: Data, signature: Data
    public let hash: String
    public init(bytes:Data,publicKey:Data,signature:Data,hash:String) { self.bytes=bytes;self.publicKey=publicKey;self.signature=signature;self.hash=hash }
}
public struct AptosSendReceipt: Sendable, Equatable {
    public enum Outcome: String, Sendable { case unknown, accepted, confirmed, failed, expired, replaced }
    public let hash: String, outcome: Outcome
    public let fee: UInt64?, version: UInt64?, timestamp: Double?, replacementHash: String?
    public init(hash:String,outcome:Outcome,fee:UInt64?=nil,version:UInt64?=nil,timestamp:Double?=nil,replacementHash:String?=nil) {
        self.hash=hash;self.outcome=outcome;self.fee=fee;self.version=version;self.timestamp=timestamp;self.replacementHash=replacementHash
    }
}

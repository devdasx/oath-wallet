import Foundation

public enum ThorchainSendError: Error, Sendable, Equatable {
    case configuration, malformed, wrongNetwork, wrongOwner, amount, insufficientFunds, metadataChanged
    case feeTooHigh, expired, changed, signing, busy, transport, http(Int), rejected(Int), execution, halted, moduleRecipient
}
public enum ThorchainSendNetwork: String, Codable, Sendable {
    case mainnet, localTestnet
    public var chainID: String { self == .mainnet ? "thorchain-1":"oath-thorchain-test-1" }
    public var prefix: String { self == .mainnet ? "thor":"tthor" }
}
public enum ThorchainSendAmount {
    public static func checked(_ value:String) throws -> String {
        guard !value.isEmpty,value.count<=78,value.utf8.allSatisfy({(48...57).contains($0)}),value=="0" || !value.hasPrefix("0") else { throw ThorchainSendError.amount }
        _ = try TronSendCrypto.uint256(value);return value
    }
    public static func less(_ a:String,_ b:String) -> Bool { a.count == b.count ? a<b:a.count<b.count }
    public static func add(_ a:String,_ b:String) throws -> String { try checked(AptosIdentity.add(checked(a),checked(b))) }
    public static func subtract(_ a:String,_ b:String) throws -> String {
        _ = try checked(a);_ = try checked(b)
        guard !less(a,b) else { throw ThorchainSendError.insufficientFunds }
        return try checked(StellarIdentity.sum(a,"-"+b))
    }
}
/// Immutable, locally reconstructed single-asset send. No swap/deposit or
/// contract execution is permitted through this payment authorization.
public struct ThorchainSendPlan: Codable, Sendable, Equatable {
    public let network:ThorchainSendNetwork
    public let sender:String,recipient:String,reference:String,memo:String
    public let publicKey:Data
    public let multisig: ThorchainMultisigPolicy?
    public let decimals:Int
    public let requestedAmount:String,amount:String,assetBalance:String,nativeBalance:String
    public let accountNumber:UInt64,sequence:UInt64,fee:UInt64,height:UInt64,timeoutHeight:UInt64
    public let createdAt:Date
    public static let gasLimit:UInt64=6_000_000
    public static let feeLimit:UInt64=100_000_000 // 1 RUNE quote guard; THORChain applies its protocol fee at execution.
    public var denom:String { reference == "native" ? "rune":reference }
    public var remaining:String { (try? ThorchainSendAmount.subtract(assetBalance,ThorchainSendAmount.add(amount,reference == "native" ? String(fee):"0"))) ?? "0" }
    public init(network:ThorchainSendNetwork,sender:String,recipient:String,reference:String,memo:String="",publicKey:Data,decimals:Int,requestedAmount:String,amount:String,assetBalance:String,nativeBalance:String,accountNumber:UInt64,sequence:UInt64,fee:UInt64,height:UInt64,timeoutHeight:UInt64,createdAt:Date = .now, multisig: ThorchainMultisigPolicy? = nil) {
        self.multisig = multisig
        self.network=network;self.sender=sender;self.recipient=recipient;self.reference=reference;self.memo=memo;self.publicKey=publicKey;self.decimals=decimals;self.requestedAmount=requestedAmount;self.amount=amount;self.assetBalance=assetBalance;self.nativeBalance=nativeBalance;self.accountNumber=accountNumber;self.sequence=sequence;self.fee=fee;self.height=height;self.timeoutHeight=timeoutHeight;self.createdAt=createdAt
    }
    public func validate(now:Date = .now,checkAge:Bool=true) throws {
        guard createdAt.timeIntervalSince1970.isFinite,createdAt.timeIntervalSince1970>0,height>0,height<UInt64(Int64.max)-60,
              timeoutHeight>height,timeoutHeight-height<=60,sequence<UInt64.max,
              (0...255).contains(decimals),memo.utf8.count<=250,!memo.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { throw ThorchainSendError.malformed }
        if checkAge,!(-5...90).contains(now.timeIntervalSince(createdAt)) { throw ThorchainSendError.expired }
        _ = try ThorchainSendCrypto.addressBytes(sender,network:network)
        _ = try ThorchainSendCrypto.addressBytes(recipient,network:network)
        if let multisig {
            try multisig.validate()
            guard publicKey == multisig.aminoPublicKey, multisig.address(network: network) == sender else { throw ThorchainSendError.wrongOwner }
        } else {
            guard try ThorchainSendCrypto.address(publicKey:publicKey,network:network)==sender else { throw ThorchainSendError.wrongOwner }
        }
        guard sender != recipient,try ThorchainIdentity.reference(reference)==reference,reference != "rune" else { throw ThorchainSendError.malformed }
        if ThorchainIdentity.hasProtocolDecimals(reference),decimals != 8 {throw ThorchainSendError.metadataChanged}
        guard fee>0,fee<=Self.feeLimit else { throw ThorchainSendError.feeTooHigh }
        for n in [requestedAmount,amount,assetBalance,nativeBalance] { _ = try ThorchainSendAmount.checked(n) }
        guard amount != "0",!ThorchainSendAmount.less(requestedAmount,amount),!ThorchainSendAmount.less(assetBalance,amount) else { throw ThorchainSendError.insufficientFunds }
        guard !ThorchainSendAmount.less(nativeBalance,String(fee)) else { throw SendFeeFundingError.insufficientNativeBalance }
        if reference == "native" {
            guard decimals==8,assetBalance==nativeBalance,!ThorchainSendAmount.less(nativeBalance,try ThorchainSendAmount.add(amount,String(fee))) else { throw ThorchainSendError.insufficientFunds }
        }
    }
}
public struct ThorchainSignedSend: Codable, Sendable, Equatable {
    public let bytes:Data,signature:Data
    public let hash:String
    public init(bytes:Data,signature:Data,hash:String) { self.bytes=bytes;self.signature=signature;self.hash=hash }
}
public struct ThorchainSendReceipt: Sendable, Equatable {
    public enum Outcome: String, Sendable { case unknown,accepted,confirmed,failed,expired,replaced }
    public let hash:String,outcome:Outcome
    public let fee:UInt64?,height:UInt64?,timestamp:Double?,replacementHash:String?
    public init(hash:String,outcome:Outcome,fee:UInt64?=nil,height:UInt64?=nil,timestamp:Double?=nil,replacementHash:String?=nil) { self.hash=hash;self.outcome=outcome;self.fee=fee;self.height=height;self.timestamp=timestamp;self.replacementHash=replacementHash }
}

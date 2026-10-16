import Foundation

public enum EVMSendError: Error, Sendable, Equatable {
    case configuration, malformed, wrongNetwork, wrongOwner, amount, insufficientFunds, metadataChanged
    case feeTooHigh, expired, changed, signing, busy, transport, http(Int), rpc(Int), simulationFailed, execution
}
/// Exact uint256 arithmetic, independent of token decimals and fiat display.
public enum EVMSendAmount {
    public static func checked(_ value:String) throws -> String {
        guard try AnkrQuantity.decimal(value)==value else { throw EVMSendError.amount }
        _ = try TronSendCrypto.uint256(value); return value
    }
    public static func less(_ a:String,_ b:String) -> Bool { a.count == b.count ? a<b : a.count<b.count }
    public static func add(_ a:String,_ b:String) throws -> String { _ = try checked(a); _ = try checked(b); return try checked(AptosIdentity.add(a,b)) }
    public static func subtract(_ a:String,_ b:String) throws -> String {
        _ = try checked(a); _ = try checked(b)
        guard !less(a,b) else { throw EVMSendError.insufficientFunds }
        return try checked(StellarIdentity.sum(a,"-"+b))
    }
    public static func multiply(_ a:String,_ b:String) throws -> String { try checked(AnkrQuantity.multiply(a,b)) }
    public static func hex(_ value:String) throws -> String {
        _ = try checked(value)
        let hex = TronSendCrypto.hex(try TronSendCrypto.uint256(value)).drop(while:{$0=="0"})
        return "0x"+(hex.isEmpty ? "0":String(hex))
    }
}

public struct EVMSendPlan: Codable, Sendable, Equatable {
    public let network: EVMSendNetwork
    public let sender:String, recipient:String, reference:String
    public let decimals:Int
    public let requestedAmount:String, amount:String, assetBalance:String, nativeBalance:String
    public let nonce:UInt64, gasLimit:UInt64, maxFeePerGas:UInt64, maxPriorityFeePerGas:UInt64, blockHeight:UInt64
    public let createdAt:Date
    public let legacy: Bool
    public let removal: EVMPermissionRemoval?
    public let call: EVMContractCall?
    public let extraFee: UInt64
    public static let maximumGas:UInt64 = 5_000_000
    public static let maximumFee:UInt64 = 1_000_000_000_000_000_000 // Safety ceiling in native atomic units, shown before authentication.
    // Validation establishes multiplication/subtraction bounds before these values are used.
    public var fee:UInt64 { gasLimit.multipliedReportingOverflow(by:maxFeePerGas).partialValue.addingReportingOverflow(extraFee).partialValue }
    public var remaining:String { StellarIdentity.sum(assetBalance,"-"+StellarIdentity.sum(amount,reference == "native" ? String(fee):"0")) }
    public var receiver:String { removal?.kind == .delegation ? EVMPermissionRemoval.zero:reference == "native" ? recipient:reference }
    public var value:String { reference == "native" ? amount:"0" }
    public init(network:EVMSendNetwork,sender:String,recipient:String,reference:String,decimals:Int,
                requestedAmount:String,amount:String,assetBalance:String,nativeBalance:String,nonce:UInt64,
                gasLimit:UInt64,maxFeePerGas:UInt64,maxPriorityFeePerGas:UInt64,blockHeight:UInt64,createdAt:Date = .now,legacy:Bool=false,extraFee:UInt64=0,removal:EVMPermissionRemoval?=nil,call:EVMContractCall?=nil) {
        self.network=network;self.sender=sender;self.recipient=recipient;self.reference=reference;self.decimals=decimals
        self.requestedAmount=requestedAmount;self.amount=amount;self.assetBalance=assetBalance;self.nativeBalance=nativeBalance
        self.nonce=nonce;self.gasLimit=gasLimit;self.maxFeePerGas=maxFeePerGas;self.maxPriorityFeePerGas=maxPriorityFeePerGas
        self.blockHeight=blockHeight;self.createdAt=createdAt;self.legacy=legacy;self.extraFee=extraFee;self.removal=removal;self.call=call
    }
    public func validate(now:Date = .now,checkAge:Bool=true) throws {
        guard createdAt.timeIntervalSince1970.isFinite,createdAt.timeIntervalSince1970>0 else { throw EVMSendError.malformed }
        if checkAge,!(-5...90).contains(now.timeIntervalSince(createdAt)) { throw EVMSendError.expired }
        guard try EVMSendIdentity.address(sender)==sender,try EVMSendIdentity.address(recipient)==recipient,
              (sender != recipient || removal?.kind == .delegation || call != nil),recipient != "0x"+String(repeating:"0",count:40),
              try EVMSendIdentity.reference(reference)==reference,(0...255).contains(decimals),nonce<UInt64.max,
              blockHeight>0,blockHeight<UInt64(Int64.max) else { throw EVMSendError.malformed }
        for n in [requestedAmount,amount,assetBalance,nativeBalance] { _ = try EVMSendAmount.checked(n) }
        let cost=gasLimit.multipliedReportingOverflow(by:maxFeePerGas)
        guard gasLimit>=21_000,gasLimit<=network.maximumGas,maxFeePerGas>0,maxPriorityFeePerGas<=maxFeePerGas,
              !cost.overflow,!cost.partialValue.addingReportingOverflow(extraFee).overflow,fee<=Self.maximumFee,
              (!legacy || maxPriorityFeePerGas==0), (network.oracle != nil || extraFee==0) else { throw EVMSendError.feeTooHigh }
        guard removal == nil || call == nil else { throw EVMSendError.changed }
        if let call {
            try call.validate()
            guard reference=="native",decimals==18,assetBalance==nativeBalance,requestedAmount==amount,
                  try !EVMSendAmount.less(nativeBalance,EVMSendAmount.add(amount,String(fee))) else { throw EVMSendError.insufficientFunds }
            return
        }
        if let removal {
            try removal.validate()
            guard reference=="native",decimals==18,recipient==removal.contract,amount=="0",requestedAmount=="0",
                  assetBalance==nativeBalance,!EVMSendAmount.less(nativeBalance,String(fee)) else { throw EVMSendError.changed }
            if removal.kind == .delegation {
                guard recipient==sender,nonce<UInt64.max-1,!legacy,gasLimit>=46_000 else {throw EVMSendError.changed}
            }
            return
        }
        guard amount != "0",!EVMSendAmount.less(requestedAmount,amount),!EVMSendAmount.less(assetBalance,amount),
              !EVMSendAmount.less(nativeBalance,String(fee)) else { throw EVMSendError.insufficientFunds }
        if reference == "native" {
            guard decimals==18,assetBalance==nativeBalance else { throw EVMSendError.metadataChanged }
            guard try !EVMSendAmount.less(nativeBalance,EVMSendAmount.add(amount,String(fee))) else { throw EVMSendError.insufficientFunds }
        }
    }
}
public struct EVMSignedSend: Codable, Sendable, Equatable {
    public let bytes:Data, signature:Data
    public let hash:String
    public let authorizationSignature:Data?
    public init(bytes:Data,signature:Data,hash:String,authorizationSignature:Data?=nil) { self.bytes=bytes;self.signature=signature;self.hash=hash;self.authorizationSignature=authorizationSignature }
}
public struct EVMSendReceipt: Sendable, Equatable {
    public enum Outcome:String,Sendable { case unknown, accepted, confirmed, failed, replaced, cancelled }
    public let hash:String, outcome:Outcome
    public let fee:UInt64?, height:UInt64?, timestamp:Double?, replacementHash:String?
    /// Actual recipient delivery from ERC-20 Transfer events. Execution status
    /// and delivered value are distinct: a transfer-tax token can succeed while
    /// delivering less than the amount authorized by the sender.
    public let deliveredAmount:String?
    public init(hash:String,outcome:Outcome,fee:UInt64?=nil,height:UInt64?=nil,timestamp:Double?=nil,replacementHash:String?=nil,deliveredAmount:String?=nil) {
        self.hash=hash;self.outcome=outcome;self.fee=fee;self.height=height;self.timestamp=timestamp;self.replacementHash=replacementHash;self.deliveredAmount=deliveredAmount
    }
}

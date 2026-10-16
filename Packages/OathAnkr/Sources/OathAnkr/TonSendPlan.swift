import Foundation

public enum TonSendError: Error, Sendable, Equatable {
    case configuration, malformed, wrongNetwork, wrongOwner, amount, insufficientFunds, metadataChanged
    case feeTooHigh, expired, changed, signing, busy, transport, http(Int), rpc(Int), simulationFailed, execution
}
public enum TonSendNetwork: String, Codable, Sendable {
    case mainnet, testnet
    public var indexURL: URL { URL(string: self == .mainnet ? "https://tonapi.io/v2/":"https://testnet.tonapi.io/v2/")! }
    public func address(_ value:String) throws -> String {
        if self == .testnet, value.count==48, var data=TonIdentity.base64(value),data.count==36,data[0]&0x80 != 0 {
            guard TonIdentity.crc16(Data(data.prefix(34)))==Array(data.suffix(2)) else { throw TonSendError.malformed }
            data[0] &= 0x7f; data=Data(data.prefix(34));data += TonIdentity.crc16(data)
            return try TonIdentity.raw(data.base64EncodedString())
        }
        return try TonIdentity.raw(value)
    }
}
/// Exact V4R2 authorization. Gas is paid in GRAM, including for Jettons. No
/// remote signing payload, contract code, or arbitrary destination is accepted.
public struct TonSendPlan: Codable, Sendable, Equatable {
    public let network:TonSendNetwork
    public let sender:String,recipient:String,reference:String
    public let publicKey:Data
    public let decimals:Int
    public let requestedAmount:TonAmount,amount:TonAmount,assetBalance:TonAmount,nativeBalance:UInt64
    public let sequence:UInt32,expiration:UInt32
    public let deploy:Bool,bounce:Bool
    public let fee:UInt64,feeReserve:UInt64,attached:UInt64
    public let jettonWallet:String?,recipientJettonWallet:String?
    public let queryID:UInt64
    public let memo:String
    public let createdAt:Date
    public var remaining:TonAmount { assetBalance-amount-(reference=="native" ? feeReserve:0) }
    public static let walletID:UInt64=698983191
    public init(network:TonSendNetwork,sender:String,recipient:String,reference:String,publicKey:Data,decimals:Int,requestedAmount:TonAmount,amount:TonAmount,assetBalance:TonAmount,nativeBalance:UInt64,sequence:UInt32,expiration:UInt32,deploy:Bool,bounce:Bool,fee:UInt64,feeReserve:UInt64,attached:UInt64,jettonWallet:String?=nil,recipientJettonWallet:String?=nil,queryID:UInt64=0,memo:String="",createdAt:Date = .now) {
        self.network=network;self.sender=sender;self.recipient=recipient;self.reference=reference;self.publicKey=publicKey;self.decimals=decimals;self.requestedAmount=requestedAmount;self.amount=amount;self.assetBalance=assetBalance;self.nativeBalance=nativeBalance;self.sequence=sequence;self.expiration=expiration;self.deploy=deploy;self.bounce=bounce;self.fee=fee;self.feeReserve=feeReserve;self.attached=attached;self.jettonWallet=jettonWallet;self.recipientJettonWallet=recipientJettonWallet;self.queryID=queryID;self.memo=memo;self.createdAt=createdAt
    }
    public func validate(now:Date = .now,checkAge:Bool=true) throws {
        guard createdAt.timeIntervalSince1970.isFinite,createdAt.timeIntervalSince1970>0,
              (60...600).contains(Double(expiration)-createdAt.timeIntervalSince1970),sequence<UInt32.max else { throw TonSendError.malformed }
        if checkAge, !(-5...90).contains(now.timeIntervalSince(createdAt)) || Double(expiration)<=now.timeIntervalSince1970+5 { throw TonSendError.expired }
        guard try TonIdentity.raw(sender)==sender,try TonIdentity.raw(recipient)==recipient,sender != recipient,
              sender.hasPrefix("0:"),recipient.hasPrefix("0:"),publicKey.count==32,
              try TonSendCrypto.address(publicKey:publicKey)==sender,memo.utf8.count<=120,(0...255).contains(decimals),!deploy || sequence==0 else { throw TonSendError.wrongOwner }
        guard fee>0,fee<=feeReserve,feeReserve<=500_000_000,feeReserve<=nativeBalance else { throw TonSendError.feeTooHigh }
        guard amount>0,amount<=requestedAmount,amount<=assetBalance else { throw TonSendError.insufficientFunds }
        if reference=="native" {
            guard decimals==9,assetBalance==TonAmount(nativeBalance),amount<=TonAmount(nativeBalance-feeReserve),TonAmount(attached)==amount,jettonWallet==nil,recipientJettonWallet==nil else { throw TonSendError.insufficientFunds }
        } else {
            guard try TonIdentity.raw(reference)==reference,let jettonWallet,let recipientJettonWallet,
                  try TonIdentity.raw(jettonWallet)==jettonWallet,try TonIdentity.raw(recipientJettonWallet)==recipientJettonWallet,
                  attached>=50_000_000,attached<=300_000_000,bounce,attached<=nativeBalance-feeReserve else { throw TonSendError.insufficientFunds }
        }
    }
}
public struct TonSignedSend:Codable,Sendable,Equatable {
    public let bytes:Data,signature:Data
    /// Normalized external message hash (TEP-467); available before inclusion.
    public let hash:String,bodyHash:String
    public init(bytes:Data,signature:Data,hash:String,bodyHash:String) { self.bytes=bytes;self.signature=signature;self.hash=hash;self.bodyHash=bodyHash }
}
public struct TonSendReceipt:Sendable,Equatable {
    public enum Outcome:String,Sendable { case unknown,accepted,confirmed,failed,expired }
    public let hash:String,outcome:Outcome
    public let transactionHash:String?,fee:UInt64?,lt:Int64?,timestamp:Double?
    public init(hash:String,outcome:Outcome,transactionHash:String?=nil,fee:UInt64?=nil,lt:Int64?=nil,timestamp:Double?=nil) { self.hash=hash;self.outcome=outcome;self.transactionHash=transactionHash;self.fee=fee;self.lt=lt;self.timestamp=timestamp }
}

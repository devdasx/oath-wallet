import Foundation

public enum NearSendError: Error, Sendable, Equatable {
    case configuration, malformed, wrongNetwork, wrongOwner, amount, insufficientFunds, recipientMissing
    case unsupportedAccount, metadataChanged, storageUnsupported, storageFunds, feeTooHigh, expired, changed, signing, busy
    case transport, http(Int), rpc(Int), execution
}
public enum NearSendNetwork: String, Codable, Sendable {
    case mainnet, testnet
    public var endpoint: URL { URL(string: "https://rpc.\(rawValue).near.org")! }
}

/// All balances are exact decimal u128 strings. Decimal/Double must never round a signed amount.
public enum NearSendAmount {
    public static func checked(_ s: String) throws -> String {
        guard try NearIdentity.amount(.string(s)) == s else { throw NearSendError.amount }; return s
    }
    public static func add(_ a: String, _ b: String) throws -> String { try checked(AptosIdentity.add(a,b)) }
    public static func subtract(_ a: String, _ b: String) throws -> String {
        guard !XrplSendAmount.less(a,b) else { throw NearSendError.insufficientFunds }
        return try checked(StellarIdentity.sum(a,"-"+b))
    }
    public static func multiply(_ a: String, _ b: UInt64) throws -> String {
        _ = try checked(a)
        var n=b, value=a, result="0"
        while n>0 { if n&1 == 1 { result=try add(result,value) }; n>>=1; if n>0 { value=try add(value,value) } }
        return result
    }
}

public struct NearSendPlan: Codable, Sendable, Equatable {
    public let network: NearSendNetwork
    public let sender: String, recipient: String, reference: String
    public let publicKey: Data
    public let decimals: Int
    public let requestedAmount: String, amount: String, assetBalance: String, nativeBalance: String
    public let reserve: String, storageDeposit: String, fee: String, gasPriceCeiling: String
    public let gas: UInt64, storageGas: UInt64, nonce: UInt64
    public let blockHash: String, blockHeight: UInt64, validityPeriod: UInt64
    public let createdAt: Date
    public var receiver: String { reference == "native" ? recipient : reference }
    public var remaining: String { StellarIdentity.sum(assetBalance,"-"+(reference == "native" ? StellarIdentity.sum(amount,fee):amount)) }
    public var nativeDebit: String { reference == "native" ? StellarIdentity.sum(amount,fee) : StellarIdentity.sum(StellarIdentity.sum(storageDeposit,"1"),fee) }
    public static let maximumFee = "1000000000000000000000000" // 1 NEAR; reject unexpected provider costs.
    public static let maximumStorage = "1000000000000000000000000"

    public init(network: NearSendNetwork, sender: String, recipient: String, reference: String, publicKey: Data,
                decimals: Int, requestedAmount: String, amount: String, assetBalance: String, nativeBalance: String,
                reserve: String, storageDeposit: String, fee: String, gasPriceCeiling: String, gas: UInt64, storageGas: UInt64,
                nonce: UInt64, blockHash: String, blockHeight: UInt64, validityPeriod: UInt64, createdAt: Date = .now) {
        self.network=network; self.sender=sender; self.recipient=recipient; self.reference=reference; self.publicKey=publicKey
        self.decimals=decimals; self.requestedAmount=requestedAmount; self.amount=amount; self.assetBalance=assetBalance
        self.nativeBalance=nativeBalance; self.reserve=reserve; self.storageDeposit=storageDeposit; self.fee=fee
        self.gasPriceCeiling=gasPriceCeiling; self.gas=gas; self.storageGas=storageGas; self.nonce=nonce
        self.blockHash=blockHash; self.blockHeight=blockHeight; self.validityPeriod=validityPeriod; self.createdAt=createdAt
    }
    public func validate(now: Date = .now, checkAge: Bool = true) throws {
        if checkAge, !(-5...90).contains(now.timeIntervalSince(createdAt)) { throw NearSendError.expired }
        guard try NearIdentity.address(sender)==sender, try NearIdentity.address(recipient)==recipient,
              sender != recipient, sender != "system", recipient != "system",
              try NearIdentity.reference(reference)==reference, publicKey.count==32, (0...255).contains(decimals),
              nonce>0, blockHeight>0, validityPeriod>0, validityPeriod<=1_000_000,
              blockHeight<=UInt64.max-validityPeriod, SolanaIdentity.isAddress(blockHash) else { throw NearSendError.malformed }
        for n in [requestedAmount,amount,assetBalance,nativeBalance,reserve,storageDeposit,fee,gasPriceCeiling] { _ = try NearSendAmount.checked(n) }
        guard amount != "0", fee != "0", gasPriceCeiling != "0",
              !XrplSendAmount.less(assetBalance,amount), !XrplSendAmount.less(requestedAmount,amount),
              !XrplSendAmount.less(Self.maximumFee,fee), !XrplSendAmount.less(Self.maximumStorage,storageDeposit) else { throw NearSendError.amount }
        if Self.isImplicit(sender) { guard TronSendCrypto.hex(publicKey)==sender else { throw NearSendError.wrongOwner } }
        if reference == "native" {
            guard decimals==24, assetBalance==nativeBalance, storageDeposit=="0", gas==0, storageGas==0 else { throw NearSendError.changed }
        } else {
            guard reference != "system", gas==50_000_000_000_000,
                  storageGas==(storageDeposit=="0" ? 0:30_000_000_000_000) else { throw NearSendError.changed }
        }
        let spendable=try NearSendAmount.subtract(nativeBalance,reserve)
        guard !XrplSendAmount.less(spendable,nativeDebit) else { throw NearSendError.insufficientFunds }
    }
    public static func isImplicit(_ s:String) -> Bool { s.count==64 && s.utf8.allSatisfy { (48...57).contains($0)||(97...102).contains($0) } }
}
public struct NearSignedSend: Codable, Sendable, Equatable {
    public let bytes: Data, publicKey: Data, signature: Data
    public let hash: String
    public init(bytes:Data,publicKey:Data,signature:Data,hash:String) { self.bytes=bytes; self.publicKey=publicKey; self.signature=signature; self.hash=hash }
}
public struct NearSendReceipt: Sendable, Equatable {
    public enum Outcome: String, Sendable { case unknown, accepted, confirmed, failed, expired }
    public let hash: String, outcome: Outcome
    public let fee: String?, block: UInt64?
    public init(hash:String,outcome:Outcome,fee:String?=nil,block:UInt64?=nil) { self.hash=hash; self.outcome=outcome; self.fee=fee; self.block=block }
}

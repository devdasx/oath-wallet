import Foundation

public enum StellarSendError: Error, Sendable, Equatable {
    case recipientMinimum(UInt64)
    case configuration, malformed, wrongNetwork, wrongOwner, amount, insufficientFunds, reserve, memoRequired
    case memoUnsupported, recipientUnfunded, trustline, restricted, unsupportedAccount, feeTooHigh, expired, changed, signing, busy
    case transport, http(Int), rpc(Int), simulation, execution, restoreRequired
}
public enum StellarSendNetwork: String, Codable, Sendable {
    case mainnet, testnet
    public var passphrase: String { self == .mainnet ? StellarIdentity.network : "Test SDF Network ; September 2015" }
    public var horizon: URL { URL(string:self == .mainnet ? "https://horizon.stellar.org":"https://horizon-testnet.stellar.org")! }
    public var rpc: URL { URL(string:self == .mainnet ? "https://soroban-rpc.mainnet.stellar.gateway.fm":"https://soroban-testnet.stellar.org")! }
}
public enum StellarSendMemoType: String, Codable, Sendable, CaseIterable { case text, id, hash, returnHash }
public struct StellarSendMemo: Codable, Sendable, Equatable {
    public let type: StellarSendMemoType
    public let value: String
    public init(type: StellarSendMemoType = .text, value: String = "") { self.type = type; self.value = value }
    public func validate() throws {
        if value.isEmpty { return }
        switch type {
        case .text: guard value.utf8.count <= 28, !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw StellarSendError.amount }
        case .id: guard value.utf8.allSatisfy({(48...57).contains($0)}), UInt64(value) != nil else { throw StellarSendError.amount }
        case .hash,.returnHash: guard value.count == 64, (try? TronIdentity.hex(value))?.count == 32 else { throw StellarSendError.amount }
        }
    }
}
public struct StellarSendPlan: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case payment, createAccount, contract, configureMultisig, changeTrust }
    public let multisig: StellarMultisigPolicy?
    public var configuresAccount: Bool { kind == .configureMultisig || kind == .changeTrust }
    public let network: StellarSendNetwork, kind: Kind
    public let sender: String, recipient: String, reference: String
    public let assetCode: String?, issuer: String?
    public let decimals: Int, memo: StellarSendMemo
    public let requestedAmount: String, amount: String, assetBalance: String
    public let nativeBalance: UInt64, reserve: UInt64, nativeLiabilities: UInt64, fee: UInt32
    public let recipientReserve: UInt64?
    public let sequence: Int64, firstLedger: UInt32, lastLedger: UInt32, maxTime: UInt64
    public let sorobanData: Data?, authorization: [Data]
    public let createdAt: Date
    public static let maximumFee: UInt32 = 10_000_000 // Bound the reviewed maximum to 1 XLM.
    public var adjusted: Bool { amount != requestedAmount }
    public var remaining: String { StellarIdentity.sum(StellarIdentity.sum(assetBalance,"-"+amount),reference == "native" ? "-"+String(fee):"0") }
    public init(network: StellarSendNetwork, kind: Kind = .payment, sender: String, recipient: String, reference: String,
                assetCode: String? = nil, issuer: String? = nil, decimals: Int = 7, memo: StellarSendMemo = .init(),
                requestedAmount: String, amount: String, assetBalance: String, nativeBalance: UInt64, reserve: UInt64,
                nativeLiabilities: UInt64 = 0, fee: UInt32, sequence: Int64, firstLedger: UInt32, lastLedger: UInt32,
                maxTime: UInt64, sorobanData: Data? = nil, authorization: [Data] = [], createdAt: Date = .now, recipientReserve: UInt64? = nil, multisig: StellarMultisigPolicy? = nil) {
        self.multisig = multisig
        self.network=network;self.kind=kind;self.sender=sender;self.recipient=recipient;self.reference=reference
        self.assetCode=assetCode;self.issuer=issuer;self.decimals=decimals;self.memo=memo
        self.requestedAmount=requestedAmount;self.amount=amount;self.assetBalance=assetBalance
        self.nativeBalance=nativeBalance;self.reserve=reserve;self.nativeLiabilities=nativeLiabilities;self.fee=fee
        self.sequence=sequence;self.firstLedger=firstLedger;self.lastLedger=lastLedger;self.maxTime=maxTime
        self.sorobanData=sorobanData;self.authorization=authorization;self.createdAt=createdAt
        self.recipientReserve=recipientReserve
    }
    public func validate(now: Date = .now, checkAge: Bool = true) throws {
        if checkAge { guard (-5...90).contains(now.timeIntervalSince(createdAt)), now.timeIntervalSince1970 < Double(maxTime) else { throw StellarSendError.expired } }
        guard try StellarIdentity.address(sender) == sender, try StellarIdentity.address(recipient) == recipient, (sender != recipient || configuresAccount),
              try StellarIdentity.reference(reference) == reference, (0...255).contains(decimals), sequence > 0,
              firstLedger > 0, lastLedger > firstLedger, lastLedger-firstLedger <= 30,
              fee > 0, fee <= Self.maximumFee, nativeBalance <= UInt64(Int64.max), reserve <= nativeBalance,
              nativeLiabilities <= nativeBalance-reserve, UInt64(fee) <= nativeBalance-reserve-nativeLiabilities,
              maxTime > UInt64(max(0,createdAt.timeIntervalSince1970)), Double(maxTime)-createdAt.timeIntervalSince1970 <= 180 else { throw StellarSendError.malformed }
        try memo.validate()
        if let multisig { try multisig.validate(); guard multisig.account == sender else { throw StellarSendError.wrongOwner } }
        if configuresAccount {
            guard multisig != nil, recipient == sender, amount == "0", requestedAmount == "0", decimals == 7,
                  memo.value.isEmpty, sorobanData == nil, authorization.isEmpty else { throw StellarSendError.changed }
            if kind == .configureMultisig {
                guard reference == "native", assetCode == nil, issuer == nil else { throw StellarSendError.changed }
            } else {
                guard let assetCode, let issuer, issuer != sender,
                      try StellarIdentity.contract(code: assetCode, issuer: issuer, network: network.passphrase) == reference else { throw StellarSendError.changed }
            }
            return
        }
        for v in [amount,requestedAmount,assetBalance] { guard try StellarIdentity.uint(v) == v else { throw StellarSendError.amount } }
        guard amount != "0", !XrplSendAmount.less(assetBalance,amount), !XrplSendAmount.less(requestedAmount,amount) else { throw StellarSendError.insufficientFunds }
        if reference == "native" {
            guard kind != .contract, decimals == 7, assetCode == nil, issuer == nil, assetBalance == String(nativeBalance),
                  let v = UInt64(amount), v <= nativeBalance-reserve-nativeLiabilities-UInt64(fee) else { throw StellarSendError.reserve }
        } else if kind == .payment {
            guard let assetCode, let issuer, decimals == 7, Int64(amount) != nil,
                  try StellarIdentity.contract(code:assetCode,issuer:issuer,network:network.passphrase) == reference else { throw StellarSendError.malformed }
        } else { guard kind == .contract, assetCode == nil, issuer == nil else { throw StellarSendError.malformed } }
        if kind != .contract { guard sorobanData == nil, authorization.isEmpty else { throw StellarSendError.changed } }
        else if !memo.value.isEmpty { throw StellarSendError.memoUnsupported }
        else if let sorobanData {
            guard sorobanData.count >= 32, sorobanData.count <= 131_072, sorobanData.count % 4 == 0,
                  try StellarSendXDR.resourceFee(sorobanData) < UInt64(fee), authorization.count <= 1 else { throw StellarSendError.changed }
            let expected = try StellarSendXDR.sourceAuthorization(reference:reference,sender:sender,recipient:recipient,amount:amount)
            guard authorization == [expected] else { throw StellarSendError.restricted }
        } else { guard authorization.isEmpty else { throw StellarSendError.changed } }
    }
}
public struct StellarSignedSend: Codable, Sendable, Equatable {
    public let signatures: [StellarMultisigSignature]?
    public let bytes: Data, publicKey: Data, signature: Data
    public let hash: String
    public init(bytes: Data, publicKey: Data, signature: Data, hash: String, signatures: [StellarMultisigSignature]? = nil) { self.signatures = signatures; self.bytes=bytes;self.publicKey=publicKey;self.signature=signature;self.hash=hash }
}
public struct StellarSendReceipt: Sendable, Equatable {
    public enum Outcome: String, Sendable { case unknown, accepted, confirmed, failed, expired }
    public let hash: String, outcome: Outcome
    public let fee: UInt64?, ledger: UInt32?
    public init(hash:String,outcome:Outcome,fee:UInt64? = nil,ledger:UInt32? = nil) { self.hash=hash;self.outcome=outcome;self.fee=fee;self.ledger=ledger }
}

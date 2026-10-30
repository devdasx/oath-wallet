import Foundation

public enum SolanaSendError: Error, Sendable, Equatable {
    case recipientMinimum(UInt64), accountRent, storageBalance, multisigFunding
    case configuration, malformed, wrongNetwork, wrongOwner, amount, insufficientFunds, metadataChanged
    case unsupportedToken, frozen, feeTooHigh, expired, changed, signing, busy, transport, http(Int), rpc(Int), simulationFailed, execution
}
public enum SolanaSendNetwork: String, Codable, Sendable {
    case mainnet, testnet, devnet
    public var endpoint: URL { URL(string: "https://api.\(self == .mainnet ? "mainnet-beta" : rawValue).solana.com")! }
    public var genesis: String {
        switch self {
        case .mainnet: SolanaIdentity.genesis
        case .testnet: "4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY"
        case .devnet: "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"
        }
    }
}
public struct SolanaSendSource: Codable, Sendable, Equatable {
    public let address: String, amount: UInt64
    public init(address:String,amount:UInt64) { self.address=address;self.amount=amount }
}
/// Immutable local instructions, exact u64 units, selected derivation owner and
/// blockhash lifetime. A provider never supplies opaque bytes to the signer.
public struct SolanaSendPlan: Codable, Sendable, Equatable {
    public let network: SolanaSendNetwork
    public let sender: String, recipient: String, reference: String, program: String
    public let decimals: Int
    public let requestedAmount: UInt64, amount: UInt64, assetBalance: UInt64, nativeBalance: UInt64
    public let blockhash: String, lastValidBlockHeight: UInt64, slot: UInt64
    public let transactionFee: UInt64, rent: UInt64, computeUnits: UInt32, microLamports: UInt64
    public let recipientReserve: UInt64?
    public let sources: [SolanaSendSource]
    public let tokenFees: [UInt64]
    public let memo: String
    public let paymentReferences: [String]?
    public let removal: SolanaPermissionRemoval?
    public let multisig: SolanaMultisigContext?
    public let createdAt: Date
    public var fee: UInt64 { transactionFee + rent + (multisig?.storageRent ?? 0) }
    public var remaining: UInt64 { assetBalance - amount - (reference == "native" ? (multisig == nil ? fee : rent) : 0) }
    public var receivedAmount: UInt64 { amount - tokenFees.reduce(0,+) }
    public init(network:SolanaSendNetwork,sender:String,recipient:String,reference:String="native",program:String="",decimals:Int=9,
                requestedAmount:UInt64,amount:UInt64,assetBalance:UInt64,nativeBalance:UInt64,blockhash:String,lastValidBlockHeight:UInt64,slot:UInt64,
                transactionFee:UInt64,rent:UInt64=0,computeUnits:UInt32=200_000,microLamports:UInt64=0,
                sources:[SolanaSendSource]=[],tokenFees:[UInt64]=[],memo:String="",createdAt:Date = .now,removal:SolanaPermissionRemoval?=nil,recipientReserve:UInt64?=nil,multisig:SolanaMultisigContext?=nil,paymentReferences:[String]=[]) {
        self.network=network;self.sender=sender;self.recipient=recipient;self.reference=reference;self.program=program;self.decimals=decimals
        self.requestedAmount=requestedAmount;self.amount=amount;self.assetBalance=assetBalance;self.nativeBalance=nativeBalance
        self.blockhash=blockhash;self.lastValidBlockHeight=lastValidBlockHeight;self.slot=slot;self.transactionFee=transactionFee;self.rent=rent
        self.computeUnits=computeUnits;self.microLamports=microLamports;self.sources=sources;self.tokenFees=tokenFees;self.memo=memo;self.createdAt=createdAt;self.removal=removal
        self.recipientReserve=recipientReserve; self.multisig=multisig
        self.paymentReferences = paymentReferences.isEmpty ? nil : paymentReferences
    }
    public func validate(now:Date = .now,checkAge:Bool=true) throws {
        guard createdAt.timeIntervalSince1970.isFinite,createdAt.timeIntervalSince1970>0 else { throw SolanaSendError.malformed }
        if checkAge,!(-5...45).contains(now.timeIntervalSince(createdAt)) { throw SolanaSendError.expired }
        guard SolanaIdentity.isAddress(sender),SolanaIdentity.isAddress(recipient),(sender != recipient || multisig?.setupTreasury != nil),
              recipient != SolanaSendCrypto.system,SolanaIdentity.isAddress(blockhash),lastValidBlockHeight>0,slot>0,
              (0...255).contains(decimals),memo.utf8.count<=128 else { throw SolanaSendError.malformed }
        let references = paymentReferences ?? []
        guard references.count <= 8, references.allSatisfy(SolanaIdentity.isAddress),
              references.isEmpty || (removal == nil && multisig?.setupTreasury == nil) else { throw SolanaSendError.malformed }
        guard (1...1_400_000).contains(computeUnits),microLamports<=1_000_000,transactionFee>0,transactionFee<=10_000_000,rent<=100_000_000 else { throw SolanaSendError.feeTooHigh }
        if let context = multisig {
            try context.policy.validate()
            guard removal == nil, network != .testnet, sender == (try context.policy.vault),
                  context.policy.members.contains(context.payer),
                  context.storageRent <= 100_000_000 else { throw SolanaSendError.changed }
            guard context.payerBalance >= transactionFee + context.storageRent else { throw SolanaSendError.multisigFunding }
            if let treasury = context.setupTreasury {
                guard SolanaIdentity.isAddress(treasury), context.index == 0, sender == recipient,
                      reference == "native", program.isEmpty, decimals == 9, amount == 0, requestedAmount == 0,
                      assetBalance == nativeBalance, sources.isEmpty, tokenFees.isEmpty, memo.isEmpty, rent == 0 else { throw SolanaSendError.changed }
                return
            }
            guard context.index > 0, context.index < UInt64.max else { throw SolanaSendError.changed }
        }
        if let removal {
            try removal.validate()
            guard reference=="native",decimals==9,program.isEmpty,sources.isEmpty,tokenFees.isEmpty,memo.isEmpty,rent==0,
                  recipient==removal.account,amount==0,requestedAmount==0,assetBalance==nativeBalance,fee<=nativeBalance else { throw SolanaSendError.changed };return
        }
        guard amount>0,amount<=requestedAmount,requestedAmount<=assetBalance else { throw SolanaSendError.insufficientFunds }
        if multisig == nil { guard fee<=nativeBalance else { throw SendFeeFundingError.insufficientNativeBalance } }
        else { guard rent<=nativeBalance else { throw SolanaSendError.accountRent } }
        if reference=="native" {
            guard decimals==9,program.isEmpty,sources.isEmpty,tokenFees.isEmpty,rent==0,assetBalance==nativeBalance,amount<=nativeBalance-(multisig == nil ? fee : rent) else { throw SolanaSendError.insufficientFunds }
        } else {
            guard SolanaIdentity.isAddress(reference),[SolanaIdentity.tokenProgram,SolanaIdentity.token2022Program].contains(program),
                  (1...12).contains(sources.count),Set(sources.map(\.address)).count==sources.count,
                  tokenFees.isEmpty || (program==SolanaIdentity.token2022Program && tokenFees.count==sources.count) else { throw SolanaSendError.malformed }
            var sum:UInt64=0
            for (i,s) in sources.enumerated() {
                guard SolanaIdentity.isAddress(s.address),s.amount>0,s.amount<=amount-sum,tokenFees.isEmpty || tokenFees[i]<=s.amount else { throw SolanaSendError.malformed }
                sum+=s.amount
            }
            guard sum==amount else { throw SolanaSendError.malformed }
        }
    }
}
public struct SolanaSignedSend: Codable, Sendable, Equatable {
    public let bytes:Data, publicKey:Data, signature:Data
    public let hash:String
    public let preparations:[SolanaSignedStage]?
    public init(bytes:Data,publicKey:Data,signature:Data,hash:String,preparations:[SolanaSignedStage]?=nil) { self.bytes=bytes;self.publicKey=publicKey;self.signature=signature;self.hash=hash;self.preparations=preparations }
}
public struct SolanaSendReceipt: Sendable, Equatable {
    public enum Outcome:String,Sendable { case unknown, accepted, confirmed, failed, expired }
    public let hash:String, outcome:Outcome
    public let fee:UInt64?, slot:UInt64?, timestamp:Double?
    public init(hash:String,outcome:Outcome,fee:UInt64?=nil,slot:UInt64?=nil,timestamp:Double?=nil) { self.hash=hash;self.outcome=outcome;self.fee=fee;self.slot=slot;self.timestamp=timestamp }
}

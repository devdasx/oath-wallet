import Foundation

public enum EVMSendError: Error, Sendable, Equatable {
    case configuration, malformed, wrongNetwork, wrongOwner, amount, insufficientFunds, metadataChanged
    case feeTooHigh, expired, changed, signing, busy, transport, http(Int), rpc(Int), simulationFailed, execution
    case multisigSetupRequired, multisigFunding, sameRecipient
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

/// Public spending commitments from the durable signed-send journal. No signed
/// bytes or signing secrets are needed to prepare the next independent send.
public struct EVMSendReservation: Codable, Sendable, Equatable {
    public let network: EVMSendNetwork
    public let sender: String, hash: String, reference: String, amount: String, nativeCost: String
    public let nonce: UInt64, lastNonce: UInt64
    public let requiresPendingState: Bool

    public init(plan: EVMSendPlan, hash: String) throws {
        try plan.validate(checkAge: false)
        guard AnkrQuantity.hash(hash) else { throw EVMSendError.changed }
        network=plan.network; sender=plan.sender; self.hash=hash.lowercased()
        reference=plan.reference; amount=plan.amount
        nonce=plan.nonce; lastNonce=plan.nonce + (plan.removal?.kind == .delegation ? 1:0)
        nativeCost=try EVMSendAmount.add(plan.value,plan.multisig == nil ? String(plan.fee):"0")
        // Arbitrary contract effects cannot be inferred from a selector. The
        // provider must have applied that predecessor to its pending state.
        requiresPendingState=plan.multisig != nil || (plan.call.map { !$0.bytes.isEmpty } ?? false)
    }

    func validate(network: EVMSendNetwork, sender: String) throws {
        guard self.network==network,self.sender==sender,AnkrQuantity.hash(hash),
              nonce<UInt64.max,lastNonce>=nonce,lastNonce<UInt64.max,lastNonce-nonce<=1,
              try EVMSendIdentity.reference(reference)==reference else { throw EVMSendError.changed }
        _ = try EVMSendAmount.checked(amount); _ = try EVMSendAmount.checked(nativeCost)
        if reference=="native",EVMSendAmount.less(nativeCost,amount) { throw EVMSendError.changed }
    }
}

/// Captures what was already committed when the user reviewed a quote. Optional
/// on old persisted plans, so existing signed transactions remain recoverable.
public struct EVMSendPendingState: Codable, Sendable, Equatable {
    public let confirmedNonce: UInt64
    public let reservations: [EVMSendReservation]
    public init(confirmedNonce: UInt64, reservations: [EVMSendReservation]) {
        self.confirmedNonce=confirmedNonce
        self.reservations=reservations.sorted { $0.nonce<$1.nonce }
    }
    func validate(network: EVMSendNetwork, sender: String) throws {
        guard confirmedNonce<UInt64.max,reservations.count<=128 else { throw EVMSendError.changed }
        var last: UInt64?
        var hashes=Set<String>()
        for row in reservations {
            try row.validate(network:network,sender:sender)
            guard row.nonce>=confirmedNonce,last.map({$0<row.nonce}) ?? true,
                  hashes.insert(row.hash).inserted else { throw EVMSendError.changed }
            last=row.lastNonce
        }
    }
    func nextNonce(confirmed: UInt64, pending: UInt64) throws -> UInt64 {
        guard confirmed>=confirmedNonce,pending>=confirmed,pending<UInt64.max else { throw EVMSendError.changed }
        var next=pending
        for row in reservations where row.lastNonce>=confirmed {
            // Never skip a missing nonce or partially consumed authorization.
            guard row.nonce>=confirmed,row.nonce<=next else { throw EVMSendError.changed }
            if row.requiresPendingState,row.lastNonce>=pending { throw EVMSendError.busy }
            next=max(next,row.lastNonce+1)
        }
        guard next<UInt64.max else { throw EVMSendError.changed }
        return next
    }
    func balances(native: String, asset: String, reference: String, confirmed: UInt64) throws -> (native: String, asset: String) {
        var nativeReserved="0",assetReserved="0"
        for row in reservations where row.lastNonce>=confirmed {
            nativeReserved=try EVMSendAmount.add(nativeReserved,row.nativeCost)
            if reference != "native",row.reference==reference {
                assetReserved=try EVMSendAmount.add(assetReserved,row.amount)
            }
        }
        let available=try EVMSendAmount.subtract(native,nativeReserved)
        return (available,reference=="native" ? available:try EVMSendAmount.subtract(asset,assetReserved))
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
    public let pendingState: EVMSendPendingState?
    public let multisig: EVMMultisigContext?
    public static let maximumGas:UInt64 = 5_000_000
    public static let maximumFee:UInt64 = 1_000_000_000_000_000_000 // Safety ceiling in native atomic units, shown before authentication.
    // Validation establishes multiplication/subtraction bounds before these values are used.
    public var fee:UInt64 { gasLimit.multipliedReportingOverflow(by:maxFeePerGas).partialValue.addingReportingOverflow(extraFee).partialValue }
    public var remaining:String { StellarIdentity.sum(assetBalance,"-"+StellarIdentity.sum(amount,reference == "native" && multisig == nil ? String(fee):"0")) }
    public var receiver:String { removal?.kind == .delegation ? EVMPermissionRemoval.zero:reference == "native" ? recipient:reference }
    public var value:String { reference == "native" ? amount:"0" }
    public init(network:EVMSendNetwork,sender:String,recipient:String,reference:String,decimals:Int,
                requestedAmount:String,amount:String,assetBalance:String,nativeBalance:String,nonce:UInt64,
                gasLimit:UInt64,maxFeePerGas:UInt64,maxPriorityFeePerGas:UInt64,blockHeight:UInt64,createdAt:Date = .now,legacy:Bool=false,extraFee:UInt64=0,removal:EVMPermissionRemoval?=nil,call:EVMContractCall?=nil,pendingState:EVMSendPendingState?=nil,multisig:EVMMultisigContext?=nil) {
        self.network=network;self.sender=sender;self.recipient=recipient;self.reference=reference;self.decimals=decimals
        self.requestedAmount=requestedAmount;self.amount=amount;self.assetBalance=assetBalance;self.nativeBalance=nativeBalance
        self.nonce=nonce;self.gasLimit=gasLimit;self.maxFeePerGas=maxFeePerGas;self.maxPriorityFeePerGas=maxPriorityFeePerGas
        self.blockHeight=blockHeight;self.createdAt=createdAt;self.legacy=legacy;self.extraFee=extraFee;self.removal=removal;self.call=call
        self.pendingState=pendingState; self.multisig=multisig
    }
    public func validate(now:Date = .now,checkAge:Bool=true) throws {
        guard createdAt.timeIntervalSince1970.isFinite,createdAt.timeIntervalSince1970>0 else { throw EVMSendError.malformed }
        if checkAge {
            let age = now.timeIntervalSince(createdAt)
            guard age.isFinite else { throw EVMSendError.expired }
            if age > 90 {
                // Only normal quote ageing is expected control flow. Validate
                // every other commitment before assigning that classification.
                try validate(now: now, checkAge: false)
                throw SendQuoteExpiredError()
            }
            if !(-5...90).contains(age) { throw EVMSendError.expired }
        }
        guard try EVMSendIdentity.address(sender)==sender,try EVMSendIdentity.address(recipient)==recipient,
              recipient != "0x"+String(repeating:"0",count:40),
              try EVMSendIdentity.reference(reference)==reference,(0...255).contains(decimals),nonce<UInt64.max,
              blockHeight>0,blockHeight<UInt64(Int64.max) else { throw EVMSendError.malformed }
        guard sender != recipient || removal?.kind == .delegation || call != nil else { throw EVMSendError.sameRecipient }
        for n in [requestedAmount,amount,assetBalance,nativeBalance] { _ = try EVMSendAmount.checked(n) }
        if let m = multisig {
            try m.policy.validate()
            guard try m.policy.address == sender, m.safeNonce < UInt64.max, removal == nil, call == nil, pendingState == nil,
                  (network.oracle != nil || extraFee == 0) else { throw EVMSendError.changed }
            _ = try EVMSendAmount.checked(m.executorBalance)
            let cost = gasLimit.multipliedReportingOverflow(by: maxFeePerGas)
            guard gasLimit >= network.minimumGas, gasLimit <= network.maximumGas, maxFeePerGas > 0,
                  maxPriorityFeePerGas <= maxFeePerGas, !cost.overflow,
                  !cost.partialValue.addingReportingOverflow(extraFee).overflow, fee <= Self.maximumFee,
                  (!legacy || maxPriorityFeePerGas == 0) else { throw EVMSendError.feeTooHigh }
            guard !EVMSendAmount.less(m.executorBalance, String(fee)) else { throw EVMSendError.multisigFunding }
            if m.setup {
                guard reference == "native", decimals == 18, amount == "0", requestedAmount == "0",
                      recipient == EVMMultisigPolicy.factory, m.safeNonce == 0 else { throw EVMSendError.changed }
            } else {
                guard amount != "0", !EVMSendAmount.less(requestedAmount, amount), !EVMSendAmount.less(assetBalance, amount),
                      reference != "native" || (decimals == 18 && nativeBalance == assetBalance) else { throw EVMSendError.insufficientFunds }
            }
            return
        }
        if let pendingState {
            try pendingState.validate(network:network,sender:sender)
            guard pendingState.confirmedNonce<=nonce,pendingState.reservations.allSatisfy({$0.lastNonce<nonce}) else { throw EVMSendError.changed }
        }
        let cost=gasLimit.multipliedReportingOverflow(by:maxFeePerGas)
        guard gasLimit>=network.minimumGas,gasLimit<=network.maximumGas,maxFeePerGas>0,maxPriorityFeePerGas<=maxFeePerGas,
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
        guard amount != "0",!EVMSendAmount.less(requestedAmount,amount),!EVMSendAmount.less(assetBalance,amount) else { throw EVMSendError.insufficientFunds }
        guard !EVMSendAmount.less(nativeBalance,String(fee)) else { throw SendFeeFundingError.insufficientNativeBalance }
        if reference == "native" {
            guard decimals==18,assetBalance==nativeBalance else { throw EVMSendError.metadataChanged }
            guard try !EVMSendAmount.less(nativeBalance,EVMSendAmount.add(amount,String(fee))) else { throw EVMSendError.insufficientFunds }
        }
    }
}
public struct EVMSignedSend: Codable, Sendable, Equatable {
    public let bytes:Data, signature:Data
    public let hash:String
    public let multisigSignatures:Data?
    public let authorizationSignature:Data?
    public init(bytes:Data,signature:Data,hash:String,authorizationSignature:Data?=nil,multisigSignatures:Data?=nil) { self.multisigSignatures=multisigSignatures; self.bytes=bytes;self.signature=signature;self.hash=hash;self.authorizationSignature=authorizationSignature }
}
public struct EVMSendReceipt: Sendable, Equatable {
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

/// Verified execution in a canonical sealed block, before consensus finality.
/// The send remains reserved and its status worker continues checking for reorgs.
public struct EVMSendInclusion: Sendable, Equatable {
    public let succeeded: Bool
    public let blockHash: String
    public let fee: UInt64, height: UInt64
    public let timestamp: Double
    public let deliveredAmount: String?

    public init(succeeded: Bool, blockHash: String, fee: UInt64, height: UInt64,
                timestamp: Double, deliveredAmount: String? = nil) {
        self.succeeded = succeeded; self.blockHash = blockHash; self.fee = fee
        self.height = height; self.timestamp = timestamp; self.deliveredAmount = deliveredAmount
    }
}

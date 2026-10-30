import Foundation

public enum PolkadotSendError: Error, Sendable, Equatable {
    case configuration, malformed, wrongNetwork, wrongOwner, amount, insufficientFunds, locked, minimumBalance
    case recipientMinimum, recipientNeedsNative, frozen, metadataChanged, runtimeUnsupported, feeTooHigh
    case expired, changed, signing, busy, transport, http(Int), rpc(Int), execution
}
public enum PolkadotSendNetwork: String, Codable, Sendable {
    case mainnet, paseo, westend
    public var genesis: String {
        switch self {
        case .mainnet: PolkadotIdentity.genesis
        case .paseo: "0xd6eec26135305a8ad257a20d003357284c8aa03d0bdb2b357ab0a22371e11ef2"
        case .westend: "0x67f9723393ef76214df0118c34bbbd3dbebc8ed46a10973a8c969d48fe7598c9"
        }
    }
    public var endpoint: URL {
        switch self {
        case .mainnet: URL(string:"https://polkadot-asset-hub-rpc.polkadot.io")!
        case .paseo: URL(string:"https://asset-hub-paseo-rpc.n.dwellir.com")!
        case .westend: URL(string:"https://westend-asset-hub-rpc.polkadot.io")!
        }
    }
    public var decimals: Int { self == .westend ? 12 : 10 }
}

public struct PolkadotSendPlan: Codable, Sendable, Equatable {
    public let network: PolkadotSendNetwork
    public let sender: String, recipient: String, token: PolkadotToken
    public let requestedAmount: String, amount: String, assetBalance: String, nativeBalance: String
    public let reserve: String, fee: String
    public let nonce: UInt32, specVersion: UInt32, transactionVersion: UInt32
    public let blockHeight: UInt64, blockHash: String, metadataHash: String
    public let callIndex: Data, extensions: [String]
    public let createdAt: Date
    public var minimumNativeBalance: String? = nil
    public var reference: String { token.reference }
    public var decimals: Int { token.decimals }
    public var isSelfTransfer: Bool { (try? PolkadotIdentity.publicKey(sender)) == (try? PolkadotIdentity.publicKey(recipient)) }
    public var remaining: String {
        let debit = isSelfTransfer ? (reference == "native" ? fee : "0") : reference == "native" ? StellarIdentity.sum(amount,fee) : amount
        return StellarIdentity.sum(assetBalance,"-"+debit)
    }
    public var nativeDebit: String { reference == "native" ? StellarIdentity.sum(amount,fee) : fee }
    public var expiresAtHeight: UInt64 { blockHeight + 64 }
    public func validate(now: Date = .now, checkAge: Bool = true) throws {
        if checkAge, !(-5...90).contains(now.timeIntervalSince(createdAt)) { throw PolkadotSendError.expired }
        _ = try PolkadotIdentity.publicKey(sender); _ = try PolkadotIdentity.publicKey(recipient)
        guard blockHeight > 0, blockHeight < UInt64.max-64, specVersion > 0, transactionVersion > 0,
              try PolkadotIdentity.bytes(blockHash).count == 32, try PolkadotIdentity.bytes(metadataHash).count == 32,
              callIndex.count == 2, extensions.count < 64, Set(extensions).count == extensions.count,
              (0...255).contains(decimals) else { throw PolkadotSendError.malformed }
        for n in [requestedAmount,amount,assetBalance,nativeBalance,reserve,fee] { _ = try NearSendAmount.checked(n) }
        guard amount != "0", fee != "0", !XrplSendAmount.less(requestedAmount,amount), !XrplSendAmount.less(assetBalance,requestedAmount) else { throw PolkadotSendError.amount }
        guard !XrplSendAmount.less(nativeBalance,try NearSendAmount.add(reserve,nativeDebit)) else { throw SendFeeFundingError.insufficientNativeBalance }
        if let minimumNativeBalance { _ = try NearSendAmount.checked(minimumNativeBalance); guard !XrplSendAmount.less(reserve,minimumNativeBalance) else { throw PolkadotSendError.changed } }
        let maximumFee = "1" + String(repeating:"0",count:network.decimals)
        guard !XrplSendAmount.less(maximumFee,fee) else { throw PolkadotSendError.feeTooHigh }
        if reference == "native" {
            guard token.pallet == "System", token.key.isEmpty, decimals == network.decimals, nativeBalance == assetBalance else { throw PolkadotSendError.changed }
        } else {
            _ = try PolkadotIdentity.reference(reference)
            if reference.hasPrefix("foreign:") {
                guard token.pallet == "ForeignAssets", !token.key.isEmpty, token.key.count <= 512,
                      reference == "foreign:" + PolkadotIdentity.hex(SuiSendCrypto.hash(token.key)) else { throw PolkadotSendError.changed }
            } else {
                guard token.key.count == 4, reference == (token.pallet == "Assets" ? "assets:" : "pool:") + PolkadotIdentity.uint(token.key), ["Assets","PoolAssets"].contains(token.pallet) else { throw PolkadotSendError.changed }
            }
        }
    }
    /// Only the native transfer is reduced, and only by the fee shortfall. The
    /// runtime's retained balance remains available to sustain the account.
    public static func transferAmount(requested: String, balance: String, reserve: String, fee: String, native: Bool) throws -> String {
        for n in [requested,balance,reserve,fee] { _ = try NearSendAmount.checked(n) }
        guard requested != "0", !XrplSendAmount.less(balance,requested) else { throw PolkadotSendError.insufficientFunds }
        if !native { return requested }
        guard !XrplSendAmount.less(balance,reserve) else { throw PolkadotSendError.locked }
        let available = try NearSendAmount.subtract(balance,reserve)
        guard XrplSendAmount.less(fee,available) else { throw SendFeeFundingError.insufficientNativeBalance }
        let afterFee = try NearSendAmount.subtract(available,fee)
        return XrplSendAmount.less(afterFee,requested) ? afterFee : requested
    }
}
public struct PolkadotSignedSend: Codable, Sendable, Equatable {
    public let bytes: Data, signature: Data, hash: String
    public init(bytes: Data, signature: Data, hash: String) { self.bytes=bytes;self.signature=signature;self.hash=hash }
}
public struct PolkadotSendReceipt: Sendable, Equatable {
    public enum Outcome: String, Sendable { case unknown, accepted, confirmed, failed, expired }
    public let hash: String, outcome: Outcome, fee: String?, block: UInt64?, extrinsicIndex: Int?
    public init(hash: String, outcome: Outcome, fee: String? = nil, block: UInt64? = nil, extrinsicIndex: Int? = nil) { self.hash=hash;self.outcome=outcome;self.fee=fee;self.block=block;self.extrinsicIndex=extrinsicIndex }
}

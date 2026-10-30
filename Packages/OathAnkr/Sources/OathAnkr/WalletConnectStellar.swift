import Foundation
import CryptoKit
import stellarsdk

public extension StellarSendNetwork {
    var walletConnectChain: String { self == .mainnet ? "stellar:pubnet" : "stellar:testnet" }
    var walletConnectName: String { self == .mainnet ? "Stellar" : "Stellar Testnet" }
    init?(walletConnectChain: String) {
        switch walletConnectChain { case "stellar:pubnet": self = .mainnet; case "stellar:testnet": self = .testnet; default: return nil }
    }
}

public struct WalletConnectStellarRequest: Codable, Sendable, Equatable {
    public static let methods: Set<String> = ["stellar_signXDR", "stellar_signAndSubmitXDR"]
    public static let signingMethods = methods
    public let method: String, account: String
    public let network: StellarSendNetwork
    public let bytes: Data
    public var broadcasts: Bool { method == "stellar_signAndSubmitXDR" }
    public var fingerprint: String { StellarSendCrypto.hex(Data(SHA256.hash(data: Data((method + network.walletConnectChain + account).utf8) + bytes))) }
    public init(method: String, chain: String, account: String, params: Data) throws {
        guard Self.methods.contains(method), let network = StellarSendNetwork(walletConnectChain: chain) else { throw StellarSendError.wrongNetwork }
        let object = try WalletConnectJSON.decode(params, byteLimit: 180_000)
        guard Set(object.fields?.keys.map { $0 } ?? []) == ["xdr"], let xdr = object["xdr"].string,
              let bytes = Data(base64Encoded: xdr), bytes.base64EncodedString() == xdr else { throw StellarSendError.malformed }
        self.method = method; self.network = network; self.account = try StellarIdentity.address(account); self.bytes = bytes
        let envelope = try StellarConnectEnvelope(bytes, network: network)
        guard envelope.signingOwner == self.account else { throw StellarSendError.wrongOwner }
    }
    public func details() throws -> WalletConnectStellarDetails { try StellarConnectEnvelope(bytes, network: network).details }
    public func sign(privateKey: Data, review: WalletConnectStellarReview, now: Date = .now) throws -> WalletConnectStellarSigned {
        guard review.request == self, (0...120).contains(now.timeIntervalSince(review.createdAt)),
              try StellarSendCrypto.address(privateKey: privateKey) == account else { throw StellarSendError.changed }
        let envelope = try StellarConnectEnvelope(bytes, network: network)
        try envelope.validateTime(now)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        let signature = try envelope.signatures.first(where: { key.publicKey.isValidSignature($0.signature, for: envelope.digest) })?.signature ?? key.signature(for: envelope.digest)
        let signed = try envelope.appending(publicKey: key.publicKey.rawRepresentation, signature: signature)
        let result = WalletConnectStellarSigned(bytes: signed, hash: envelope.details.hash, publicKey: key.publicKey.rawRepresentation, signature: signature)
        try verify(result)
        return result
    }
    public func verify(_ signed: WalletConnectStellarSigned) throws {
        let envelope = try StellarConnectEnvelope(bytes, network: network)
        guard signed.hash == envelope.details.hash, signed.publicKey == Data(try StellarIdentity.bytes(account, version: 48)),
              try Curve25519.Signing.PublicKey(rawRepresentation: signed.publicKey).isValidSignature(signed.signature, for: envelope.digest),
              try envelope.appending(publicKey: signed.publicKey, signature: signed.signature) == signed.bytes else { throw StellarSendError.signing }
    }
}
public struct WalletConnectStellarSigned: Codable, Sendable, Equatable {
    public let bytes: Data, hash: String, publicKey: Data, signature: Data
    public var response: StellarJSON { .object(["signedXDR": .string(bytes.base64EncodedString())]) }
}
public struct WalletConnectStellarDetails: Codable, Sendable, Equatable {
    public let hash: String, source: String, feePayer: String, fee: UInt64, sequence: Int64
    public let memo: String, operations: [String], transaction: String
    public let maxTime: UInt64
}
public struct WalletConnectStellarReview: Codable, Sendable, Equatable {
    public let request: WalletConnectStellarRequest, details: WalletConnectStellarDetails
    public let firstLedger: UInt32, createdAt: Date
}

// Decode all protocol operation variants through the pinned SDK, then require an
// exact round trip. Trailing bytes and noncanonical option/padding encodings fail.
struct StellarConnectEnvelope {
    let envelope: TransactionEnvelopeXDR, tx: TransactionXDR
    let signingOwner: String, digest: Data, details: WalletConnectStellarDetails
    let signatures: [DecoratedSignatureXDR]
    init(_ bytes: Data, network: StellarSendNetwork) throws {
        guard (20...131_072).contains(bytes.count), bytes.count % 4 == 0 else { throw StellarSendError.malformed }
        let envelope = try XDRDecoder.decode(TransactionEnvelopeXDR.self, data: bytes)
        guard try Data(XDREncoder.encode(envelope)) == bytes else { throw StellarSendError.malformed }
        let tx: TransactionXDR, owner: String, fee: UInt64, digest: Data, signatures: [DecoratedSignatureXDR]
        switch envelope {
        case .v1(let e):
            tx = e.tx; owner = e.tx.sourceAccount.ed25519AccountId; fee = UInt64(e.tx.fee); signatures = e.signatures
            digest = try e.tx.hash(network: .custom(passphrase: network.passphrase))
        case .v0(let e):
            // V0 signs a V1 payload. Its fee is already the transaction total.
            var converted = TransactionXDR(sourceAccount: .ed25519(e.tx.sourceAccountEd25519), seqNum: e.tx.seqNum,
                cond: e.tx.timeBounds.map { .time($0) } ?? .none, memo: e.tx.memo, operations: e.tx.operations)
            converted.fee = e.tx.fee
            tx = converted; owner = converted.sourceAccount.ed25519AccountId; fee = UInt64(e.tx.fee); signatures = e.signatures
            digest = try converted.hash(network: .custom(passphrase: network.passphrase))
        case .feeBump(let e):
            switch e.tx.innerTx { case .v1(let inner): tx = inner.tx; guard inner.signatures.count <= 20 else { throw StellarSendError.malformed } }
            owner = e.tx.sourceAccount.ed25519AccountId; fee = e.tx.fee; signatures = e.signatures
            digest = try e.tx.hash(network: .custom(passphrase: network.passphrase))
        }
        guard signatures.count <= 20, signatures.allSatisfy({ $0.signature.count <= 64 }),
              (1...100).contains(tx.operations.count), tx.seqNum > 0, fee > 0,
              fee <= UInt64(StellarSendPlan.maximumFee) else { throw StellarSendError.malformed }
        self.envelope = envelope; self.tx = tx; self.signingOwner = owner; self.digest = digest; self.signatures = signatures
        let bound: UInt64
        switch tx.cond { case .none: bound = 0; case .time(let t): bound = t.maxTime; case .v2(let v): bound = v.timeBounds?.maxTime ?? 0 }
        details = .init(hash: StellarSendCrypto.hex(digest), source: tx.sourceAccount.accountId, feePayer: owner,
            fee: fee, sequence: tx.seqNum, memo: try tx.memo.toXdrJson(),
            operations: try tx.operations.map { try $0.toXdrJson() }, transaction: try envelope.toXdrJson(), maxTime: bound)
    }
    func validateTime(_ now: Date) throws {
        let bounds: TimeBoundsXDR?
        switch tx.cond { case .none: bounds = nil; case .time(let t): bounds = t; case .v2(let v): bounds = v.timeBounds }
        if let bounds {
            guard Double(bounds.minTime) <= now.timeIntervalSince1970,
                  bounds.maxTime == 0 || now.timeIntervalSince1970 < Double(bounds.maxTime) else { throw StellarSendError.expired }
        }
    }
    func appending(publicKey: Data, signature: Data) throws -> Data {
        guard publicKey.count == 32, signature.count == 64 else { throw StellarSendError.signing }
        let decorated = DecoratedSignatureXDR(hint: WrappedData4(Data(publicKey.suffix(4))), signature: signature)
        let next = signatures.contains { $0.hint.wrapped == decorated.hint.wrapped && $0.signature == signature } ? signatures : signatures + [decorated]
        guard next.count <= 20 else { throw StellarSendError.signing }
        let result: TransactionEnvelopeXDR
        switch envelope {
        case .v0(let e): result = .v0(.init(tx: e.tx, signatures: next))
        case .v1(let e): result = .v1(.init(tx: e.tx, signatures: next))
        case .feeBump(let e): result = .feeBump(.init(tx: e.tx, signatures: next))
        }
        return try Data(XDREncoder.encode(result))
    }
}

extension WalletConnectStellarRequest {
    static func rejectionOutcome(_ base64: String?) throws -> StellarSendReceipt.Outcome {
        guard let base64, let bytes = Data(base64Encoded: base64), bytes.count <= 131_072 else { throw StellarSendError.malformed }
        let result = try XDRDecoder.decode(TransactionResultXDR.self, data: bytes)
        guard try Data(XDREncoder.encode(result)) == bytes else { throw StellarSendError.malformed }
        switch result.result {
        // A consumed sequence can mean an earlier broadcast succeeded while
        // Horizon is still indexing it. Continue looking up the exact hash.
        case .badSeq, .tooEarly, .tooLate, .badMinSeqAgeOrGap, .internalError: return .unknown
        case .success, .feeBumpInnerSuccess: throw StellarSendError.malformed
        default: return .failed
        }
    }
}

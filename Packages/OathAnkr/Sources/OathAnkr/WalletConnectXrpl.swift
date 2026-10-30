import Foundation
import CryptoKit
import JavaScriptCore
import OathSecp256k1

public extension XrplSendNetwork {
    var walletConnectChain: String { self == .mainnet ? "xrpl:0" : "xrpl:1" }
    var walletConnectName: String { self == .mainnet ? "XRP Ledger" : "XRP Ledger Testnet" }
    init?(walletConnectChain: String) {
        switch walletConnectChain { case "xrpl:0": self = .mainnet; case "xrpl:1": self = .testnet; default: return nil }
    }
}

public struct WalletConnectXrplRequest: Codable, Sendable, Equatable {
    public static let methods: Set<String> = ["xrpl_signTransaction", "xrpl_signTransactionFor"]
    public static let signingMethods = methods
    public let method: String, account: String
    public let network: XrplSendNetwork
    public let transaction: XrplJSON
    public let autofill: Bool, broadcasts: Bool
    public var multisign: Bool { method == "xrpl_signTransactionFor" }
    public var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return XrplSendCrypto.hex(Data(SHA256.hash(data: (try? encoder.encode(self)) ?? Data())))
    }
    public init(method: String, chain: String, account: String, params: Data) throws {
        guard Self.methods.contains(method), let network = XrplSendNetwork(walletConnectChain: chain) else { throw XrplSendError.wrongNetwork }
        let object = try WalletConnectJSON.decode(params, byteLimit: 150_000)
        let multi = method == "xrpl_signTransactionFor"
        guard let fields = object.fields, Set(fields.keys).isSubset(of: multi ? ["tx_json", "tx_signer", "autofill", "submit"] : ["tx_json", "autofill", "submit"]),
              let tx = object["tx_json"].fields, let source = tx["Account"]?.string else { throw XrplSendError.malformed }
        self.account = try XrplIdentity.address(account)
        _ = try XrplIdentity.address(source)
        guard multi ? object["tx_signer"].string == self.account && source != self.account : source == self.account else { throw XrplSendError.wrongOwner }
        func flag(_ name: String, fallback: Bool) throws -> Bool {
            guard let value = fields[name] else { return fallback }
            if value == .bool(true) { return true }; if value == .bool(false) { return false }
            throw XrplSendError.malformed
        }
        self.method = method; self.network = network
        self.autofill = try flag("autofill", fallback: !multi)
        self.broadcasts = try flag("submit", fallback: !multi)
        // NetworkID is omitted on mainnet and testnet. A signature or delegated
        // owner in a single-sign request must never be silently overwritten.
        guard tx["NetworkID"] == nil, tx["TxnSignature"] == nil, tx["Delegate"] == nil,
              tx["SigningPubKey"] == nil || tx["SigningPubKey"] == .string(""),
              multi || tx["Signers"] == nil else { throw XrplSendError.malformed }
        if let signers = tx["Signers"] {
            guard let entries = signers.array, (1...31).contains(entries.count),
                  !entries.contains(where: { $0["Signer"]["Account"].string == account }) else { throw XrplSendError.malformed }
            // Existing signatures bind every field; autofill must not change them.
            guard !autofill else { throw XrplSendError.changed }
        }
        self.transaction = .object(tx)
        _ = try XrplConnectCodec.run(transaction)
    }
    public func details() throws -> XrplJSON { transaction }
    public func sign(privateKey: Data, review: WalletConnectXrplReview, now: Date = .now) throws -> WalletConnectXrplSigned {
        try review.validate()
        guard review.request == self, (0...120).contains(now.timeIntervalSince(review.createdAt)),
              try XrplSendCrypto.address(privateKey: privateKey) == account else { throw XrplSendError.changed }
        let publicKey = try XrplSendCrypto.publicKey(privateKey: privateKey)
        var tx = review.transaction.fields!
        tx["SigningPubKey"] = .string(multisign ? "" : XrplSendCrypto.hex(publicKey))
        let encoded = try XrplConnectCodec.run(.object(tx), signer: multisign ? account : nil)
        let signature = try OathSecp256k1.sign(XrplSendCrypto.half(encoded.signing), key: privateKey)
        if multisign {
            var entries = tx["Signers"]?.array ?? []
            entries.append(.object(["Signer": .object(["Account": .string(account), "SigningPubKey": .string(XrplSendCrypto.hex(publicKey)), "TxnSignature": .string(XrplSendCrypto.hex(signature))])]))
            entries = try entries.sorted { try XrplIdentity.accountBytes($0["Signer"]["Account"].string!).lexicographicallyPrecedes(XrplIdentity.accountBytes($1["Signer"]["Account"].string!)) }
            tx["Signers"] = .array(entries)
        } else { tx["TxnSignature"] = .string(XrplSendCrypto.hex(signature)) }
        let final = try XrplConnectCodec.run(.object(tx), signer: multisign ? account : nil)
        let result = WalletConnectXrplSigned(bytes: final.bytes, hash: XrplSendCrypto.transactionHash(final.bytes), transaction: final.transaction, publicKey: publicKey, signature: signature)
        try verify(result, review: review)
        return result
    }
    public func verify(_ signed: WalletConnectXrplSigned, review: WalletConnectXrplReview) throws {
        try review.validate()
        guard review.request == self, try XrplSendCrypto.address(publicKey: signed.publicKey) == account else { throw XrplSendError.signing }
        var tx = signed.transaction.fields ?? [:]
        if multisign {
            guard tx["SigningPubKey"] == .string(""), let entries = tx["Signers"]?.array,
                  entries.count == (review.transaction["Signers"].array?.count ?? 0) + 1 else { throw XrplSendError.signing }
            let ours = entries.filter { $0["Signer"]["Account"].string == account }
            guard ours.count == 1, ours[0]["Signer"]["SigningPubKey"].string == XrplSendCrypto.hex(signed.publicKey),
                  ours[0]["Signer"]["TxnSignature"].string == XrplSendCrypto.hex(signed.signature) else { throw XrplSendError.signing }
            let remaining = entries.filter { $0["Signer"]["Account"].string != account }
            guard remaining == (review.transaction["Signers"].array ?? []) else { throw XrplSendError.signing }
            tx["Signers"] = review.transaction.fields?["Signers"]
        } else {
            guard tx.removeValue(forKey: "TxnSignature") == .string(XrplSendCrypto.hex(signed.signature)),
                  tx["SigningPubKey"] == .string(XrplSendCrypto.hex(signed.publicKey)) else { throw XrplSendError.signing }
        }
        let signing = try XrplConnectCodec.run(.object(tx), signer: multisign ? account : nil)
        tx["SigningPubKey"] = review.transaction.fields?["SigningPubKey"]
        guard .object(tx) == review.transaction else { throw XrplSendError.signing }
        try OathSecp256k1.verify(signed.signature, digest: XrplSendCrypto.half(signing.signing), publicKey: signed.publicKey)
        let encoded = try XrplConnectCodec.run(signed.transaction, signer: multisign ? account : nil)
        guard encoded.bytes == signed.bytes, XrplSendCrypto.transactionHash(signed.bytes) == signed.hash else { throw XrplSendError.signing }
    }
}

public struct WalletConnectXrplReview: Codable, Sendable, Equatable {
    public let request: WalletConnectXrplRequest, transaction: XrplJSON
    public let firstLedger: UInt32, createdAt: Date
    public var lastLedger: UInt32 { UInt32(exactly: transaction["LastLedgerSequence"].integer ?? 0) ?? 0 }
    public var fee: UInt64 { transaction["Fee"].string.flatMap(UInt64.init) ?? 0 }
    public func validate() throws {
        guard firstLedger > 0, let last = transaction["LastLedgerSequence"].integer, last > UInt64(firstLedger), last <= UInt64(firstLedger) + 1000,
              fee > 0, fee <= XrplSendPlan.maximumFee,
              let sequence = transaction["Sequence"].integer, sequence <= UInt32.max,
              transaction["Account"] == request.transaction["Account"] else { throw XrplSendError.changed }
        // Only absent autofill fields may be added. Approval binds all others.
        var original = transaction.fields ?? [:]
        for key in ["Fee", "Sequence", "LastLedgerSequence", "SigningPubKey"] where request.transaction.fields?[key] == nil { original.removeValue(forKey: key) }
        guard .object(original) == request.transaction else { throw XrplSendError.changed }
        if !request.autofill {
            for key in ["Fee", "Sequence", "LastLedgerSequence"] { guard request.transaction.fields?[key] != nil else { throw XrplSendError.malformed } }
        }
        _ = try XrplConnectCodec.run(transaction, signer: request.multisign ? request.account : nil)
    }
}
public struct WalletConnectXrplSigned: Codable, Sendable, Equatable {
    public let bytes: Data, hash: String, transaction: XrplJSON, publicKey: Data, signature: Data
    public var response: XrplJSON {
        var tx = transaction.fields ?? [:]; tx["hash"] = .string(hash)
        return .object(["tx_json": .object(tx)])
    }
}

// A fresh confined runtime per call avoids shared mutable JS state across tasks.
// Only the bundled codec is evaluated; the untrusted JSON is passed as an argument.
enum XrplConnectCodec {
    struct Result { let bytes: Data, signing: Data, transaction: XrplJSON }
    static let source: Swift.Result<String, Error> = Swift.Result {
        guard let url = Bundle.module.url(forResource: "XrplCodec", withExtension: "js") else { throw XrplSendError.configuration }
        return try String(contentsOf: url, encoding: .utf8)
    }
    static func run(_ tx: XrplJSON, signer: String? = nil) throws -> Result {
        let source = try source.get()
        guard let context = JSContext() else { throw XrplSendError.configuration }
        context.evaluateScript(source)
        let input = XrplJSON.object(["tx": tx, "signer": signer.map(XrplJSON.string) ?? .null])
        let bytes = try JSONEncoder().encode(input)
        guard bytes.count <= 150_000, let json = String(data: bytes, encoding: .utf8),
              context.exception == nil, let function = context.objectForKeyedSubscript("OathXrplCodec")?.objectForKeyedSubscript("run"),
              let output = function.call(withArguments: [json])?.toString(), context.exception == nil,
              let data = output.data(using: .utf8), data.count < 1_000_000 else { throw XrplSendError.malformed }
        let value = try JSONDecoder().decode(XrplJSON.self, from: data)
        guard let encoded = value["bytes"].string, let signing = value["signing"].string else { throw XrplSendError.malformed }
        return try .init(bytes: TronIdentity.hex(encoded), signing: TronIdentity.hex(signing), transaction: value["transaction"])
    }
}

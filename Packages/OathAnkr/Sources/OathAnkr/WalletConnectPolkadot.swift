import Foundation
import CryptoKit

public enum PolkadotConnectNetwork: String, CaseIterable, Sendable {
    case relay, assetHub, paseo, westend
    public var genesis: String {
        switch self {
        case .relay: PolkadotIdentity.relayGenesis
        case .assetHub: PolkadotSendNetwork.mainnet.genesis
        case .paseo: PolkadotSendNetwork.paseo.genesis
        case .westend: PolkadotSendNetwork.westend.genesis
        }
    }
    public var chain: String { "polkadot:" + genesis.dropFirst(2).prefix(32) }
    public init?(chain: String) {
        guard let value = Self.allCases.first(where: { $0.chain == chain }) else { return nil }; self = value
    }
    public var name: String {
        switch self { case .relay: "Polkadot Relay Chain"; case .assetHub: "Polkadot Asset Hub"; case .paseo: "Paseo Asset Hub Testnet"; case .westend: "Westend Asset Hub Testnet" }
    }
    public var symbol: String { self == .paseo ? "PAS" : self == .westend ? "WND" : "DOT" }
    public var decimals: Int { self == .westend ? 12 : 10 }
    var endpoints: [URL] {
        switch self {
        case .relay: [URL(string:"https://rpc.polkadot.io")!]
        case .assetHub: [PolkadotSendNetwork.mainnet.endpoint, URL(string:"https://asset-hub.selvagelabs.io")!]
        case .paseo: [PolkadotSendNetwork.paseo.endpoint]
        case .westend: [PolkadotSendNetwork.westend.endpoint]
        }
    }
}

public struct WalletConnectPolkadotRequest: Sendable, Equatable {
    public static let methods: Set<String> = ["polkadot_signTransaction", "polkadot_signMessage"]
    public let network: PolkadotConnectNetwork
    public let account: String
    public let message: Data?
    public let call: Data, era: Data
    public let blockHash: String
    public let blockNumber: UInt64
    public let nonce: UInt32, specVersion: UInt32, transactionVersion: UInt32
    public let tip: String
    public let extensions: [String]
    public let withSignedTransaction: Bool

    public init(method: String, chain: String, account: String, params: Data) throws {
        guard let network = PolkadotConnectNetwork(chain:chain), Self.methods.contains(method) else { throw PolkadotSendError.wrongNetwork }
        let input = try WalletConnectJSON.decode(params)
        guard try PolkadotIdentity.publicKey(input["address"].string ?? "") == PolkadotIdentity.publicKey(account) else { throw PolkadotSendError.wrongOwner }
        self.network = network; self.account = try PolkadotIdentity.address(account)
        if method == "polkadot_signMessage" {
            try Self.keys(input, ["address","data","type"])
            guard input["type"].isNull || input["type"].string == "bytes" else { throw PolkadotSendError.runtimeUnsupported }
            let bytes = try Self.hex(input["data"], maximum:8_192)
            guard !bytes.isEmpty else { throw PolkadotSendError.malformed }
            let start = Data("<Bytes>".utf8), end = Data("</Bytes>".utf8)
            // Match the SDK's wrap-once convention; never sign arbitrary raw payloads.
            message = bytes.starts(with:start) && bytes.suffix(end.count) == end ? bytes : start + bytes + end
            call = Data(); era = Data(); blockHash = ""; blockNumber = 0; nonce = 0
            specVersion = 0; transactionVersion = 0; tip = "0"; extensions = []; withSignedTransaction = false
            return
        }
        try Self.keys(input, ["address","transactionPayload"])
        let p = input["transactionPayload"]
        try Self.keys(p, ["address","assetId","blockHash","blockNumber","era","genesisHash","metadataHash","method","mode","nonce","specVersion","tip","transactionVersion","signedExtensions","version","withSignedTransaction"])
        guard try PolkadotIdentity.publicKey(p["address"].string ?? "") == PolkadotIdentity.publicKey(account),
              p["genesisHash"].string?.lowercased() == network.genesis else { throw PolkadotSendError.wrongNetwork }
        guard p["version"].integer == 4, p["assetId"].isNull, p["metadataHash"].isNull,
              p["mode"].isNull || p["mode"].integer == 0,
              p["withSignedTransaction"].isNull || p["withSignedTransaction"] == .bool(false) || p["withSignedTransaction"] == .bool(true) else { throw PolkadotSendError.runtimeUnsupported }
        guard let names = p["signedExtensions"].array, names.count <= 64,
              names.allSatisfy({ $0.string != nil }), Set(names.compactMap(\.string)).count == names.count else { throw PolkadotSendError.malformed }
        extensions = names.compactMap(\.string)
        call = try Self.hex(p["method"], maximum:16_384)
        era = try Self.hex(p["era"], maximum:2)
        let hash = try Self.hex(p["blockHash"], maximum:32)
        guard call.count >= 2, hash.count == 32 else { throw PolkadotSendError.malformed }
        blockHash = PolkadotIdentity.hex(hash)
        guard let block = UInt64(try Self.number(p["blockNumber"], bytes:8)),
              let nonce = UInt32(try Self.number(p["nonce"], bytes:4)),
              let spec = UInt32(try Self.number(p["specVersion"], bytes:4)),
              let tx = UInt32(try Self.number(p["transactionVersion"], bytes:4)), spec > 0, tx > 0 else { throw PolkadotSendError.malformed }
        blockNumber = block; self.nonce = nonce; specVersion = spec; transactionVersion = tx
        tip = try Self.number(p["tip"], bytes:16)
        withSignedTransaction = p["withSignedTransaction"] == .bool(true); message = nil
        _ = try lifetime()
    }
    static func keys(_ value: TronJSON, _ allowed: Set<String>) throws {
        guard let fields = value.fields, Set(fields.keys).isSubset(of:allowed) else { throw PolkadotSendError.malformed }
    }
    static func hex(_ value: TronJSON, maximum: Int) throws -> Data {
        guard let text = value.string, text.count <= maximum * 2 + 2 else { throw PolkadotSendError.malformed }
        return try PolkadotIdentity.bytes(text)
    }
    static func number(_ value: TronJSON, bytes: Int) throws -> String {
        let data = try hex(value, maximum:bytes)
        guard !data.isEmpty else { throw PolkadotSendError.malformed }
        return PolkadotIdentity.uint(Data(data.reversed()))
    }
    func lifetime() throws -> (birth: UInt64, death: UInt64) {
        if era == Data([0]) {
            guard blockHash == network.genesis else { throw PolkadotSendError.wrongNetwork }
            return (0, UInt64.max)
        }
        guard era.count == 2 else { throw PolkadotSendError.malformed }
        let encoded = UInt64(era[0]) | UInt64(era[1]) << 8
        let period = UInt64(2) << (encoded & 15), phase = (encoded >> 4) * max(period >> 12, 1)
        guard period >= 4, period <= 65_536, phase < period, blockNumber >= phase else { throw PolkadotSendError.malformed }
        let birth = (blockNumber - phase) / period * period + phase
        guard birth <= UInt64.max - period else { throw PolkadotSendError.malformed }
        return (birth, birth + period)
    }
    func extensionBytes(_ name: String) throws -> (Data, Data) {
        switch name {
        case "CheckSpecVersion": (Data(), PolkadotScale.le(specVersion))
        case "CheckTxVersion": (Data(), PolkadotScale.le(transactionVersion))
        case "CheckGenesis": (Data(), try PolkadotIdentity.bytes(network.genesis))
        case "CheckMortality", "CheckEra": (era, try PolkadotIdentity.bytes(blockHash))
        case "CheckNonce": (try PolkadotScale.compact(String(nonce)), Data())
        case "ChargeTransactionPayment": (try PolkadotScale.compact(tip), Data())
        case "ChargeAssetTxPayment": (try PolkadotScale.compact(tip) + Data([0]), Data())
        case "CheckMetadataHash": (Data([0]), Data([0]))
        case "AsScarcity", "AsPgas", "AsDotnsGateway", "RestrictOrigins": (Data([0]), Data())
        case "AuthorizeCall", "CheckNonZeroSender", "CheckWeight", "PrevalidateAttests", "EthSetOrigin", "StorageWeightReclaim", "UnitTransactionExtension": (Data(), Data())
        default: throw PolkadotSendError.runtimeUnsupported
        }
    }
    func encoded() throws -> (extra: Data, payload: Data) {
        var extra = Data(), additional = Data()
        for name in extensions { let pair = try extensionBytes(name); extra += pair.0; additional += pair.1 }
        let payload = call + extra + additional
        return (extra, payload.count > 256 ? SuiSendCrypto.hash(payload) : payload)
    }
    func extrinsic(signature: Data) throws -> Data {
        guard signature.count == 64 else { throw PolkadotSendError.signing }
        let body = try Data([0x84,0]) + PolkadotIdentity.publicKey(account) + Data([0]) + signature + encoded().extra + call
        return try PolkadotScale.compact(String(body.count)) + body
    }
    public func sign(privateKey: Data, review: PolkadotConnectReview? = nil, now: Date = .now) throws -> TronJSON {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey)
        guard try key.publicKey.rawRepresentation == PolkadotIdentity.publicKey(account) else { throw PolkadotSendError.wrongOwner }
        if let message { return .object(["signature":.string(PolkadotIdentity.hex(try key.signature(for:message)))]) }
        guard let review, review.request == self else { throw PolkadotSendError.changed }
        try review.validate(now:now)
        let signature = try key.signature(for:encoded().payload)
        var result: [String:TronJSON] = ["signature":.string(PolkadotIdentity.hex(Data([0]) + signature))]
        if withSignedTransaction { result["signedTransaction"] = .string(PolkadotIdentity.hex(try extrinsic(signature:signature))) }
        return .object(result)
    }
}

public struct PolkadotConnectReview: Sendable, Equatable {
    public let request: WalletConnectPolkadotRequest
    public let callName: String, details: String, fee: String, metadataHash: String
    public let recipient: String?, nativeAmount: String?
    public let createdAt: Date
    public func validate(now: Date = .now) throws {
        guard (-5...90).contains(now.timeIntervalSince(createdAt)) else { throw PolkadotSendError.expired }
    }
}

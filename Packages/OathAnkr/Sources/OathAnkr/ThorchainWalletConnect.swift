import Foundation
import CryptoKit
import OathSecp256k1

/// A decoded, immutable Cosmos request. Only reviewed THORChain bank transfers
/// and native protocol deposits are accepted. Unknown messages/extensions,
/// fee grants and multisig are rejected rather than blind-signed.
public struct ThorchainWalletConnectRequest: Sendable, Equatable {
    public struct Coin: Sendable, Equatable {
        public let reference: String
        public let amount: String
    }
    public let method: String
    public let network: ThorchainSendNetwork
    public let sender: String
    public let publicKey: Data
    public let accountNumber: UInt64
    public let sequence: UInt64
    public let timeoutHeight: UInt64
    public let recipient: String? // nil means MsgDeposit, never an implicit send.
    public let coins: [Coin]
    public let memo: String
    public let transactionMemo: String
    public let signedDocument: SolanaJSON
    public let signBytes: Data

    public static let methods: Set<String> = ["cosmos_getAccounts", "cosmos_signAmino", "cosmos_signDirect"]
    public static let blockchain = "cosmos:thorchain"
    /// Both identifiers address mainnet. Session permissions still require an
    /// exact match; recognizing one never grants the other to an existing peer.
    public static let blockchains = [blockchain, "cosmos:" + ThorchainSendNetwork.mainnet.chainID]
    public enum Failure: Error { case invalidRequest, unsupported, wrongAccount, wrongChain }

    public init(method: String, params: SolanaJSON, sender: String, publicKey: Data,
                network: ThorchainSendNetwork = .mainnet) throws {
        guard method == "cosmos_signAmino" || method == "cosmos_signDirect" else { throw Failure.unsupported }
        try Self.keys(params, required: ["signerAddress", "signDoc"])
        guard params["signerAddress"].string == sender,
              try ThorchainSendCrypto.address(publicKey: publicKey, network: network) == sender else { throw Failure.wrongAccount }
        let doc = params["signDoc"]
        self.method = method; self.network = network; self.sender = sender; self.publicKey = publicKey
        self.signedDocument = doc
        let message: Message
        if method == "cosmos_signAmino" {
            try Self.keys(doc, required: ["chain_id", "account_number", "sequence", "fee", "msgs", "memo"], optional: ["timeout_height"])
            guard doc["chain_id"].string == network.chainID else { throw Failure.wrongChain }
            accountNumber = try Self.uint(doc["account_number"]); sequence = try Self.uint(doc["sequence"])
            timeoutHeight = doc["timeout_height"].isNull ? 0 : try Self.uint(doc["timeout_height"])
            transactionMemo = try Self.memo(doc["memo"])
            try Self.keys(doc["fee"], required: ["amount", "gas"])
            // THORNode charges its native fee in ante handling. Reject extra
            // Cosmos fees, payer/granter or auth data not represented in review.
            guard doc["fee"]["amount"].array == [], try Self.uint(doc["fee"]["gas"]) <= 1_000_000_000,
                  let msgs = doc["msgs"].array, msgs.count == 1 else { throw Failure.unsupported }
            message = try Self.aminoMessage(msgs[0], sender: sender, network: network)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            // Cosmos amino JSON uses sorted keys and Go's HTML escaping.
            let json = String(decoding: try encoder.encode(doc), as: UTF8.self)
                .replacingOccurrences(of: "&", with: "\\u0026")
                .replacingOccurrences(of: "<", with: "\\u003c")
                .replacingOccurrences(of: ">", with: "\\u003e")
            signBytes = Data(json.utf8)
        } else {
            try Self.keys(doc, required: ["chainId", "accountNumber", "bodyBytes", "authInfoBytes"])
            guard doc["chainId"].string == network.chainID else { throw Failure.wrongChain }
            accountNumber = try Self.uint(doc["accountNumber"])
            let bodyBytes = try Self.base64(doc["bodyBytes"]), authBytes = try Self.base64(doc["authInfoBytes"])
            let body = try Proto(bodyBytes, allowed: [1, 2, 3])
            let any = try Proto(body.bytes(1), allowed: [1, 2])
            transactionMemo = try Self.memo(.string(body.text(2, default: "")))
            timeoutHeight = try body.number(3)
            message = try Self.directMessage(type: any.text(1), bytes: any.bytes(2), sender: sender, network: network)
            let auth = try Proto(authBytes, allowed: [1, 2])
            let signer = try Proto(auth.bytes(1), allowed: [1, 2, 3])
            let keyAny = try Proto(signer.bytes(1), allowed: [1, 2])
            guard try keyAny.text(1) == "/cosmos.crypto.secp256k1.PubKey",
                  try Proto(keyAny.bytes(2), allowed: [1]).bytes(1) == publicKey else { throw Failure.wrongAccount }
            let mode = try Proto(signer.bytes(2), allowed: [1])
            guard try Proto(mode.bytes(1), allowed: [1]).number(1) == 1 else { throw Failure.unsupported }
            sequence = try signer.number(3)
            let fee = try Proto(auth.bytes(2), allowed: [2])
            guard try fee.number(2) <= 1_000_000_000 else { throw Failure.invalidRequest }
            signBytes = TronSendCrypto.field(1, bodyBytes) + TronSendCrypto.field(2, authBytes)
                + TronSendCrypto.field(3, Data(network.chainID.utf8)) + TronSendCrypto.number(4, accountNumber)
        }
        recipient = message.recipient; coins = message.coins; memo = message.memo ?? transactionMemo
        guard signBytes.count <= 32_768, sequence < UInt64.max else { throw Failure.invalidRequest }
    }

    /// Both methods return the Cosmos standard response; TCSwap consumes its
    /// nested signature. The dApp, not the wallet's payment sender, broadcasts.
    public func sign(privateKey: Data) throws -> SolanaJSON {
        try Task.checkCancellation()
        guard try ThorchainSendCrypto.publicKey(privateKey: privateKey) == publicKey else { throw Failure.wrongAccount }
        let digest = Data(SHA256.hash(data: signBytes))
        let signature = try OathSecp256k1.signRecoverable(digest, key: privateKey)
        let recovered = try OathSecp256k1.recover(signature, digest: digest)
        let compressed = Data([recovered.last! & 1 == 0 ? 2 : 3]) + recovered.dropFirst().prefix(32)
        guard compressed == publicKey else { throw ThorchainSendError.signing }
        return .object(["signed": signedDocument, "signature": .object([
            "pub_key": .object(["type": .string("tendermint/PubKeySecp256k1"), "value": .string(publicKey.base64EncodedString())]),
            "signature": .string(Data(signature.prefix(64)).base64EncodedString())])])
    }

    private struct Message { let recipient: String?; let coins: [Coin]; let memo: String? }
    private static func aminoMessage(_ j: SolanaJSON, sender: String, network: ThorchainSendNetwork) throws -> Message {
        try keys(j, required: ["type", "value"])
        let v = j["value"]
        switch j["type"].string {
        case "thorchain/MsgSend":
            try keys(v, required: ["from_address", "to_address", "amount"])
            guard v["from_address"].string == sender, let to = v["to_address"].string else { throw Failure.wrongAccount }
            _ = try ThorchainSendCrypto.addressBytes(to, network: network)
            guard let list = v["amount"].array else { throw Failure.invalidRequest }
            let coins = try list.map { coin -> Coin in
                try keys(coin, required: ["denom", "amount"])
                return try bankCoin(denom: coin["denom"].string, amount: coin["amount"].string)
            }
            try checkCoins(coins)
            return Message(recipient: to, coins: coins, memo: nil)
        case "thorchain/MsgDeposit":
            try keys(v, required: ["signer", "coins", "memo"])
            guard v["signer"].string == sender, let list = v["coins"].array else { throw Failure.wrongAccount }
            let coins = try list.map { coin -> Coin in
                try keys(coin, required: ["asset", "amount"], optional: ["decimals"])
                guard coin["decimals"].isNull || coin["decimals"] == .number("0") || coin["decimals"] == .string("0") else { throw Failure.unsupported }
                return try depositCoin(asset: coin["asset"].string, amount: coin["amount"].string)
            }
            try checkCoins(coins)
            return Message(recipient: nil, coins: coins, memo: try memo(v["memo"]))
        default: throw Failure.unsupported
        }
    }
    private static func directMessage(type: String, bytes: Data, sender: String, network: ThorchainSendNetwork) throws -> Message {
        let j = try Proto(bytes, allowed: [1, 2, 3], repeated: type == "/types.MsgSend" ? [3] : [1])
        let senderBytes = try ThorchainSendCrypto.addressBytes(sender, network: network)
        switch type {
        case "/types.MsgSend":
            guard try j.bytes(1) == senderBytes else { throw Failure.wrongAccount }
            let toBytes = try j.bytes(2)
            guard [20, 32].contains(toBytes.count) else { throw Failure.invalidRequest }
            let coins = try j.allBytes(3).map { data -> Coin in
                let coin = try Proto(data, allowed: [1, 2])
                return try bankCoin(denom: coin.text(1), amount: coin.text(2))
            }
            try checkCoins(coins)
            return Message(recipient: ThorchainSendCrypto.bech32(toBytes, prefix: network.prefix), coins: coins, memo: nil)
        case "/types.MsgDeposit":
            guard try j.bytes(3) == senderBytes else { throw Failure.wrongAccount }
            let coins = try j.allBytes(1).map { data -> Coin in
                let coin = try Proto(data, allowed: [1, 2, 3])
                let asset = try Proto(coin.bytes(1), allowed: [1, 2, 3, 4, 5, 6])
                guard try asset.text(1) == "THOR", try asset.text(2) == asset.text(3),
                      try asset.number(4) == 0, try asset.number(5) == 0, try asset.number(6) == 0,
                      try coin.number(3) == 0 else { throw Failure.unsupported }
                return try depositCoin(asset: "THOR." + asset.text(2), amount: coin.text(2))
            }
            try checkCoins(coins)
            return Message(recipient: nil, coins: coins, memo: try memo(.string(j.text(2, default: ""))))
        default: throw Failure.unsupported
        }
    }
    private static func bankCoin(denom: String?, amount: String?) throws -> Coin {
        guard let denom, let amount else { throw Failure.invalidRequest }
        return try Coin(reference: ThorchainIdentity.reference(denom), amount: ThorchainSendAmount.checked(amount))
    }
    private static func depositCoin(asset: String?, amount: String?) throws -> Coin {
        // Explicit native deposit scope. External, synth, trade and secured
        // asset operations need their own review semantics before enabling.
        guard let asset, ["THOR.RUNE", "THOR.TCY"].contains(asset) else { throw Failure.unsupported }
        return try bankCoin(denom: asset == "THOR.RUNE" ? "rune" : "tcy", amount: amount)
    }
    private static func checkCoins(_ coins: [Coin]) throws {
        guard !coins.isEmpty, coins.count <= 8, Set(coins.map(\.reference)).count == coins.count else { throw Failure.invalidRequest }
    }
    private static func memo(_ j: SolanaJSON) throws -> String {
        guard let value = j.string, value.utf8.count <= 250,
              !value.unicodeScalars.contains(where: { $0.properties.isBidiControl || $0.properties.isDefaultIgnorableCodePoint || CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalidRequest }
        return value
    }
    private static func keys(_ j: SolanaJSON, required: Set<String>, optional: Set<String> = []) throws {
        guard case .object(let fields) = j, required.isSubset(of: Set(fields.keys)),
              Set(fields.keys).isSubset(of: required.union(optional)), fields.values.allSatisfy({ !$0.isNull }) else { throw Failure.invalidRequest }
    }
    private static func uint(_ j: SolanaJSON) throws -> UInt64 {
        guard let s = j.string, let n = UInt64(s), String(n) == s else { throw Failure.invalidRequest }; return n
    }
    private static func base64(_ j: SolanaJSON) throws -> Data {
        guard let s = j.string, s.utf8.count <= 43_692, let data = Data(base64Encoded: s), data.base64EncodedString() == s else { throw Failure.invalidRequest }; return data
    }

    /// Deliberately small protobuf reader: bounded input, canonical varints,
    /// no duplicate singular fields, no unknown tags or alternative wire types.
    private struct Proto {
        enum Value { case bytes(Data), number(UInt64) }
        var fields = [UInt64: [Value]]()
        init(_ data: Data, allowed: Set<UInt64>, repeated: Set<UInt64> = []) throws {
            guard data.count <= 32_768 else { throw Failure.invalidRequest }
            let bytes = Array(data); var index = 0
            func number() throws -> UInt64 {
                var value: UInt64 = 0
                for shift in stride(from: 0, through: 63, by: 7) {
                    guard index < bytes.count else { throw Failure.invalidRequest }
                    let byte = bytes[index]; index += 1
                    guard shift < 63 || byte <= 1 else { throw Failure.invalidRequest }
                    value |= UInt64(byte & 127) << shift
                    if byte & 128 == 0 {
                        guard shift == 0 || byte != 0 else { throw Failure.invalidRequest }
                        return value
                    }
                }; throw Failure.invalidRequest
            }
            while index < bytes.count {
                let key = try number(), tag = key >> 3
                guard allowed.contains(tag), fields[tag] == nil || repeated.contains(tag), (fields[tag]?.count ?? 0) < 8 else { throw Failure.unsupported }
                let value: Value
                switch key & 7 {
                case 0: value = .number(try number())
                case 2:
                    let length = try number(); guard length <= UInt64(bytes.count - index) else { throw Failure.invalidRequest }
                    let end = index + Int(length); value = .bytes(Data(bytes[index..<end])); index = end
                default: throw Failure.unsupported
                }
                fields[tag, default: []].append(value)
            }
        }
        func bytes(_ tag: UInt64) throws -> Data {
            guard fields[tag]?.count == 1, case .bytes(let data) = fields[tag]?.first else { throw Failure.invalidRequest }; return data
        }
        func allBytes(_ tag: UInt64) throws -> [Data] {
            try (fields[tag] ?? []).map { guard case .bytes(let data) = $0 else { throw Failure.invalidRequest }; return data }
        }
        func text(_ tag: UInt64, default fallback: String? = nil) throws -> String {
            if fields[tag] == nil, let fallback { return fallback }
            guard let text = String(data: try bytes(tag), encoding: .utf8) else { throw Failure.invalidRequest }; return text
        }
        func number(_ tag: UInt64) throws -> UInt64 {
            if fields[tag] == nil { return 0 }
            guard fields[tag]?.count == 1, case .number(let n) = fields[tag]?.first else { throw Failure.invalidRequest }; return n
        }
    }
}

public struct ThorchainWalletConnectReview: Sendable {
    public let fee: UInt64
    public let decimals: [String: Int]
    public let checkedAt: Date
    public let swap: ThorchainSwapQuote?
    public init(fee: UInt64, decimals: [String: Int], checkedAt: Date = .now, swap: ThorchainSwapQuote? = nil) {
        self.fee = fee; self.decimals = decimals; self.checkedAt = checkedAt; self.swap = swap
    }
}

/// A failed transaction review does not invalidate its WalletConnect session.
/// Keep protocol rejection codes and user-facing recovery consistent.
public enum ThorchainWalletConnectIssue: Sendable, Equatable {
    case invalid, unsupported, changed, expired, funding, unavailable
    public init(_ error: any Error) {
        if let failure = error as? ThorchainWalletConnectRequest.Failure {
            self = failure == .unsupported ? .unsupported : .invalid
        } else if error is WalletConnectJSON.Failure { self = .invalid }
        else if error is SendFeeFundingError { self = .funding }
        else {
            switch error as? ThorchainSendError {
            case .insufficientFunds: self = .funding
            case .expired: self = .expired
            case .changed, .metadataChanged: self = .changed
            case .wrongNetwork, .wrongOwner, .amount, .moduleRecipient: self = .invalid
            default: self = .unavailable
            }
        }
    }
    public var rpcCode: Int {
        switch self {
        case .invalid: -32602
        case .unsupported: 4200
        default: -32000
        }
    }
}

import Foundation
import CryptoKit
import OathSecp256k1

extension TronSendNetwork {
    public var walletConnectChain: String { self == .mainnet ? "tron:0x2b6653dc" : "tron:0xcd8690dc" }
    public var walletConnectName: String { self == .mainnet ? "TRON" : "TRON Nile Testnet" }
    public init?(walletConnectChain: String) {
        switch walletConnectChain {
        case "tron:0x2b6653dc": self = .mainnet
        case "tron:0xcd8690dc": self = .nile
        default: return nil
        }
    }
}

/// Reconstruct the protobuf locally. Never sign a peer-supplied hash or trust
/// JSON descriptions that differ from the bytes the network will execute.
public struct WalletConnectTronRequest: Sendable, Equatable {
    public static let methods: Set<String> = ["tron_signTransaction", "tron_signMessage"]
    public static let blockchains: Set<String> = [TronSendNetwork.mainnet.walletConnectChain, TronSendNetwork.nile.walletConnectChain]
    public let network: TronSendNetwork
    public let account: String
    public let message: String?
    public let transaction: TronJSON?
    public let raw: Data
    public let hash: String
    public let destination: String
    public let nativeValue: UInt64
    public let amount: String
    public let reference: String
    public let action: Action
    public let calldata: Data
    public let memo: Data
    public let expiration: UInt64
    public let feeLimit: UInt64
    public let refBytes: Data
    public let refHash: Data
    public enum Action: String, Sendable { case message, transfer, approval, contract }

    public init(method: String, chain: String, account: String, params: Data, now: Date = .now) throws {
        guard let network = TronSendNetwork(walletConnectChain: chain) else { throw TronSendError.wrongNetwork }
        guard Self.methods.contains(method), TronIdentity.isAddress(account) else { throw TronSendError.malformed }
        let input = try WalletConnectJSON.decode(params)
        guard try TronIdentity.address(input["address"].string ?? "") == account else { throw TronSendError.wrongOwner }
        self.network = network; self.account = account
        if method == "tron_signMessage" {
            try Self.keys(input, ["address", "message"])
            guard let text = input["message"].string, !text.isEmpty, text.utf8.count <= 8_192 else { throw TronSendError.malformed }
            message = text; transaction = nil; raw = Data(); hash = ""; destination = ""; nativeValue = 0
            amount = "0"; reference = "native"; action = .message; calldata = Data(); memo = Data()
            expiration = 0; feeLimit = 0; refBytes = Data(); refHash = Data(); return
        }
        try Self.keys(input, ["address", "transaction"])
        var tx = input["transaction"]
        if !tx["transaction"].isNull {
            // Reown's legacy wrapper may also contain the builder's result.
            try Self.keys(tx, ["transaction", "result"])
            tx = tx["transaction"]
        }
        try Self.keys(tx, ["raw_data", "raw_data_hex", "txID", "visible", "signature"])
        guard tx["signature"].isNull || tx["signature"].array == [],
              tx["visible"].isNull || tx["visible"] == .bool(true) || tx["visible"] == .bool(false) else { throw TronSendError.malformed }
        let data = tx["raw_data"]
        try Self.keys(data, ["contract", "ref_block_bytes", "ref_block_hash", "expiration", "timestamp", "fee_limit", "data"])
        guard let contracts = data["contract"].array, contracts.count == 1 else { throw TronSendError.malformed }
        let contract = contracts[0]
        try Self.keys(contract, ["type", "parameter", "Permission_id"])
        guard try Self.number(contract["Permission_id"], optional: true) == 0 else { throw TronSendError.unsupportedAccount }
        let parameter = contract["parameter"], value = parameter["value"]
        try Self.keys(parameter, ["value", "type_url"])
        guard let type = contract["type"].string, parameter["type_url"].string == "type.googleapis.com/protocol." + type,
              try TronIdentity.address(value["owner_address"].string ?? "") == account else { throw TronSendError.wrongOwner }
        func address(_ field: String) throws -> String {
            try TronIdentity.address(value[field].string ?? "")
        }
        let owner = try TronIdentity.bytes(account)
        let payload: Data, typeNumber: UInt64
        var normalizedValue: [String: TronJSON] = ["owner_address": .string(TronSendCrypto.hex(owner))]
        var action: Action = .transfer, reference = "native", calldata = Data(), native: UInt64 = 0, amount = "0"
        var destination: String
        switch type {
        case "TransferContract":
            try Self.keys(value, ["owner_address", "to_address", "amount"])
            typeNumber = 1; destination = try address("to_address")
            native = try Self.number(value["amount"]); amount = String(native)
            guard native > 0, destination != account else { throw TronSendError.amount }
            normalizedValue["to_address"] = .string(TronSendCrypto.hex(try TronIdentity.bytes(destination)))
            normalizedValue["amount"] = .number(String(native))
            payload = TronSendCrypto.field(1, owner) + TronSendCrypto.field(2, try TronIdentity.bytes(destination)) + TronSendCrypto.number(3, native)
        case "TransferAssetContract":
            try Self.keys(value, ["owner_address", "to_address", "asset_name", "amount"])
            typeNumber = 2; destination = try address("to_address")
            let units = try Self.number(value["amount"])
            let asset = tx["visible"] == .bool(true) ? Data((value["asset_name"].string ?? "").utf8) : try TronIdentity.hex(value["asset_name"].string ?? "")
            guard let id = String(data: asset, encoding: .utf8), TronIdentity.isTRC10(id), units > 0, destination != account else { throw TronSendError.amount }
            reference = id; amount = String(units)
            normalizedValue["to_address"] = .string(TronSendCrypto.hex(try TronIdentity.bytes(destination)))
            normalizedValue["amount"] = .number(String(units)); normalizedValue["asset_name"] = .string(TronSendCrypto.hex(asset))
            payload = TronSendCrypto.field(1, asset) + TronSendCrypto.field(2, owner) + TronSendCrypto.field(3, try TronIdentity.bytes(destination)) + TronSendCrypto.number(4, units)
        case "TriggerSmartContract":
            try Self.keys(value, ["owner_address", "contract_address", "call_value", "data", "call_token_value", "token_id"])
            guard try Self.number(value["call_token_value"], optional: true) == 0,
                  try Self.number(value["token_id"], optional: true) == 0 else { throw TronSendError.malformed }
            typeNumber = 31; reference = try address("contract_address"); destination = reference
            native = try Self.number(value["call_value"], optional: true)
            calldata = try TronIdentity.hex(value["data"].string ?? "")
            guard calldata.count >= 4, calldata.count <= 16_384 else { throw TronSendError.malformed }
            normalizedValue["contract_address"] = .string(TronSendCrypto.hex(try TronIdentity.bytes(reference)))
            normalizedValue["data"] = .string(TronSendCrypto.hex(calldata))
            if native > 0 { normalizedValue["call_value"] = .number(String(native)) }
            action = .contract; amount = String(native)
            if calldata.count == 68, native == 0 {
                let selector = TronSendCrypto.hex(calldata.prefix(4))
                if selector == "a9059cbb" || selector == "095ea7b3" {
                    destination = try TronIdentity.address(TronSendCrypto.hex(calldata[4..<36]))
                    amount = try TronIdentity.uint256(TronSendCrypto.hex(calldata[36..<68]))
                    action = selector == "a9059cbb" ? .transfer : .approval
                }
            }
            payload = TronSendCrypto.field(1, owner) + TronSendCrypto.field(2, try TronIdentity.bytes(reference)) + TronSendCrypto.number(3, native) + TronSendCrypto.field(4, calldata)
        default: throw TronSendError.unsupportedAccount
        }
        let refBytes = try TronIdentity.hex(data["ref_block_bytes"].string ?? "")
        let refHash = try TronIdentity.hex(data["ref_block_hash"].string ?? "")
        let expiration = try Self.number(data["expiration"]), timestamp = try Self.number(data["timestamp"])
        let fee = try Self.number(data["fee_limit"], optional: true)
        let memo = try TronIdentity.hex(data["data"].string ?? "")
        guard refBytes.count == 2, refHash.count == 8, memo.count <= 1_024,
              timestamp <= expiration, Double(timestamp) <= now.timeIntervalSince1970 * 1_000 + 60_000,
              Double(expiration) <= now.timeIntervalSince1970 * 1_000 + 86_400_000,
              fee <= TronSendPlan.maximumFee, typeNumber != 31 || fee > 0 else { throw TronSendError.malformed }
        let any = TronSendCrypto.field(1, Data(("type.googleapis.com/protocol." + type).utf8)) + TronSendCrypto.field(2, payload)
        let encodedContract = TronSendCrypto.number(1, typeNumber) + TronSendCrypto.field(2, any)
        let raw = TronSendCrypto.field(1, refBytes) + TronSendCrypto.field(4, refHash) + TronSendCrypto.number(8, expiration) + TronSendCrypto.field(10, memo) + TronSendCrypto.field(11, encodedContract) + TronSendCrypto.number(14, timestamp) + TronSendCrypto.number(18, fee)
        let hash = TronSendCrypto.hex(Data(SHA256.hash(data: raw)))
        if !tx["raw_data_hex"].isNull { guard try TronIdentity.hex(tx["raw_data_hex"].string ?? "") == raw else { throw TronSendError.changed } }
        if !tx["txID"].isNull { guard tx["txID"].string?.lowercased() == hash else { throw TronSendError.changed } }
        var normalizedData: [String: TronJSON] = [
            "ref_block_bytes": .string(TronSendCrypto.hex(refBytes)), "ref_block_hash": .string(TronSendCrypto.hex(refHash)),
            "expiration": .number(String(expiration)), "timestamp": .number(String(timestamp)),
            "contract": .array([.object(["type": .string(type), "parameter": .object([
                "type_url": .string("type.googleapis.com/protocol." + type), "value": .object(normalizedValue)])])])]
        if fee > 0 { normalizedData["fee_limit"] = .number(String(fee)) }
        if !memo.isEmpty { normalizedData["data"] = .string(TronSendCrypto.hex(memo)) }
        self.message = nil; self.transaction = .object(["raw_data":.object(normalizedData), "raw_data_hex":.string(TronSendCrypto.hex(raw)), "txID":.string(hash), "visible":.bool(false)])
        self.raw = raw; self.hash = hash; self.destination = destination; self.nativeValue = native
        self.amount = amount; self.reference = reference; self.action = action; self.calldata = calldata; self.memo = memo
        self.expiration = expiration; self.feeLimit = fee; self.refBytes = refBytes; self.refHash = refHash
        try validateTime(now: now)
    }
    public func validateTime(now: Date = .now) throws {
        guard message != nil || Double(expiration) > now.timeIntervalSince1970 * 1_000 + 5_000 else { throw TronSendError.expired }
    }
    static func referenceHeight(head: UInt64, bytes: Data) throws -> UInt64 {
        guard bytes.count == 2, head <= UInt64(Int64.max) else { throw TronSendError.malformed }
        let low = bytes.reduce(UInt64(0)) { $0 * 256 + UInt64($1) }
        let forward = (low + 65_536 - (head & 65_535)) % 65_536
        // Load-balanced nodes may trail the node that built the transaction.
        // The fetched block hash must still match the signed TAPOS reference.
        if forward <= 20 { return head + forward }
        let back = 65_536 - forward
        guard head >= back else { throw TronSendError.wrongNetwork }
        return head - back
    }
    static func keys(_ json: TronJSON, _ allowed: Set<String>) throws {
        guard let fields = json.fields, Set(fields.keys).isSubset(of: allowed) else { throw TronSendError.malformed }
    }
    static func number(_ json: TronJSON, optional: Bool = false) throws -> UInt64 {
        if optional, json.isNull { return 0 }
        guard let value = json.integer, value <= UInt64(Int64.max) else { throw TronSendError.malformed }
        return value
    }
    public func sign(privateKey: Data, now: Date = .now) throws -> TronJSON {
        guard try TronSendCrypto.address(privateKey: privateKey) == account else { throw TronSendError.wrongOwner }
        try validateTime(now: now)
        let digest: Data
        if let message {
            let bytes = Data(message.utf8)
            digest = TronSendCrypto.keccak(Data(("\u{19}TRON Signed Message:\n" + String(bytes.count)).utf8) + bytes)
        } else { digest = Data(SHA256.hash(data: raw)) }
        var signature = try OathSecp256k1.signRecoverable(digest, key: privateKey)
        // Match TronWeb's recoverable signature representation.
        signature[64] += 27
        if message != nil { return .object(["signature":.string("0x" + TronSendCrypto.hex(signature))]) }
        guard var fields = transaction?.fields else { throw TronSendError.malformed }
        fields["signature"] = .array([.string(TronSendCrypto.hex(signature))])
        return .object(fields)
    }
}

public struct WalletConnectTronReview: Sendable, Equatable {
    public let request: WalletConnectTronRequest
    public let maximumFee: UInt64
    public let symbol: String
    public let decimals: Int
    public let createdAt: Date
    public func validate(now: Date = .now) throws {
        try request.validateTime(now: now)
        guard (-5...90).contains(now.timeIntervalSince(createdAt)) else { throw TronSendError.expired }
    }
}

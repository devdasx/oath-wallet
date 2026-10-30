import Foundation
import CryptoKit

public extension SuiSendNetwork {
    var walletConnectChain: String { "sui:" + rawValue }
    var walletConnectName: String { self == .mainnet ? "Sui" : "Sui Testnet" }
    init?(walletConnectChain: String) {
        guard let network = Self(rawValue: String(walletConnectChain.dropFirst(4))), walletConnectChain == network.walletConnectChain else { return nil }
        self = network
    }
}

public struct WalletConnectSuiRequest: Sendable, Equatable, Codable {
    public static let signingMethods: Set<String> = ["sui_signTransaction", "sui_signAndExecuteTransaction", "sui_signPersonalMessage"]
    public static let methods = signingMethods.union(["sui_getAccounts"])
    public let method: String, account: String
    public let network: SuiSendNetwork
    public let message: Data?, transaction: Data?
    public var broadcasts: Bool { method == "sui_signAndExecuteTransaction" }
    public var fingerprint: String {
        SHA256.hash(data: Data((network.walletConnectChain + ":" + method + ":" + account).utf8) + (transaction ?? message ?? Data())).map { String(format:"%02x",$0) }.joined()
    }
    public init(method:String, chain:String, account:String, params:Data) throws {
        guard Self.methods.contains(method), let network = SuiSendNetwork(walletConnectChain:chain), params.count <= 180_000 else { throw SuiSendError.wrongNetwork }
        let input = try WalletConnectJSON.decode(params)
        guard let fields = input.fields else { throw SuiSendError.malformed }
        self.method = method; self.network = network; self.account = try SuiIdentity.address(account)
        if method == "sui_getAccounts" {
            guard fields.isEmpty else { throw SuiSendError.malformed }; message = nil; transaction = nil; return
        }
        guard try SuiIdentity.address(input["address"].string ?? "") == self.account else { throw SuiSendError.wrongOwner }
        if method == "sui_signPersonalMessage" {
            guard Set(fields.keys) == ["address","message"], let text = input["message"].string, !text.isEmpty, text.utf8.count <= 8_192 else { throw SuiSendError.malformed }
            // Reown's RPC encodes personal messages as plain text, not base64.
            message = Data(text.utf8); transaction = nil
        } else {
            guard Set(fields.keys) == ["address","transaction"], let text = input["transaction"].string,
                  let bytes = Data(base64Encoded:text), bytes.base64EncodedString() == text,
                  !bytes.isEmpty, bytes.count <= 128_000 else { throw SuiSendError.malformed }
            message = nil; transaction = bytes
            _ = try WalletConnectSuiTransaction(bytes, network:network, account:self.account, executing:broadcasts)
        }
    }
    public func sign(privateKey:Data, review:WalletConnectSuiReview? = nil, now:Date = .now) throws -> WalletConnectSuiSignature {
        guard try SuiSendCrypto.address(privateKey:privateKey) == account else { throw SuiSendError.wrongOwner }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey)
        let payload: Data
        if let message { payload = Data([3,0,0]) + SuiBCS.vector(message) }
        else {
            guard let transaction, let review, review.request == self, now.timeIntervalSince(review.createdAt) >= 0,
                  now.timeIntervalSince(review.createdAt) <= 120 else { throw SuiSendError.expired }
            _ = try WalletConnectSuiTransaction(transaction,network:network,account:account,executing:broadcasts,now:now)
            payload = Data([0,0,0]) + transaction
        }
        let signature = Data([0]) + (try key.signature(for:SuiSendCrypto.hash(payload))) + key.publicKey.rawRepresentation
        let signed = transaction.map { SuiSignedSend(bytes:$0,signature:signature,digest:SuiSendCrypto.digest($0)) }
        return .init(signature:signature.base64EncodedString(), transaction:signed)
    }
    public static func accountResponse(publicKey:Data) throws -> [[String:String]] {
        guard publicKey.count == 32 else { throw SuiSendError.wrongOwner }
        let address = "0x" + SuiSendCrypto.hash(Data([0]) + publicKey).map { String(format:"%02x",$0) }.joined()
        return [["address":address,"pubkey":publicKey.base64EncodedString()]]
    }
}
public struct WalletConnectSuiSignature: Sendable {
    public let signature:String
    public let transaction:SuiSignedSend?
    public var response: [String:String] {
        if let transaction { return ["signature":signature,"transactionBytes":transaction.bytes.base64EncodedString()] }
        return ["signature":signature]
    }
}
public struct WalletConnectSuiReview: Sendable, Equatable, Codable {
    public let request:WalletConnectSuiRequest
    public let changes:[String]
    public var tokens:[String:SuiToken] = [:]
    public let details:[String], gasOwner:String
    public let gasBudget:UInt64
    public let estimatedFee:UInt64
    public let createdAt:Date
}

/// Decode the complete transaction before signing; never infer the sender or fee
/// from the request envelope. Limits also bound adversarial BCS allocations.
public struct WalletConnectSuiTransaction: Sendable {
    public let sender:String, gasOwner:String
    public let gasPrice:UInt64, gasBudget:UInt64
    public let commands:[String], inputs:[String]
    public let minimumEpoch:UInt64?, maximumEpoch:UInt64?
    public init(_ bytes:Data, network:SuiSendNetwork, account:String, executing:Bool, now:Date = .now) throws {
        guard !bytes.isEmpty, bytes.count <= 128_000 else { throw SuiSendError.malformed }
        var r = SuiConnectBCS(bytes:bytes)
        guard try r.length(3) == 0, try r.length(10) == 0 else { throw SuiSendError.malformed }
        var inputs = [String](), commands = [String]()
        for _ in 0..<(try r.length(512)) {
            switch try r.length(3) {
            case 0: inputs.append("Pure: " + (try r.vector(16_384)).base64EncodedString())
            case 1:
                let kind = try r.length(3)
                if kind == 1 {
                    let id = try r.address(), version = try r.uint(8), mutable = try r.length(1)
                    inputs.append("Shared object: \(id), version \(version), mutable \(mutable == 1)")
                } else if kind == 0 || kind == 2 { inputs.append(try r.object()) }
                else { throw SuiSendError.malformed }
            case 2:
                guard try r.length(1) == 0 else { throw SuiSendError.malformed }
                let amount = try r.uint(8)
                guard try r.length(1) == 0 else { throw SuiSendError.malformed }
                let type = try r.type(), source = try r.length(2)
                var owner = source == 0 ? "sender" : "sponsor"
                if source == 2 { owner = try r.address() + " allowance " + r.address() }
                inputs.append("Withdraw \(amount) atomic \(type) from \(owner)")
            default: throw SuiSendError.malformed
            }
        }
        r.inputCount = inputs.count
        for index in 0..<(try r.length(512)) {
            r.commandIndex = index
            switch try r.length(7) {
            case 0:
                let target = try r.address() + "::" + r.identifier() + "::" + r.identifier()
                var types = [String]()
                for _ in 0..<(try r.length(64)) { types.append(try r.type()) }
                commands.append(try target + "<" + types.joined(separator:",") + ">(" + r.arguments() + ")")
            case 1: commands.append(try "TransferObjects " + r.arguments() + " to " + r.argument())
            case 2: commands.append(try "SplitCoins " + r.argument() + " amounts " + r.arguments())
            case 3: commands.append(try "MergeCoins " + r.argument() + " sources " + r.arguments())
            case 4, 6:
                // Publishing/upgrading code is not an ordinary transfer, but the
                // modules and dependencies are still fully bound to the signature.
                let kind = bytes[r.lastEnumOffset]
                var hashes = [String]()
                for _ in 0..<(try r.length(64)) { hashes.append(SuiSendCrypto.hash(try r.vector(128_000)).map { String(format:"%02x",$0) }.joined()) }
                var deps = [String]()
                for _ in 0..<(try r.length(128)) { deps.append(try r.address()) }
                var detail = "Publish modules " + hashes.joined(separator:",") + " dependencies " + deps.joined(separator:",")
                if kind == 6 { detail = try "Upgrade " + r.address() + " ticket " + r.argument() + ": " + detail }
                commands.append(detail)
            case 5:
                let hasType = try r.length(1), type = hasType == 1 ? try r.type() : "inferred"
                commands.append(try "MakeMoveVec<" + type + "> " + r.arguments())
            default: throw SuiSendError.malformed
            }
        }
        guard !commands.isEmpty else { throw SuiSendError.malformed }
        sender = try r.address()
        var gasObjects = Set<String>()
        for _ in 0..<(try r.length(256)) {
            guard gasObjects.insert(try r.object()).inserted else { throw SuiSendError.malformed }
        }
        gasOwner = try r.address(); gasPrice = try r.uint(8); gasBudget = try r.uint(8)
        guard sender == (try SuiIdentity.address(account)), !executing || gasOwner == sender else { throw SuiSendError.wrongOwner }
        guard gasPrice > 0, gasBudget > 0 else { throw SuiSendError.malformed }
        let expiration = try r.length(3)
        var minimumEpoch:UInt64?, maximumEpoch:UInt64?
        if expiration == 1 { maximumEpoch = try r.uint(8) }
        if expiration == 2 || expiration == 3 {
            minimumEpoch = try r.optionalUInt(); maximumEpoch = try r.optionalUInt()
            let minTime = try r.optionalUInt(), maxTime = try r.optionalUInt()
            let time = now.timeIntervalSince1970 * 1000
            guard minTime.map({ Double($0) <= time }) ?? true, maxTime.map({ time <= Double($0) }) ?? true else { throw SuiSendError.expired }
            guard try SuiSendCrypto.base58(r.vector(32)) == network.chainIdentifier else { throw SuiSendError.wrongNetwork }
            _ = try r.uint(4)
            if expiration == 3, try r.length(1) == 1 {
                _ = try r.uint(8)
                var previous:UInt64?
                let count = try r.length(512); guard count > 0 else { throw SuiSendError.malformed }
                for _ in 0..<count { let next = try r.uint(4); guard previous.map({next > $0}) ?? true else { throw SuiSendError.malformed }; previous = next }
            }
        }
        guard r.offset == bytes.count, minimumEpoch == nil || maximumEpoch == nil || minimumEpoch! <= maximumEpoch! else { throw SuiSendError.malformed }
        self.minimumEpoch = minimumEpoch; self.maximumEpoch = maximumEpoch
        self.inputs = inputs; self.commands = commands
    }
}
private struct SuiConnectBCS {
    let bytes:Data
    var offset = 0, lastEnumOffset = 0, inputCount = 0, commandIndex = 0
    mutating func take(_ n:Int) throws -> Data {
        guard n >= 0, n <= bytes.count-offset else { throw SuiSendError.malformed }
        defer { offset += n }; return bytes.subdata(in:offset..<offset+n)
    }
    mutating func uint(_ n:Int) throws -> UInt64 {
        try take(n).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset*8) }
    }
    mutating func length(_ maximum:Int) throws -> Int {
        lastEnumOffset = offset
        var value = 0
        for i in 0..<5 {
            let byte = Int(try uint(1)); value |= (byte & 127) << (7*i)
            if byte < 128 { guard value <= maximum, i == 0 || byte != 0 else { throw SuiSendError.malformed }; return value }
        }
        throw SuiSendError.malformed
    }
    mutating func vector(_ maximum:Int) throws -> Data { try take(length(maximum)) }
    mutating func address() throws -> String { "0x" + (try take(32)).map { String(format:"%02x",$0) }.joined() }
    mutating func object() throws -> String {
        let id = try address(), version = try uint(8), digest = try vector(32)
        guard digest.count == 32 else { throw SuiSendError.malformed }
        return id + " @ " + String(version) + " / " + SuiSendCrypto.base58(digest)
    }
    mutating func identifier() throws -> String {
        guard let value = String(data:try vector(128),encoding:.utf8), !value.isEmpty,
              value.utf8.allSatisfy({(65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95}) else { throw SuiSendError.malformed }; return value
    }
    mutating func type(_ depth:Int = 0) throws -> String {
        guard depth < 16 else { throw SuiSendError.malformed }
        switch try length(10) {
        case 0:return "bool"; case 1:return "u8"; case 2:return "u64"; case 3:return "u128"; case 4:return "address"; case 5:return "signer"
        case 6:return try "vector<" + type(depth+1) + ">"
        case 7:
            let name = try address() + "::" + identifier() + "::" + identifier()
            var types = [String](); for _ in 0..<(try length(64)) { types.append(try type(depth+1)) }
            return name + (types.isEmpty ? "" : "<" + types.joined(separator:",") + ">")
        case 8:return "u16"; case 9:return "u32"; case 10:return "u256"
        default:throw SuiSendError.malformed
        }
    }
    mutating func argument() throws -> String {
        switch try length(3) {
        case 0:return "GasCoin"
        case 1:let index = try uint(2); guard index < inputCount else { throw SuiSendError.malformed }; return "Input[\(index)]"
        case 2:let index = try uint(2); guard index < commandIndex else { throw SuiSendError.malformed }; return "Result[\(index)]"
        case 3:let index = try uint(2), nested = try uint(2); guard index < commandIndex else { throw SuiSendError.malformed }; return "Result[\(index),\(nested)]"
        default:throw SuiSendError.malformed
        }
    }
    mutating func arguments() throws -> String {
        var values = [String](); for _ in 0..<(try length(512)) { values.append(try argument()) }; return values.joined(separator:", ")
    }
    mutating func optionalUInt() throws -> UInt64? { try length(1) == 1 ? uint(8) : nil }
}

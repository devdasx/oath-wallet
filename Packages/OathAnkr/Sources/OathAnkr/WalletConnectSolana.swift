import Foundation
import CryptoKit

public extension SolanaSendNetwork {
    var walletConnectChain: String { "solana:" + genesis.prefix(32) }
    init?(walletConnectChain: String) {
        guard let value = [Self.mainnet, .devnet, .testnet].first(where: { $0.walletConnectChain == walletConnectChain }) else { return nil }
        self = value
    }
    var walletConnectName: String { self == .mainnet ? "Solana" : "Solana " + rawValue.capitalized }
}

/// Immutable wire intent. Never rebuild a dApp transaction, replace its blockhash,
/// change fee instructions or discard another signer's signature.
public struct WalletConnectSolanaRequest: Sendable, Equatable {
    public static let signingMethods: Set<String> = ["solana_signMessage", "solana_signTransaction", "solana_signAllTransactions", "solana_signAndSendTransaction"]
    public static let methods = signingMethods.union(["solana_getAccounts", "solana_requestAccounts"])
    public let network: SolanaSendNetwork
    public let method: String, account: String
    public let message: Data?
    public let transactions: [WalletConnectSolanaTransaction]
    public let minContextSlot: UInt64
    public var fingerprint: String {
        let fields = [network.walletConnectChain, method, account, String(minContextSlot), message?.base64EncodedString() ?? ""] + transactions.map { $0.bytes.base64EncodedString() }
        return SHA256.hash(data: Data(fields.joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public var broadcasts: Bool { method == "solana_signAndSendTransaction" }
    public init(method: String, chain: String, account: String, params: Data) throws {
        guard let network = SolanaSendNetwork(walletConnectChain: chain) else { throw SolanaSendError.wrongNetwork }
        guard Self.signingMethods.contains(method), SolanaIdentity.isAddress(account) else { throw SolanaSendError.wrongOwner }
        let json = try WalletConnectJSON.decode(params)
        guard case .object = json else { throw SolanaSendError.malformed }
        if !json["pubkey"].isNull, json["pubkey"].string != account { throw SolanaSendError.wrongOwner }
        self.network = network; self.method = method; self.account = account
        if method == "solana_signMessage" {
            guard json["pubkey"].string == account, let encoded = json["message"].string else { throw SolanaSendError.malformed }
            let bytes = try Self.decodeMessage(encoded)
            // Text signing must not become an alternate transaction-signing API.
            // Common SIWS and dApp challenges are UTF-8. Binary messages are not
            // offered until a separate, unambiguous binary review is available.
            guard !bytes.isEmpty, let text = String(data: bytes, encoding: .utf8),
                  !text.unicodeScalars.contains(where: { $0.properties.isBidiControl || $0.properties.isDefaultIgnorableCodePoint || ($0.value < 32 && $0.value != 9 && $0.value != 10) || $0.value == 127 }),
                  bytes.first.map({ $0 >= 32 && $0 != 128 }) == true else { throw SolanaSendError.malformed }
            message = bytes; transactions = []; minContextSlot = 0
        } else {
            message = nil
            let encoded: [String]
            if method == "solana_signAllTransactions" {
                guard let values = json["transactions"].array, (1...8).contains(values.count), values.allSatisfy({ $0.string != nil }) else { throw SolanaSendError.malformed }
                encoded = values.compactMap(\.string)
            } else {
                guard let value = json["transaction"].string else { throw SolanaSendError.malformed }; encoded = [value]
            }
            transactions = try encoded.map {
                guard $0.utf8.count <= 1644, let bytes = Data(base64Encoded: $0), bytes.base64EncodedString() == $0 else { throw SolanaSendError.malformed }
                return try WalletConnectSolanaTransaction(bytes: bytes, account: account)
            }
            let options = json["sendOptions"]
            if !options.isNull { guard case .object = options else { throw SolanaSendError.malformed } }
            if !options["minContextSlot"].isNull, options["minContextSlot"].integer == nil { throw SolanaSendError.malformed }
            minContextSlot = options["minContextSlot"].integer ?? 0
        }
    }
    private static func decodeMessage(_ text: String) throws -> Data {
        guard !text.isEmpty, text.utf8.count <= 5594 else { throw SolanaSendError.malformed }
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
        var bytes = [UInt8]()
        for c in text.utf8 {
            guard let n = alphabet.firstIndex(of: c) else { throw SolanaSendError.malformed }
            var carry = n
            for i in bytes.indices { carry += Int(bytes[i]) * 58; bytes[i] = UInt8(carry & 255); carry >>= 8 }
            while carry > 0 { bytes.append(UInt8(carry & 255)); carry >>= 8 }
            guard bytes.count <= 4096 else { throw SolanaSendError.malformed }
        }
        let result = Data(Array(repeating: UInt8(0), count: text.utf8.prefix(while: { $0 == 49 }).count) + bytes.reversed())
        guard result.count <= 4096 else { throw SolanaSendError.malformed }; return result
    }
    public func sign(privateKey: Data) throws -> WalletConnectSolanaSigned {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        guard SolanaSendCrypto.encode(key.publicKey.rawRepresentation) == account else { throw SolanaSendError.wrongOwner }
        if let message {
            return .init(response: .object(["signature": .string(SolanaSendCrypto.encode(try key.signature(for: message)))]), transactions: [])
        }
        let signed = try transactions.map { try $0.sign(key) }
        let response: SolanaJSON
        if method == "solana_signAllTransactions" { response = .object(["transactions": .array(signed.map { .string($0.base64EncodedString()) })]) }
        else {
            let transaction = transactions[0], bytes = signed[0]
            let signature = bytes.subdata(in: transaction.signatureOffset + transaction.signerIndex * 64 ..< transaction.signatureOffset + (transaction.signerIndex + 1) * 64)
            response = .object(["signature": .string(SolanaSendCrypto.encode(signature)), "transaction": .string(bytes.base64EncodedString())])
        }
        return .init(response: response, transactions: signed)
    }
}
public struct WalletConnectSolanaSigned: Sendable {
    public let response: SolanaJSON
    public let transactions: [Data]
}

public struct WalletConnectSolanaTransaction: Sendable, Equatable {
    public struct Instruction: Sendable, Equatable { public let program: Int, accounts: [Int], data: Data }
    public struct Lookup: Sendable, Equatable { public let address: String, writable: [Int], readonly: [Int] }
    public let bytes: Data, message: Data
    public let keys: [String], writable: Set<Int>, instructions: [Instruction], lookups: [Lookup]
    public let blockhash: String, signerIndex: Int, signatureCount: Int, signatureOffset: Int
    public let version: Int?
    public var feePayer: String { keys[0] }
    public init(bytes: Data, account: String) throws {
        guard bytes.count <= 1232 else { throw SolanaSendError.malformed }
        var r = Reader(bytes: Array(bytes))
        let signatures = try r.short(); guard (1...19).contains(signatures) else { throw SolanaSendError.malformed }
        signatureCount = signatures; signatureOffset = r.offset
        let signatureBytes = try r.take(signatures * 64), messageStart = r.offset
        let first = try r.byte()
        let required: Int
        if first & 128 != 0 { guard first == 128 else { throw SolanaSendError.malformed }; version = 0; required = try r.byte() }
        else { version = nil; required = first }
        let readonlySigned = try r.byte(), readonlyUnsigned = try r.byte(), count = try r.short()
        guard required == signatures, count >= required, count <= 256, readonlySigned < required, readonlyUnsigned <= count - required else { throw SolanaSendError.malformed }
        var keys = [String]()
        for _ in 0..<count { keys.append(SolanaSendCrypto.encode(Data(try r.take(32)))) }
        guard Set(keys).count == keys.count, let signer = keys.prefix(required).firstIndex(of: account) else { throw SolanaSendError.wrongOwner }
        self.keys = keys; signerIndex = signer
        writable = Set((0..<count).filter { $0 < required ? $0 < required - readonlySigned : $0 < count - readonlyUnsigned })
        blockhash = SolanaSendCrypto.encode(Data(try r.take(32)))
        let instructionCount = try r.short(); guard (1...128).contains(instructionCount) else { throw SolanaSendError.malformed }
        var instructions = [Instruction]()
        for _ in 0..<instructionCount {
            let program = try r.byte(), count = try r.short(), accounts = try r.take(count).map(Int.init), length = try r.short()
            guard program > 0, program < keys.count else { throw SolanaSendError.malformed }
            instructions.append(.init(program: program, accounts: accounts, data: Data(try r.take(length))))
        }
        var lookups = [Lookup]()
        if version != nil {
            let count = try r.short(); guard count <= 32 else { throw SolanaSendError.malformed }
            for _ in 0..<count {
                let address = SolanaSendCrypto.encode(Data(try r.take(32))), wc = try r.short(), wi = try r.take(wc).map(Int.init), rc = try r.short(), ri = try r.take(rc).map(Int.init)
                guard !wi.isEmpty || !ri.isEmpty, Set(wi + ri).count == wi.count + ri.count else { throw SolanaSendError.malformed }
                lookups.append(.init(address: address, writable: wi, readonly: ri))
            }
        }
        let total = keys.count + lookups.reduce(0) { $0 + $1.writable.count + $1.readonly.count }
        guard total <= 256, r.offset == bytes.count, instructions.allSatisfy({ $0.accounts.allSatisfy { $0 < total } }) else { throw SolanaSendError.malformed }
        self.bytes = bytes; message = bytes.subdata(in: messageStart..<bytes.count); self.instructions = instructions; self.lookups = lookups
        for i in 0..<required {
            let signature = Data(signatureBytes[i * 64..<(i + 1) * 64])
            if signature.contains(where: { $0 != 0 }) {
                guard try Curve25519.Signing.PublicKey(rawRepresentation: SolanaSendCrypto.decode(keys[i])).isValidSignature(signature, for: message) else { throw SolanaSendError.signing }
            }
        }
    }
    fileprivate func sign(_ key: Curve25519.Signing.PrivateKey) throws -> Data {
        guard SolanaSendCrypto.encode(key.publicKey.rawRepresentation) == keys[signerIndex] else { throw SolanaSendError.wrongOwner }
        var result = bytes
        result.replaceSubrange(signatureOffset + signerIndex * 64 ..< signatureOffset + (signerIndex + 1) * 64, with: try key.signature(for: message))
        return result
    }
    public func verifySigned(_ signed: Data, requireAll: Bool) throws {
        let parsed = try Self(bytes: signed, account: keys[signerIndex])
        guard parsed.message == message, parsed.signatureCount == signatureCount else { throw SolanaSendError.changed }
        for i in 0..<signatureCount {
            let range = signatureOffset + i * 64 ..< signatureOffset + (i + 1) * 64
            if requireAll || i == signerIndex { guard signed[range].contains(where: { $0 != 0 }) else { throw SolanaSendError.signing } }
            if i != signerIndex { guard signed[range] == bytes[range] else { throw SolanaSendError.changed } }
        }
    }
    struct Reader {
        let bytes: [UInt8]; var offset = 0
        mutating func byte() throws -> Int { Int(try take(1)[0]) }
        mutating func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, n <= bytes.count - offset else { throw SolanaSendError.malformed }
            defer { offset += n }; return Array(bytes[offset..<offset+n])
        }
        mutating func short() throws -> Int {
            var value = 0
            for i in 0..<3 {
                let byte = try byte(); value |= (byte & 127) << (7 * i)
                if byte & 128 == 0 { guard value <= 65535, i == 0 || byte != 0 else { throw SolanaSendError.malformed }; return value }
            }
            throw SolanaSendError.malformed
        }
    }
}

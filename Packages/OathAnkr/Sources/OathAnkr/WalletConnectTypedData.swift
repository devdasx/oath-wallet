import Foundation
import OathSecp256k1

/// EIP-712 v4, including arrays and nested structs. Review and signing share
/// this immutable value. No key, request body, or signed field is diagnostic data.
public struct WalletConnectTypedData: Sendable, Equatable {
    public enum Failure: Error, Sendable, Equatable {
        case malformed, unsupportedType, limits, wrongChain, wrongOwner, signing, expired
    }
    public struct Field: Sendable, Equatable {
        public let name: String, type: String
        public init(_ name: String, _ type: String) { self.name = name; self.type = type }
    }
    public struct ReviewField: Sendable, Equatable {
        public let path: String, type: String, value: String
    }
    public enum Permission: Sendable, Equatable {
        case erc2612(token: String, owner: String, spender: String, amount: String, nonce: String, deadline: String)
        case permit2Allowance(token: String, spender: String, amount: String, nonce: String, expiration: String, deadline: String)
        case permit2Transfer(token: String, spender: String, amount: String, nonce: String, deadline: String)
    }
    public let types: [String: [Field]]
    public let primaryType: String
    public let sessionChainID: UInt64
    public let domain: SolanaJSON, message: SolanaJSON
    public let domainSeparator: Data, messageHash: Data, digest: Data
    public let chainID: String?
    public let verifyingContract: String?
    public let fields: [ReviewField]
    public let permission: Permission?

    public init(json: Data, chainID expectedChain: UInt64, account: String) throws {
        let json = try WalletConnectJSON.decode(json)
        guard case .object(let root) = json, Set(root.keys) == ["types", "primaryType", "domain", "message"],
              case .object(let definitions) = json["types"], (1...64).contains(definitions.count),
              let primary = json["primaryType"].string, primary != "EIP712Domain" else { throw Failure.malformed }
        var parsed = [String: [Field]](), totalFields = 0
        for (name, definition) in definitions {
            guard Self.identifier(name), !Self.reserved(name), let rows = definition.array, rows.count <= 64 else { throw Failure.unsupportedType }
            var fields = [Field](), names = Set<String>()
            for row in rows {
                guard case .object(let object) = row, Set(object.keys) == ["name", "type"],
                      let fieldName = row["name"].string, Self.identifier(fieldName), names.insert(fieldName).inserted,
                      let fieldType = row["type"].string, fieldType.utf8.count <= 128 else { throw Failure.malformed }
                fields.append(.init(fieldName, fieldType)); totalFields += 1
            }
            parsed[name] = fields
        }
        guard totalFields <= 512, parsed[primary] != nil, let domainFields = parsed["EIP712Domain"] else { throw Failure.limits }
        let domainTypes = ["name": "string", "version": "string", "chainId": "uint256", "verifyingContract": "address", "salt": "bytes32"]
        guard domainFields.allSatisfy({ domainTypes[$0.name] == $0.type }) else { throw Failure.unsupportedType }
        let encoder = Encoder(types: parsed)
        for definition in parsed.values { for field in definition { try encoder.validate(type: field.type) } }
        let domain = json["domain"], message = json["message"]
        // Missing chain binding remains visible in the generic review. A
        // supplied chain must match the session, including values above 2^53.
        let chain: String?
        if domainFields.contains(where: { $0.name == "chainId" }) {
            chain = try Self.unsigned(domain["chainId"], bits: 256).decimal
            guard chain == String(expectedChain) else { throw Failure.wrongChain }
        } else { chain = nil }
        let contract = domainFields.contains(where: { $0.name == "verifyingContract" }) ? try Self.address(domain["verifyingContract"]) : nil
        var budget = 4_096
        let domainHash = try encoder.structure("EIP712Domain", value: domain, depth: 0, budget: &budget)
        let messageHash = try encoder.structure(primary, value: message, depth: 0, budget: &budget)
        self.types = parsed; self.primaryType = primary; self.sessionChainID = expectedChain; self.domain = domain; self.message = message
        self.chainID = chain; self.verifyingContract = contract
        self.domainSeparator = domainHash; self.messageHash = messageHash
        self.digest = TronSendCrypto.keccak(Data([0x19, 0x01]) + domainHash + messageHash)
        var review = [ReviewField]()
        encoder.review(type: "EIP712Domain", value: domain, path: "domain", into: &review)
        encoder.review(type: primary, value: message, path: "message", into: &review)
        self.fields = review
        self.permission = try Self.permission(primary: primary, types: parsed, domain: domain, message: message,
                                              contract: contract, chain: chain, account: account)
    }

    public func sign(privateKey: Data, account: String) throws -> String {
        try Task.checkCancellation()
        guard try ArcSendCrypto.address(privateKey: privateKey).lowercased() == account.lowercased() else { throw Failure.wrongOwner }
        let signature = try OathSecp256k1.signRecoverable(digest, key: privateKey)
        guard signature.count == 65, let recovery = signature.last, recovery <= 1,
              try OathSecp256k1.recover(signature, digest: digest) == OathSecp256k1.publicKey(privateKey, compressed: false) else { throw Failure.signing }
        return "0x" + TronSendCrypto.hex(Data(signature.prefix(64)) + Data([recovery + 27]))
    }

    /// Check recognizable permission time bounds again after authentication.
    /// Large uint256 deadlines are valid; avoid converting them through Double.
    /// Permit2 expiration == 0 means the current block timestamp, not "expired".
    public func validatePermissionTime(now: Date = .now) throws {
        let deadline: String?, expiration: String?
        switch permission {
        case .erc2612(_, _, _, _, _, let value): deadline = value; expiration = nil
        case .permit2Allowance(_, _, _, _, let expires, let value): deadline = value; expiration = expires
        case .permit2Transfer(_, _, _, _, let value): deadline = value; expiration = nil
        case nil: return
        }
        let seconds = String(UInt64(max(0, now.timeIntervalSince1970.rounded(.down))))
        func beforeNow(_ raw: String) -> Bool {
            raw.count < seconds.count || (raw.count == seconds.count && raw < seconds)
        }
        if let deadline, beforeNow(deadline) { throw Failure.expired }
        if let expiration, expiration != "0", beforeNow(expiration) { throw Failure.expired }
    }

    /// Present invisible/control characters explicitly without changing the
    /// bytes that will be signed. Never silently normalize a signed string.
    public static func visible(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            if scalar.properties.isBidiControl || scalar.properties.isDefaultIgnorableCodePoint || scalar.value < 32 || scalar.value == 127 {
                return String(format: "\\u{%04X}", scalar.value)
            }
            return String(scalar)
        }.joined()
    }
    private static func identifier(_ text: String) -> Bool {
        guard (1...64).contains(text.utf8.count), let first = text.utf8.first,
              (65...90).contains(first) || (97...122).contains(first) || first == 95 else { return false }
        return text.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }
    private static func reserved(_ text: String) -> Bool {
        if ["address", "bool", "string", "bytes", "uint", "int"].contains(text) { return true }
        return ["uint", "int", "bytes"].contains { prefix in text.hasPrefix(prefix) && !text.dropFirst(prefix.count).isEmpty && text.dropFirst(prefix.count).utf8.allSatisfy({ (48...57).contains($0) }) }
    }
    private static func address(_ value: SolanaJSON) throws -> String {
        guard let text = value.string, text.count == 42, text.hasPrefix("0x"),
              text.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw Failure.malformed }
        return text.lowercased()
    }
    private static func numeric(_ value: SolanaJSON) throws -> String {
        switch value {
        case .string(let text): return text
        case .number(let text):
            // JSON integer literals are retained losslessly by our parser.
            return text
        default: throw Failure.malformed
        }
    }
    private static func unsigned(_ value: SolanaJSON, bits: Int) throws -> (bytes: Data, decimal: String) {
        let raw = try numeric(value)
        let number: String
        if raw.hasPrefix("0x") {
            guard (1...64).contains(raw.dropFirst(2).count), raw.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw Failure.malformed }
            number = try AnkrQuantity.decimal(raw)
        } else {
            guard !raw.isEmpty, raw.count <= 78, raw.utf8.allSatisfy({ (48...57).contains($0) }), raw == "0" || raw.first != "0" else { throw Failure.malformed }
            number = raw
        }
        // Range overflow is expected untrusted-field validation.
        guard let bytes = try? TronSendCrypto.uint256(number) else { throw Failure.malformed }
        guard bytes.prefix(32 - bits / 8).allSatisfy({ $0 == 0 }) else { throw Failure.malformed }
        return (bytes, number)
    }
    private static func integer(_ value: SolanaJSON, bits: Int, signed: Bool) throws -> Data {
        let raw = try numeric(value), negative = raw.hasPrefix("-")
        guard !negative || signed else { throw Failure.malformed }
        let magnitude = try unsigned(.string(negative ? String(raw.dropFirst()) : raw), bits: bits).bytes
        if signed {
            let first = 32 - bits / 8
            if negative {
                guard raw != "-0", magnitude[first] < 128 || (magnitude[first] == 128 && magnitude.dropFirst(first + 1).allSatisfy({ $0 == 0 })) else { throw Failure.malformed }
                var inverted = magnitude.map { ~$0 }, carry = 1
                for index in inverted.indices.reversed() { let n = Int(inverted[index]) + carry; inverted[index] = UInt8(n & 255); carry = n >> 8 }
                return Data(inverted)
            }
            guard magnitude[first] < 128 else { throw Failure.malformed }
        }
        return magnitude
    }
    private struct Encoder {
        let types: [String: [Field]]
        func array(_ type: String) throws -> (element: String, count: Int?)? {
            guard type.hasSuffix("]") else { return nil }
            guard let bracket = type.lastIndex(of: "[") else { throw Failure.unsupportedType }
            let length = String(type[type.index(after: bracket)..<type.index(before: type.endIndex)])
            let count: Int?
            if length.isEmpty { count = nil }
            else {
                guard let size = Int(length), (1...1_024).contains(size), String(size) == length else { throw Failure.limits }
                count = size
            }
            return (String(type[..<bracket]), count)
        }
        func validate(type: String, depth: Int = 0) throws {
            guard depth <= 8 else { throw Failure.limits }
            if let array = try array(type) { try validate(type: array.element, depth: depth + 1); return }
            if types[type] != nil || ["address", "bool", "bytes", "string"].contains(type) { return }
            if let bits = width(type, prefix: "uint", upper: 256, step: 8), bits > 0 { return }
            if let bits = width(type, prefix: "int", upper: 256, step: 8), bits > 0 { return }
            if width(type, prefix: "bytes", upper: 32, step: 1) != nil { return }
            throw Failure.unsupportedType
        }
        func width(_ type: String, prefix: String, upper: Int, step: Int) -> Int? {
            guard type.hasPrefix(prefix), let width = Int(type.dropFirst(prefix.count)), (1...upper).contains(width), width % step == 0,
                  type == prefix + String(width) else { return nil }
            return width
        }
        func base(_ type: String) -> String { String(type.prefix(while: { $0 != "[" })) }
        func typeHash(_ name: String) -> Data {
            var dependencies = Set<String>()
            func visit(_ type: String) {
                guard dependencies.insert(type).inserted else { return }
                for field in types[type] ?? [] where types[base(field.type)] != nil { visit(base(field.type)) }
            }
            visit(name); dependencies.remove(name)
            let encoded = ([name] + dependencies.sorted()).map { type in
                type + "(" + (types[type] ?? []).map { $0.type + " " + $0.name }.joined(separator: ",") + ")"
            }.joined()
            return TronSendCrypto.keccak(Data(encoded.utf8))
        }
        func structure(_ type: String, value: SolanaJSON, depth: Int, budget: inout Int) throws -> Data {
            guard depth <= 32, budget > 0 else { throw Failure.limits }
            guard let definition = types[type], case .object(let object) = value,
                  Set(object.keys) == Set(definition.map(\.name)) else { throw Failure.malformed }
            var data = typeHash(type)
            for field in definition { data += try encode(field.type, value: object[field.name]!, depth: depth + 1, budget: &budget) }
            return TronSendCrypto.keccak(data)
        }
        func encode(_ type: String, value: SolanaJSON, depth: Int, budget: inout Int) throws -> Data {
            budget -= 1
            guard depth <= 32, budget >= 0 else { throw Failure.limits }
            if let array = try array(type) {
                guard let values = value.array, values.count <= 1_024, array.count == nil || array.count == values.count else { throw Failure.malformed }
                var bytes = Data()
                for item in values { bytes += try encode(array.element, value: item, depth: depth + 1, budget: &budget) }
                return TronSendCrypto.keccak(bytes)
            }
            if types[type] != nil { return try structure(type, value: value, depth: depth + 1, budget: &budget) }
            if type == "string" {
                guard let text = value.string else { throw Failure.malformed }
                return TronSendCrypto.keccak(Data(text.utf8))
            }
            if type == "address" { return try Data(repeating: 0, count: 12) + TronIdentity.hex(String(WalletConnectTypedData.address(value).dropFirst(2))) }
            if type == "bool" {
                guard case .bool(let bool) = value else { throw Failure.malformed }
                return Data(repeating: 0, count: 31) + Data([bool ? 1 : 0])
            }
            if type == "bytes" || type.hasPrefix("bytes") {
                guard let text = value.string, text.hasPrefix("0x"), text.count % 2 == 0 else { throw Failure.malformed }
                guard let bytes = try? TronIdentity.hex(String(text.dropFirst(2))) else { throw Failure.malformed }
                if type == "bytes" { return TronSendCrypto.keccak(bytes) }
                guard let count = width(type, prefix: "bytes", upper: 32, step: 1), bytes.count == count else { throw Failure.malformed }
                return bytes + Data(repeating: 0, count: 32 - count)
            }
            if let bits = width(type, prefix: "uint", upper: 256, step: 8) { return try WalletConnectTypedData.integer(value, bits: bits, signed: false) }
            if let bits = width(type, prefix: "int", upper: 256, step: 8) { return try WalletConnectTypedData.integer(value, bits: bits, signed: true) }
            throw Failure.unsupportedType
        }
        func review(type: String, value: SolanaJSON, path: String, into fields: inout [ReviewField]) {
            if let array = try? array(type), let items = value.array {
                fields.append(.init(path: path, type: type, value: String(items.count)))
                for (index, item) in items.enumerated() { review(type: array.element, value: item, path: path + "[\(index)]", into: &fields) }
            } else if let definition = types[type] {
                for field in definition { review(type: field.type, value: value[field.name], path: path + "." + field.name, into: &fields) }
            } else {
                let text: String
                switch value {
                case .string(let v), .number(let v): text = WalletConnectTypedData.visible(v)
                case .bool(let v): text = v ? "true" : "false"
                default: text = "" // Validated encoding excludes null and mismatched containers.
                }
                fields.append(.init(path: path, type: type, value: text))
            }
        }
    }
    private static func permission(primary: String, types: [String: [Field]], domain: SolanaJSON, message: SolanaJSON,
                                   contract: String?, chain: String?, account: String) throws -> Permission? {
        guard let contract, chain != nil else { return nil }
        func number(_ value: SolanaJSON, _ bits: Int = 256) throws -> String { try unsigned(value, bits: bits).decimal }
        if primary == "Permit", types[primary] == [.init("owner", "address"), .init("spender", "address"), .init("value", "uint256"), .init("nonce", "uint256"), .init("deadline", "uint256")] {
            let owner = try address(message["owner"])
            guard owner == account.lowercased() else { throw Failure.wrongOwner }
            return try .erc2612(token: contract, owner: owner, spender: address(message["spender"]), amount: number(message["value"]), nonce: number(message["nonce"]), deadline: number(message["deadline"]))
        }
        // Names alone are supplied by the peer. Recognize Permit2 only at its
        // canonical deployment with the exact signed field structure.
        guard contract == "0x000000000022d473030f116ddee9f6b43ac78ba3", domain["name"].string == "Permit2" else { return nil }
        if primary == "PermitSingle", types[primary] == [.init("details", "PermitDetails"), .init("spender", "address"), .init("sigDeadline", "uint256")],
           types["PermitDetails"] == [.init("token", "address"), .init("amount", "uint160"), .init("expiration", "uint48"), .init("nonce", "uint48")] {
            let details = message["details"]
            return try .permit2Allowance(token: address(details["token"]), spender: address(message["spender"]), amount: number(details["amount"], 160), nonce: number(details["nonce"], 48), expiration: number(details["expiration"], 48), deadline: number(message["sigDeadline"]))
        }
        if primary == "PermitTransferFrom", types[primary] == [.init("permitted", "TokenPermissions"), .init("spender", "address"), .init("nonce", "uint256"), .init("deadline", "uint256")],
           types["TokenPermissions"] == [.init("token", "address"), .init("amount", "uint256")] {
            return try .permit2Transfer(token: address(message["permitted"]["token"]), spender: address(message["spender"]), amount: number(message["permitted"]["amount"]), nonce: number(message["nonce"]), deadline: number(message["deadline"]))
        }
        return nil
    }
}

/// Read-only presentation of the exact recognized permission. Permit2's
/// allowance uses uint160; a one-use transfer amount is never an ongoing allowance.
public extension WalletConnectTypedData.Permission {
    var tokenAddress: String {
        switch self {
        case .erc2612(let token, _, _, _, _, _), .permit2Allowance(let token, _, _, _, _, _),
             .permit2Transfer(let token, _, _, _, _): token
        }
    }
    var spenderAddress: String {
        switch self {
        case .erc2612(_, _, let spender, _, _, _), .permit2Allowance(_, let spender, _, _, _, _),
             .permit2Transfer(_, let spender, _, _, _): spender
        }
    }
    var atomicAmount: String {
        switch self {
        case .erc2612(_, _, _, let amount, _, _), .permit2Allowance(_, _, let amount, _, _, _),
             .permit2Transfer(_, _, let amount, _, _): amount
        }
    }
    var isOneTimeTransfer: Bool {
        if case .permit2Transfer = self { return true }
        return false
    }
    var isUnlimitedAllowance: Bool {
        switch self {
        case .erc2612: atomicAmount == WalletConnectEVMAction.maximum
        case .permit2Allowance: atomicAmount == "1461501637330902918203684832716283019655932542975"
        case .permit2Transfer: false
        }
    }
    var signatureDeadline: String {
        switch self {
        case .erc2612(_, _, _, _, _, let deadline), .permit2Allowance(_, _, _, _, _, let deadline),
             .permit2Transfer(_, _, _, _, let deadline): deadline
        }
    }
    var allowanceExpiration: String? {
        if case .permit2Allowance(_, _, _, _, let expiration, _) = self { return expiration }
        return nil
    }
}

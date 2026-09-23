import Foundation

enum SolanaJSONValue: Codable, Sendable {
    case object([String: SolanaJSONValue])
    case array([SolanaJSONValue])
    case string(String)
    case number(Decimal)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(
            [String: SolanaJSONValue].self
        ) {
            self = .object(value)
        } else {
            self = .array(try container.decode([SolanaJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var object: [String: SolanaJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var array: [SolanaJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var string: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var decimal: Decimal? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    var int64: Int64? {
        decimal.map { NSDecimalNumber(decimal: $0).int64Value }
    }
}

struct SolanaRPCRequest: Encodable, Sendable {
    let jsonrpc = "2.0"
    let method: String
    let params: [SolanaJSONValue]
    let id: Int
}

struct SolanaRPCResponse: Decodable, Sendable {
    struct RPCError: Decodable, Error, Sendable {
        let code: Int
        let message: String
    }

    let result: SolanaJSONValue?
    let error: RPCError?
    let id: Int?

    private enum CodingKeys: String, CodingKey { case result, error, id }

    init(result: SolanaJSONValue?, error: RPCError?, id: Int?) {
        self.result = result
        self.error = error
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A JSON null is a valid RPC result (for example a missing transaction).
        // Keep it distinct from a response that omits both result and error.
        result = container.contains(.result)
            ? try container.decode(SolanaJSONValue.self, forKey: .result) : nil
        error = try container.decodeIfPresent(RPCError.self, forKey: .error)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
    }
}

struct SolanaSignatureInfo: Sendable {
    let signature: String
    let slot: Int64
    let blockTime: Double?
    let failed: Bool
}

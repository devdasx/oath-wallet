import Foundation

struct ElectrumRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [AnyEncodable]
}

struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        encodeValue = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

struct ElectrumResponse: Decodable {
    let id: BitcoinFamilyLosslessInt64?
    let result: JSONValue?
    let error: ElectrumRPCError?
    let method: String?
    let params: [JSONValue]?

    private enum CodingKeys: String, CodingKey {
        case id, result, error, method, params
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(BitcoinFamilyLosslessInt64.self, forKey: .id)
        // A present null is a successful subscription status for an unused
        // address. Optional synthesis would collapse it into a missing result
        // and make the transport tear down every request on the connection.
        result = values.contains(.result)
            ? try values.decode(JSONValue.self, forKey: .result)
            : nil
        error = try values.decodeIfPresent(ElectrumRPCError.self, forKey: .error)
        method = try values.decodeIfPresent(String.self, forKey: .method)
        params = try values.decodeIfPresent([JSONValue].self, forKey: .params)
    }
}

struct ElectrumRPCError: Decodable, Sendable {
    let code: BitcoinFamilyLosslessInt64
    let message: String
}

enum JSONValue: Decodable, Sendable {
    case array([JSONValue])
    case bool(Bool)
    case number(Decimal)
    case object([String: JSONValue])
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let value = try? value.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? value.decode(String.self) {
            self = .string(value)
        } else if let value = try? value.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? value.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(
                try value.decode([String: JSONValue].self)
            )
        }
    }

    var array: [JSONValue]? {
        if case let .array(value) = self { value } else { nil }
    }

    var object: [String: JSONValue]? {
        if case let .object(value) = self { value } else { nil }
    }

    var string: String? {
        if case let .string(value) = self { value } else { nil }
    }

    var int64: Int64? {
        exactInt64
    }

    var exactInt64: Int64? {
        switch self {
        case let .string(value):
            return Int64(value)
        case let .number(value):
            let string = NSDecimalNumber(decimal: value).stringValue
            guard
                !string.contains("e"),
                !string.contains("E"),
                let integer = Int64(string),
                Decimal(integer) == value
            else {
                return nil
            }
            return integer
        default:
            return nil
        }
    }

    var atomicInteger: BitcoinFamilyAtomicInteger? {
        guard case let .string(value) = self else { return nil }
        return try? BitcoinFamilyAtomicInteger(validating: value)
    }
}

enum BitcoinFamilyElectrumError: Error, Sendable {
    case unavailable
    case invalidResponse
    case responseTooLarge
    case rpc(Int, String)
    case submissionNotAttempted(String)

    var submissionWasAttempted: Bool {
        if case .submissionNotAttempted = self { return false }
        return true
    }

    var submissionWasCancelledBeforeAttempt: Bool {
        if case .submissionNotAttempted("cancelled") = self { return true }
        return false
    }

    var diagnosticDescription: String {
        switch self {
        case .unavailable:
            return "unavailable"
        case .invalidResponse:
            return "invalid_response"
        case .responseTooLarge:
            return "response_too_large"
        case let .rpc(code, message):
            let sanitizedMessage = message
                .components(separatedBy: .controlCharacters)
                .joined(separator: " ")
                .prefix(240)
            return "rpc_code=\(code) provider_message=\(sanitizedMessage)"
        case let .submissionNotAttempted(code):
            return "submission_not_attempted_\(code)"
        }
    }
}

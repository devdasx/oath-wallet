import Foundation

enum XRPJSONValue: Codable, Hashable, Sendable {
    case string(String)
    case integer(Int64)
    case boolean(Bool)
    case object([String: XRPJSONValue])
    case array([XRPJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(
            [String: XRPJSONValue].self
        ) {
            self = .object(value)
        } else if let value = try? container.decode([XRPJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported XRP JSON value."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: XRPJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [XRPJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        switch self {
        case let .string(value): value
        case let .integer(value): String(value)
        default: nil
        }
    }

    var integerValue: Int64? {
        switch self {
        case let .integer(value): value
        case let .string(value): Int64(value)
        default: nil
        }
    }

    var booleanValue: Bool? {
        guard case let .boolean(value) = self else { return nil }
        return value
    }
}

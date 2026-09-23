import Foundation

enum NEARJSONValue: Codable, Hashable, Sendable {
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case decimal(Decimal)
    case boolean(Bool)
    case object([String: NEARJSONValue])
    case array([NEARJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .decimal(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(
            [String: NEARJSONValue].self
        ) { self = .object(value) }
        else if let value = try? container.decode([NEARJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported NEAR JSON value."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .unsignedInteger(value): try container.encode(value)
        case let .decimal(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: NEARJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [NEARJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        switch self {
        case let .string(value): value
        case let .integer(value): String(value)
        case let .unsignedInteger(value): String(value)
        case let .decimal(value): Self.string(from: value)
        default: nil
        }
    }

    var integerValue: Int64? {
        switch self {
        case let .integer(value): value
        case let .unsignedInteger(value):
            value <= UInt64(Int64.max) ? Int64(value) : nil
        case let .string(value): Int64(value)
        default: nil
        }
    }

    func containsString(_ fragment: String) -> Bool {
        switch self {
        case let .string(value):
            value.localizedCaseInsensitiveContains(fragment)
        case let .object(value):
            value.values.contains { $0.containsString(fragment) }
        case let .array(value):
            value.contains { $0.containsString(fragment) }
        case .integer, .unsignedInteger, .decimal, .boolean, .null:
            false
        }
    }

    private static func string(from value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description(
            withLocale: Locale(identifier: "en_US_POSIX")
        )
    }
}

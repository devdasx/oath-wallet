import Foundation

struct ContractDecoder {

    static func address(_ result: String, offset: String.Index? = nil) throws -> (String, String.Index) {
        guard let (word, end) = extractHexFragment(result, start: offset),
              word.prefix(24).allSatisfy({ $0 == "0" }) else {
            throw Errors.invalidAddress
        }
        return ("0x" + word.suffix(40), end)
    }

    static func int(_ result: String, offset: String.Index? = nil) throws -> (Int, String.Index) {
        guard let (word, end) = extractHexFragment(result, start: offset),
              let value = Int(word, radix: 16) else {
            throw Errors.invalidInt
        }
        return (value, end)
    }

    static func string(_ result: String, at: Int) throws -> String {
        let data = try dynamicBytes(result, at: at)
        guard let string = String(data: data, encoding: .utf8) else {
            throw Errors.invalidString
        }
        return string
    }

    static func dynamicBytes(_ result: String, at: Int) throws -> Data {
        guard let payloadStart = index0x(result),
              at >= 0, at % 32 == 0,
              at <= result.distance(from: payloadStart, to: result.endIndex) / 2 else {
            throw Errors.invalidDynamicBytes
        }
        let lengthStart = result.index(payloadStart, offsetBy: at * 2)
        guard let (length, start) = try? ContractDecoder.int(result, offset: lengthStart) else {
            throw Errors.invalidDynamicBytes
        }
        let availableBytes = result.distance(from: start, to: result.endIndex) / 2
        let padding = (32 - length % 32) % 32
        guard length <= availableBytes, padding <= availableBytes - length else {
            throw Errors.invalidDynamicBytes
        }
        let end = result.index(start, offsetBy: length * 2)
        let paddedEnd = result.index(end, offsetBy: padding * 2)
        guard result[end..<paddedEnd].allSatisfy({ $0 == "0" }) else {
            throw Errors.invalidDynamicBytes
        }
        return Data(hex: String(result[start..<end]))
    }
}

private extension ContractDecoder {

    static func index0x(_ value: String) -> String.Index? {
        guard value.hasPrefix("0x"),
              value.utf8.count % 2 == 0,
              value.utf8.dropFirst(2).allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }) else {
            return nil
        }
        return value.index(value.startIndex, offsetBy: 2)
    }

    static func extractHexFragment(_ value: String, start: String.Index? = nil) -> (String, String.Index)? {
        guard let payloadStart = index0x(value) else { return nil }
        let start = start ?? payloadStart
        guard start >= payloadStart, start <= value.endIndex,
              let end = value.index(start, offsetBy: 64, limitedBy: value.endIndex) else {
            return nil
        }
        return (String(value[start..<end]), end)
    }

    enum Errors: Error {
        case invalidAddress
        case invalidInt
        case invalidString
        case invalidDynamicBytes
    }
}

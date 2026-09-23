import Foundation

/// A data-only reader for pre-2.0 Electrum's Python-literal wallet files.
/// No evaluation, identifiers, calls, operators, or executable Python are allowed.
struct BitcoinElectrumLegacyLiteral {
    private let input: [UInt8]
    private var offset = 0
    private var values = 0

    static func read(_ data: Data) throws -> [String: Any]? {
        guard data.drop(while: { [9, 10, 13, 32].contains($0) }).first == 123, data.contains(39) else { return nil }
        guard data.count <= 16 * 1024 * 1024 else { throw BitcoinImportError.fileTooLarge }
        var parser = Self(input: Array(data))
        let value = try parser.value(depth: 0)
        parser.space()
        guard parser.offset == parser.input.count, let object = value as? [String: Any],
              BitcoinElectrumFileImporter.recognizes(object) else { throw BitcoinImportError.invalidFile }
        return object
    }

    private mutating func space() {
        while offset < input.count, [9, 10, 13, 32].contains(input[offset]) { offset += 1 }
    }
    private mutating func consume(_ byte: UInt8) -> Bool {
        space()
        guard offset < input.count, input[offset] == byte else { return false }
        offset += 1; return true
    }
    private mutating func value(depth: Int) throws -> Any {
        values += 1
        guard depth <= 128, values <= 1_000_000 else { throw BitcoinImportError.fileTooLarge }
        if values.isMultiple(of: 1024) { try Task.checkCancellation() }
        space()
        guard offset < input.count else { throw BitcoinImportError.invalidFile }
        let byte = input[offset]
        if byte == 39 || byte == 34 { return try string() }
        // Python 2 unicode-string prefix used by some historical wallet writers.
        if byte == 117, offset + 1 < input.count, [39, 34].contains(input[offset + 1]) {
            offset += 1; return try string()
        }
        if consume(123) {
            var object: [String: Any] = [:]
            if consume(125) { return object }
            while true {
                let key = try value(depth: depth + 1)
                let name: String
                if let string = key as? String { name = string }
                else if let number = key as? NSNumber { name = number.stringValue }
                else { throw BitcoinImportError.invalidFile }
                guard object[name] == nil, consume(58) else { throw BitcoinImportError.invalidFile }
                object[name] = try value(depth: depth + 1)
                if consume(125) { return object }
                guard consume(44) else { throw BitcoinImportError.invalidFile }
                if consume(125) { return object }
            }
        }
        if byte == 91 || byte == 40 {
            offset += 1
            let end: UInt8 = byte == 91 ? 93 : 41
            var array: [Any] = []
            if consume(end) { return array }
            while true {
                array.append(try value(depth: depth + 1))
                if consume(end) { return array }
                guard consume(44) else { throw BitcoinImportError.invalidFile }
                if consume(end) { return array }
            }
        }
        for (word, result) in [("True", true as Any), ("False", false as Any), ("None", NSNull() as Any)] {
            let bytes = Array(word.utf8)
            if input.dropFirst(offset).starts(with: bytes) { offset += bytes.count; return result }
        }
        let start = offset
        while offset < input.count, "0123456789.eE+-".utf8.contains(input[offset]) { offset += 1 }
        guard start < offset else { throw BitcoinImportError.invalidFile }
        let number = try JSONSerialization.jsonObject(with: Data(input[start..<offset]), options: .fragmentsAllowed)
        guard number is NSNumber else { throw BitcoinImportError.invalidFile }
        if offset < input.count, input[offset] == 76 { offset += 1 } // Python 2 long integer suffix.
        return number
    }

    private mutating func string() throws -> String {
        let quote = input[offset]; offset += 1
        var bytes: [UInt8] = []
        while offset < input.count {
            let byte = input[offset]; offset += 1
            if byte == quote {
                guard let value = String(bytes: bytes, encoding: .utf8) else { throw BitcoinImportError.invalidFile }
                return value
            }
            guard byte >= 32 else { throw BitcoinImportError.invalidFile }
            if byte != 92 { bytes.append(byte); continue }
            guard offset < input.count else { throw BitcoinImportError.invalidFile }
            let escape = input[offset]; offset += 1
            switch escape {
            case 39, 34, 92: bytes.append(escape)
            case 110: bytes.append(10)
            case 114: bytes.append(13)
            case 116: bytes.append(9)
            case 98: bytes.append(8)
            case 102: bytes.append(12)
            case 120, 117, 85:
                let count = escape == 120 ? 2 : (escape == 117 ? 4 : 8)
                guard offset + count <= input.count,
                      let value = UInt32(String(decoding: input[offset..<(offset + count)], as: UTF8.self), radix: 16) else {
                    throw BitcoinImportError.invalidFile
                }
                offset += count
                guard let scalar = UnicodeScalar(value) else { throw BitcoinImportError.invalidFile }
                bytes += String(scalar).utf8
            default: throw BitcoinImportError.invalidFile
            }
        }
        throw BitcoinImportError.invalidFile
    }
}

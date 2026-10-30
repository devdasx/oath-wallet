import Foundation

/// Request JSON must not pass through floating point or Decimal: a uint256 can
/// have 78 digits. Reject duplicate keys before decoding so review and signing
/// cannot disagree about which occurrence wins. This parser never logs input.
public enum WalletConnectJSON {
    public enum Failure: Error, Sendable { case malformed, tooLarge }
    public static func decode(_ data: Data, byteLimit:Int = 65_536, collectionLimit:Int = 1_024, nodeLimit:Int = 4_096) throws -> SolanaJSON {
        guard byteLimit <= 600_000, collectionLimit <= 131_072, nodeLimit <= 150_000, data.count <= byteLimit else { throw Failure.tooLarge }
        var parser = Parser(bytes: Array(data), collectionLimit:collectionLimit, nodeLimit:nodeLimit)
        let value = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.offset == parser.bytes.count else { throw Failure.malformed }
        return value
    }
    private struct Parser {
        let bytes: [UInt8]
        let collectionLimit:Int, nodeLimit:Int
        var offset = 0, nodes = 0
        mutating func whitespace() {
            while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
        }
        mutating func take(_ byte: UInt8) -> Bool {
            whitespace()
            guard offset < bytes.count, bytes[offset] == byte else { return false }
            offset += 1; return true
        }
        mutating func value(depth: Int) throws -> SolanaJSON {
            nodes += 1; whitespace()
            guard depth <= 32, nodes <= nodeLimit else { throw Failure.tooLarge }
            guard offset < bytes.count else { throw Failure.malformed }
            switch bytes[offset] {
            case 123:
                offset += 1; var object = [String: SolanaJSON]()
                if take(125) { return .object(object) }
                repeat {
                    whitespace(); let key = try string()
                    guard object[key] == nil, take(58) else { throw Failure.malformed }
                    object[key] = try value(depth: depth + 1)
                    if take(125) { return .object(object) }
                } while take(44)
                throw Failure.malformed
            case 91:
                offset += 1; var array = [SolanaJSON]()
                if take(93) { return .array(array) }
                repeat {
                    guard array.count < collectionLimit else { throw Failure.tooLarge }
                    array.append(try value(depth: depth + 1))
                    if take(93) { return .array(array) }
                } while take(44)
                throw Failure.malformed
            case 34: return .string(try string())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            default:
                let start = offset
                if bytes[offset] == 45 { offset += 1 }
                guard offset < bytes.count else { throw Failure.malformed }
                if bytes[offset] == 48 { offset += 1 }
                else {
                    guard (49...57).contains(bytes[offset]) else { throw Failure.malformed }
                    while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
                }
                if offset < bytes.count, bytes[offset] == 46 {
                    offset += 1; let fraction = offset
                    while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
                    guard offset > fraction else { throw Failure.malformed }
                }
                if offset < bytes.count, [69, 101].contains(bytes[offset]) {
                    offset += 1
                    if offset < bytes.count, [43, 45].contains(bytes[offset]) { offset += 1 }
                    let exponent = offset
                    while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
                    guard offset > exponent else { throw Failure.malformed }
                }
                return .number(String(decoding: bytes[start..<offset], as: UTF8.self))
            }
        }
        mutating func literal(_ text: String) throws {
            let expected = Array(text.utf8)
            guard offset + expected.count <= bytes.count,
                  Array(bytes[offset..<offset + expected.count]) == expected else { throw Failure.malformed }
            offset += expected.count
        }
        mutating func string() throws -> String {
            guard offset < bytes.count, bytes[offset] == 34 else { throw Failure.malformed }
            let start = offset; offset += 1
            while offset < bytes.count {
                let byte = bytes[offset]; offset += 1
                if byte == 34 {
                    // Foundation validates UTF-8, escapes and surrogate pairs.
                    // Invalid peer JSON is expected input validation, not an app failure.
                    guard let decoded = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) else { throw Failure.malformed }
                    return decoded
                }
                guard byte >= 32 else { throw Failure.malformed }
                if byte == 92 {
                    guard offset < bytes.count else { throw Failure.malformed }
                    offset += 1
                }
            }
            throw Failure.malformed
        }
    }
}

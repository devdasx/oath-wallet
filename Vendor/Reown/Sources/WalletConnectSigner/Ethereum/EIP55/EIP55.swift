import Foundation

// NOTE: https://github.com/ethereum/EIPs/blob/master/EIPS/eip-55.md
public struct EIP55 {

    private let crypto: CryptoProvider

    public init(crypto: CryptoProvider) {
        self.crypto = crypto
    }

    public enum Errors: Error {
        case invalidAddress
        case invalidHashLength
    }

    public func encode(_ string: String) throws -> String {
        let body = string.hasPrefix("0x") || string.hasPrefix("0X") ? string.dropFirst(2) : string[...]
        guard body.utf8.count == 40 else { throw Errors.invalidAddress }
        let input = Array(body.utf8)
        var address = Data(capacity: 20)
        for index in stride(from: 0, to: input.count, by: 2) {
            guard let high = Self.nibble(input[index]), let low = Self.nibble(input[index + 1]) else {
                throw Errors.invalidAddress
            }
            address.append((high << 4) | low)
        }
        return "0x" + (try encode(address))
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    public func encode(_ data: Data) throws -> String {
        guard data.count == 20 else { throw Errors.invalidAddress }
        let address = data.toHexString()
        let digest = crypto.keccak256(Data(address.utf8))
        guard digest.count == 32 else { throw Errors.invalidHashLength }
        let hash = digest.toHexString()

        return zip(address, hash)
            .map { a, h -> String in
                switch (a, h) {
                case ("0", _), ("1", _), ("2", _), ("3", _), ("4", _), ("5", _), ("6", _), ("7", _), ("8", _), ("9", _):
                    return String(a)
                case (_, "8"), (_, "9"), (_, "a"), (_, "b"), (_, "c"), (_, "d"), (_, "e"), (_, "f"):
                    return String(a).uppercased()
                default:
                    return String(a).lowercased()
                }
            }
            .joined()
    }
}

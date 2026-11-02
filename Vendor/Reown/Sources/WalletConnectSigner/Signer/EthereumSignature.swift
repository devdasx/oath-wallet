import Foundation

public struct EthereumSignature {
    public let v: UInt8
    public let r: [UInt8]
    public let s: [UInt8]

    public enum Errors: Error {
        case invalidLength
        case invalidRecoveryID
    }

    public init(v: UInt8, r: [UInt8], s: [UInt8]) throws {
        guard r.count == 32, s.count == 32 else { throw Errors.invalidLength }
        guard v <= 3 else { throw Errors.invalidRecoveryID }
        self.v = v
        self.r = r
        self.s = s
    }

    public init(serialized: Data) throws {
        guard serialized.count == 65 else { throw Errors.invalidLength }
        let bytes = [UInt8](serialized)
        var recoveryID = bytes[64]
        if (27...30).contains(recoveryID) {
            recoveryID -= 27
        } else if (31...34).contains(recoveryID) {
            recoveryID -= 31
        } else if (35...38).contains(recoveryID) {
            recoveryID -= 35
        }
        try self.init(v: recoveryID, r: Array(bytes[0..<32]), s: Array(bytes[32..<64]))
    }

    public var serialized: Data {
        return Data(r + s + [v + 27])
    }

    public func hex() -> String {
        return "0x" + serialized.toHexString()
    }
}

import Foundation

struct ContractEncoder {
    enum Errors: Error {
        case invalidHashLength
    }

    static func bytes(_ bytes: Data) throws -> String {
        guard bytes.count == 32 else { throw Errors.invalidHashLength }
        return bytes.toHexString()
    }
}

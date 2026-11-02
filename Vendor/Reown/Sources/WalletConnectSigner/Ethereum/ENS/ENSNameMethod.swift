import Foundation

struct ENSNameMethod {
    static let methodHash = "0x691f3431"

    let namehash: Data

    func encode() throws -> String {
        return [ENSNameMethod.methodHash, try ContractEncoder.bytes(namehash)].joined()
    }
}

import Foundation

struct ENSAddressMethod {
    static let methodHash = "0x3b3b57de"

    let namehash: Data

    func encode() throws -> String {
        return [ENSAddressMethod.methodHash, try ContractEncoder.bytes(namehash)].joined()
    }
}

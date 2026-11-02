import Foundation

struct ENSResolverMethod {
    static let methodHash = "0x0178b8bf"

    let namehash: Data

    func encode() throws -> String {
        return [ENSResolverMethod.methodHash, try ContractEncoder.bytes(namehash)].joined()
    }
}

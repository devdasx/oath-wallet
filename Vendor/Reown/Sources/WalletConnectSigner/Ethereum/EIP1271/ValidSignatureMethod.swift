import Foundation

struct ValidSignatureMethod {
    static let methodHash = "0x1626ba7e"
    static let paddingIndex = "0000000000000000000000000000000000000000000000000000000000000040"

    let signature: Data
    let messageHash: Data

    func encode() throws -> String {
        let hash = try ContractEncoder.bytes(messageHash)
        let length = String(signature.count, radix: 16)
        let lengthWord = String(repeating: "0", count: 64 - length.count) + length
        let paddingBytes = (32 - signature.count % 32) % 32
        return [
            ValidSignatureMethod.methodHash,
            hash,
            ValidSignatureMethod.paddingIndex,
            lengthWord,
            signature.toHexString(),
            String(repeating: "00", count: paddingBytes)
        ].joined()
    }
}

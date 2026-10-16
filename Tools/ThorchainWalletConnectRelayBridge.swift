import Foundation
import OathAnkr

/// Isolated relay fixture: public synthetic test key only, no vault or app data.
@main struct ThorchainWalletConnectRelayBridge {
    static func main() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard input.count <= 65_536 else { exit(1) }
        let json = try JSONDecoder().decode(SolanaJSON.self, from: input)
        let key = Data(repeating: 1, count: 32)
        let pub = try ThorchainSendCrypto.publicKey(privateKey: key)
        let sender = try ThorchainSendCrypto.address(publicKey: pub, network: .mainnet)
        let response: SolanaJSON
        if json["method"].string == "cosmos_getAccounts" {
            response = .array([.object(["address": .string(sender), "algo": .string("secp256k1"), "pubkey": .string(pub.base64EncodedString())])])
        } else {
            let request = try ThorchainWalletConnectRequest(method: json["method"].string ?? "", params: json["params"], sender: sender, publicKey: pub)
            response = try request.sign(privateKey: key)
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(response))
    }
}

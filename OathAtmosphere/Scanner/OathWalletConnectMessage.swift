import Foundation
import OathAnkr
import OathSecp256k1

/// Byte-exact EIP-191 signing. The vault supplies the key only after consent and
/// fresh authentication; this layer does not access storage or network services.
enum OathWalletConnectMessage {
    enum Failure: Error { case invalid, signature }
    static func digest(_ message: Data) -> Data {
        TronSendCrypto.keccak(Data("\u{19}Ethereum Signed Message:\n\(message.count)".utf8) + message)
    }
    static func sign(_ message: Data, key: Data, account: String) throws -> String {
        guard message.count <= 4_096,
              try ArcSendCrypto.address(privateKey: key).lowercased() == account.lowercased() else { throw Failure.invalid }
        let hash = digest(message)
        let signature = try OathSecp256k1.signRecoverable(hash, key: key)
        guard try OathSecp256k1.recover(signature, digest: hash) == OathSecp256k1.publicKey(key, compressed: false) else { throw Failure.signature }
        return "0x" + (Data(signature.prefix(64)) + Data([signature.last! + 27])).map { String(format: "%02x", $0) }.joined()
    }
}

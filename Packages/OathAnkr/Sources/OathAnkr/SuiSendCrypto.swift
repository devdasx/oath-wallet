import Foundation
import CryptoKit

/// Sui's Ed25519 envelope signs Blake2b-256(intent || TransactionData), not
/// the transaction digest. Keys never leave the caller's authenticated vault.
public enum SuiSendCrypto {
    public static func address(privateKey: Data) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        return "0x" + hash(Data([0]) + key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined()
    }
    public static func sign(_ plan: SuiSendPlan, privateKey: Data, now: Date = .now) throws -> SuiSignedSend {
        try plan.validate(now: now)
        guard try address(privateKey: privateKey) == plan.sender else { throw SuiSendError.signing }
        let bytes = try plan.transactionBytes()
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        let signature = try key.signature(for: hash(Data([0, 0, 0]) + bytes))
        return .init(bytes: bytes, signature: Data([0]) + signature + key.publicKey.rawRepresentation,
                     digest: digest(bytes))
    }
    public static func digest(_ bytes: Data) -> String { base58(hash(Data("TransactionData::".utf8) + bytes)) }
    public static func verify(_ signed: SuiSignedSend, sender: String) throws {
        guard signed.signature.count == 97, signed.signature.first == 0,
              signed.digest == digest(signed.bytes) else { throw SuiSendError.signing }
        let publicBytes = signed.signature.suffix(32)
        let address = "0x" + hash(Data([0]) + publicBytes).map { String(format: "%02x", $0) }.joined()
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
        guard address == sender, key.isValidSignature(signed.signature.dropFirst().prefix(64),
            for: hash(Data([0, 0, 0]) + signed.bytes)) else { throw SuiSendError.signing }
    }
    // RFC 7693 Blake2b with a 32-byte digest. Arithmetic is explicitly wrapping.
    static func hash(_ data: Data) -> Data {
        let iv: [UInt64] = [0x6a09e667f3bcc908,0xbb67ae8584caa73b,0x3c6ef372fe94f82b,0xa54ff53a5f1d36f1,
                            0x510e527fade682d1,0x9b05688c2b3e6c1f,0x1f83d9abfb41bd6b,0x5be0cd19137e2179]
        let sigma = [[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],[14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3],
                     [11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4],[7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8],
                     [9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13],[2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9],
                     [12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11],[13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10],
                     [6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5],[10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0]]
        func rotate(_ v: UInt64, _ n: UInt64) -> UInt64 { (v >> n) | (v << (64-n)) }
        var h = iv; h[0] ^= 0x01010020
        let bytes = Array(data); var offset = 0
        repeat {
            let count = min(128, bytes.count-offset)
            var block = [UInt8](repeating: 0, count: 128)
            if count > 0 { block.replaceSubrange(0..<count, with: bytes[offset..<offset+count]) }
            var m = [UInt64](repeating: 0, count: 16)
            for i in 0..<16 { for j in 0..<8 { m[i] |= UInt64(block[i*8+j]) << (j*8) } }
            var v = h + iv; v[12] ^= UInt64(offset+count)
            if offset+count == bytes.count { v[14] = ~v[14] }
            func mix(_ a:Int,_ b:Int,_ c:Int,_ d:Int,_ x:UInt64,_ y:UInt64) {
                v[a] = v[a] &+ v[b] &+ x; v[d] = rotate(v[d] ^ v[a],32)
                v[c] = v[c] &+ v[d]; v[b] = rotate(v[b] ^ v[c],24)
                v[a] = v[a] &+ v[b] &+ y; v[d] = rotate(v[d] ^ v[a],16)
                v[c] = v[c] &+ v[d]; v[b] = rotate(v[b] ^ v[c],63)
            }
            for r in 0..<12 {
                let s = sigma[r % 10]
                mix(0,4,8,12,m[s[0]],m[s[1]]); mix(1,5,9,13,m[s[2]],m[s[3]])
                mix(2,6,10,14,m[s[4]],m[s[5]]); mix(3,7,11,15,m[s[6]],m[s[7]])
                mix(0,5,10,15,m[s[8]],m[s[9]]); mix(1,6,11,12,m[s[10]],m[s[11]])
                mix(2,7,8,13,m[s[12]],m[s[13]]); mix(3,4,9,14,m[s[14]],m[s[15]])
            }
            for i in 0..<8 { h[i] ^= v[i] ^ v[i+8] }; offset += count
        } while offset < bytes.count
        return Data(h.prefix(4).flatMap { v in (0..<8).map { UInt8(truncatingIfNeeded: v >> ($0*8)) } })
    }
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    static func base58(_ data: Data) -> String {
        var digits = [Int]()
        for byte in data {
            var carry = Int(byte)
            for i in digits.indices { carry += digits[i]*256; digits[i] = carry % 58; carry /= 58 }
            while carry > 0 { digits.append(carry % 58); carry /= 58 }
        }
        return String(bytes: Array(repeating: alphabet[0], count: data.prefix(while: {$0 == 0}).count) + digits.reversed().map { alphabet[$0] }, encoding: .utf8)!
    }
    static func unbase58(_ text: String) throws -> Data {
        guard !text.isEmpty, text.count <= 64 else { throw SuiSendError.malformed }
        var bytes = [Int]()
        for c in text.utf8 {
            guard let index = alphabet.firstIndex(of:c) else { throw SuiSendError.malformed }
            var carry = index
            for i in bytes.indices { carry += bytes[i]*58; bytes[i] = carry & 255; carry >>= 8 }
            while carry > 0 { bytes.append(carry & 255); carry >>= 8 }
        }
        return Data(Array(repeating: UInt8(0), count: text.utf8.prefix(while: {$0 == alphabet[0]}).count) + bytes.reversed().map(UInt8.init))
    }
}
public struct SuiSignedSend: Codable, Sendable, Equatable {
    public let bytes: Data, signature: Data
    public let digest: String
}

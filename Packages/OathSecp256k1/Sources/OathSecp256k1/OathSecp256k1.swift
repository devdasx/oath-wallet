import Foundation
internal import libsecp256k1

/// One shared dynamic instance of the audited curve library. Errors contain no
/// inputs; the wallet/send boundary reports failures through OathDiagnostics.
public enum OathSecp256k1 {
    public enum Failure: Error { case invalidKey, signature }
    public static func publicKey(_ secret: Data, compressed: Bool = true) throws -> Data {
        guard secret.count == 32, let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN)) else { throw Failure.invalidKey }
        defer { secp256k1_context_destroy(ctx) }
        var key = Array(secret); defer { _ = key.withUnsafeMutableBytes { $0.initializeMemory(as:UInt8.self,repeating:0) } }
        var pub = secp256k1_pubkey(), count = compressed ? 33:65, bytes = [UInt8](repeating:0,count:65)
        guard secp256k1_ec_pubkey_create(ctx,&pub,&key) == 1,
              secp256k1_ec_pubkey_serialize(ctx,&bytes,&count,&pub,UInt32(compressed ? SECP256K1_EC_COMPRESSED:SECP256K1_EC_UNCOMPRESSED)) == 1 else { throw Failure.invalidKey }
        return Data(bytes.prefix(count))
    }
    public static func sign(_ digest: Data, key: Data) throws -> Data {
        guard digest.count == 32, key.count == 32, let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN)) else { throw Failure.signature }
        defer { secp256k1_context_destroy(ctx) }
        var secret = Array(key); defer { _ = secret.withUnsafeMutableBytes { $0.initializeMemory(as:UInt8.self,repeating:0) } }
        var random = (0..<32).map { _ in UInt8.random(in:.min ... .max) }
        guard secp256k1_context_randomize(ctx,&random) == 1 else { throw Failure.signature }
        var hash = Array(digest), sig = secp256k1_ecdsa_signature(), bytes = [UInt8](repeating:0,count:72), count = 72
        guard secp256k1_ecdsa_sign(ctx,&sig,&hash,&secret,nil,nil) == 1,
              secp256k1_ecdsa_signature_serialize_der(ctx,&bytes,&count,&sig) == 1 else { throw Failure.signature }
        let signature = Data(bytes.prefix(count))
        try verify(signature,digest:digest,publicKey:publicKey(key))
        return signature
    }
    public static func verify(_ signature: Data, digest: Data, publicKey: Data) throws {
        guard digest.count == 32, [33,65].contains(publicKey.count), (8...72).contains(signature.count),
              let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_VERIFY)) else { throw Failure.signature }
        defer { secp256k1_context_destroy(ctx) }
        var pub = secp256k1_pubkey(), sig = secp256k1_ecdsa_signature(), hash = Array(digest)
        let p = publicKey.withUnsafeBytes { secp256k1_ec_pubkey_parse(ctx,&pub,$0.bindMemory(to:UInt8.self).baseAddress!,publicKey.count) }
        let s = signature.withUnsafeBytes { secp256k1_ecdsa_signature_parse_der(ctx,&sig,$0.bindMemory(to:UInt8.self).baseAddress!,signature.count) }
        guard p == 1, s == 1, secp256k1_ecdsa_verify(ctx,&sig,&hash,&pub) == 1 else { throw Failure.signature }
    }
}

extension OathSecp256k1 {
    /// TRON's compact low-S signature followed by the recovery ID.
    public static func signRecoverable(_ digest:Data,key:Data) throws -> Data {
        guard digest.count==32,key.count==32,let ctx=secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN)) else { throw Failure.signature }
        defer { secp256k1_context_destroy(ctx) }
        var secret=Array(key);defer { _ = secret.withUnsafeMutableBytes { $0.initializeMemory(as:UInt8.self,repeating:0) } }
        var random=(0..<32).map { _ in UInt8.random(in:.min ... .max) },hash=Array(digest),sig=secp256k1_ecdsa_recoverable_signature(),out=[UInt8](repeating:0,count:64),recid:Int32=0
        guard secp256k1_context_randomize(ctx,&random)==1,
              secp256k1_ecdsa_sign_recoverable(ctx,&sig,&hash,&secret,nil,nil)==1,
              secp256k1_ecdsa_recoverable_signature_serialize_compact(ctx,&out,&recid,&sig)==1 else { throw Failure.signature }
        return Data(out+[UInt8(recid)])
    }
    public static func recover(_ signature:Data,digest:Data) throws -> Data {
        guard signature.count==65,signature.last!<=3,digest.count==32,let ctx=secp256k1_context_create(UInt32(SECP256K1_CONTEXT_VERIFY)) else { throw Failure.signature }
        defer { secp256k1_context_destroy(ctx) }
        var sig=secp256k1_ecdsa_recoverable_signature(),compact=Array(signature.prefix(64)),hash=Array(digest),pub=secp256k1_pubkey(),out=[UInt8](repeating:0,count:65),count=65
        guard secp256k1_ecdsa_recoverable_signature_parse_compact(ctx,&sig,&compact,Int32(signature.last!))==1,
              secp256k1_ecdsa_recover(ctx,&pub,&sig,&hash)==1,
              secp256k1_ec_pubkey_serialize(ctx,&out,&count,&pub,UInt32(SECP256K1_EC_UNCOMPRESSED))==1 else { throw Failure.signature }
        // Reject high-S encodings, even when public-key recovery succeeds.
        var normal=secp256k1_ecdsa_signature(),normalized=secp256k1_ecdsa_signature()
        guard secp256k1_ecdsa_recoverable_signature_convert(ctx,&normal,&sig)==1,
              secp256k1_ecdsa_signature_normalize(ctx,&normalized,&normal)==0 else { throw Failure.signature }
        return Data(out)
    }
}

extension OathSecp256k1 {
    /// Public derivation for legacy Electrum and TrustedCoin's extended child index.
    public static func adding(_ tweak: Data, toPublicKey key: Data, compressed: Bool = true) throws -> Data {
        guard [33, 65].contains(key.count), tweak.count == 32, let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_VERIFY)) else { throw Failure.invalidKey }
        defer { secp256k1_context_destroy(ctx) }
        var pub = secp256k1_pubkey(), output = [UInt8](repeating: 0, count: 65), count = compressed ? 33 : 65
        let parsed = key.withUnsafeBytes { secp256k1_ec_pubkey_parse(ctx, &pub, $0.bindMemory(to: UInt8.self).baseAddress!, key.count) }
        guard parsed == 1 else { throw Failure.invalidKey }
        let added = tweak.withUnsafeBytes { secp256k1_ec_pubkey_tweak_add(ctx, &pub, $0.bindMemory(to: UInt8.self).baseAddress!) }
        guard added == 1, secp256k1_ec_pubkey_serialize(ctx, &output, &count, &pub, UInt32(compressed ? SECP256K1_EC_COMPRESSED : SECP256K1_EC_UNCOMPRESSED)) == 1 else { throw Failure.invalidKey }
        return Data(output.prefix(count))
    }
    public static func adding(_ tweak: Data, toSecretKey key: Data) throws -> Data {
        guard key.count == 32, tweak.count == 32, let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN)) else { throw Failure.invalidKey }
        defer { secp256k1_context_destroy(ctx) }
        var secret = Array(key)
        defer { _ = secret.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let added = tweak.withUnsafeBytes { secp256k1_ec_seckey_tweak_add(ctx, &secret, $0.bindMemory(to: UInt8.self).baseAddress!) }
        guard added == 1 else { throw Failure.invalidKey }
        return Data(secret)
    }
}

import Foundation
import CryptoKit

public enum PolkadotSendCrypto {
    public static func publicKey(privateKey: Data) throws -> Data { try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey).publicKey.rawRepresentation }
    static func era(_ height: UInt64) -> Data { PolkadotScale.le(UInt16(5 | (height % 64) << 4)) }
    static func call(_ plan: PolkadotSendPlan) throws -> Data {
        var result = plan.callIndex
        if plan.reference != "native" {
            result += plan.token.pallet != "Assets" ? plan.token.key : try PolkadotScale.compact(PolkadotIdentity.uint(plan.token.key))
        }
        return try result + Data([0]) + PolkadotIdentity.publicKey(plan.recipient) + PolkadotScale.compact(plan.amount)
    }
    static func extensionBytes(_ name: String, plan: PolkadotSendPlan) throws -> (Data,Data) {
        switch name {
        case "CheckSpecVersion": return (Data(),PolkadotScale.le(plan.specVersion))
        case "CheckTxVersion": return (Data(),PolkadotScale.le(plan.transactionVersion))
        case "CheckGenesis": return (Data(),try PolkadotIdentity.bytes(plan.network.genesis))
        case "CheckMortality": return (era(plan.blockHeight),try PolkadotIdentity.bytes(plan.blockHash))
        case "CheckNonce": return (try PolkadotScale.compact(String(plan.nonce)),Data())
        case "ChargeAssetTxPayment": return (Data([0,0]),Data())
        case "CheckMetadataHash": return (Data([0]),Data([0]))
        case "AsScarcity", "AsPgas", "AsDotnsGateway", "RestrictOrigins": return (Data([0]),Data())
        case "AuthorizeCall", "CheckNonZeroSender", "CheckWeight", "PrevalidateAttests", "EthSetOrigin", "StorageWeightReclaim", "UnitTransactionExtension": return (Data(),Data())
        default: throw PolkadotSendError.runtimeUnsupported
        }
    }
    static func extensions(_ plan: PolkadotSendPlan) throws -> (Data,Data) {
        var extra=Data(), additional=Data()
        for name in plan.extensions { let pair = try extensionBytes(name,plan:plan); extra += pair.0; additional += pair.1 }
        return (extra,additional)
    }
    public static func signingPayload(_ plan: PolkadotSendPlan) throws -> Data {
        let (extra,additional) = try extensions(plan), payload = try call(plan)+extra+additional
        return payload.count > 256 ? SuiSendCrypto.hash(payload) : payload
    }
    static func extrinsic(_ plan: PolkadotSendPlan, signature: Data) throws -> Data {
        let body = try Data([0x84,0]) + PolkadotIdentity.publicKey(plan.sender) + Data([0]) + signature + extensions(plan).0 + call(plan)
        return try PolkadotScale.compact(String(body.count)) + body
    }
    public static func sign(_ plan: PolkadotSendPlan, privateKey: Data, now: Date = .now) throws -> PolkadotSignedSend {
        try plan.validate(now:now)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation:privateKey)
        guard try key.publicKey.rawRepresentation == PolkadotIdentity.publicKey(plan.sender) else { throw PolkadotSendError.wrongOwner }
        let signature = try key.signature(for:signingPayload(plan)), bytes = try extrinsic(plan,signature:signature)
        let result = PolkadotSignedSend(bytes:bytes,signature:signature,hash:PolkadotIdentity.hex(SuiSendCrypto.hash(bytes)))
        try verify(result,plan:plan); return result
    }
    public static func verify(_ signed: PolkadotSignedSend, plan: PolkadotSendPlan) throws {
        try plan.validate(checkAge:false)
        guard signed.signature.count == 64, try signed.bytes == extrinsic(plan,signature:signed.signature),
              signed.hash == PolkadotIdentity.hex(SuiSendCrypto.hash(signed.bytes)),
              try Curve25519.Signing.PublicKey(rawRepresentation:PolkadotIdentity.publicKey(plan.sender)).isValidSignature(signed.signature,for:signingPayload(plan)) else { throw PolkadotSendError.signing }
    }
}

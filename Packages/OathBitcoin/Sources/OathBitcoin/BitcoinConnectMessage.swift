import Foundation
import CryptoKit
import OathSecp256k1
internal import BitcoinDevKit

public struct BitcoinConnectMessageSignature: Codable, Sendable {
    public let address: String
    public let signature: String
    public let messageHash: String
}

extension BitcoinConnectSigning {
    public static func sign(_ plan: BitcoinConnectPlan, source: BitcoinPrivateKeySource) throws -> BitcoinConnectSigned {
        try sign(plan) { address in
            let wif = try UTXONetwork.bitcoin.privateKeyWIF(source:source, address:address)
            return try BitcoinKeys.decodeImport(wif).bytes
        }
    }
    public static func message(_ request: BitcoinConnectRequest, address: BitcoinDerivedAddress, source: BitcoinPrivateKeySource) throws -> BitcoinConnectMessageSignature {
        try request.validate()
        guard request.method == "signMessage", let message = request.message,
              try request.network.script(request.address ?? request.account).hex == address.script,
              address.multisigInputWeight == nil else { throw BitcoinConnectError.wrongAccount }
        let wif = try UTXONetwork.bitcoin.privateKeyWIF(source:source, address:address)
        var key = try BitcoinKeys.decodeImport(wif).bytes
        defer { key.resetBytes(in:0..<key.count) }
        let encodedAddress = try request.network.address(mainnetAddress:address.address)
        if request.protocol != "bip322" {
            guard address.type != .taproot else { throw BitcoinConnectError.unsupported }
            let payload = BitcoinWire.vector(Data("Bitcoin Signed Message:\n".utf8)) + BitcoinWire.vector(Data(message.utf8))
            let digest = Data(SHA256.hash(data:Data(SHA256.hash(data:payload))))
            let signature = try OathSecp256k1.signRecoverable(digest,key:key)
            let compressed = try BitcoinKeys.decodeImport(wif).compressed
            let base: UInt8 = address.type == .nativeSegwit ? 39 : address.type == .nestedSegwit ? 35 : compressed ? 31 : 27
            return .init(address:encodedAddress,signature:(Data([base + signature.last!]) + signature.prefix(64)).hex,messageHash:digest.hex)
        }
        // WalletConnect transports the simple BIP322 witness bytes as hex.
        // Legacy/wrapped scripts need the full format, which this RPC cannot identify.
        guard [.nativeSegwit,.taproot].contains(address.type) else { throw BitcoinConnectError.unsupported }
        let tag = Data(SHA256.hash(data:Data("BIP0322-signed-message".utf8)))
        let digest = Data(SHA256.hash(data:tag + tag + Data(message.utf8)))
        let script = try request.network.script(encodedAddress)
        var parent = BitcoinWire.little(UInt32(0)) + Data([1]) + Data(repeating:0,count:32)
        parent += BitcoinWire.little(UInt32.max) + BitcoinWire.vector(Data([0,32]) + digest)
        parent += BitcoinWire.little(UInt32(0)) + Data([1]) + BitcoinWire.little(UInt64(0))
        parent += BitcoinWire.vector(script) + BitcoinWire.little(UInt32(0))
        let hash = try Transaction(transactionBytes:parent).computeTxid().description
        var unsigned = BitcoinWire.little(UInt32(0)) + Data([1]) + Data(Data(hex:hash)!.reversed())
        unsigned += BitcoinWire.little(UInt32(0)) + Data([0]) + BitcoinWire.little(UInt32(0))
        unsigned += Data([1]) + BitcoinWire.little(UInt64(0)) + BitcoinWire.vector(Data([0x6a])) + BitcoinWire.little(UInt32(0))
        let data = Data([0x70,0x73,0x62,0x74,0xff]) + BitcoinWire.pair(0,unsigned) + Data([0]) + BitcoinWire.pair(0,parent) + BitcoinWire.pair(1,BitcoinWire.little(UInt64(0)) + BitcoinWire.vector(script)) + Data([0,0])
        let descriptor = try Descriptor(descriptor:address.type.wrap(wif),networkKind:.main)
        let wallet = try Wallet.createSingle(descriptor:descriptor,network:.bitcoin,persister:Persister.newInMemory())
        _ = wallet.revealNextAddress(keychain:.external)
        let psbt = try Psbt(psbtBase64:data.base64EncodedString())
        _ = try wallet.sign(psbt:psbt,signOptions:nil)
        let parsed = try BitcoinConnectPSBT(psbt.serialize())
        guard parsed.transaction.serialize() == unsigned, let witness = parsed.field(8,input:0), !witness.isEmpty else { throw BitcoinSendError.signing }
        return .init(address:encodedAddress,signature:witness.hex,messageHash:digest.hex)
    }

    public static func verify(_ signed: BitcoinConnectSigned, plan: BitcoinConnectPlan) throws {
        try validate(plan)
        let original = try BitcoinConnectPSBT(plan.psbt), result = try BitcoinConnectPSBT(signed.psbt)
        guard original.transaction.serialize() == result.transaction.serialize(), try Psbt(psbtBase64:signed.psbt).fee() == plan.fee else { throw BitcoinConnectError.changed }
        let requested = Set(plan.inputs.map(\.index))
        guard original.maps[0] == result.maps[0],
              original.maps.suffix(original.transaction.output().count) == result.maps.suffix(result.transaction.output().count) else { throw BitcoinConnectError.changed }
        for index in original.transaction.input().indices {
            if requested.contains(index) {
                guard result.field(7,input:index) != nil || result.field(8,input:index) != nil else { throw BitcoinConnectError.changed }
                for type: UInt8 in [0,1] {
                    if let expected = original.field(type,input:index) {
                        guard result.field(type,input:index) == expected else { throw BitcoinConnectError.changed }
                    }
                }
            } else {
                guard original.maps[index + 1] == result.maps[index + 1] else { throw BitcoinConnectError.changed }
            }
        }
        if plan.request.broadcasts {
            let tx = try Psbt(psbtBase64:signed.psbt).extractTx()
            guard tx.serialize() == signed.raw, tx.computeTxid().description == signed.txid else { throw BitcoinConnectError.changed }
        } else if signed.raw != nil || signed.txid != nil { throw BitcoinConnectError.changed }
    }
}

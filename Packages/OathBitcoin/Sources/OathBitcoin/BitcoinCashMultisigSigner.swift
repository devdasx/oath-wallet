import Foundation
import CryptoKit
import OathSecp256k1
internal import BitcoinDevKit

/// P2SH20 sortedmulti using ECDSA ALL|FORKID. No witness or Bitcoin sighash reuse.
/// Caller rederives every input and change from the authenticated vault policy.
enum BitcoinCashMultisigSigner {
    static func sign(_ plan: BitcoinSendPlan, required: Int,
                     keysForCoin: (BitcoinSendCoin) throws -> [Data]) throws -> BitcoinSignedSend {
        try plan.validate()
        guard plan.chain == .bitcoincash else { throw BitcoinError.wrongNetwork }
        let sequence = BitcoinWire.little(plan.inputSequence)
        let outpoints = plan.coins.map { Data(Data(hex: $0.txid)!.reversed()) + BitcoinWire.little(UInt32($0.vout)) }
        let prevoutsHash = hash(outpoints.reduce(Data(), +))
        let sequencesHash = hash(plan.coins.reduce(Data()) { data, _ in data + sequence })
        let outputs = plan.outputs.reduce(Data()) { $0 + BitcoinWire.little(UInt64($1.value)) + BitcoinWire.vector($1.script) }
        let outputsHash = hash(outputs)
        var raw = BitcoinWire.little(UInt32(2)) + BitcoinWire.compact(UInt64(plan.coins.count))
        for (index, coin) in plan.coins.enumerated() {
            try Task.checkCancellation()
            var keys = try keysForCoin(coin)
            defer { for i in keys.indices { keys[i].resetBytes(in: 0..<keys[i].count) } }
            guard (2...15).contains(keys.count), (1...keys.count).contains(required) else { throw BitcoinSendError.signing }
            let publicKeys = try keys.map { try OathSecp256k1.publicKey($0, compressed: true) }
            guard Set(publicKeys).count == keys.count else { throw BitcoinSendError.signing }
            let order = publicKeys.indices.sorted { publicKeys[$0].lexicographicallyPrecedes(publicKeys[$1]) }
            let sorted = order.map { publicKeys[$0] }
            let descriptor = try Descriptor(descriptor: "sh(sortedmulti(\(required),\(sorted.map(\.hex).joined(separator: ","))))", networkKind: .main)
            try descriptor.sanityCheck()
            guard try descriptor.deriveAddress(index: 0, network: .bitcoin).scriptPubkey().toBytes() == Data(hex: coin.address.script) else { throw BitcoinSendError.signing }
            let redeem = Data([0x50 + UInt8(required)]) + sorted.reduce(Data()) { $0 + push($1) } + Data([0x50 + UInt8(keys.count), 0xae])
            guard redeem.count <= 520 else { throw BitcoinSendError.signing }
            var preimage = BitcoinWire.little(UInt32(2)) + prevoutsHash + sequencesHash + outpoints[index]
            preimage += BitcoinWire.vector(redeem) + BitcoinWire.little(UInt64(coin.value)) + sequence
            preimage += outputsHash + BitcoinWire.little(UInt32(0)) + BitcoinWire.little(UInt32(0x41))
            let digest = hash(preimage)
            // Empty CHECKMULTISIG dummy selects the ECDSA path on BCH.
            var script = Data([0])
            for keyIndex in order.prefix(required) {
                script += push(try OathSecp256k1.sign(digest, key: keys[keyIndex]) + Data([0x41]))
            }
            script += push(redeem)
            raw += outpoints[index] + BitcoinWire.vector(script) + sequence
        }
        raw += BitcoinWire.compact(UInt64(plan.outputs.count)) + outputs + BitcoinWire.little(UInt32(0))
        let tx = try BitcoinTransactions.details(raw, network: .bitcoincash)
        guard raw.count >= 100 else { throw BitcoinSendError.signing }
        let signed = BitcoinSignedSend(raw: raw, txid: tx.txid, virtualBytes: UInt64(raw.count), fee: plan.fee)
        try plan.checkSigned(signed)
        return signed
    }
    private static func push(_ data: Data) -> Data {
        if data.count < 76 { return Data([UInt8(data.count)]) + data }
        if data.count <= 255 { return Data([0x4c, UInt8(data.count)]) + data }
        return Data([0x4d]) + BitcoinWire.little(UInt16(data.count)) + data
    }
    private static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: Data(SHA256.hash(data: data)))) }
}

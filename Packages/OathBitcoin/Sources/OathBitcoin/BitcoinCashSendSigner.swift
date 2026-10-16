import Foundation
import CryptoKit
import OathSecp256k1

/// BCH's replay-protected ALL|FORKID signature (0x41). Curve operations,
/// deterministic nonces, low-S normalization and DER encoding use libsecp256k1.
/// Only wallet-supported P2PKH inputs are consumed; P2SH20/32 recipients work.
public enum BitcoinCashSendSigner {
    public static func sign(_ plan: BitcoinSendPlan,
                            source: (String) throws -> BitcoinPrivateKeySource) throws -> BitcoinSignedSend {
        try plan.validate()
        guard plan.chain == .bitcoincash else { throw BitcoinError.wrongNetwork }
        let sequence = BitcoinWire.little(plan.inputSequence)
        let outpoints = plan.coins.map { Data(Data(hex: $0.txid)!.reversed()) + BitcoinWire.little(UInt32($0.vout)) }
        let prevoutsHash = hash(outpoints.reduce(Data(), +))
        let sequencesHash = hash(plan.coins.reduce(Data()) { data, _ in data + sequence })
        let outputs = plan.outputs.reduce(Data()) { $0 + BitcoinWire.little(UInt64($1.value)) + BitcoinWire.vector($1.script) }
        let outputsHash = hash(outputs)
        var raw = BitcoinWire.little(UInt32(2)) + BitcoinWire.compact(UInt64(plan.coins.count))
        // Derive each distinct address once, including its exact account,
        // receive/change branch and index. Keep key material inside this scope.
        var keys: [String: Data] = [:]
        defer { for id in keys.keys { keys[id]!.resetBytes(in: 0..<keys[id]!.count) } }
        for (index, coin) in plan.coins.enumerated() {
            try Task.checkCancellation()
            let id = coin.accountID + ":" + coin.address.id
            if keys[id] == nil {
                let wif = try UTXONetwork.bitcoincash.privateKeyWIF(source: source(coin.accountID), address: coin.address)
                let decoded = try BitcoinCashKeys.decodeImport(wif)
                guard decoded.compressed == coin.compressed else { throw BitcoinSendError.signing }
                keys[id] = decoded.bytes
            }
            let publicData = try OathSecp256k1.publicKey(keys[id]!,compressed:coin.compressed)
            var preimage = BitcoinWire.little(UInt32(2)) + prevoutsHash + sequencesHash + outpoints[index]
            preimage += BitcoinWire.vector(Data(hex: coin.address.script)!) + BitcoinWire.little(UInt64(coin.value)) + sequence
            preimage += outputsHash + BitcoinWire.little(UInt32(0)) + BitcoinWire.little(UInt32(0x41))
            let signatureBytes = try OathSecp256k1.sign(hash(preimage),key:keys[id]!)+Data([0x41])
            let script = Data([UInt8(signatureBytes.count)]) + signatureBytes + Data([UInt8(publicData.count)]) + publicData
            raw += outpoints[index] + BitcoinWire.vector(script) + sequence
        }
        raw += BitcoinWire.compact(UInt64(plan.outputs.count)) + outputs + BitcoinWire.little(UInt32(0))
        let tx = try BitcoinTransactions.details(raw, network: .bitcoincash)
        guard raw.count >= 100 else { throw BitcoinSendError.signing }
        let signed = BitcoinSignedSend(raw: raw, txid: tx.txid, virtualBytes: UInt64(raw.count), fee: plan.fee)
        try plan.checkSigned(signed)
        return signed
    }
    private static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: Data(SHA256.hash(data: data)))) }
}

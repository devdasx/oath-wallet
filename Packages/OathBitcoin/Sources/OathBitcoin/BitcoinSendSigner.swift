import Foundation
internal import BitcoinDevKit

public struct BitcoinSignedSend: Sendable {
    public let raw: Data
    public let txid: String
    public let virtualBytes: UInt64
    public let fee: Int64
}

public enum BitcoinSendSigner {
    /// The source closure runs only inside the vault, after fresh authorization.
    /// BDK handles ECDSA/Schnorr, Taproot tweaking and PSBT finalization; this
    /// layer constructs and independently checks the exact reviewed outputs.
    public static func sign(_ plan: BitcoinSendPlan,
                            source: (String) throws -> BitcoinPrivateKeySource) throws -> BitcoinSignedSend {
        try signWithDescriptors(plan) { coin in
            guard coin.address.multisigInputWeight == nil else { throw BitcoinSendError.signing }
            let chainWIF = try plan.chain.privateKeyWIF(source: source(coin.accountID), address: coin.address)
            // BDK accepts Bitcoin WIF; only the version byte changes. The leaf
            // and all script commitments were derived on the selected chain.
            var payload = try Base58Check.decode(chainWIF)
            defer { payload.resetBytes(in: 0..<payload.count) }
            payload[0] = 0x80
            let wif = Base58Check.encode(payload)
            let descriptor = try Descriptor(descriptor: coin.address.type.wrap(wif), networkKind: .main)
            return descriptor
        }
    }

    static func signWithDescriptors(_ plan: BitcoinSendPlan,
                                    descriptorForCoin: (BitcoinSendCoin) throws -> Descriptor) throws -> BitcoinSignedSend {
        try plan.validate()
        guard [.bitcoin, .litecoin, .dogecoin].contains(plan.chain) else { throw BitcoinError.wrongNetwork }
        var unsigned = BitcoinWire.little(UInt32(2)) + BitcoinWire.compact(UInt64(plan.coins.count))
        for coin in plan.coins {
            unsigned += Data(Data(hex: coin.txid)!.reversed()) + BitcoinWire.little(UInt32(coin.vout))
            unsigned += Data([0]) + BitcoinWire.little(plan.inputSequence)
        }
        unsigned += BitcoinWire.compact(UInt64(plan.outputs.count))
        for output in plan.outputs {
            unsigned += BitcoinWire.little(UInt64(output.value)) + BitcoinWire.vector(output.script)
        }
        unsigned += BitcoinWire.little(UInt32(0))
        let global = BitcoinWire.pair(0, unsigned) + Data([0])
        let inputMaps = try plan.coins.map { coin -> Data in
            // MWEB extensions are outside the transparent transaction ID and
            // signature. BDK must receive the canonical transparent parent.
            var map = BitcoinWire.pair(0, plan.chain == .litecoin ? try LitecoinTransaction.transparentBytes(coin.previousTransaction) : coin.previousTransaction)
            if coin.address.type != .legacy {
                map += BitcoinWire.pair(1, BitcoinWire.little(UInt64(coin.value)) + BitcoinWire.vector(Data(hex: coin.address.script)!))
            }
            return map
        }
        var finalMaps = inputMaps
        var signedAddresses = Set<String>()
        for coin in plan.coins where signedAddresses.insert(coin.accountID + ":" + coin.address.id).inserted {
            try Task.checkCancellation()
            let descriptor = try descriptorForCoin(coin)
            guard try descriptor.deriveAddress(index: 0, network: .bitcoin).scriptPubkey().toBytes().hex == coin.address.script else {
                throw BitcoinSendError.signing
            }
            let matching = plan.coins.map { $0.accountID == coin.accountID && $0.address == coin.address }
            var data = Data([0x70,0x73,0x62,0x74,0xff]) + global
            for i in inputMaps.indices {
                data += inputMaps[i]
                // BDK's single-key signer visits every input, including those
                // using another signing algorithm. Scope this signing pass by
                // marking unrelated inputs finalized in this temporary PSBT.
                // Their maps are NEVER copied into the resulting transaction.
                if !matching[i] { data += BitcoinWire.pair(7, Data()) }
                data += Data([0])
            }
            data += Data(repeating: 0, count: plan.outputs.count)
            let psbt = try Psbt(psbtBase64: data.base64EncodedString())
            let wallet = try Wallet.createSingle(descriptor: descriptor, network: .bitcoin, persister: Persister.newInMemory())
            _ = wallet.revealNextAddress(keychain: .external)
            _ = try wallet.sign(psbt: psbt, signOptions: nil)
            let maps = try PSBTMaps.decode(Data(base64Encoded: psbt.serialize())!)
            guard maps.count == 1 + plan.coins.count + (plan.outputs.count), maps[0] == global else {
                throw BitcoinSendError.signing
            }
            for i in matching.indices where matching[i] { finalMaps[i] = maps[i + 1].dropLast() }
        }
        var finalData = Data([0x70,0x73,0x62,0x74,0xff]) + global
        for map in finalMaps { finalData += map + Data([0]) }
        finalData += Data(repeating: 0, count: plan.outputs.count)
        let psbt = try Psbt(psbtBase64: finalData.base64EncodedString())
        // BDK's default 25,000 sat/vB guard is a Bitcoin policy. DOGE uses
        // koinu and legitimately exceeds it. First enforce the exact reviewed
        // absolute fee, then derive a bound from that budget and the unsigned
        // transaction's size (a lower bound on finalized virtual size). Keep
        // BDK's checked extraction; never use unchecked fee extraction.
        guard try psbt.fee() == UInt64(plan.fee) else { throw BitcoinSendError.signing }
        let tx: Transaction
        if plan.chain == .dogecoin {
            let sizeFloor = UInt64(unsigned.count)
            let reviewedRateCeiling = (UInt64(plan.fee) + sizeFloor - 1) / sizeFloor
            tx = try psbt.extractTxWithFeeRateLimit(maxFeeRate: .fromSatPerVb(satVb: reviewedRateCeiling))
        } else {
            tx = try psbt.extractTx()
        }
        let signed = BitcoinSignedSend(raw: tx.serialize(), txid: tx.computeTxid().description, virtualBytes: tx.vsize(), fee: plan.fee)
        try plan.checkSigned(signed)
        return signed
    }
}

// Container parsing only; cryptography and transaction consensus parsing stay
// inside BDK. Preserves each signed map byte-for-byte, excluding scoped sentinels.
private enum PSBTMaps {
    static func decode(_ data: Data) throws -> [Data] {
        let bytes = Array(data)
        guard bytes.prefix(5) == [0x70,0x73,0x62,0x74,0xff] else { throw BitcoinSendError.signing }
        var cursor = 5, maps: [Data] = []
        func size() throws -> Int {
            guard cursor < bytes.count else { throw BitcoinSendError.signing }
            let prefix = bytes[cursor]; cursor += 1
            if prefix < 253 { return Int(prefix) }
            let count = prefix == 253 ? 2 : prefix == 254 ? 4 : 8
            guard cursor + count <= bytes.count else { throw BitcoinSendError.signing }
            var result: UInt64 = 0
            for offset in 0..<count { result |= UInt64(bytes[cursor + offset]) << (8 * offset) }
            cursor += count
            guard result <= UInt64(bytes.count) else { throw BitcoinSendError.signing }
            return Int(result)
        }
        while cursor < bytes.count {
            let start = cursor
            while true {
                let key = try size()
                if key == 0 { break }
                guard cursor + key <= bytes.count else { throw BitcoinSendError.signing }; cursor += key
                let value = try size()
                guard cursor + value <= bytes.count else { throw BitcoinSendError.signing }; cursor += value
            }
            maps.append(Data(bytes[start..<cursor]))
        }
        return maps
    }
}

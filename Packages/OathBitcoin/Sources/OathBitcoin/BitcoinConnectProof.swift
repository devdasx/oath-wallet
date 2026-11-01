import Foundation
internal import BitcoinDevKit

/// Verify only the requested, single-key inputs against the reviewed transaction.
enum BitcoinConnectProof {
    static func check(plan: BitcoinConnectPlan, reviewed: BitcoinConnectPSBT, final: Transaction) throws {
        let inputs = final.input()
        let selected = Set(plan.inputs.map(\.index))
        guard inputs.count == reviewed.transaction.input().count, selected.isSubset(of: inputs.indices) else { throw BitcoinConnectError.changed }
        var proof = reviewed
        proof.maps[0] = reviewed.maps[0].filter { $0.key == Data([0]) }
        for index in inputs.indices {
            let input = inputs[index]
            guard let raw = reviewed.field(0, input: index) else { throw BitcoinConnectError.wrongInput }
            let outputs = try Transaction(transactionBytes: raw).output()
            let vout = Int(input.previousOutput.vout)
            guard outputs.indices.contains(vout) else { throw BitcoinConnectError.wrongInput }
            let output = outputs[vout]
            // Review already matched the full parent to its txid. Taproot needs
            // the actual previous output of *every* input, including foreign ones.
            let utxo = BitcoinWire.little(output.value.toSat()) + BitcoinWire.vector(output.scriptPubkey.toBytes())
            proof.maps[index + 1] = [.init(key: Data([1]), value: utxo)]
            if selected.contains(index) {
                guard let address = plan.ownedInputs[index], let flag = reviewed.field(3, input: index) else {
                    throw BitcoinConnectError.changed
                }
                try addSignature(input, type: address.type, flag: flag, map: &proof.maps[index + 1])
            } else {
                // Ask miniscript to skip this input. This sentinel is confined to
                // the verifier and never enters the returned or journaled packet.
                proof.set(7, Data(), input: index)
            }
        }
        for index in (1 + inputs.count)..<proof.maps.count { proof.maps[index] = [] }

        // An already-finalized map is skipped by BDK. Rebuild the requested
        // partials and let its script interpreter validate their actual digests.
        let checked = try Psbt(psbtBase64: proof.encoded).finalize()
        guard checked.couldFinalize else { throw BitcoinConnectError.changed }
        let reproduced = try checked.psbt.extractTx().input()
        guard reproduced.count == inputs.count else { throw BitcoinConnectError.changed }
        for index in selected {
            guard reproduced[index].scriptSig.toBytes() == inputs[index].scriptSig.toBytes(),
                  reproduced[index].witness == inputs[index].witness else { throw BitcoinConnectError.changed }
        }
    }

    private static func addSignature(_ input: TxIn, type: BitcoinAddressType, flag: Data,
                                     map: inout [BitcoinConnectPSBT.Pair]) throws {
        let script = input.scriptSig.toBytes()
        let signature: Data, pubkey: Data
        switch type {
        case .taproot:
            guard script.isEmpty, input.witness.count == 1 else { throw BitcoinConnectError.changed }
            let sig = input.witness[0]
            guard (sig.count == 64 && flag == BitcoinWire.little(UInt32(0))) ||
                  (sig.count == 65 && sig.last == 1 && flag == BitcoinWire.little(UInt32(1))) else {
                throw BitcoinConnectError.changed
            }
            map.append(.init(key: Data([0x13]), value: sig))
            return
        case .legacy:
            guard input.witness.isEmpty, let size = script.first, (9...73).contains(size),
                  script.count > 1 + Int(size) else { throw BitcoinConnectError.changed }
            let offset = 1 + Int(size), keySize = Int(script[offset])
            guard [33, 65].contains(keySize), script.count == offset + 1 + keySize else { throw BitcoinConnectError.changed }
            signature = script.subdata(in: 1..<offset)
            pubkey = Data(script.suffix(keySize))
        case .nativeSegwit, .nestedSegwit:
            guard input.witness.count == 2, input.witness[1].count == 33 else { throw BitcoinConnectError.changed }
            if type == .nestedSegwit {
                guard script.count == 23, script.prefix(3) == Data([22, 0, 20]) else { throw BitcoinConnectError.changed }
                map.append(.init(key: Data([4]), value: Data(script.dropFirst())))
            } else if !script.isEmpty { throw BitcoinConnectError.changed }
            signature = input.witness[0]
            pubkey = input.witness[1]
        }
        guard signature.last == 1, flag == BitcoinWire.little(UInt32(1)) else { throw BitcoinConnectError.changed }
        map.append(.init(key: Data([2]) + pubkey, value: signature))
    }
}

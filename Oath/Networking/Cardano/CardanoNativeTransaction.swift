import Foundation
import WalletCore

struct CardanoSignedTransfer: Sendable {
    let encoded: Data
    let hash: String
    let amount: UInt64
    let fee: UInt64
    let change: UInt64
    let inputs: [CardanoUTXO]
}

/// Signing is entirely local. Only the final CBOR is passed to the submit API.
enum CardanoNativeTransaction {
    static func sign(snapshot: CardanoSnapshot, recipient: String, amount: UInt64,
                     sendMax: Bool, privateKey: Data,
                     parameters: CardanoProtocolParameters) throws -> CardanoSignedTransfer {
        guard CardanoAddress.isKeyPaymentAddress(recipient),
              CardanoAddress.validated(snapshot.address) == snapshot.address else {
            throw CardanoError.invalidAddress
        }
        guard privateKey.count == 192, let key = PrivateKey(data: privateKey),
              CoinType.cardano.deriveAddress(privateKey: key) == snapshot.address else {
            throw CardanoError.invalidKey
        }
        guard parameters.feePerByte > 0, parameters.feePerByte < 1_000_000,
              parameters.feeConstant > 0, parameters.feeConstant < 100_000_000,
              parameters.coinsPerUTXOByte > 0, parameters.maxTransactionSize > 0,
              parameters.slot < UInt64.max - 1_800 else { throw CardanoError.invalidResponse }
        let minimum = try minimumOutput(recipient, parameters: parameters)
        let minimumChange = try minimumOutput(snapshot.address, parameters: parameters)
        if !sendMax && amount < minimum { throw CardanoError.minimumOutput }
        var seen = Set<String>()
        for output in snapshot.utxos {
            guard CardanoAPIClient.validHash(output.hash), seen.insert(output.id).inserted,
                  output.tokenCount >= 0, output.index <= UInt16.max else { throw CardanoError.invalidResponse }
        }
        let eligible = snapshot.utxos.filter { $0.tokenCount == 0 }.sorted {
            $0.amount == $1.amount ? $0.id < $1.id : $0.amount > $1.amount
        }
        guard !eligible.isEmpty else {
            throw snapshot.utxos.isEmpty ? CardanoError.insufficientFunds : CardanoError.tokenBearingFunds
        }
        var fee = try checkedAdd(parameters.feeConstant, checkedMultiply(parameters.feePerByte, 300))
        // A monotonic fee converges despite CBOR integer-width boundaries.
        for _ in 0..<16 {
            var selected: [CardanoUTXO] = []
            var total: UInt64 = 0
            let required = sendMax ? 0 : try checkedAdd(amount, fee)
            for output in eligible {
                total = try checkedAdd(total, output.amount)
                selected.append(output)
                if !sendMax && total >= required && (total == required || total - required >= minimumChange) { break }
            }
            guard total >= fee else { throw CardanoError.insufficientFunds }
            let sending = sendMax ? total - fee : amount
            guard sending >= minimum, total >= (try checkedAdd(sending, fee)) else {
                throw CardanoError.insufficientFunds
            }
            let change = total - sending - fee
            guard change == 0 || change >= minimumChange else { throw CardanoError.minimumOutput }
            var input = CardanoSigningInput()
            input.privateKey = [privateKey]
            input.ttl = parameters.slot + 1_800
            input.transferMessage.toAddress = recipient
            input.transferMessage.changeAddress = snapshot.address
            input.transferMessage.amount = sending
            input.transferMessage.forceFee = fee
            input.utxos = try selected.map { output in
                guard let hash = Data(hexString: output.hash), hash.count == 32 else { throw CardanoError.invalidResponse }
                var value = CardanoTxInput()
                value.outPoint.txHash = hash
                value.outPoint.outputIndex = output.index
                value.address = snapshot.address
                value.amount = output.amount
                return value
            }
            var plan = CardanoTransactionPlan()
            plan.availableAmount = total
            plan.amount = sending
            plan.fee = fee
            plan.change = change
            plan.utxos = input.utxos
            input.plan = plan
            let signed: CardanoSigningOutput = AnySigner.sign(input: input, coin: .cardano)
            guard signed.error == .ok, !signed.encoded.isEmpty, signed.txID.count == 32 else {
                throw CardanoError.invalidTransaction
            }
            let encoded = try currentEraEnvelope(signed.encoded)
            guard encoded.count <= parameters.maxTransactionSize else { throw CardanoError.invalidTransaction }
            let requiredFee = try checkedAdd(parameters.feeConstant,
                checkedMultiply(parameters.feePerByte, UInt64(encoded.count)))
            if fee >= requiredFee {
                return CardanoSignedTransfer(encoded: encoded, hash: signed.txID.hexString,
                    amount: sending, fee: fee, change: change, inputs: selected)
            }
            fee = requiredFee
        }
        throw CardanoError.invalidTransaction
    }

    // WalletCore's native signer emits the three-field Shelley envelope.
    // Alonzo and later add the script-validity flag; body bytes (and therefore
    // transaction ID and signatures) must remain byte-for-byte unchanged.
    static func currentEraEnvelope(_ legacy: Data) throws -> Data {
        guard legacy.first == 0x83, legacy.last == 0xf6 else { throw CardanoError.invalidTransaction }
        return Data([0x84]) + legacy.dropFirst().dropLast() + Data([0xf5, 0xf6])
    }

    static func minimumOutput(_ address: String, parameters: CardanoProtocolParameters) throws -> UInt64 {
        guard let text = Cardano.outputMinAdaAmount(toAddress: address,
              tokenBundle: try CardanoTokenBundle().serializedData(),
              coinsPerUtxoByte: String(parameters.coinsPerUTXOByte)),
              let value = UInt64(text), value > 0 else { throw CardanoError.invalidResponse }
        return value
    }

    private static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw CardanoError.invalidResponse }
        return result.partialValue
    }

    private static func checkedMultiply(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { throw CardanoError.invalidResponse }
        return result.partialValue
    }
}

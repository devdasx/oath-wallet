import CryptoKit
import Foundation
import WalletCore

struct SendBitcoinFinalizedTransaction: Sendable {
    let encoded: Data
    let transactionID: String
    let virtualSize: Int64
    let patchedOutpointIDs: Set<String>
}

enum SendBitcoinNestedSegwitTransaction {
    private static let maximumTransactionBytes = 4_000_000

    static func finalize(
        encoded: Data,
        nestedPublicKeysByOutpointID: [String: Data]
    ) throws -> SendBitcoinFinalizedTransaction {
        guard !encoded.isEmpty,
              encoded.count <= maximumTransactionBytes else {
            throw invalidTransaction("bitcoin_transaction_size")
        }
        var transaction = try Transaction(encoded)
        var patched = Set<String>()
        for index in transaction.inputs.indices {
            let id = transaction.inputs[index].outpointID
            guard let publicKeyData = nestedPublicKeysByOutpointID[id]
            else { continue }
            guard transaction.hasWitness,
                  transaction.inputs[index].script.isEmpty,
                  let publicKey = PublicKey(
                      data: publicKeyData,
                      type: .secp256k1
                  ) else {
                throw invalidTransaction(
                    "bitcoin_nested_segwit_input"
                )
            }
            let redeem = BitcoinScript.buildPayToWitnessPubkeyHash(
                hash: publicKey.bitcoinKeyHash
            ).data
            guard redeem.count == 22 else {
                throw invalidTransaction(
                    "bitcoin_nested_segwit_redeem"
                )
            }
            transaction.inputs[index].script = Data([UInt8(redeem.count)])
                + redeem
            patched.insert(id)
        }

        let finalized = transaction.serialized(includeWitness: true)
        let stripped = transaction.serialized(includeWitness: false)
        guard finalized.count <= maximumTransactionBytes else {
            throw invalidTransaction("bitcoin_transaction_size")
        }
        let weight = try checkedAdd(
            try checkedMultiply(stripped.count, 3),
            finalized.count
        )
        let virtualSize = try checkedAdd(weight, 3) / 4
        let first = Data(SHA256.hash(data: stripped))
        let second = Data(SHA256.hash(data: first))
        let transactionID = second.reversed()
            .map { String(format: "%02x", $0) }
            .joined()
        return SendBitcoinFinalizedTransaction(
            encoded: finalized,
            transactionID: transactionID,
            virtualSize: Int64(virtualSize),
            patchedOutpointIDs: patched
        )
    }

    private static func checkedMultiply(
        _ left: Int,
        _ right: Int
    ) throws -> Int {
        let result = left.multipliedReportingOverflow(by: right)
        guard !result.overflow else {
            throw invalidTransaction("bitcoin_transaction_weight")
        }
        return result.partialValue
    }

    private static func checkedAdd(
        _ left: Int,
        _ right: Int
    ) throws -> Int {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else {
            throw invalidTransaction("bitcoin_transaction_weight")
        }
        return result.partialValue
    }

    private static func invalidTransaction(
        _ code: String
    ) -> SendTransactionSubmissionError {
        .signing(
            code: code,
            message: WalletLocalization.string(
                "send.submit.error.provider_invalid_response"
            )
        )
    }
}

private extension SendBitcoinNestedSegwitTransaction {
    struct Transaction {
        struct Input {
            let previousHash: Data
            let previousIndex: UInt32
            var script: Data
            let sequence: UInt32
            var witness: [Data]

            var outpointID: String {
                "\(Data(previousHash.reversed()).hexString):\(previousIndex)"
            }
        }

        struct Output {
            let value: UInt64
            let script: Data
        }

        let version: Data
        let hasWitness: Bool
        var inputs: [Input]
        let outputs: [Output]
        let lockTime: Data

        init(_ encoded: Data) throws {
            var reader = Reader(encoded)
            version = try reader.read(count: 4)
            let witness = reader.remainingCount >= 2
                && reader.peek() == 0
                && reader.peek(offset: 1) != 0
            if witness {
                _ = try reader.readByte()
                _ = try reader.readByte()
            }
            let inputCount = try reader.readVariableInteger()
            guard inputCount > 0 else {
                throw SendBitcoinNestedSegwitTransaction
                    .invalidTransaction("bitcoin_transaction_inputs")
            }
            var values: [Input] = []
            values.reserveCapacity(inputCount)
            for _ in 0..<inputCount {
                values.append(
                    Input(
                        previousHash: try reader.read(count: 32),
                        previousIndex: try reader.readUInt32(),
                        script: try reader.readVariableData(),
                        sequence: try reader.readUInt32(),
                        witness: []
                    )
                )
            }
            let outputCount = try reader.readVariableInteger()
            guard outputCount > 0 else {
                throw SendBitcoinNestedSegwitTransaction
                    .invalidTransaction("bitcoin_transaction_outputs")
            }
            var transactionOutputs: [Output] = []
            transactionOutputs.reserveCapacity(outputCount)
            for _ in 0..<outputCount {
                transactionOutputs.append(
                    Output(
                        value: try reader.readUInt64(),
                        script: try reader.readVariableData()
                    )
                )
            }
            if witness {
                for index in values.indices {
                    let count = try reader.readVariableInteger()
                    var items: [Data] = []
                    items.reserveCapacity(count)
                    for _ in 0..<count {
                        items.append(try reader.readVariableData())
                    }
                    values[index].witness = items
                }
            }
            lockTime = try reader.read(count: 4)
            guard reader.remainingCount == 0 else {
                throw SendBitcoinNestedSegwitTransaction
                    .invalidTransaction("bitcoin_transaction_trailing")
            }
            hasWitness = witness
            inputs = values
            outputs = transactionOutputs
        }

        func serialized(includeWitness: Bool) -> Data {
            var output = version
            if includeWitness, hasWitness {
                output.append(contentsOf: [0x00, 0x01])
            }
            output.append(Self.variableInteger(inputs.count))
            for input in inputs {
                output.append(input.previousHash)
                output.append(Self.littleEndian(input.previousIndex))
                output.append(Self.variableInteger(input.script.count))
                output.append(input.script)
                output.append(Self.littleEndian(input.sequence))
            }
            output.append(Self.variableInteger(outputs.count))
            for transactionOutput in outputs {
                output.append(Self.littleEndian(transactionOutput.value))
                output.append(
                    Self.variableInteger(transactionOutput.script.count)
                )
                output.append(transactionOutput.script)
            }
            if includeWitness, hasWitness {
                for input in inputs {
                    output.append(Self.variableInteger(input.witness.count))
                    for item in input.witness {
                        output.append(Self.variableInteger(item.count))
                        output.append(item)
                    }
                }
            }
            output.append(lockTime)
            return output
        }

        private static func variableInteger(_ value: Int) -> Data {
            if value < 0xfd {
                return Data([UInt8(value)])
            }
            if value <= Int(UInt16.max) {
                return Data([0xfd]) + littleEndian(UInt16(value))
            }
            if UInt64(value) <= UInt64(UInt32.max) {
                return Data([0xfe]) + littleEndian(UInt32(value))
            }
            return Data([0xff]) + littleEndian(UInt64(value))
        }

        private static func littleEndian<T: FixedWidthInteger>(
            _ value: T
        ) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
    }

    struct Reader {
        let data: Data
        private(set) var offset = 0

        var remainingCount: Int { data.count - offset }

        init(_ data: Data) {
            self.data = data
        }

        func peek(offset additionalOffset: Int = 0) -> UInt8? {
            let index = offset + additionalOffset
            guard data.indices.contains(index) else { return nil }
            return data[index]
        }

        mutating func readByte() throws -> UInt8 {
            guard let value = peek() else {
                throw SendBitcoinNestedSegwitTransaction
                    .invalidTransaction("bitcoin_transaction_truncated")
            }
            offset += 1
            return value
        }

        mutating func read(count: Int) throws -> Data {
            guard count >= 0, remainingCount >= count else {
                throw SendBitcoinNestedSegwitTransaction
                    .invalidTransaction("bitcoin_transaction_truncated")
            }
            let start = offset
            offset += count
            return data[start..<offset]
        }

        mutating func readUInt16() throws -> UInt16 {
            let bytes = try read(count: 2)
            return bytes.enumerated().reduce(UInt16(0)) {
                $0 | (UInt16($1.element) << UInt16($1.offset * 8))
            }
        }

        mutating func readUInt32() throws -> UInt32 {
            let bytes = try read(count: 4)
            return bytes.enumerated().reduce(UInt32(0)) {
                $0 | (UInt32($1.element) << UInt32($1.offset * 8))
            }
        }

        mutating func readUInt64() throws -> UInt64 {
            let bytes = try read(count: 8)
            return bytes.enumerated().reduce(UInt64(0)) {
                $0 | (UInt64($1.element) << UInt64($1.offset * 8))
            }
        }

        mutating func readVariableInteger() throws -> Int {
            let prefix = try readByte()
            let value: UInt64
            switch prefix {
            case 0..<0xfd:
                value = UInt64(prefix)
            case 0xfd:
                value = UInt64(try readUInt16())
                guard value >= 0xfd else {
                    throw SendBitcoinNestedSegwitTransaction
                        .invalidTransaction("bitcoin_transaction_varint")
                }
            case 0xfe:
                value = UInt64(try readUInt32())
                guard value > UInt64(UInt16.max) else {
                    throw SendBitcoinNestedSegwitTransaction
                        .invalidTransaction("bitcoin_transaction_varint")
                }
            case 0xff:
                value = try readUInt64()
                guard value > UInt64(UInt32.max) else {
                    throw SendBitcoinNestedSegwitTransaction
                        .invalidTransaction("bitcoin_transaction_varint")
                }
            default:
                throw SendBitcoinNestedSegwitTransaction
                    .invalidTransaction("bitcoin_transaction_varint")
            }
            guard let count = Int(exactly: value),
                  count <= remainingCount else {
                throw SendBitcoinNestedSegwitTransaction
                    .invalidTransaction("bitcoin_transaction_varint")
            }
            return count
        }

        mutating func readVariableData() throws -> Data {
            try read(count: readVariableInteger())
        }
    }
}

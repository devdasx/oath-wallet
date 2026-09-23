import CryptoKit
import Foundation

struct BitcoinRawTransaction {
    struct Input {
        let previousHash: String
        let previousIndex: Int
    }

    struct Output {
        let value: BitcoinFamilyAtomicInteger
        let script: Data
    }

    let inputs: [Input]
    let outputs: [Output]
    let transactionID: String

    init?(hex: String) {
        guard let data = Data(bitcoinHex: hex) else { return nil }
        var reader = BitcoinDataReader(data)
        guard let version = reader.data(4) else { return nil }
        var isSegWit = false
        if reader.peek() == 0, reader.peek(offset: 1) != 0 {
            guard reader.skip(2) else { return nil }
            isSegWit = true
        }
        let strippedBodyStart = reader.offset
        guard let inputCount = reader.varInt(), inputCount <= 100_000 else {
            return nil
        }
        var parsedInputs: [Input] = []
        for _ in 0..<inputCount {
            guard let previousHashLE = reader.data(32),
                  let previousIndex = reader.uint32(),
                  let scriptLength = reader.varInt(),
                  reader.skip(Int(scriptLength)),
                  reader.skip(4) else { return nil }
            let previousHash = previousHashLE.reversed()
                .map { String(format: "%02x", $0) }.joined()
            parsedInputs.append(
                Input(
                    previousHash: previousHash,
                    previousIndex: Int(previousIndex)
                )
            )
        }
        guard let outputCount = reader.varInt(), outputCount <= 100_000 else {
            return nil
        }
        var parsedOutputs: [Output] = []
        for _ in 0..<outputCount {
            guard let value = reader.uint64(),
                  let scriptLength = reader.varInt(),
                  let script = reader.data(Int(scriptLength)) else {
                return nil
            }
            parsedOutputs.append(
                Output(
                    value: BitcoinFamilyAtomicInteger(value),
                    script: script
                )
            )
        }
        let witnessStart = reader.offset
        if isSegWit {
            for _ in 0..<inputCount {
                guard let itemCount = reader.varInt() else { return nil }
                for _ in 0..<itemCount {
                    guard let size = reader.varInt(),
                          reader.skip(Int(size)) else { return nil }
                }
            }
        }
        guard let lockTime = reader.data(4), reader.isAtEnd else {
            return nil
        }
        let stripped: Data
        if isSegWit {
            stripped = version
                + Data(data[strippedBodyStart..<witnessStart])
                + lockTime
        } else {
            stripped = data
        }
        let firstHash = Data(SHA256.hash(data: stripped))
        transactionID = Data(SHA256.hash(data: firstHash)).reversed()
            .map { String(format: "%02x", $0) }
            .joined()
        inputs = parsedInputs
        outputs = parsedOutputs
    }
}

private struct BitcoinDataReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    var isAtEnd: Bool { offset == bytes.count }

    func peek(offset relative: Int = 0) -> UInt8? {
        let index = offset + relative
        return bytes.indices.contains(index) ? bytes[index] : nil
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0,
              offset <= bytes.count,
              count <= bytes.count - offset else { return false }
        offset += count
        return true
    }

    mutating func data(_ count: Int) -> Data? {
        guard count >= 0,
              offset <= bytes.count,
              count <= bytes.count - offset else { return nil }
        defer { offset += count }
        return Data(bytes[offset..<(offset + count)])
    }

    mutating func uint32() -> UInt32? {
        guard let data = data(4) else { return nil }
        return data.enumerated().reduce(0) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
    }

    mutating func uint64() -> UInt64? {
        guard let data = data(8) else { return nil }
        return data.enumerated().reduce(0) {
            $0 | (UInt64($1.element) << UInt64($1.offset * 8))
        }
    }

    mutating func varInt() -> Int? {
        guard let first = data(1)?.first else { return nil }
        switch first {
        case 0...0xfc:
            return Int(first)
        case 0xfd:
            guard let value = data(2) else { return nil }
            return Int(value.enumerated().reduce(UInt16(0)) {
                $0 | (UInt16($1.element) << UInt16($1.offset * 8))
            })
        case 0xfe:
            return uint32().map(Int.init)
        default:
            guard let value = uint64(), value <= UInt64(Int.max) else {
                return nil
            }
            return Int(value)
        }
    }
}

extension Data {
    init?(bitcoinHex: String) {
        guard bitcoinHex.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        result.reserveCapacity(bitcoinHex.count / 2)
        var index = bitcoinHex.startIndex
        while index < bitcoinHex.endIndex {
            let end = bitcoinHex.index(index, offsetBy: 2)
            guard let value = UInt8(bitcoinHex[index..<end], radix: 16) else {
                return nil
            }
            result.append(value)
            index = end
        }
        self = result
    }
}

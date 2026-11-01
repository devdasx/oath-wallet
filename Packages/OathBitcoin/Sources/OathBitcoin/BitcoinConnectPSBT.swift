import Foundation
internal import BitcoinDevKit

public struct BitcoinConnectOutput: Codable, Equatable, Sendable {
    public let address: String?
    public let script: Data
    public let value: UInt64
    public let owned: Bool
    public var dataOutput: BitcoinDataOutput? { BitcoinDataOutput(script: script) }
}

public struct BitcoinConnectPlan: Codable, Equatable, Sendable {
    public let request: BitcoinConnectRequest
    public let psbt: String
    public let inputs: [BitcoinConnectRequest.Input]
    public let ownedInputs: [Int: BitcoinDerivedAddress]
    public let reviewedAddresses: [BitcoinDerivedAddress]
    public let outputs: [BitcoinConnectOutput]
    public let fee: UInt64
    public let debit: UInt64
    public let createdAt: Date
    public var outpoints: [String] {
        (try? BitcoinConnectPSBT(psbt).transaction.input().map { $0.previousOutput.txid.description + ":" + String($0.previousOutput.vout) }) ?? []
    }
}

public struct BitcoinConnectSigned: Codable, Equatable, Sendable {
    public let psbt: String
    public let raw: Data?
    public let txid: String?
}

/// Parses only the PSBT container. BDK validates the unsigned transaction and
/// performs all consensus signing. Unknown fields and unselected inputs survive.
struct BitcoinConnectPSBT {
    static let maximumBytes = 500_000
    struct Pair: Equatable { let key: Data; var value: Data }
    var maps: [[Pair]]
    let transaction: Transaction
    init(_ base64: String) throws {
        guard base64.utf8.count <= ((Self.maximumBytes + 2) / 3) * 4,
              let raw = Data(base64Encoded: base64), raw.count <= Self.maximumBytes,
              raw.prefix(5) == Data([0x70,0x73,0x62,0x74,0xff]) else { throw BitcoinConnectError.invalidPSBT }
        _ = try Psbt(psbtBase64: base64)
        let bytes = Array(raw); var offset = 5, result: [[Pair]] = []
        func size() throws -> Int {
            guard offset < bytes.count else { throw BitcoinConnectError.invalidPSBT }
            let first = bytes[offset]; offset += 1
            if first < 253 { return Int(first) }
            let width = first == 253 ? 2 : first == 254 ? 4 : 8
            guard width <= bytes.count - offset else { throw BitcoinConnectError.invalidPSBT }
            var value: UInt64 = 0
            for i in 0..<width { value |= UInt64(bytes[offset + i]) << (8 * i) }; offset += width
            guard value <= UInt64(bytes.count), value >= (width == 2 ? 253 : width == 4 ? 65536 : 4294967296) else { throw BitcoinConnectError.invalidPSBT }
            return Int(value)
        }
        while offset < bytes.count {
            var pairs: [Pair] = [], keys = Set<Data>()
            while true {
                let count = try size(); if count == 0 { break }
                guard count <= bytes.count - offset else { throw BitcoinConnectError.invalidPSBT }
                let key = Data(bytes[offset..<(offset + count)]); offset += count
                guard keys.insert(key).inserted else { throw BitcoinConnectError.invalidPSBT }
                let length = try size()
                guard length <= bytes.count - offset else { throw BitcoinConnectError.invalidPSBT }
                pairs.append(.init(key: key, value: Data(bytes[offset..<(offset + length)]))); offset += length
            }
            result.append(pairs)
            guard result.count <= 258 else { throw BitcoinConnectError.tooLarge }
        }
        guard let global = result.first, let unsigned = global.first(where: { $0.key == Data([0]) })?.value,
              global.first(where: { $0.key == Data([0xfb]) }).map({ $0.value == Data(repeating: 0, count: 4) }) ?? true else { throw BitcoinConnectError.unsupported }
        transaction = try Transaction(transactionBytes: unsigned)
        guard !transaction.input().isEmpty, transaction.input().count <= 128, !transaction.output().isEmpty,
              transaction.output().count <= 128, result.count == 1 + transaction.input().count + transaction.output().count else { throw BitcoinConnectError.tooLarge }
        maps = result
    }
    func field(_ type: UInt8, input: Int) -> Data? { maps[input + 1].first { $0.key == Data([type]) }?.value }
    mutating func set(_ type: UInt8, _ value: Data, input: Int) {
        maps[input + 1].removeAll { $0.key == Data([type]) }; maps[input + 1].append(.init(key: Data([type]), value: value))
    }
    var encoded: String {
        get throws {
            var data = Data([0x70,0x73,0x62,0x74,0xff])
            for map in maps {
                for pair in map {
                    for field in [pair.key, pair.value] {
                        let prefix = BitcoinWire.compact(UInt64(field.count))
                        guard prefix.count + field.count <= Self.maximumBytes - data.count else {
                            throw BitcoinConnectError.tooLarge
                        }
                        data.append(prefix)
                        data.append(field)
                    }
                }
                guard data.count < Self.maximumBytes else { throw BitcoinConnectError.tooLarge }
                data.append(0)
            }
            return data.base64EncodedString()
        }
    }
}

public enum BitcoinConnectSigning {
    public static func previousTransactions(_ psbt: String) throws -> [String] {
        let parsed = try BitcoinConnectPSBT(psbt)
        let hashes = parsed.transaction.input().map { $0.previousOutput.txid.description }
        guard Set(parsed.transaction.input().map { $0.previousOutput.txid.description + ":" + String($0.previousOutput.vout) }).count == hashes.count else { throw BitcoinConnectError.wrongInput }
        return Array(Set(hashes)).sorted()
    }

    public static func review(request: BitcoinConnectRequest, psbt: String, inputs: [BitcoinConnectRequest.Input],
                              addresses: [BitcoinDerivedAddress], previous: [String: Data], now: Date = .now) throws -> BitcoinConnectPlan {
        try request.validate()
        var parsed = try BitcoinConnectPSBT(psbt)
        _ = try previousTransactions(psbt)
        guard !inputs.isEmpty, inputs.count <= 128, Set(inputs.map(\.index)).count == inputs.count else { throw BitcoinConnectError.wrongInput }
        let txInputs = parsed.transaction.input()
        var total: UInt64 = 0, owned: UInt64 = 0, ownedInputs: [Int: BitcoinDerivedAddress] = [:]
        // Each input map retains its own complete parent, even for siblings.
        var remainingParentBytes = BitcoinConnectPSBT.maximumBytes
        for (index, input) in txInputs.enumerated() {
            let hash = input.previousOutput.txid.description
            guard let raw = previous[hash] else { throw BitcoinConnectError.wrongInput }
            guard raw.count <= remainingParentBytes else { throw BitcoinConnectError.tooLarge }
            remainingParentBytes -= raw.count
            let parent = try Transaction(transactionBytes: raw)
            guard parent.computeTxid().description == hash, Int(input.previousOutput.vout) < parent.output().count else { throw BitcoinConnectError.wrongInput }
            let output = parent.output()[Int(input.previousOutput.vout)], value = output.value.toSat(), script = output.scriptPubkey.toBytes()
            guard value <= UInt64(BitcoinSendPlan.maximumMoney), total <= UInt64(BitcoinSendPlan.maximumMoney) - value else { throw BitcoinConnectError.invalidFee }; total += value
            let witness = BitcoinWire.little(value) + BitcoinWire.vector(script)
            if let supplied = parsed.field(0, input: index), supplied != raw { throw BitcoinConnectError.wrongInput }
            if let supplied = parsed.field(1, input: index), supplied != witness { throw BitcoinConnectError.wrongInput }
            // Hash-checked full parents anchor every fee, including foreign inputs.
            parsed.set(0, raw, input: index)
            if let derived = addresses.first(where: { $0.script == script.hex }) { owned += value; ownedInputs[index] = derived }
        }
        for input in inputs {
            guard txInputs.indices.contains(input.index), let own = ownedInputs[input.index],
                  try request.network.script(input.address).hex == own.script,
                  parsed.field(7, input: input.index) == nil, parsed.field(8, input: input.index) == nil,
                  // Script-path Taproot signing needs a separate leaf review.
                  !parsed.maps[input.index + 1].contains(where: { $0.key.first == 0x15 }) else { throw BitcoinConnectError.wrongInput }
            let allowed = input.sighashTypes ?? [1]
            let rawSighash = parsed.field(3, input: input.index)
            guard rawSighash == nil || rawSighash!.count == 4 else { throw BitcoinConnectError.invalidPSBT }
            let sighash = rawSighash.map { $0.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) } } ?? (allowed.contains(1) ? 1 : 0)
            guard allowed.contains(sighash), sighash == 1 || (sighash == 0 && own.type == .taproot) else { throw BitcoinConnectError.unsupported }
            parsed.set(3, BitcoinWire.little(sighash), input: input.index)
        }
        var outputTotal: UInt64 = 0, change: UInt64 = 0
        let outputs = try parsed.transaction.output().map { output -> BitcoinConnectOutput in
            let value = output.value.toSat(), script = output.scriptPubkey.toBytes()
            guard value <= UInt64(BitcoinSendPlan.maximumMoney), outputTotal <= UInt64(BitcoinSendPlan.maximumMoney) - value else { throw BitcoinConnectError.invalidFee }
            outputTotal += value
            let ours = addresses.contains { $0.script == script.hex }; if ours { change += value }
            return .init(address: try? request.network.address(script: script), script: script, value: value, owned: ours)
        }
        guard total >= outputTotal else { throw BitcoinConnectError.invalidFee }
        let fee = total - outputTotal
        guard fee <= 10_000_000, fee <= UInt64(parsed.transaction.serialize().count) * 1_000 else { throw BitcoinConnectError.invalidFee }
        return .init(request: request, psbt: try parsed.encoded, inputs: inputs, ownedInputs: ownedInputs,
                     reviewedAddresses: addresses, outputs: outputs, fee: fee, debit: owned > change ? owned - change : 0, createdAt: now)
    }

    public static func validate(_ plan: BitcoinConnectPlan) throws {
        let parsed = try BitcoinConnectPSBT(plan.psbt)
        var previous: [String: Data] = [:]
        for (index, input) in parsed.transaction.input().enumerated() {
            guard let raw = parsed.field(0, input: index) else { throw BitcoinConnectError.wrongInput }
            previous[input.previousOutput.txid.description] = raw
        }
        let rebuilt = try review(request: plan.request, psbt: plan.psbt, inputs: plan.inputs,
            addresses: plan.reviewedAddresses, previous: previous, now: plan.createdAt)
        guard rebuilt == plan else { throw BitcoinConnectError.changed }
        if plan.request.method == "signPsbt" {
            guard let original = plan.request.psbt,
                  try BitcoinConnectPSBT(original).transaction.serialize() == parsed.transaction.serialize(),
                  plan.request.signInputs == plan.inputs else { throw BitcoinConnectError.changed }
        } else if plan.request.method == "sendTransfer" {
            let messages = plan.outputs.dropFirst().filter { !$0.owned }
            let memo = plan.request.memo.flatMap(Data.init(hex:)) ?? Data()
            let memoScript = Data([0x6a]) + (memo.count <= 75 ? Data([UInt8(memo.count)]) : Data([0x4c,UInt8(memo.count)])) + memo
            guard let recipient = plan.request.recipientAddress, let amount = plan.request.amount.flatMap(UInt64.init),
                  let first = plan.outputs.first, first.script == (try plan.request.network.script(recipient)), first.value == amount,
                  plan.outputs.dropFirst().allSatisfy({ $0.owned || ($0.value == 0 && $0.dataOutput != nil) }),
                  messages.count == (memo.isEmpty ? 0 : 1),
                  memo.isEmpty || messages.first?.script == memoScript else { throw BitcoinConnectError.changed }
            if let change = plan.request.changeAddress {
                let script = try plan.request.network.script(change)
                guard plan.outputs.dropFirst().filter(\.owned).allSatisfy({ $0.script == script }) else { throw BitcoinConnectError.changed }
            }
        } else { throw BitcoinConnectError.invalidRequest }
    }

    public static func sign(_ plan: BitcoinConnectPlan, key: (BitcoinDerivedAddress) throws -> Data) throws -> BitcoinConnectSigned {
        guard Date.now.timeIntervalSince(plan.createdAt) < 180, plan.createdAt <= .now else { throw BitcoinConnectError.expired }
        try validate(plan)
        var result = try BitcoinConnectPSBT(plan.psbt)
        for requested in plan.inputs {
            try Task.checkCancellation()
            guard let address = plan.ownedInputs[requested.index], address.multisigInputWeight == nil else { throw BitcoinConnectError.unsupported }
            var bytes = try key(address); defer { bytes.resetBytes(in: 0..<bytes.count) }
            var descriptor = try Descriptor(descriptor: address.type.wrap(BitcoinKeys.wif(bytes: bytes, compressed: true)), networkKind: .main)
            if address.type == .legacy, try descriptor.deriveAddress(index: 0, network: .bitcoin).scriptPubkey().toBytes().hex != address.script {
                descriptor = try Descriptor(descriptor: address.type.wrap(BitcoinKeys.wif(bytes: bytes, compressed: false)), networkKind: .main)
            }
            guard try descriptor.deriveAddress(index: 0, network: .bitcoin).scriptPubkey().toBytes().hex == address.script else { throw BitcoinConnectError.wrongAccount }
            var scoped = result
            for index in 0..<result.transaction.input().count where index != requested.index {
                scoped.set(7, Data(), input: index)
            }
            let psbt = try Psbt(psbtBase64: scoped.encoded)
            let wallet = try Wallet.createSingle(descriptor: descriptor, network: .bitcoin, persister: Persister.newInMemory())
            _ = wallet.revealNextAddress(keychain: .external)
            _ = try wallet.sign(psbt: psbt, signOptions: nil)
            let signed = try BitcoinConnectPSBT(psbt.serialize())
            guard signed.transaction.serialize() == result.transaction.serialize(),
                  signed.field(7, input: requested.index) != nil || signed.field(8, input: requested.index) != nil else { throw BitcoinSendError.signing }
            result.maps[requested.index + 1] = signed.maps[requested.index + 1]
        }
        let encoded = try result.encoded
        let signed = try Psbt(psbtBase64: encoded)
        guard try signed.fee() == plan.fee else { throw BitcoinConnectError.invalidFee }
        if plan.request.broadcasts {
            let transaction = try signed.extractTx()
            guard transaction.input().allSatisfy({ !$0.scriptSig.toBytes().isEmpty || !$0.witness.isEmpty }) else { throw BitcoinSendError.signing }
            return .init(psbt: encoded, raw: transaction.serialize(), txid: transaction.computeTxid().description)
        }
        return .init(psbt: encoded, raw: nil, txid: nil)
    }
}

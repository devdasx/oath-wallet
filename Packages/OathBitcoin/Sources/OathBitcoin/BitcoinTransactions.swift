import Foundation
internal import BitcoinDevKit

public enum BitcoinTransactions {
    public struct Input: Codable, Sendable, Equatable {
        public let txid: String
        public let index: Int
        public var outpoint: String { "\(txid):\(index)" }
    }
    public struct Output: Codable, Sendable, Equatable {
        public let value: Int64
        public let script: String
        public let address: String?
        public var dataOutput: BitcoinDataOutput? {
            guard let bytes = Data(hex: script) else { return nil }
            return BitcoinDataOutput(script: bytes)
        }
    }
    public struct Details: Sendable {
        public let txid: String
        public let coinbase: Bool
        public let inputs: [Input]
        public let outputs: [Output]
    }
    /// Decode the same hash-checked bytes used to validate spendable outputs.
    public static func details(_ raw: Data, network: UTXONetwork) throws -> Details {
        let tx = try transaction(raw, network: network)
        let outputs = try tx.output().map { output -> Output in
            let bytes = output.scriptPubkey.toBytes()
            let script = try network == .bitcoincash ? BitcoinCashTokens.lockingScript(bytes) : bytes
            guard output.value.toSat() <= UInt64(network.maximumOutput) else { throw BitcoinError.invalidResponse }
            return Output(value: Int64(output.value.toSat()), script: script.hex, address: address(script, network: network))
        }
        return Details(txid: tx.computeTxid().description, coinbase: tx.isCoinbase(),
            inputs: tx.isCoinbase() ? [] : tx.input().map { Input(txid: $0.previousOutput.txid.description, index: Int($0.previousOutput.vout)) }, outputs: outputs)
    }
    private static func address(_ script: Data, network: UTXONetwork) -> String? {
        if network == .bitcoin { return try? Address.fromScript(script: Script(rawOutputScript: script), network: .bitcoin).description }
        if network == .bitcoincash { return try? CashAddress.p2pkh(script: script) }
        let bytes = Array(script)
        if bytes.count == 25, bytes.prefix(3) == [0x76, 0xa9, 0x14], bytes.suffix(2) == [0x88, 0xac] {
            return Base58Check.encode(Data([network == .dogecoin ? 30 : 48]) + script.dropFirst(3).prefix(20))
        }
        if bytes.count == 23, bytes.prefix(2) == [0xa9, 0x14], bytes.last == 0x87 {
            return Base58Check.encode(Data([network == .dogecoin ? 22 : 50]) + script.dropFirst(2).prefix(20))
        }
        if network == .litecoin, (4...42).contains(bytes.count), bytes[1] == bytes.count - 2,
           bytes[0] == 0 || (0x51...0x60).contains(bytes[0]) {
            let version = bytes[0] == 0 ? 0 : bytes[0] - 0x50
            let program = script.dropFirst(2)
            if version == 0 && program.count != 20 && program.count != 32 { return nil }
            // A 32-byte HogAddr or peg-in kernel identifies MWEB protocol data.
            if (version == 8 || version == 9) && program.count == 32 { return nil }
            return SegwitAddress.encode(hrp: "ltc", version: version, program: program)
        }
        return nil
    }
    public static func txid(_ raw: Data, network: UTXONetwork = .bitcoin) throws -> String {
        try transaction(raw, network: network).computeTxid().description
    }
    public static func isCoinbase(_ raw: Data, network: UTXONetwork = .bitcoin) throws -> Bool {
        try transaction(raw, network: network).isCoinbase()
    }
    public static func hasTokens(_ raw: Data, vout: Int, network: UTXONetwork = .bitcoin) throws -> Bool {
        guard network == .bitcoincash else { return false }
        let outputs = try transaction(raw, network: network).output()
        guard outputs.indices.contains(vout) else { throw BitcoinError.invalidResponse }
        return outputs[vout].scriptPubkey.toBytes().first == 0xef
    }
    public static func isPegout(_ raw: Data, vout: Int, network: UTXONetwork = .bitcoin) throws -> Bool {
        guard network == .litecoin, vout > 0 else { return false }
        let outputs = try transaction(raw, network: network).output()
        guard outputs.indices.contains(vout), let first = outputs.first else { return false }
        let script = first.scriptPubkey.toBytes()
        // Electrum/Core RPC may strip the MWEB flag. The first HogEx output's
        // version-8 witness program is committed by the txid and survives that
        // stripping; every later output is a peg-out (Core PEGOUT_MATURITY=6).
        return script.count == 34 && script.prefix(2) == Data([0x58, 0x20])
    }
    public static func validates(_ raw: Data, txid: String, vout: Int, value: Int64, script: String, network: UTXONetwork = .bitcoin) throws -> Bool {
        let tx = try transaction(raw, network: network)
        guard tx.computeTxid().description == txid, (0...network.maximumOutput).contains(value) else { return false }
        let outputs = tx.output()
        guard outputs.indices.contains(vout) else { return false }
        let encoded = outputs[vout].scriptPubkey.toBytes()
        let locking = try network == .bitcoincash ? BitcoinCashTokens.lockingScript(encoded) : encoded
        return outputs[vout].value.toSat() == UInt64(value) && locking.hex == script
    }

    private static func transaction(_ raw: Data, network: UTXONetwork) throws -> Transaction {
        guard !raw.isEmpty, raw.count <= 4_000_000 else { throw BitcoinError.invalidResponse }
        if network == .bitcoincash || network == .dogecoin {
            // BCH and Dogecoin have no SegWit serialization. BDK would otherwise accept BTC
            // witness bytes and compute a stripped hash for the wrong chain.
            guard raw.count >= 10, raw.count <= 1_000_000, raw.dropFirst(4).first != 0 else { throw BitcoinError.invalidResponse }
        }
        return try Transaction(transactionBytes: network == .litecoin ? LitecoinTransaction.transparentBytes(raw) : raw)
    }
}

/// Litecoin Core computes a transparent txid without witness OR MWEB data.
/// Extract only that public transaction for BDK's txid/script/value checks;
/// the original bytes remain cached. This does not validate confidential MWEB
/// proofs or claim ownership of MWEB outputs. HogEx peg-outs are ordinary
/// transparent outputs and must remain discoverable/spendable.
enum LitecoinTransaction {
    static func transparentBytes(_ raw: Data) throws -> Data {
        let bytes = Array(raw)
        guard bytes.count >= 10 else { throw BitcoinError.invalidResponse }
        guard bytes[4] == 0, bytes[5] & 8 != 0 else { return raw }
        let flags = bytes[5]
        guard flags == 8 || flags == 9 else { throw BitcoinError.invalidResponse }
        var cursor = Cursor(bytes: bytes, offset: 6)
        let inputs = try cursor.count()
        // MWEB-only transactions have no transparent wallet outputs.
        guard inputs > 0 else { throw BitcoinError.invalidResponse }
        for _ in 0..<inputs { try cursor.skip(36); try cursor.vector(); try cursor.skip(4) }
        let outputs = try cursor.count()
        guard outputs > 0 else { throw BitcoinError.invalidResponse }
        for _ in 0..<outputs { try cursor.skip(8); try cursor.vector() }
        if flags & 1 != 0 {
            for _ in 0..<inputs {
                let items = try cursor.count()
                for _ in 0..<items { try cursor.vector() }
            }
        }
        let extensionStart = cursor.offset
        try cursor.skip(1)
        guard cursor.offset <= bytes.count - 4 else { throw BitcoinError.invalidResponse }
        switch bytes[extensionStart] {
        case 0: // Null MWEB::Tx marks HogEx; no payload precedes locktime.
            guard cursor.offset == bytes.count - 4 else { throw BitcoinError.invalidResponse }
        case 1:
            // An MWEB payload is opaque to transparent wallets. Its contents
            // are excluded from the hash; the requested txid still commits to
            // every transparent input/output and the final locktime.
            guard cursor.offset < bytes.count - 4 else { throw BitcoinError.invalidResponse }
        default: throw BitcoinError.invalidResponse
        }
        var canonical = Data(bytes.prefix(4))
        if flags & 1 != 0 { canonical.append(contentsOf: [0, 1]) }
        canonical.append(contentsOf: bytes[6..<extensionStart])
        canonical.append(contentsOf: bytes.suffix(4))
        return canonical
    }

    private struct Cursor {
        let bytes: [UInt8]
        var offset: Int
        mutating func skip(_ length: Int) throws {
            guard length >= 0, length <= bytes.count - offset else { throw BitcoinError.invalidResponse }
            offset += length
        }
        mutating func count() throws -> Int {
            try skip(1)
            let first = bytes[offset - 1]
            if first < 253 { return Int(first) }
            let length = first == 253 ? 2 : first == 254 ? 4 : 8
            let start = offset
            try skip(length)
            var value: UInt64 = 0
            for i in 0..<length { value |= UInt64(bytes[start + i]) << (8 * i) }
            let minimum: UInt64 = length == 2 ? 253 : length == 4 ? 65_536 : 4_294_967_296
            guard value >= minimum, value <= UInt64(bytes.count) else { throw BitcoinError.invalidResponse }
            return Int(value)
        }
        mutating func vector() throws { let length = try count(); try skip(length) }
    }
}

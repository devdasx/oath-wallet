import Foundation
import OathDiagnostics
internal import BitcoinDevKit

public struct BitcoinConnectCoin: Sendable {
    public let txid: String
    public let vout: UInt32
    public let value: UInt64
    public let address: BitcoinDerivedAddress
    public init(txid: String, vout: UInt32, value: UInt64, address: BitcoinDerivedAddress) {
        self.txid = txid; self.vout = vout; self.value = value; self.address = address
    }
}

public struct BitcoinConnectClient: Sendable {
    public init() {}
    private func bases(_ network: BitcoinConnectNetwork) -> [String] {
        switch network {
        case .mainnet: ["https://mempool.space/api", "https://blockstream.info/api"]
        case .testnet: ["https://mempool.space/testnet/api", "https://blockstream.info/testnet/api"]
        case .testnet4: ["https://mempool.space/testnet4/api"]
        case .signet: ["https://mempool.space/signet/api", "https://blockstream.info/signet/api"]
        }
    }
    private func fetch(_ path: String, network: BitcoinConnectNetwork, body: Data? = nil, missing: Bool = false) async throws -> Data {
        var notFound = false
        for base in bases(network) {
            try Task.checkCancellation()
            var request = URLRequest(url: URL(string: base + path)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("text/plain", forHTTPHeaderField: "Content-Type") }
            do {
                let data = try await UTXOAPIProvider.fetch(request, limit: 8_100_000, allowMissing: missing)
                if missing && data.isEmpty { notFound = true; continue }
                return data
            } catch {
                if Task.isCancelled { throw CancellationError() }
                OathDiagnostics.record(error, component: "BitcoinConnectClient", operation: "provider", context: ["chain":"bitcoin", "stage":network.rawValue])
            }
        }
        if notFound { return Data() }
        throw BitcoinConnectError.unavailable
    }
    public func coins(addresses: [BitcoinDerivedAddress], network: BitcoinConnectNetwork) async throws -> [BitcoinConnectCoin] {
        struct Coin: Decodable { let txid: String; let vout: UInt32; let value: UInt64 }
        guard addresses.count <= 4_000 else { throw BitcoinConnectError.tooLarge }
        var result: [BitcoinConnectCoin] = []
        // A bounded pool avoids opening hundreds of connections on HD wallets.
        for start in stride(from: 0, to: addresses.count, by: 8) {
            let batch = Array(addresses[start..<min(start + 8, addresses.count)])
            let rows = try await withThrowingTaskGroup(of: [BitcoinConnectCoin].self) { group in
                for address in batch {
                    group.addTask {
                        let encoded = try network.address(mainnetAddress: address.address)
                        let data = try await fetch("/address/\(encoded)/utxo", network: network)
                        let coins = try JSONDecoder().decode([Coin].self, from: data)
                        guard coins.count <= 2_000 else { throw BitcoinConnectError.tooLarge }
                        return try coins.map {
                            guard $0.txid.count == 64, Data(hex: $0.txid)?.count == 32, $0.value <= UInt64(BitcoinSendPlan.maximumMoney) else { throw BitcoinConnectError.wrongInput }
                            return BitcoinConnectCoin(txid:$0.txid, vout:$0.vout, value:$0.value, address:address)
                        }
                    }
                }
                var rows: [BitcoinConnectCoin] = []
                for try await row in group { rows += row }; return rows
            }
            result += rows
            guard result.count <= 4_000 else { throw BitcoinConnectError.tooLarge }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.txid + ":" + String($0.vout)).inserted }
    }
    public func parents(psbt: String, network: BitcoinConnectNetwork) async throws -> [String: Data] {
        let hashes = try BitcoinConnectSigning.previousTransactions(psbt)
        var result: [String:Data] = [:]
        var remainingParentBytes = BitcoinConnectPSBT.maximumBytes
        for start in stride(from: 0, to: hashes.count, by: 8) {
            let batch = Array(hashes[start..<min(start + 8, hashes.count)])
            try await withThrowingTaskGroup(of: (String,Data).self) { group in
                for hash in batch { group.addTask {
                    let bytes = try await fetch("/tx/\(hash)/hex", network:network)
                    guard let text = String(data:bytes, encoding:.utf8), let raw = Data(hex:text.trimmingCharacters(in:.whitespacesAndNewlines)),
                          try Transaction(transactionBytes:raw).computeTxid().description == hash else { throw BitcoinConnectError.wrongInput }
                    return (hash,raw)
                } }
                for try await (hash, raw) in group {
                    guard raw.count <= remainingParentBytes else { throw BitcoinConnectError.tooLarge }
                    remainingParentBytes -= raw.count
                    result[hash] = raw
                }
            }
        }
        return result
    }
    public func review(_ request: BitcoinConnectRequest, addresses: [BitcoinDerivedAddress], change: BitcoinDerivedAddress) async throws -> BitcoinConnectPlan {
        let psbt: String, inputs: [BitcoinConnectRequest.Input]
        let selectedChange: BitcoinDerivedAddress
        if let requested = request.changeAddress {
            let script = try request.network.script(requested).hex
            guard let owned = (addresses + [change]).first(where: { $0.script == script }) else { throw BitcoinConnectError.wrongAccount }
            selectedChange = owned
        } else { selectedChange = change }
        if request.method == "signPsbt" {
            guard let supplied = request.psbt, let selected = request.signInputs else { throw BitcoinConnectError.invalidRequest }
            psbt = supplied; inputs = selected
        } else {
            async let available = coins(addresses:addresses, network:request.network)
            async let rates = fetch("/fee-estimates", network:request.network)
            let fees = try JSONDecoder().decode([String:Double].self, from: await rates)
            guard let rate = fees["3"] ?? fees["2"] ?? fees["6"], rate.isFinite, rate > 0, rate <= 1_000 else { throw BitcoinConnectError.invalidFee }
            var remaining = try await available
            var candidate: (String,[BitcoinConnectRequest.Input])?
            // An indexer's UTXO list may lag a just-broadcast transaction. Remove
            // spent candidates before review; never sign against that stale list.
            for _ in 0..<3 {
                let transfer = try Self.transfer(request, coins:remaining, change:selectedChange, rate:UInt64(ceil(rate)))
                let spent = try await spentOutpoints(psbt:transfer.0,network:request.network)
                if spent.isEmpty { candidate = transfer; break }
                remaining.removeAll { spent.contains($0.txid + ":" + String($0.vout)) }
            }
            guard let candidate else { throw BitcoinConnectError.changed }
            (psbt,inputs) = candidate
        }
        let previous = try await parents(psbt:psbt, network:request.network)
        return try BitcoinConnectSigning.review(request:request, psbt:psbt, inputs:inputs, addresses:addresses + [selectedChange], previous:previous)
    }
    public func preflight(_ plan: BitcoinConnectPlan) async throws {
        guard Date.now.timeIntervalSince(plan.createdAt) < 180 else { throw BitcoinConnectError.expired }
        guard try await spentOutpoints(psbt:plan.psbt,network:plan.request.network).isEmpty else { throw BitcoinConnectError.changed }
    }
    private func spentOutpoints(psbt: String, network: BitcoinConnectNetwork) async throws -> Set<String> {
        let inputs = try BitcoinConnectPSBT(psbt).transaction.input()
        struct Spend: Decodable { let spent: Bool }
        var spent = Set<String>()
        for start in stride(from:0, to:inputs.count, by:8) {
            let batch = Array(inputs[start..<min(start + 8, inputs.count)])
            let points = try await withThrowingTaskGroup(of: String?.self) { group in
                for input in batch { group.addTask {
                    let data = try await fetch("/tx/\(input.previousOutput.txid.description)/outspend/\(input.previousOutput.vout)", network:network)
                    return try JSONDecoder().decode(Spend.self, from:data).spent ? input.previousOutput.txid.description + ":" + String(input.previousOutput.vout) : nil
                } }
                var points: [String] = []
                for try await point in group { if let point { points.append(point) } }; return points
            }
            spent.formUnion(points)
        }
        return spent
    }
    public enum Status: String, Codable, Sendable { case unknown, accepted, confirmed }
    public func status(hash: String, network: BitcoinConnectNetwork) async throws -> Status {
        guard hash.count == 64, Data(hex:hash)?.count == 32 else { throw BitcoinConnectError.invalidRequest }
        let data = try await fetch("/tx/\(hash)/status", network:network, missing:true)
        if data.isEmpty { return .unknown }
        struct StatusResponse: Decodable { let confirmed: Bool }
        return try JSONDecoder().decode(StatusResponse.self, from:data).confirmed ? .confirmed : .accepted
    }
    public func broadcast(_ signed: BitcoinConnectSigned, network: BitcoinConnectNetwork) async throws -> Status {
        guard let raw = signed.raw, let hash = signed.txid, try Transaction(transactionBytes:raw).computeTxid().description == hash else { throw BitcoinConnectError.changed }
        do {
            let data = try await fetch("/tx", network:network, body:Data(raw.hex.utf8))
            guard String(data:data, encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) == hash else { throw BitcoinConnectError.changed }
            return .accepted
        } catch {
            if Task.isCancelled { throw CancellationError() }
            OathDiagnostics.record(error, component:"BitcoinConnectClient", operation:"broadcast", context:["chain":"bitcoin", "stage":network.rawValue])
            return try await status(hash:hash, network:network)
        }
    }
    public static func transfer(_ request: BitcoinConnectRequest, coins: [BitcoinConnectCoin], change: BitcoinDerivedAddress, rate: UInt64) throws -> (String,[BitcoinConnectRequest.Input]) {
        try request.validate()
        guard request.method == "sendTransfer", let recipient = request.recipientAddress, let amount = request.amount.flatMap(UInt64.init), (1...1_000).contains(rate) else { throw BitcoinConnectError.invalidRequest }
        let script = try request.network.script(recipient), changeScript = try request.network.script(request.changeAddress ?? request.network.address(mainnetAddress:change.address))
        // A dApp may choose an owned change address, but cannot disguise another recipient as change.
        guard changeScript.hex == change.script || coins.contains(where: { $0.address.script == changeScript.hex }), amount >= UInt64(BitcoinSendPlan.dust(script)) else { throw BitcoinConnectError.wrongInput }
        var memo = Data()
        if let hex = request.memo, let bytes = Data(hex:hex), !bytes.isEmpty { memo = Data([0x6a]) + (bytes.count <= 75 ? Data([UInt8(bytes.count)]) : Data([0x4c,UInt8(bytes.count)])) + bytes }
        var selected: [BitcoinConnectCoin] = [], total: UInt64 = 0, fee: UInt64 = 0
        for coin in coins.sorted(by: { $0.value > $1.value }) {
            guard selected.count < 128, coin.value <= UInt64(BitcoinSendPlan.maximumMoney), total <= UInt64(BitcoinSendPlan.maximumMoney) - coin.value else { throw BitcoinConnectError.tooLarge }
            selected.append(coin); total += coin.value
            // Public addresses do not expose key compression; reserve enough
            // space for uncompressed legacy imports as well as HD keys.
            let inputBytes = selected.reduce(UInt64(0)) { $0 + ($1.address.type == .legacy ? 181 : $1.address.type == .nestedSegwit ? 92 : $1.address.type == .taproot ? 59 : 69) }
            fee = (12 + inputBytes + UInt64(18 + script.count + changeScript.count + (memo.isEmpty ? 0 : 9 + memo.count))) * rate
            if total >= amount + fee { break }
        }
        guard !selected.isEmpty, total >= amount + fee else { throw BitcoinConnectError.insufficientFunds }
        var outputs: [(UInt64,Data)] = [(amount,script)]
        if total - amount - fee >= UInt64(BitcoinSendPlan.dust(changeScript)) { outputs.append((total - amount - fee,changeScript)) }
        if !memo.isEmpty { outputs.append((0,memo)) }
        var unsigned = BitcoinWire.little(UInt32(2)) + BitcoinWire.compact(UInt64(selected.count))
        for coin in selected {
            guard let hash = Data(hex:coin.txid), hash.count == 32 else { throw BitcoinConnectError.wrongInput }
            unsigned += Data(hash.reversed()) + BitcoinWire.little(coin.vout) + Data([0]) + BitcoinWire.little(UInt32(0xfffffffd))
        }
        unsigned += BitcoinWire.compact(UInt64(outputs.count))
        for (value,script) in outputs { unsigned += BitcoinWire.little(value) + BitcoinWire.vector(script) }
        unsigned += BitcoinWire.little(UInt32(0))
        let packet = Data([0x70,0x73,0x62,0x74,0xff]) + BitcoinWire.pair(0,unsigned) + Data(repeating:0,count:1 + selected.count + outputs.count)
        return (packet.base64EncodedString(),try selected.enumerated().map { .init(address:try request.network.address(mainnetAddress:$0.element.address.address),index:$0.offset) })
    }
}

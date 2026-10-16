import OathDiagnostics
import Foundation
import Network
import CryptoKit

public struct ElectrumServer: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    /// Requests per JSON-RPC batch, not number of addresses. Each address uses
    /// three requests. Keep a bounded response even on very large public peers.
    public let batchLimit: Int
    public init(_ host: String, port: UInt16 = 50002, batchLimit: Int = 300) {
        self.host = host; self.port = port; self.batchLimit = max(3, min(batchLimit, 1_000))
    }
    public static let publicMainnet: [Self] = [
        .init("electrum.jhoenicke.de"), .init("electrum.diynodes.com", port: 50022),
        // This endpoint closes oversized batches without a JSON-RPC error.
        // Keep balance/history/UTXO triplets together within its tested cap.
        .init("electrum.blockstream.info", batchLimit: 12)
    ]
}

enum JSONValue: Codable, Sendable, Equatable {
    case string(String), integer(Int64), decimal(Double), bool(Bool), array([Self]), object([String: Self]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .decimal(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([Self].self) { self = .array(v) }
        else { self = .object(try c.decode([String: Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .decimal(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    subscript(_ key: String) -> Self? { if case .object(let d) = self { d[key] } else { nil } }
    var string: String? { if case .string(let s) = self { s } else { nil } }
    var integer: Int64? { if case .integer(let n) = self { n } else { nil } }
    var array: [Self]? { if case .array(let v) = self { v } else { nil } }
}

struct RPCRequest: Encodable, Sendable {
    var jsonrpc = "2.0"
    let id: Int
    let method: String
    var params: [JSONValue] = []
}

enum ElectrumBatch {
    static func decode(_ data: Data, ids: Set<Int>, context: [String: String] = [:],
                       broadcast: (id: Int, txid: String)? = nil) throws -> [Int: JSONValue] {
        guard case .array(let values) = try JSONDecoder().decode(JSONValue.self, from: data) else { throw BitcoinError.batchUnsupported }
        var results: [Int: JSONValue] = [:]
        for value in values {
            guard let number = value["id"]?.integer, let id = Int(exactly: number), ids.contains(id), results[id] == nil else { throw BitcoinError.invalidResponse }
            if let error = value["error"], error != .null {
                guard let code = error["code"]?.integer, let integer = Int(exactly: code) else { throw BitcoinError.invalidResponse }
                // A retry of the exact signed bytes is idempotent. Only this
                // broadcast request can acknowledge its locally computed hash;
                // unrelated RPC errors and double spends never become success.
                if let broadcast, broadcast.id == id,
                   [1, -27, -26].contains(integer), let message = error["message"]?.string,
                   alreadyKnownBroadcast(message) {
                    results[id] = .string(broadcast.txid); continue
                }
                OathDiagnostics.record(NSError(domain: "Oath.ElectrumRPC", code: integer,
                    userInfo: [NSLocalizedDescriptionKey: error["message"]?.string ?? "Electrum server rejected request"]),
                    component: "electrum", operation: "rpc_response", context: context.merging(["rpc_code": String(integer)]) { _, new in new })
                if integer == -32600 || integer == -32601 { throw BitcoinError.batchUnsupported }
                throw BitcoinError.server(code: integer)
            }
            guard let result = value["result"] else { throw BitcoinError.invalidResponse }
            results[id] = result
        }
        guard Set(results.keys) == ids else { throw BitcoinError.invalidResponse }
        return results
    }
    private static func alreadyKnownBroadcast(_ message: String) -> Bool {
        let lines = message.lowercased().split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let acknowledgements: Set<String> = ["transaction already in block chain", "transaction already in blockchain",
                                            "txn-already-known", "txn-already-in-mempool", "already in block chain",
                                            "transaction outputs already in utxo set"]
        // Electrum may append the raw transaction in brackets. Never inspect or
        // log that line, and never match broad words such as 'already'/'spent'.
        return lines.contains { acknowledgements.contains($0) }
    }
}

/// Every mutable socket field is confined to queue. Only one exchange is in
/// flight per leased connection. Timeouts/cancellation resume exactly once.
protocol ElectrumTransport: Sendable {
    func exchange(_ data: Data, timeout: TimeInterval) async throws -> Data
    func close()
}

final class ElectrumWire: ElectrumTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.oathwallet.electrum", qos: .userInitiated)
    private let connection: NWConnection
    private var ready = false
    private var ended = false
    private var buffer = Data()
    private var pending: CheckedContinuation<Data, Error>?
    private var outgoing: Data?
    private var deadline: DispatchWorkItem?

    init(server: ElectrumServer) {
        let options = NWProtocolTLS.Options()
        // The default trust evaluator verifies the certificate and hostname.
        // Never downgrade a failed TLS peer to plaintext or disable validation.
        connection = NWConnection(host: NWEndpoint.Host(server.host), port: NWEndpoint.Port(rawValue: server.port)!, using: NWParameters(tls: options))
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.ready = true; self.sendPending(); self.receive()
            case .failed(let error): OathDiagnostics.record(error, component: "electrum", operation: "connection"); self.fail(Self.classify(error))
            case .cancelled: self.fail(BitcoinError.disconnected)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func exchange(_ data: Data, timeout: TimeInterval = 12) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.ended, self.pending == nil else { continuation.resume(throwing: BitcoinError.disconnected); return }
                    self.pending = continuation
                    self.outgoing = data + Data([10])
                    let deadline = DispatchWorkItem { self.fail(BitcoinError.timeout) }
                    self.deadline = deadline
                    self.queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
                    self.sendPending()
                }
            }
        } onCancel: { self.close() }
    }

    func close() { queue.async { self.fail(CancellationError()) } }
    private func sendPending() {
        guard ready, let data = outgoing else { return }; outgoing = nil
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(Self.classify(error)) }
        })
    }
    private func receive() {
        guard !ended else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.ended else { return }
            if let data { self.buffer.append(data) }
            guard self.buffer.count <= 16 * 1_024 * 1_024 else { self.fail(BitcoinError.invalidResponse); return }
            while let newline = self.buffer.firstIndex(of: 10) {
                let line = Data(self.buffer.prefix(upTo: newline)); self.buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                // A header subscription can notify between batch responses.
                if let value = try? JSONDecoder().decode(JSONValue.self, from: line), value["method"] != nil, value["id"] == nil { continue }
                guard let pending = self.pending else { self.fail(BitcoinError.invalidResponse); return }
                self.pending = nil; self.deadline?.cancel(); self.deadline = nil
                pending.resume(returning: line)
            }
            if let error { self.fail(Self.classify(error)) }
            else if complete { self.fail(BitcoinError.disconnected) }
            else { self.receive() }
        }
    }
    private func fail(_ error: Error) {
        guard !ended else { return }
        ended = true; ready = false; outgoing = nil; buffer.removeAll()
        deadline?.cancel(); deadline = nil
        let continuation = pending; pending = nil
        connection.cancel(); continuation?.resume(throwing: error)
    }
    private static func classify(_ error: NWError) -> BitcoinError {
        switch error { case .tls: .tls; default: .disconnected }
    }
    deinit { connection.cancel() }
}

public struct BitcoinHistoryItem: Codable, Equatable, Sendable {
    public let txid: String
    public let height: Int64
    public init(txid: String, height: Int64) { self.txid = txid; self.height = height }

    // Electrum history uses -1 for an unconfirmed transaction with unconfirmed
    // parents; listunspent uses 0 for every mempool output, including descendants.
    var unspentHeight: Int64 { max(0, height) }
}
public struct BitcoinUnspent: Codable, Equatable, Sendable {
    public let txid: String
    public let vout: Int
    public let value: Int64
    public let height: Int64
    public init(txid: String, vout: Int, value: Int64, height: Int64) {
        self.txid = txid; self.vout = vout; self.value = value; self.height = height
    }
    public var id: String { "\(txid):\(vout)" }
}
public struct BitcoinAddressState: Codable, Equatable, Sendable {
    public let confirmed: Int64
    public let unconfirmed: Int64
    public let history: [BitcoinHistoryItem]
    public let unspent: [BitcoinUnspent]
    public init(confirmed: Int64, unconfirmed: Int64, history: [BitcoinHistoryItem], unspent: [BitcoinUnspent]) {
        self.confirmed = confirmed; self.unconfirmed = unconfirmed; self.history = history; self.unspent = unspent
    }
}
public protocol BitcoinAddressQuerying: Sendable {
    func query(scriptHashes: [String]) async throws -> [BitcoinAddressState]
}

public struct ElectrumAttempt: Sendable, Equatable {
    public let server: String
    public let error: BitcoinError?
    public let requestCount: Int
}

/// Three concurrent leases, one active request per peer. A failed batch rotates
/// to another batch-capable TLS peer. Empty results are successful results;
/// failures never become empty balances. No keys or addresses enter diagnostics.
public actor ElectrumPool: BitcoinAddressQuerying {
    private struct Peer {
        let server: ElectrumServer
        var wire: (any ElectrumTransport)?
        var busy = false
        var cooldown = Date.distantPast
        var failure: BitcoinError?
    }
    private var peers: [Peer]
    private var position = 0
    private var attempts: [ElectrumAttempt] = []
    private let network: UTXONetwork
    private let maximumConnections: Int
    private let makeTransport: @Sendable (ElectrumServer) -> any ElectrumTransport
    private let transactionFallback: (@Sendable ([String]) async throws -> [String: Data])?
    private let requestTimeout: TimeInterval
    public init(servers: [ElectrumServer]? = nil, maximumConnections: Int = 3, network: UTXONetwork = .bitcoin) {
        self.network = network
        requestTimeout = 12
        peers = (servers ?? network.servers).map { Peer(server: $0) }
        self.maximumConnections = max(1, min(maximumConnections, 4))
        makeTransport = { ElectrumWire(server: $0) }
        if network == .bitcoin {
            transactionFallback = { txids in try await BitcoinTransactionFallback.shared.transactions(txids: txids) }
        } else { transactionFallback = nil }
    }
    // Injectable only within the module/tests; production always verifies TLS.
    init(servers: [ElectrumServer], maximumConnections: Int = 3, network: UTXONetwork = .bitcoin,
         transactionFallback: (@Sendable ([String]) async throws -> [String: Data])? = nil,
         requestTimeout: TimeInterval = 12,
         makeTransport: @escaping @Sendable (ElectrumServer) -> any ElectrumTransport) {
        self.network = network
        peers = servers.map { Peer(server: $0) }
        self.maximumConnections = max(1, min(maximumConnections, 4))
        self.makeTransport = makeTransport
        self.transactionFallback = transactionFallback
        self.requestTimeout = requestTimeout
    }
    public func diagnostics() -> [ElectrumAttempt] { attempts }
    public func close() {
        for i in peers.indices { peers[i].wire?.close(); peers[i].wire = nil }
    }

    /// Pin every read in a scan to one TLS-verified peer at the freshest observed
    /// tip. Rotating peers between the start/end headers is not a coherent scan.
    /// The read-only operation may run concurrently on multiple peers. Publish
    /// or commit only the returned snapshot, never inside the operation itself.
    public func withStableSnapshot<Value: Sendable>(
        _ operation: @escaping @Sendable (ElectrumPool) async throws -> Value
    ) async throws -> (value: Value, tip: BitcoinChainTip) {
        let candidates = peers.map { peer in
            (peer.server.host, ElectrumPool(servers: [peer.server], maximumConnections: 1, network: network,
                transactionFallback: transactionFallback, requestTimeout: requestTimeout, makeTransport: makeTransport))
        }
        return try await ElectrumSnapshot.read(candidates, network: network, operation: operation)
    }

    /// Only the snapshot coordinator may retry its private, single-peer pool.
    /// Normal shared-pool callers retain the outage cooldown. Protocol, network
    /// and TLS failures are never bypassed by this transport recovery.
    func retrySnapshotConnection() {
        guard peers.count == 1, !peers[0].busy,
              peers[0].failure == .timeout || peers[0].failure == .disconnected else { return }
        peers[0].wire?.close(); peers[0].wire = nil
        peers[0].cooldown = .distantPast; peers[0].failure = nil
    }

    private func lease(excluding: Set<Int>) async throws -> Int {
        for _ in 0..<600 {
            try Task.checkCancellation()
            guard peers.indices.contains(where: { !excluding.contains($0) }) else { throw BitcoinError.unavailable }
            if peers.filter(\.busy).count < maximumConnections {
                let indices = (0..<peers.count).map { (position + $0) % peers.count }
                let candidates = indices.filter { !peers[$0].busy && !excluding.contains($0) }
                if let i = candidates.first(where: { peers[$0].cooldown <= .now }) {
                    peers[i].busy = true; position = (i + 1) % peers.count; return i
                }
                // All available peers failed recently. The caller receives a
                // failure instead of hammering every peer during an outage.
                if !candidates.isEmpty, !peers.contains(where: \.busy) { throw BitcoinError.unavailable }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw BitcoinError.timeout
    }

    private func request<Value: Sendable>(_ requests: [RPCRequest], broadcastTXID: String? = nil,
                                         decode: @Sendable ([Int: JSONValue]) throws -> Value) async throws -> Value {
        guard !requests.isEmpty else { return try decode([:]) }
        let payload = try JSONEncoder().encode(requests)
        var tried = Set<Int>()
        var last: BitcoinError = .unavailable
        while tried.count < peers.count {
            let i = try await lease(excluding: tried)
            tried.insert(i)
            let server = peers[i].server
            var stage = "request"
            do {
                let wire: any ElectrumTransport
                if let existing = peers[i].wire { wire = existing }
                else {
                    stage = "handshake"
                    wire = makeTransport(server)
                    peers[i].wire = wire
                    var handshake = [RPCRequest(id: -3, method: "server.version", params: [.string("Oath"), .string(network == .bitcoincash ? "1.5" : "1.4")]),
                                     RPCRequest(id: -2, method: "server.features"), RPCRequest(id: -1, method: "blockchain.headers.subscribe")]
                    if let checkpoint = network.checkpoint {
                        handshake.append(.init(id: -4, method: "blockchain.block.header", params: [.integer(checkpoint.height)]))
                    }
                    let result = try ElectrumBatch.decode(await wire.exchange(JSONEncoder().encode(handshake), timeout: requestTimeout), ids: Set(handshake.map(\.id)), context: ["chain": network.rawValue, "host": server.host, "method": "handshake"])
                    guard result[-2]?["genesis_hash"]?.string == network.genesis,
                          (result[-1]?["height"]?.integer ?? 0) > 0 else { wire.close(); throw BitcoinError.wrongNetwork }
                    if let checkpoint = network.checkpoint {
                        guard let headerHex = result[-4]?.string, headerHex.count == 160, let header = Data(hex: headerHex),
                              Data(SHA256.hash(data: Data(SHA256.hash(data: header))).reversed()).hex == checkpoint.hash,
                              (result[-1]?["height"]?.integer ?? 0) >= checkpoint.height else { throw BitcoinError.wrongNetwork }
                        // Explicit inclusion of token-bearing BCH needs 1.5. A
                        // 1.4 peer silently omits those satoshis by default.
                        guard let version = result[-3]?.array?.last?.string,
                              version == "1.5" || version.hasPrefix("1.5.") else { throw BitcoinError.invalidResponse }
                    }
                    peers[i].wire = wire
                }
                stage = "request"
                guard requests.count <= server.batchLimit else { throw BitcoinError.batchUnsupported }
                let broadcast = requests.count == 1 && requests[0].method == "blockchain.transaction.broadcast"
                    ? broadcastTXID.map { (id: requests[0].id, txid: $0) } : nil
                let result = try ElectrumBatch.decode(await wire.exchange(payload, timeout: requestTimeout), ids: Set(requests.map(\.id)), context: ["chain": network.rawValue, "host": server.host, "method": requests.prefix(4).map(\.method).joined(separator: ",")], broadcast: broadcast)
                let validated = try decode(result)
                try Task.checkCancellation()
                record(.init(server: server.host, error: nil, requestCount: requests.count))
                peers[i].failure = nil
                peers[i].busy = false
                return validated
            } catch { OathDiagnostics.record(error, component: "electrum", operation: "request", context: ["chain": network.rawValue, "host": server.host, "stage": stage, "method": requests.prefix(4).map(\.method).joined(separator: ",")]);
                peers[i].wire?.close(); peers[i].wire = nil; peers[i].busy = false
                try Task.checkCancellation()
                last = (error as? BitcoinError) ?? .invalidResponse
                peers[i].failure = last
                // A valid RPC rejection is not a broken connection. Allow an
                // immediate transaction lookup to reconcile an uncertain send.
                if case .server = last { peers[i].cooldown = .distantPast }
                else { peers[i].cooldown = Date.now.addingTimeInterval(last == .batchUnsupported || last == .wrongNetwork ? 300 : 15) }
                record(.init(server: server.host, error: last, requestCount: requests.count))
            }
        }
        throw last
    }

    private func record(_ attempt: ElectrumAttempt) {
        attempts.append(attempt); if attempts.count > 64 { attempts.removeFirst(attempts.count - 64) }
    }

    public func transactions(txids: [String]) async throws -> [String: Data] {
        guard txids.allSatisfy(Self.hash), Set(txids).count == txids.count else { throw BitcoinError.invalidResponse }
        let network = network, fallback = transactionFallback
        let size = min(40, peers.map { $0.server.batchLimit }.min() ?? 40)
        return try await withThrowingTaskGroup(of: [String: Data].self) { group in
            // Bounded concurrency comes from the same pool as discovery. Raw
            // transactions are immutable and fetched only if absent from SQL.
            for start in stride(from: 0, to: txids.count, by: size) {
                let chunk = Array(txids[start..<min(start + size, txids.count)])
                group.addTask {
                    do { return try await self.request(chunk.enumerated().map { .init(id: $0.offset, method: "blockchain.transaction.get", params: [.string($0.element), .bool(false)]) }) { values in
                        var result: [String: Data] = [:]
                        for (i, txid) in chunk.enumerated() {
                            guard let hex = values[i]?.string, let raw = Data(hex: hex), try BitcoinTransactions.txid(raw, network: network) == txid else { throw BitcoinError.invalidResponse }
                            result[txid] = raw
                        }
                        return result
                    } } catch {
                        if Task.isCancelled || error is CancellationError { throw CancellationError() }
                        OathDiagnostics.record(error, component: "electrum", operation: "transaction_peers_exhausted", context: ["chain": network.rawValue])
                        guard network == .bitcoin, let fallback else { throw error }
                        let recovered = try await fallback(chunk)
                        guard Set(recovered.keys) == Set(chunk), try recovered.allSatisfy({ try BitcoinTransactions.txid($0.value) == $0.key }) else {
                            throw BitcoinError.invalidResponse
                        }
                        return recovered
                    }
                }
            }
            var result: [String: Data] = [:]
            for try await values in group { result.merge(values) { old, _ in old } }
            return result
        }
    }

    /// Integer sat/kVB; ceil conversion avoids underpaying a fractional quote.
    public func bitcoinFeeRate() async throws -> Int64 {
        guard [.bitcoin, .bitcoincash, .litecoin, .dogecoin].contains(network) else { throw BitcoinError.wrongNetwork }
        let permitsRelayFallback = network != .bitcoin
        let rates = network.sendFeeRates
        return try await request([
            .init(id: 0, method: "blockchain.estimatefee", params: [.integer(3)]),
            .init(id: 1, method: "blockchain.relayfee")
        ]) { values in
            func sats(_ value: JSONValue?) throws -> Int64 {
                let number: Double
                switch value { case .decimal(let v): number = v; case .integer(let v): number = Double(v); default: throw BitcoinSendError.feeUnavailable }
                guard number.isFinite, number > 0, number <= Double(rates.upperBound) / 100_000_000 else { throw BitcoinSendError.feeUnavailable }
                guard let decimal = Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX")) else { throw BitcoinSendError.feeUnavailable }
                var scaled = decimal * 100_000_000, rounded = Decimal()
                NSDecimalRound(&rounded, &scaled, 0, .up)
                return NSDecimalNumber(decimal: rounded).int64Value
            }
            let relay = try sats(values[1])
            // BCH/Litecoin/Dogecoin may return -1 without an estimate. A
            // verified relay rate is bounded by the chain's recommended floor.
            let estimate: Int64
            if permitsRelayFallback && (values[0] == .integer(-1) || values[0] == .decimal(-1)) { estimate = relay }
            else { estimate = try sats(values[0]) }
            return max(rates.lowerBound, estimate, relay)
        }
    }

    /// Only an identical, already-signed payload may be retried. A timeout is
    /// ambiguous, so callers must retain its input reservations and local txid.
    public func broadcastBitcoin(_ raw: Data, acceptAlreadyKnown: Bool = true) async throws -> String {
        guard [.bitcoin, .bitcoincash, .litecoin, .dogecoin].contains(network) else { throw BitcoinError.wrongNetwork }
        let expected = try BitcoinTransactions.txid(raw, network: network)
        return try await request([.init(id: 0, method: "blockchain.transaction.broadcast", params: [.string(raw.hex)])], broadcastTXID: acceptAlreadyKnown ? expected : nil) { values in
            guard values[0]?.string?.lowercased() == expected else { throw BitcoinError.invalidResponse }
            return expected
        }
    }

    public func query(scriptHashes: [String]) async throws -> [BitcoinAddressState] {
        guard scriptHashes.allSatisfy({ Self.hash($0) }) else { throw BitcoinError.invalidAddress }
        // Use the smallest configured cap so every retry can carry the same
        // batch. Connection errors must not permanently disable batching.
        let size = max(1, (peers.map { $0.server.batchLimit }.min() ?? 60) / 3)
        if scriptHashes.count > size {
            return try await withThrowingTaskGroup(of: (Int, [BitcoinAddressState]).self) { group in
                for start in stride(from: 0, to: scriptHashes.count, by: size) {
                    let chunk = Array(scriptHashes[start..<min(start + size, scriptHashes.count)])
                    group.addTask { (start, try await self.query(scriptHashes: chunk)) }
                }
                var values: [(Int, [BitcoinAddressState])] = []
                for try await result in group { values.append(result) }
                return values.sorted { $0.0 < $1.0 }.flatMap(\.1)
            }
        }
        var requests: [RPCRequest] = []
        for (i, hash) in scriptHashes.enumerated() {
            for (j, method) in ["get_balance", "get_history", "listunspent"].enumerated() {
                var params: [JSONValue] = [.string(hash)]
                if network == .bitcoincash && method != "get_history" { params.append(.string("include_tokens")) }
                requests.append(.init(id: i * 3 + j, method: "blockchain.scripthash." + method, params: params))
            }
        }
        let maximum = network.maximumMoney
        let outputMaximum = network.maximumOutput
        return try await request(requests) { result in
            try Self.addressStates(result, count: scriptHashes.count, maximumMoney: maximum, maximumOutput: outputMaximum)
        }
    }

    private static func addressStates(_ result: [Int: JSONValue], count: Int, maximumMoney: Int64, maximumOutput: Int64) throws -> [BitcoinAddressState] {
        try (0..<count).map { i in
            guard let balance = result[i * 3], let confirmed = balance["confirmed"]?.integer,
                  let unconfirmed = balance["unconfirmed"]?.integer, confirmed >= 0, confirmed <= maximumMoney,
                  (-maximumMoney...maximumMoney).contains(unconfirmed),
                  let items = result[i * 3 + 1]?.array, let outputs = result[i * 3 + 2]?.array,
                  items.count <= 100_000, outputs.count <= 100_000 else { throw BitcoinError.invalidResponse }
            let history = try items.map { item -> BitcoinHistoryItem in
                guard let hash = item["tx_hash"]?.string, Self.hash(hash), let height = item["height"]?.integer, height >= -1 else { throw BitcoinError.invalidResponse }
                return .init(txid: hash, height: height)
            }
            let unspent = try outputs.map { item -> BitcoinUnspent in
                guard let hash = item["tx_hash"]?.string, Self.hash(hash), let height = item["height"]?.integer, height >= 0,
                      let value = item["value"]?.integer, (0...maximumOutput).contains(value),
                      let position = item["tx_pos"]?.integer, (0...Int64(UInt32.max)).contains(position) else { throw BitcoinError.invalidResponse }
                return .init(txid: hash, vout: Int(position), value: value, height: height)
            }
            guard Set(history.map(\.txid)).count == history.count, Set(unspent.map(\.id)).count == unspent.count else { throw BitcoinError.invalidResponse }
            let total = try unspent.reduce(Int64(0)) { sum, output in
                guard sum <= maximumMoney - output.value else { throw BitcoinError.invalidResponse }; return sum + output.value
            }
            // These three calls may straddle a mempool change. Retry the whole
            // address batch, never publish a contradictory balance/UTXO pair.
            let combined = confirmed.addingReportingOverflow(unconfirmed)
            let historyHeights = Dictionary(uniqueKeysWithValues: history.map { ($0.txid, $0.unspentHeight) })
            guard !combined.overflow, combined.partialValue == total,
                  unspent.allSatisfy({ historyHeights[$0.txid] == $0.height }) else { throw BitcoinError.inconsistentSnapshot }
            return .init(confirmed: confirmed, unconfirmed: unconfirmed, history: history, unspent: unspent)
        }
    }

    public func chainTip() async throws -> BitcoinChainTip {
        let network = network
        return try await request([.init(id: 0, method: "blockchain.headers.subscribe")]) { result in
            guard let height = result[0]?["height"]?.integer, height > 0,
                  let header = result[0]?["hex"]?.string,
                  (network == .dogecoin ? (160...32_768).contains(header.count) : header.count == 160),
                  Data(hex: header) != nil else { throw BitcoinError.invalidResponse }
            return BitcoinChainTip(height: height, header: String(header.prefix(160)).lowercased())
        }
    }

    /// Time is the mined block timestamp, not the time the wallet refreshed.
    public func blockTimes(heights: [Int64]) async throws -> [Int64: Double] {
        guard heights.allSatisfy({ $0 > 0 }), Set(heights).count == heights.count else { throw BitcoinError.invalidResponse }
        let size = min(40, peers.map { $0.server.batchLimit }.min() ?? 40)
        var times: [Int64: Double] = [:]
        for start in stride(from: 0, to: heights.count, by: size) {
            let chunk = Array(heights[start..<min(start + size, heights.count)])
            let values = try await request(chunk.enumerated().map {
                .init(id: $0.offset, method: "blockchain.block.header", params: [.integer($0.element)])
            }) { response in
                var result: [Int64: Double] = [:]
                for (index, height) in chunk.enumerated() {
                    guard let hex = response[index]?.string, let data = Data(hex: hex), data.count >= 80 else { throw BitcoinError.invalidResponse }
                    let bytes = Array(data)
                    let seconds = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[68 + $1]) << (8 * $1) }
                    guard seconds > 0 else { throw BitcoinError.invalidResponse }
                    result[height] = Double(seconds)
                }
                return result
            }
            times.merge(values) { _, new in new }
        }
        return times
    }

    static let maximumMoney: Int64 = 2_100_000_000_000_000
    static func hash(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

public struct BitcoinChainTip: Sendable, Equatable {
    public let height: Int64
    public let header: String
}

import Foundation
import XCTest
@testable import OathBitcoin

final class StubTransport: ElectrumTransport, @unchecked Sendable {
    enum Mode: Sendable { case empty, malformed, inconsistent, overflow, unsupported, wrongNetwork, legacyProtocol, failure(BitcoinError), suspended, badTransaction, state(BitcoinAddressState), fee(JSONValue, JSONValue), broadcast(String) }
    let mode: Mode
    let network: UTXONetwork
    init(_ mode: Mode, network: UTXONetwork = .bitcoin) { self.mode = mode; self.network = network }
    func close() { }
    func exchange(_ data: Data, timeout: TimeInterval) async throws -> Data {
        let requests = try JSONDecoder().decode(JSONValue.self, from: data).array!
        let handshake = requests.first?["method"]?.string == "server.version"
        if network == .bitcoincash {
            for request in requests {
                switch request["method"]?.string {
                case "server.version":
                    guard request["params"]?.array?.last?.string == "1.5" else { throw BitcoinError.invalidResponse }
                case "blockchain.block.header":
                    guard request["params"]?.array?.first?.integer == 792773 else { throw BitcoinError.wrongNetwork }
                case "blockchain.scripthash.get_balance", "blockchain.scripthash.listunspent":
                    guard request["params"]?.array?.last?.string == "include_tokens" else { throw BitcoinError.invalidResponse }
                default: break
                }
            }
        }
        if !handshake {
            if case .failure(let error) = mode { throw error }
            if case .suspended = mode { try await Task.sleep(for: .seconds(60)) }
            if case .unsupported = mode { return Data(#"{"error":{"code":-32600},"id":null}"#.utf8) }
        }
        let values = requests.map { request -> JSONValue in
            let result: JSONValue
            switch request["method"]?.string ?? "" {
            case "server.version":
                if case .legacyProtocol = mode { result = .array([.string("fixture"), .string("1.4")]) }
                else { result = .array([.string("fixture"), .string(network == .bitcoincash ? "1.5" : "1.4")]) }
            case "blockchain.block.header": result = .string(network == .bitcoincash ? "00004020d11e3a6eeb27fe2620c3a99caec74e403e1c8471c478b60200000000000000002bce0a3beaa741afd400f6468bdb266212bfa60d27874541a65b51e1f024df9e563462648c8e05182bd28251" : String(repeating: "0", count: 160))
            case "server.features":
                if case .wrongNetwork = mode { result = .object(["genesis_hash": .string("wrong")]) }
                else { result = .object(["genesis_hash": .string(network.genesis)]) }
            case "blockchain.headers.subscribe": result = .object(["height": .integer(900_000), "hex": .string(String(repeating: "0", count: network == .dogecoin ? 1698 : 160))])
            case "blockchain.scripthash.get_balance":
                if case .state(let state) = mode { result = .object(["confirmed": .integer(state.confirmed), "unconfirmed": .integer(state.unconfirmed)]) }
                else if case .malformed = mode { result = .object(["confirmed": .string("0"), "unconfirmed": .integer(0)]) }
                else if case .inconsistent = mode { result = .object(["confirmed": .integer(1), "unconfirmed": .integer(0)]) }
                else if case .overflow = mode { result = .object(["confirmed": .integer(Int64.max), "unconfirmed": .integer(1)]) }
                else { result = .object(["confirmed": .integer(0), "unconfirmed": .integer(0)]) }
            case "blockchain.scripthash.get_history":
                if case .state(let state) = mode {
                    result = .array(state.history.map { .object(["tx_hash": .string($0.txid), "height": .integer($0.height)]) })
                } else { result = .array([]) }
            case "blockchain.scripthash.listunspent":
                if case .state(let state) = mode {
                    result = .array(state.unspent.map { .object(["tx_hash": .string($0.txid), "tx_pos": .integer(Int64($0.vout)), "height": .integer($0.height), "value": .integer($0.value)]) })
                } else { result = .array([]) }
            case "blockchain.transaction.get": result = .string("00")
            case "blockchain.estimatefee":
                if case .fee(let quote, _) = mode { result = quote } else { result = .integer(-1) }
            case "blockchain.relayfee":
                if case .fee(_, let relay) = mode { result = relay } else { result = .decimal(0.00001) }
            case "blockchain.transaction.broadcast":
                if case .broadcast(let hash) = mode { result = .string(hash) } else { result = .null }
            default: result = .array([])
            }
            return .object(["jsonrpc": .string("2.0"), "id": request["id"]!, "result": result])
        }
        return try JSONEncoder().encode(JSONValue.array(values.reversed()))
    }
}

final class ElectrumRecoveryTests: XCTestCase, @unchecked Sendable {
    func testBothNetworksDecodeIncomingAndOutgoingMempoolBalances() async throws {
        let a = String(repeating: "1", count: 64), b = String(repeating: "2", count: 64)
        for network in UTXONetwork.allCases {
            let states: [BitcoinAddressState] = [
                .init(confirmed: 50_000, unconfirmed: 20_000,
                      history: [.init(txid: a, height: 100), .init(txid: b, height: 0)],
                      unspent: [.init(txid: a, vout: 0, value: 50_000, height: 100), .init(txid: b, vout: 0, value: 20_000, height: 0)]),
                .init(confirmed: 50_000, unconfirmed: -38_000,
                      history: [.init(txid: a, height: 100), .init(txid: b, height: -1)],
                      unspent: [.init(txid: b, vout: 0, value: 12_000, height: 0)]),
                .init(confirmed: 50_000, unconfirmed: -50_000,
                      history: [.init(txid: a, height: 100), .init(txid: b, height: 0)], unspent: [])
            ]
            for state in states {
                let pool = ElectrumPool(servers: [.init("fixture")], network: network) { _ in StubTransport(.state(state), network: network) }
                let result = try await pool.query(scriptHashes: [a])
                XCTAssertEqual(result, [state], network.rawValue)
                await pool.close()
            }
        }
    }

    func testConfirmationRaceRetriesEvenWhenAmountsStillMatch() async throws {
        let txid = String(repeating: "1", count: 64)
        for network in UTXONetwork.allCases {
            for heights: (history: Int64, output: Int64) in [(0, 100), (100, 0), (100, 101)] {
                let inconsistent = BitcoinAddressState(confirmed: 20_000, unconfirmed: 0,
                    history: [.init(txid: txid, height: heights.history)],
                    unspent: [.init(txid: txid, vout: 0, value: 20_000, height: heights.output)])
                let coherent = BitcoinAddressState(confirmed: 20_000, unconfirmed: 0,
                    history: [.init(txid: txid, height: 100)], unspent: [.init(txid: txid, vout: 0, value: 20_000, height: 100)])
                let pool = ElectrumPool(servers: [.init("changing"), .init("settled")], maximumConnections: 1, network: network) {
                    StubTransport(.state($0.host == "changing" ? inconsistent : coherent), network: network)
                }
                let states = try await pool.query(scriptHashes: [txid])
                XCTAssertEqual(states, [coherent])
                let attempts = await pool.diagnostics()
                XCTAssertEqual(attempts.map(\.error), [.inconsistentSnapshot, nil])
                await pool.close()
            }
        }
    }

    func testDogecoinRejectsBitcoinPeerAndOverflowThenRecovers() async throws {
        let pool = ElectrumPool(servers: [.init("bitcoin"), .init("overflow"), .init("dogecoin")], maximumConnections: 1, network: .dogecoin) {
            switch $0.host {
            case "bitcoin": StubTransport(.empty)
            case "overflow": StubTransport(.overflow, network: .dogecoin)
            default: StubTransport(.empty, network: .dogecoin)
            }
        }
        let states = try await pool.query(scriptHashes: [String(repeating: "1", count: 64)])
        XCTAssertEqual(states.first?.confirmed, 0)
        let attempts = await pool.diagnostics()
        XCTAssertEqual(attempts.map(\.error), [.wrongNetwork, .inconsistentSnapshot, nil])
        let tip = try await pool.chainTip()
        XCTAssertEqual(tip.header.count, 160, "Only the base header identifies the AuxPoW block")
        await pool.close()
    }

    func testSemanticFailuresTimeoutsAndUnsupportedPeersRotate() async throws {
        let cases: [(StubTransport.Mode, BitcoinError)] = [(.malformed, .invalidResponse), (.inconsistent, .inconsistentSnapshot),
            (.unsupported, .batchUnsupported), (.wrongNetwork, .wrongNetwork), (.failure(.timeout), .timeout),
            (.failure(.disconnected), .disconnected), (.failure(.tls), .tls), (.failure(.server(code: 1)), .server(code: 1))]
        for (mode, expected) in cases {
            let pool = ElectrumPool(servers: [.init("failing"), .init("healthy")], maximumConnections: 1) {
                StubTransport($0.host == "failing" ? mode : .empty)
            }
            let states = try await pool.query(scriptHashes: [String(repeating: "1", count: 64)])
            XCTAssertEqual(states.first?.confirmed, 0)
            let attempts = await pool.diagnostics()
            XCTAssertEqual(attempts.map(\.error), [expected, nil])
            await pool.close()
        }
    }
    func testOutageIsFailureNeverAnEmptyBalance() async throws {
        let pool = ElectrumPool(servers: [.init("a"), .init("b")]) { _ in StubTransport(.failure(.timeout)) }
        do { _ = try await pool.query(scriptHashes: [String(repeating: "1", count: 64)]); XCTFail("Outage became success") }
        catch { XCTAssertEqual(error as? BitcoinError, .timeout) }
        let attempts = await pool.diagnostics(); XCTAssertEqual(attempts.count, 2)
        do { _ = try await pool.query(scriptHashes: [String(repeating: "1", count: 64)]); XCTFail("Cooldown ignored") }
        catch { XCTAssertEqual(error as? BitcoinError, .unavailable) }
    }
    func testRawTransactionValidationParticipatesInFallback() async throws {
        let pool = ElectrumPool(servers: [.init("a"), .init("b")]) { _ in StubTransport(.badTransaction) }
        do { _ = try await pool.transactions(txids: [String(repeating: "1", count: 64)]); XCTFail("Invalid transaction accepted") } catch { }
        let attempts = await pool.diagnostics(); XCTAssertEqual(attempts.count, 2)
        XCTAssertTrue(attempts.allSatisfy { $0.error == .invalidResponse })
    }
    func testBatchSplittingAndOrderedResults() async throws {
        let pool = ElectrumPool(servers: [.init("a", batchLimit: 60), .init("b", batchLimit: 60)]) { _ in StubTransport(.empty) }
        let states = try await pool.query(scriptHashes: (0..<160).map { String(format: "%064x", $0) })
        XCTAssertEqual(states.count, 160)
        let attempts = await pool.diagnostics()
        XCTAssertEqual(attempts.count, 8); XCTAssertTrue(attempts.allSatisfy { $0.requestCount == 60 })
        let tip = try await pool.chainTip(); XCTAssertEqual(tip.height, 900_000)
    }
    func testCancellationReleasesConnectionLease() async throws {
        let pool = ElectrumPool(servers: [.init("a")]) { _ in StubTransport(.suspended) }
        let work = Task { try await pool.query(scriptHashes: [String(repeating: "1", count: 64)]) }
        try await Task.sleep(for: .milliseconds(20)); work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled query returned") } catch is CancellationError { }
        let attempts = await pool.diagnostics(); XCTAssertTrue(attempts.isEmpty)
        await pool.close()
    }
}

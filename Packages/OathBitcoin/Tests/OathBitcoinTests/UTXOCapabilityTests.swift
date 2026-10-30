import Foundation
import XCTest
@testable import OathBitcoin

final class UTXOCapabilityTests: XCTestCase, @unchecked Sendable {
    func testGeneralAlchemyKeyDoesNotImplyUTXOCapability() {
        let config = UTXOConfiguredSources(ankrAPIKey: "fixture", alchemyAPIKey: "fixture")
        XCTAssertFalse(config.hasAlchemy)
        for chain in UTXONetwork.allCases {
            XCTAssertNil(config.broadcastPreferred(chain))
            XCTAssertNil(config.feeFallback(chain))
            XCTAssertEqual(config.feePreferred(chain)?.name, chain == .bitcoin ? "rpc.ankr.com" : nil)
        }
    }
    func testExplicitCapabilityIsScopedToItsNetworkAndPreservesAnkrFallback() {
        for enabled in UTXONetwork.allCases {
            let config = UTXOConfiguredSources(ankrAPIKey: "fixture", alchemyAPIKey: "fixture", alchemyNetworks: [enabled])
            for chain in UTXONetwork.allCases {
                XCTAssertEqual(config.broadcastPreferred(chain)?.name, chain == enabled ? AlchemyUTXOAPI.host(chain) : nil)
                XCTAssertEqual(config.feePreferred(chain)?.name,
                               chain == enabled ? AlchemyUTXOAPI.host(chain) : (chain == .bitcoin ? "rpc.ankr.com" : nil))
                XCTAssertEqual(config.feeFallback(chain)?.name, chain == enabled && chain == .bitcoin ? "rpc.ankr.com" : nil)
            }
        }
        let missingKey = UTXOConfiguredSources(ankrAPIKey: "fixture", alchemyNetworks: [.bitcoin])
        XCTAssertEqual(missingKey.feePreferred(.bitcoin)?.name, "rpc.ankr.com")
        XCTAssertNil(missingKey.broadcastPreferred(.bitcoin))
    }
    func testUnconfiguredPaidRouteStillReconcilesWithoutRebroadcasting() async throws {
        let config = UTXOConfiguredSources(alchemyAPIKey: "fixture")
        var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 1, count: 32)
        raw += BitcoinWire.little(UInt32(0)) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        raw += BitcoinWire.little(UInt64(10000)) + BitcoinWire.vector(Data([0x51])) + BitcoinWire.little(UInt32(0))
        let bytes = raw
        for chain in UTXONetwork.allCases {
            let hash = try BitcoinTransactions.txid(bytes, network: chain)
            let provider = UTXOBroadcastProvider(preferred: { config.broadcastPreferred($0) }, sources: { _ in [
                .init(name: "public-fixture", delay: .zero, submit: { _ in
                    XCTFail("An exact read must reconcile without sending again"); throw BitcoinError.invalidResponse
                }, lookup: { requested in XCTAssertEqual(requested, hash); return bytes })
            ] })
            let accepted = await provider.submit(bytes, txid: hash, network: chain, reconcileFirst: true)
            XCTAssertTrue(accepted)
        }
    }
    func testLiveConfiguredAnkrFeeAndPublicBitcoinLookup() async throws {
        guard let path = ProcessInfo.processInfo.environment["OATH_UTXO_CAPABILITY_CONFIG"] else {
            throw XCTSkip("Opt-in read-only provider verification; no signing or broadcast")
        }
        let values = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertNil(values["AlchemyUTXONetworks"], "This check targets the currently unconfigured UTXO capability")
        let config = UTXOConfiguredSources(ankrAPIKey: values["AnkrAPIKey"], alchemyAPIKey: values["AlchemyAPIKey"])
        let source = try XCTUnwrap(config.feePreferred(.bitcoin))
        XCTAssertEqual(source.name, "rpc.ankr.com")
        let rate = try await source.load()
        XCTAssertGreaterThan(rate, 0)
        XCTAssertNil(config.broadcastPreferred(.bitcoin))
        let base = URL(string: "https://mempool.space/api")!
        func get(_ path: String) async throws -> Data {
            var request = URLRequest(url: URL(string: base.absoluteString + path)!)
            request.timeoutInterval = 15
            return try await UTXOAPIProvider.fetch(request, limit: 4_194_304)
        }
        let tip = String(decoding: try await get("/blocks/tip/hash"), as: UTF8.self)
        guard tip.count == 64, tip.allSatisfy(\.isHexDigit) else { throw BitcoinError.invalidResponse }
        let hashes = try JSONDecoder().decode([String].self, from: await get("/block/" + tip + "/txids"))
        let hash = try XCTUnwrap(hashes.first)
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw BitcoinError.invalidResponse }
        let api = UTXOAPIProvider(network: .bitcoin, base: base, format: .mempool)
        let request = api.lookupRequest(txid: hash)
        XCTAssertTrue(request.httpMethod == nil || request.httpMethod == "GET")
        let data = try await UTXOAPIProvider.fetch(request, limit: 4_194_304)
        let bytes = try XCTUnwrap(api.decodeRaw(data, txid: hash))
        XCTAssertEqual(try BitcoinTransactions.txid(bytes, network: .bitcoin), hash)
        print("UTXO_CAPABILITY_LIVE ankrFee=true publicLookupVerified=true alchemyUTXORequests=0 broadcast=false")
    }
}

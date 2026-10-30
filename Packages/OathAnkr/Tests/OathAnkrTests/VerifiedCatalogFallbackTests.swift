import Foundation
import XCTest
@testable import OathAnkr

final class VerifiedCatalogFallbackTests: XCTestCase, @unchecked Sendable {
    func testLiveDirectoryRecoversReportedChainsAfterInjectedTokenListRateLimit() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_CATALOG_RECOVERY"] == "1" else {
            throw XCTSkip("Opt-in public catalog reads; no wallets, credentials or signing")
        }
        let transport = LiveCatalogRecoveryTransport()
        for chain: AnkrChain in [.story, .telos, .xlayer] {
            let catalog = try await VerifiedEVMTokenCatalog.fetch(chain: chain, transport: transport)
            let data = await transport.directory
            let coins = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [[String: Any]])
            let platform = VerifiedEVMTokenCatalog.source(for: chain).platform
            let expected = Set(coins.compactMap { coin -> String? in
                guard let platforms = coin["platforms"] as? [String: Any],
                      let address = platforms[platform] as? String, !address.isEmpty else { return nil }
                return address.lowercased()
            })
            XCTAssertFalse(expected.isEmpty)
            XCTAssertEqual(Set(catalog.referencesWithoutDecimals ?? []), expected)
            XCTAssertTrue(catalog.decimalsByReference.isEmpty)
            print("CATALOG_RECOVERY chain=\(chain.networkID) exactContracts=\(expected.count) injectedHTTP=429")
        }
    }

    func testUnavailableTokenListsRecoverExactContractsOnEverySupportedEVMChain() async throws {
        for chain in AnkrChain.allCases where chain != .taiko {
            for status in [403, 404, 408, 429, 500, 502, 503, 504] {
                let transport = CatalogFallbackTransport(chain: chain, mode: .http(status))
                let catalog = try await VerifiedEVMTokenCatalog.fetch(chain: chain, transport: transport)
                XCTAssertEqual(catalog.networkID, chain.networkID)
                XCTAssertEqual(catalog.referencesWithoutDecimals, [CatalogFallbackTransport.contract])
                XCTAssertTrue(catalog.decimalsByReference.isEmpty, "Directory identity cannot invent precision")
                let hosts = await transport.hosts
                XCTAssertEqual(hosts, ["tokens.coingecko.com", "api.coingecko.com"])
            }
        }
    }

    func testTransportFailureRecoversButCancellationNeverFallsBack() async throws {
        let transport = CatalogFallbackTransport(chain: .story, mode: .transport)
        let catalog = try await VerifiedEVMTokenCatalog.fetch(chain: .story, transport: transport)
        XCTAssertEqual(catalog.referencesWithoutDecimals, [CatalogFallbackTransport.contract])
        let cancelled = CatalogFallbackTransport(chain: .story, mode: .cancelled)
        do { _ = try await VerifiedEVMTokenCatalog.fetch(chain: .story, transport: cancelled); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        let hosts = await cancelled.hosts
        XCTAssertEqual(hosts, ["tokens.coingecko.com"])
    }

    func testInvalidSuccessfulResponseAndAuthenticationFailureDoNotFallback() async throws {
        for mode: CatalogFallbackTransport.Mode in [.wrongChain, .http(401)] {
            let transport = CatalogFallbackTransport(chain: .telos, mode: mode)
            do { _ = try await VerifiedEVMTokenCatalog.fetch(chain: .telos, transport: transport); XCTFail() }
            catch { XCTAssertFalse(error is CancellationError) }
            let hosts = await transport.hosts
            XCTAssertEqual(hosts, ["tokens.coingecko.com"])
        }
    }

    func testFallbackFailureNeverCreatesEmptyTrustedCatalog() async throws {
        for mode: CatalogFallbackTransport.Mode in [.fallbackFailure, .wrongPlatform, .invalidContract] {
            let transport = CatalogFallbackTransport(chain: .xlayer, mode: mode)
            do { _ = try await VerifiedEVMTokenCatalog.fetch(chain: .xlayer, transport: transport); XCTFail() }
            catch { XCTAssertFalse(error is CancellationError) }
        }
    }

    func testSuccessfulTokenListRetainsDecimalsWithoutFallback() async throws {
        let transport = CatalogFallbackTransport(chain: .story, mode: .success)
        let catalog = try await VerifiedEVMTokenCatalog.fetch(chain: .story, transport: transport)
        XCTAssertEqual(catalog.decimalsByReference, [CatalogFallbackTransport.contract: 6])
        XCTAssertNil(catalog.referencesWithoutDecimals)
        let hosts = await transport.hosts
        XCTAssertEqual(hosts, ["tokens.coingecko.com"])
    }

    func testTaikoKeepsItsDirectDirectoryRoute() async throws {
        let transport = CatalogFallbackTransport(chain: .taiko, mode: .success)
        let catalog = try await VerifiedEVMTokenCatalog.fetch(chain: .taiko, transport: transport)
        XCTAssertEqual(catalog.referencesWithoutDecimals, [CatalogFallbackTransport.contract])
        let hosts = await transport.hosts
        XCTAssertEqual(hosts, ["api.coingecko.com"])
    }
}

private actor LiveCatalogRecoveryTransport: AnkrTransport {
    private let transport = AnkrHTTPTransport()
    private(set) var directory: Data?
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "tokens.coingecko.com" { return (Data(), 429) }
        let response = try await transport.send(request)
        if response.1 == 200 { directory = response.0 }
        return response
    }
}

private actor CatalogFallbackTransport: AnkrTransport {
    enum Mode { case http(Int), transport, cancelled, wrongChain, fallbackFailure, wrongPlatform, invalidContract, success }
    static let contract = "0x" + String(repeating: "a", count: 40)
    let chain: AnkrChain
    let mode: Mode
    private(set) var hosts: [String] = []
    init(chain: AnkrChain, mode: Mode) { self.chain = chain; self.mode = mode }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        hosts.append(request.url!.host!)
        let source = VerifiedEVMTokenCatalog.source(for: chain)
        if request.url!.host == "tokens.coingecko.com" {
            switch mode {
            case .http(let status): return (Data(), status)
            case .transport: throw AnkrError.transport
            case .cancelled: throw CancellationError()
            case .wrongChain, .success:
                let chainID = if case .wrongChain = mode { -1 } else { source.chainID }
                return (try JSONSerialization.data(withJSONObject: ["tokens": [["chainId": chainID,
                    "address": Self.contract, "decimals": 6]]]), 200)
            default: return (Data(), 429)
            }
        }
        if case .fallbackFailure = mode { return (Data(), 503) }
        let platform = if case .wrongPlatform = mode { "wrong-chain" } else { source.platform }
        let contract = if case .invalidContract = mode { "symbol-is-not-a-contract" } else { Self.contract }
        return (try JSONSerialization.data(withJSONObject: [
            ["id": "fixture", "platforms": [platform: contract]],
            ["id": "same-symbol-other-chain", "platforms": ["unrelated-network": "0x" + String(repeating: "b", count: 40)]]
        ]), 200)
    }
}

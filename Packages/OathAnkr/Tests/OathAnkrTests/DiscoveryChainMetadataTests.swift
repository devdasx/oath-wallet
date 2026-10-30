import XCTest
@testable import OathAnkr

final class DiscoveryChainMetadataTests: XCTestCase, @unchecked Sendable {
    func testAptosCoinAndFungibleAssetUseCorrectViewAtVerifiedLedger() async throws {
        for ref in ["0x123::coin::Token", "0x456"] {
            let transport = DiscoveryAptosTransport()
            let client = try AptosSendClient(transport: transport)
            let decimals = try await client.tokenDecimals(reference: ref)
            XCTAssertEqual(decimals, 6)
            let functions = await transport.functions
            XCTAssertEqual(functions, [ref.contains("::") ? "0x1::coin::decimals" : "0x1::fungible_asset::decimals"])
        }
        for mode in ["wrong-chain", "overflow"] {
            let client = try AptosSendClient(transport: DiscoveryAptosTransport(mode: mode))
            do { _ = try await client.tokenDecimals(reference: "0x456"); XCTFail("Invalid metadata accepted") }
            catch { XCTAssertEqual(error as? AptosSendError, mode == "wrong-chain" ? .wrongNetwork : .malformed) }
        }
    }

    func testTonStringScaleRequiresMatchingMasterAndMainnet() async throws {
        let client = TonClient(testTransport: DiscoveryTonTransport())
        let decimals = try await client.tokenDecimals(reference: TonIdentity.usdt)
        XCTAssertEqual(decimals, 6)
        for mode in ["wrong-chain", "wrong-token", "overflow"] {
            let client = TonClient(testTransport: DiscoveryTonTransport(mode: mode))
            do { _ = try await client.tokenDecimals(reference: TonIdentity.usdt); XCTFail("Invalid metadata accepted") }
            catch { XCTAssertEqual(error as? TonError, mode == "wrong-chain" ? .wrongNetwork : .malformed) }
        }
    }
}

private actor DiscoveryAptosTransport: AnkrTransport {
    let mode: String
    var functions: [String] = []
    init(mode: String = "valid") { self.mode = mode }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.lastPathComponent == "view" {
            let parameters = try JSONDecoder().decode(AptosJSON.self, from: XCTUnwrap(request.httpBody))
            functions.append(try XCTUnwrap(parameters["function"].string))
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                [URLQueryItem(name: "ledger_version", value: "100")])
            return (Data(mode == "overflow" ? "[\"256\"]".utf8 : "[\"6\"]".utf8), 200)
        }
        return (Data("{\"chain_id\":\(mode == "wrong-chain" ? 2 : 1),\"ledger_version\":\"100\"}".utf8), 200)
    }
}

private struct DiscoveryTonTransport: AnkrTransport {
    var mode = "valid"
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "tonapi.io" {
            let address = mode == "wrong-token" ? "0:" + String(repeating: "1", count: 64) : TonIdentity.usdt
            return (Data("{\"metadata\":{\"address\":\"\(address)\",\"decimals\":\"\(mode == "overflow" ? "256" : "6")\"}}".utf8), 200)
        }
        let root = mode == "wrong-chain" ? "other" : TonIdentity.genesis
        return (Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"init\":{\"root_hash\":\"\(root)\"}}}".utf8), 200)
    }
}

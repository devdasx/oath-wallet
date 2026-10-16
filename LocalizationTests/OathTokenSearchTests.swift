import XCTest
import OathDatabase
import WalletCore
@testable import OathAtmosphere

@MainActor final class OathTokenSearchTests: XCTestCase {
    func testRegistryCoversEverySupportedEVMAndBothTokenNetworks() {
        XCTAssertEqual(Set(OathTokenNetwork.all.filter { $0.chain.isEVM }.map(\.chain)),
                       Set(OathImportChain.allCases.filter(\.isEVM)))
        XCTAssertEqual(Set(OathTokenNetwork.all.map(\.chain)), Set(OathTokenLiveFixture.all.map(\.chain)))
        XCTAssertEqual(OathTokenNetwork.all.count, 20)
    }

    /// Intentionally live and simulator-hosted. No provider mocks, substitute
    /// metadata, cached fixture responses, or secret wallet material.
    func testLiveMetadataForEverySupportedNetwork() async throws {
        let service = OathTokenService(configuration: .bundled())
        var evidence: [String] = []
        for fixture in OathTokenLiveFixture.all {
            let network = try XCTUnwrap(OathTokenNetwork.find(fixture.chain))
            do {
                let token = try await service.lookup(address: fixture.address, network: network)
                XCTAssertEqual(token.name, fixture.name, network.id)
                XCTAssertEqual(token.symbol, fixture.symbol, network.id)
                XCTAssertEqual(token.decimals, fixture.decimals, network.id)
                XCTAssertEqual(token.address.lowercased(), fixture.address.lowercased(), network.id)
                evidence.append("\(network.id): \(token.name) / \(token.symbol) / \(token.decimals) decimals")
            } catch {
                // Errors intentionally have no provider URL or credential.
                XCTFail("Live token lookup failed on \(network.id): \(error)")
            }
        }
        XCTAssertEqual(evidence.count, 20)
        let attachment = XCTAttachment(string: evidence.joined(separator: "\n"))
        attachment.name = "Live token lookup - all 20 networks"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    func testLiveToken2022AndMissingContracts() async throws {
        let service = OathTokenService(configuration: .bundled())
        let solana = try XCTUnwrap(OathTokenNetwork.find(.solana))
        let token = try await service.lookup(address: "2b1kV6DkPAnxd5ixfnxCpjxmKwqjjaYmCZfHsFu24GXo", network: solana)
        XCTAssertEqual(token.name, "PayPal USD")
        XCTAssertEqual(token.symbol, "PYUSD")
        XCTAssertEqual(token.decimals, 6)
        XCTAssertEqual(token.standard, "Token-2022")
        for network in OathTokenNetwork.all {
            let address = network.chain == .solana ? "11111111111111111111111111111111"
                : network.chain == .tron ? "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb"
                : "0x0000000000000000000000000000000000000000"
            do {
                _ = try await service.lookup(address: address, network: network)
                XCTFail("Non-token address accepted: \(network.id)")
            } catch OathTokenLookupError.notToken { }
            catch { XCTFail("Non-token address was not conclusively checked: \(network.id), \(error)") }
        }
    }

    func testAddressAndABIBoundaries() throws {
        XCTAssertEqual(OathTokenAddress.networks(for: "  0x0000000000000000000000000000000000000001\n").count, 18)
        XCTAssertEqual(OathTokenAddress.networks(for: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t").map(\.chain), [.tron])
        XCTAssertTrue(OathTokenAddress.networks(for: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6u").isEmpty)
        XCTAssertTrue(OathTokenAddress.networks(for: "0xNOTANADDRESS").isEmpty)
        XCTAssertEqual(try OathTokenABI.decimals("0x" + String(repeating: "00", count: 32)), 0)
        XCTAssertEqual(try OathTokenABI.decimals("0x" + String(repeating: "00", count: 31) + "ff"), 255)
        XCTAssertThrowsError(try OathTokenABI.decimals("0x" + String(repeating: "00", count: 30) + "0100"))
        XCTAssertThrowsError(try OathTokenABI.decimals("0x12"))
        XCTAssertThrowsError(try OathTokenABI.string("0x" + String(repeating: "ff", count: 96)))
        XCTAssertThrowsError(try OathTokenABI.clean("TOKEN\u{202e}fake"))
        XCTAssertThrowsError(try OathTokenABI.clean(String(repeating: "x", count: 513)))
        let bytes32 = "0x55534454" + String(repeating: "00", count: 28)
        XCTAssertEqual(try OathTokenABI.string(bytes32), "USDT")
        let candidates = try OathSolanaMetadata.candidates(mint: OathTokenLiveFixture.all.last!.address)
        XCTAssertEqual(candidates.count, 256)
        XCTAssertEqual(Set(candidates).count, 256)
        XCTAssertThrowsError(try OathSolanaMetadata.decode(Data(repeating: 0, count: 128), mint: OathTokenLiveFixture.all.last!.address))
        let arc = try XCTUnwrap(OathTokenNetwork.find(.arc))
        let nativeAlias = OathTokenDefinition(network: arc, address: "0x3600000000000000000000000000000000000000",
            name: "USD Coin", symbol: "USDC", decimals: 6, standard: "ERC-20", logoURL: nil)
        XCTAssertTrue(nativeAlias.isNativeRepresentation)
        XCTAssertEqual(nativeAlias.id, "arc:native", "Arc USDC must not be counted twice")
    }

    func testWrongNetworkAndMalformedResponsesAreNeverTokens() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TokenRPCStub.self]
        let network = try XCTUnwrap(OathTokenNetwork.find(.ethereum))
        for mode in ["wrongchain", "wrongid", "badjson", "providererror", "invaliddecimals"] {
            let session = URLSession(configuration: config)
            let service = OathTokenService(configuration: .init(ankrKey: mode), session: session)
            do {
                _ = try await service.lookup(address: OathTokenLiveFixture.all[0].address, network: network)
                XCTFail("Invalid provider response accepted: \(mode)")
            } catch OathTokenLookupError.notToken { XCTFail("Transport/schema failure incorrectly reported as absent token") }
            catch { }
            session.invalidateAndCancel()
        }
    }

    func testChangedQueryCannotPublishOldResultsAndFailuresRemainVisible() async throws {
        let model = OathTokenSearchModel(service: DelayedTokenLookup())
        let first = Task { await model.search(OathTokenLiveFixture.all[0].address, available: [.ethereum]) }
        try await Task.sleep(for: .milliseconds(400))
        await model.search("Bitcoin", available: [.ethereum])
        await first.value
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.isAddress)
        XCTAssertFalse(model.isSearching)
        await model.search(OathTokenLiveFixture.all[0].address, available: [.base])
        XCTAssertEqual(model.failedNetworks.map(\.chain), [.base])
        XCTAssertTrue(model.results.isEmpty)
        await model.search(OathTokenLiveFixture.all[0].address, available: [.solana])
        XCTAssertTrue(model.unavailableForWallet)
    }

    func testMultiNetworkResultsAreDistinctAndLookupConcurrencyIsBounded() async {
        let service = ConcurrentTokenLookup()
        let model = OathTokenSearchModel(service: service)
        let chains = Set(OathImportChain.allCases.filter(\.isEVM))
        await model.search(OathTokenLiveFixture.all[0].address, available: chains, savedNetworks: ["ethereum"])
        XCTAssertEqual(model.results.count, 17)
        XCTAssertEqual(Set(model.results.map(\.id)).count, 17)
        XCTAssertFalse(model.results.contains { $0.network.chain == .ethereum })
        XCTAssertFalse(model.isSearching)
        let peak = await service.peak
        XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertGreaterThan(peak, 1)
    }
}

private actor ConcurrentTokenLookup: OathTokenLookingUp {
    private var active = 0
    private(set) var peak = 0
    func lookup(address: String, network: OathTokenNetwork) async throws -> OathTokenDefinition {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(30))
        return .init(network: network, address: address, name: "Fixture", symbol: "FXT", decimals: 6, standard: "ERC-20", logoURL: nil)
    }
}

private actor DelayedTokenLookup: OathTokenLookingUp {
    func lookup(address: String, network: OathTokenNetwork) async throws -> OathTokenDefinition {
        try await Task.sleep(for: .milliseconds(250))
        if network.chain == .base { throw OathTokenLookupError.unavailable }
        return OathTokenDefinition(network: network, address: address, name: "Test", symbol: "TST",
            decimals: 0, standard: "ERC-20", logoURL: nil)
    }
}

private final class TokenRPCStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.url!.lastPathComponent
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            body = data
        }
        let input = try! JSONDecoder().decode(OathTokenJSON.self, from: body!)
        let method = input["method"].string!
        var result: OathTokenJSON = .string("0x" + String(repeating: "00", count: 32))
        if method == "eth_chainId" { result = .string(mode == "wrongchain" ? "0x38" : "0x1") }
        if method == "eth_getCode" { result = .string("0x6000") }
        if method == "eth_call" {
            if input["params"].array?.first?["data"].string == "0x313ce567" { result = .string("0x" + String(repeating: "ff", count: 32)) }
            else { result = .string("0x54455354" + String(repeating: "00", count: 28)) }
        }
        var output: [String: OathTokenJSON] = ["jsonrpc": .string("2.0"), "id": mode == "wrongid" ? .string("other") : input["id"], "result": result]
        if mode == "providererror" { output["error"] = .object(["message": .string("rate limited")]) }
        let data = mode == "badjson" ? Data("invalid".utf8) : try! JSONEncoder().encode(OathTokenJSON.object(output))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

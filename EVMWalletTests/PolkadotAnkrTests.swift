import Foundation
import Testing
@testable import Aperture

@Suite(.serialized) struct PolkadotAnkrTests {
    private let address = "134BxqvdkMzf1v95j1Wr2NmXoqpys2Y96GXG5a5H3YtMKLqf"
    private let raw = "0x050000000300000001000000000000005c0155580200000000000000000000000458a3494f6d000000000000000000000000000000000000000000000000000000000000000000000000000000000080"
    private func configuration() throws -> AnkrConfiguration {
        try .runtime(environment: [
            "ANKR_MULTICHAIN_PROXY_URL": "https://wallet.example/v1/provider/ankr/multichain",
            "ANKR_TRON_JSONRPC_PROXY_URL": "https://wallet.example/v1/provider/ankr/tron/jsonrpc",
            "ANKR_TRON_REST_PROXY_BASE_URL": "https://wallet.example/v1/provider/ankr/tron/rest/"
        ])
    }
    @Test func hubAndRelayHaveSeparateCredentialFreeProxyRoutes() throws {
        let config = try configuration()
        #expect(config.polkadotAssetHubJSONRPCEndpoint.absoluteString == "https://wallet.example/v1/provider/ankr/polkadot/asset-hub/jsonrpc")
        #expect(config.polkadotRelayJSONRPCEndpoint.absoluteString == "https://wallet.example/v1/provider/ankr/polkadot/relay/jsonrpc")
        #expect(PolkadotLedger.assetHub.genesis != PolkadotLedger.relay.genesis)
    }
    @Test func publicAccountStorageKeyMatchesLiveRead() throws {
        let key = try PolkadotRPCClient.accountStorageKey(address: address)
        #expect(key == "0x26aa394eea5630e07c48ae0c9558cef7b99d880ec681799c0cf30e8886371da9e7cc38ce7eae45537f36e2017ca956215ae71b755496fdb0efd63be998fec8f2ea497f231ff43bd2980e1f12b564a757")
        #expect(throws: (any Error).self) { try PolkadotRPCClient.accountStorageKey(address: String(address.dropLast()) + "1") }
    }
    @Test func scaleBalancesPreserve128BitValuesAndExcludeReservedFunds() throws {
        let value = try PolkadotAccountBalance.decode(raw)
        #expect(value.nonce == 5)
        #expect(value.free == "10071900508")
        #expect(value.reserved == "120187305285636")
        #expect(value.frozen == "0")
        #expect(value.unlocked == value.free)
        let maximum = "0x" + String(repeating: "00", count: 16) + String(repeating: "ff", count: 16) + String(repeating: "00", count: 48)
        #expect(try PolkadotAccountBalance.decode(maximum).free == "340282366920938463463374607431768211455")
        #expect(PolkadotAccountBalance(nonce: 0, free: "10", reserved: "100", frozen: "11").unlocked == "0")
        #expect(throws: (any Error).self) { try PolkadotAccountBalance.decode("0x00") }
    }
    @Test func readsRuntimeAndBalanceAtOneFinalizedBlock() async throws {
        let block = "0x" + String(repeating: "a", count: 64)
        let raw = self.raw
        PolkadotFixtureProtocol.handler = { request in
            let body = try Self.requestBody(request)
            let method = body["method"] as! String
            let params = body["params"] as! [Any]
            let result: Any
            switch method {
            case "chain_getBlockHash": result = PolkadotLedger.assetHub.genesis
            case "chain_getFinalizedHead": result = block
            case "state_getRuntimeVersion":
                #expect(params as? [String] == [block])
                result = ["specName": "statemint", "specVersion": 2005000, "transactionVersion": 15]
            case "state_getStorage":
                #expect(params.last as? String == block)
                result = raw
            default: throw PolkadotRPCError.invalidResponse
            }
            return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": body["id"]!, "result": result])
        }
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = PolkadotRPCClient(configuration: try configuration(), ledger: .assetHub, session: session)
        let result = try await client.accountBalance(address: address)
        #expect(result.blockHash == block)
        #expect(result.balance.free == "10071900508")
    }
    @Test func rejectsRelayAsHubBeforeReadingBalance() async throws {
        PolkadotFixtureProtocol.handler = { request in
            let body = try Self.requestBody(request)
            #expect(body["method"] as? String == "chain_getBlockHash")
            return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": body["id"]!, "result": PolkadotLedger.relay.genesis])
        }
        let session = session()
        defer { session.invalidateAndCancel() }
        let client = PolkadotRPCClient(configuration: try configuration(), ledger: .assetHub, session: session)
        await #expect(throws: (any Error).self) { try await client.accountBalance(address: address) }
    }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PolkadotFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw PolkadotRPCError.invalidResponse }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
private final class PolkadotFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

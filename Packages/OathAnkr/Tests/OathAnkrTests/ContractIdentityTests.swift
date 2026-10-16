import XCTest
@testable import OathAnkr

@MainActor final class ContractIdentityTests: XCTestCase {
    private let token = "0x" + String(repeating: "a", count: 40)
    private let owner = "0x" + String(repeating: "1", count: 40)
    private let spender = "0x" + String(repeating: "2", count: 40)

    func testPermit2UsesTokenAndNFTUsesCollection() throws {
        for kind in [WalletPermission.Kind.permit2, .permit2Nonce] {
            let p = WalletPermission(network: "ethereum", owner: owner, contract: EVMPermissionRemoval.permit2,
                spender: spender, kind: kind, amount: "123:456:0", tokenID: token.uppercased())
            XCTAssertEqual(p.identityKey, "ethereum:" + token)
            XCTAssertEqual(p.spenderIdentityKey, "ethereum:" + spender)
            XCTAssertEqual(p.contract, EVMPermissionRemoval.permit2, "Display resolution must not change the revocation target")
        }
        let nft = WalletPermission(network: "ethereum", owner: owner, contract: token, spender: spender, kind: .collectible, amount: spender, tokenID: "123")
        XCTAssertEqual(nft.identityAddress, token)
        let delegation = WalletPermission(network: "ethereum", owner: owner, contract: owner, spender: spender, kind: .delegation, amount: spender)
        XCTAssertEqual(delegation.identityAddress, spender)
    }

    func testABITextAcceptsDynamicAndLegacyAndRejectsUnsafeValues() throws {
        XCTAssertEqual(ContractIdentity.abiText(Self.abi("Dai Stablecoin")), "Dai Stablecoin")
        XCTAssertEqual(ContractIdentity.abiText(Self.abi("MKR", legacy: true)), "MKR")
        for text in ["", "bad\u{202e}name", "bad\nname", String(repeating: "x", count: 257)] {
            XCTAssertNil(ContractIdentity.clean(text))
        }
        for raw in ["0x", "not hex", "0x" + String(repeating: "ff", count: 64), "0x" + String(repeating: "00", count: 31) + "20"] {
            XCTAssertNil(ContractIdentity.abiText(raw))
        }
        XCTAssertNil(ContractIdentity.abiText(String(Self.abi("Name").dropLast(64))))
        let value = try ContractIdentity(network: "ethereum", address: token.uppercased().replacingOccurrences(of: "0X", with: "0x"), name: " Name ", source: .onChain)
        XCTAssertEqual(value.address, token); XCTAssertEqual(value.name, "Name")
        XCTAssertThrowsError(try ContractIdentity(network: "ethereum", address: token, name: "Name", decimals: 256, source: .onChain))
    }

    func testOnchainNameDoesNotRequireDecimalsOrBalance() async throws {
        let transport = IdentityRPC(name: Self.abi("Collection"), symbol: Self.abi("NFT"), decimals: nil)
        let client = try EVMSendClient(network: .ethereum, endpoints: [URL(string: "https://rpc.example")!], transport: transport)
        let result = try await client.permissionIdentity(address: token)
        XCTAssertEqual(result?.name, "Collection"); XCTAssertEqual(result?.symbol, "NFT"); XCTAssertNil(result?.decimals)
        let methods = await transport.selectors
        XCTAssertEqual(Set(methods), ["0x06fdde03", "0x95d89b41", "0x313ce567"])
    }

    func testOnchainSymbolFallbackAndDecimals() async throws {
        let transport = IdentityRPC(name: nil, symbol: Self.abi("MKR", legacy: true), decimals: "0x12")
        let client = try EVMSendClient(network: .ethereum, endpoints: [URL(string: "https://rpc.example")!], transport: transport)
        let result = try await client.permissionIdentity(address: token)
        XCTAssertEqual(result?.name, "MKR"); XCTAssertEqual(result?.decimals, 18)
    }

    func testNoIdentityInventedForEmptyOrWrongChainResponse() async throws {
        for transport in [IdentityRPC(), IdentityRPC(name: Self.abi("Wrong chain token"), chain: "0x38")] {
            let client = try EVMSendClient(network: .ethereum, endpoints: [URL(string: "https://rpc.example")!], transport: transport)
            let result = try await client.permissionIdentity(address: token)
            XCTAssertNil(result)
        }
    }

    func testRegistryChecksChainAddressAndRuntimeVerification() async throws {
        let good = registry()
        let result = try await ContractIdentityClient(transport: IdentityHTTP(json: good)).verifiedContract(network: .ethereum, address: token)
        XCTAssertEqual(result?.name, "AllowanceHolder"); XCTAssertEqual(result?.source, .sourcify)
        for bad in [registry(chain: "56"), registry(address: spender)] {
            do {
                _ = try await ContractIdentityClient(transport: IdentityHTTP(json: bad)).verifiedContract(network: .ethereum, address: token)
                XCTFail("Accepted wrong network/address")
            } catch { XCTAssertEqual(error as? AnkrError, .wrongChain) }
        }
        let unverified = try await ContractIdentityClient(transport: IdentityHTTP(json: registry(runtime: nil))).verifiedContract(network: .ethereum, address: token)
        XCTAssertNil(unverified)
    }

    func testRegistryMissingAndProviderFailureAreDifferent() async throws {
        let missing = try await ContractIdentityClient(transport: IdentityHTTP(json: .null, status: 404)).verifiedContract(network: .ethereum, address: token)
        XCTAssertNil(missing)
        do {
            _ = try await ContractIdentityClient(transport: IdentityHTTP(json: .null, status: 429)).verifiedContract(network: .ethereum, address: token)
            XCTFail("Rate limiting must not become a successful lookup")
        } catch { XCTAssertEqual(error as? AnkrError, .http(429)) }
    }

    func testRegistryOnlyRequestsNameAndRejectsUnsafeNames() async throws {
        let transport = IdentityHTTP(json: registry(name: "fake\u{202e}name"))
        let value = try await ContractIdentityClient(transport: transport).verifiedContract(network: .ethereum, address: token)
        XCTAssertNil(value)
        let captured = await transport.request()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [.init(name: "fields", value: "compilation.name")])
    }

    private func registry(chain: String = "1", address: String? = nil, runtime: String? = "match", name: String = "AllowanceHolder") -> SolanaJSON {
        .object(["chainId": .string(chain), "address": .string(address ?? token), "runtimeMatch": runtime.map(SolanaJSON.string) ?? .null,
                 "compilation": .object(["name": .string(name)])])
    }
    static func abi(_ text: String, legacy: Bool = false) -> String {
        let bytes = Data(text.utf8)
        if legacy { return "0x" + TronSendCrypto.hex(bytes + Data(repeating: 0, count: 32 - bytes.count)) }
        return "0x" + String(repeating: "0", count: 62) + "20" + String(format: "%064x", bytes.count)
            + TronSendCrypto.hex(bytes) + String(repeating: "0", count: ((32 - bytes.count % 32) % 32) * 2)
    }
}

private actor IdentityRPC: AnkrTransport {
    let name: String?, symbol: String?, decimals: String?, chain: String
    var selectors = [String]()
    init(name: String? = nil, symbol: String? = nil, decimals: String? = nil, chain: String = "0x1") {
        self.name = name; self.symbol = symbol; self.decimals = decimals; self.chain = chain
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
        let rows = try XCTUnwrap(body.array)
        let selector = rows[1]["params"].array?[0]["data"].string ?? ""
        selectors.append(selector)
        let value = selector == "0x06fdde03" ? name : selector == "0x95d89b41" ? symbol : decimals
        let field: SolanaJSON = value.map { .object(["jsonrpc": .string("2.0"), "id": .number("1"), "result": .string($0)]) }
            ?? .object(["jsonrpc": .string("2.0"), "id": .number("1"), "error": .object(["code": .number("3"), "message": .string("execution reverted")])])
        return (try JSONEncoder().encode(SolanaJSON.array([
            .object(["jsonrpc": .string("2.0"), "id": .number("0"), "result": .string(chain)]), field])), 200)
    }
}

private actor IdentityHTTP: AnkrTransport {
    let json: SolanaJSON, status: Int
    var lastRequest: URLRequest?
    init(json: SolanaJSON, status: Int = 200) { self.json = json; self.status = status }
    func request() -> URLRequest? { lastRequest }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lastRequest = request
        return (try JSONEncoder().encode(json), status)
    }
}

@MainActor final class ContractIdentityPublicTests: XCTestCase {
    /// Read-only public calls. No wallet, signature, transaction, or funded account.
    func testRealTokenNFTAndSpenderNames() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_CONTRACT_IDENTITIES"] == "1" else { throw XCTSkip("Opt-in public metadata lookup") }
        let cases: [(EVMSendNetwork, String, String, String)] = [
            (.ethereum, "https://ethereum-rpc.publicnode.com", "0x6b175474e89094c44da98b954eedeac495271d0f", "Dai Stablecoin"),
            (.ethereum, "https://ethereum-rpc.publicnode.com", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "USD Coin"),
            (.ethereum, "https://ethereum-rpc.publicnode.com", "0xdac17f958d2ee523a2206206994597c13d831ec7", "Tether USD"),
            (.ethereum, "https://ethereum-rpc.publicnode.com", "0xbc4ca0eda7647a8ab7c2061c2e118a18a936f13d", "BoredApeYachtClub"),
            (.base, "https://base-rpc.publicnode.com", "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", "USD Coin"),
            (.bnb, "https://bsc-rpc.publicnode.com", "0x55d398326f99059ff775485246999027b3197955", "Tether USD")
        ]
        for (chain, endpoint, address, expected) in cases {
            let client = try EVMSendClient(network: chain, endpoints: [URL(string: endpoint)!])
            let value = try await client.permissionIdentity(address: address)
            XCTAssertEqual(value?.name, expected, chain.rawValue)
            XCTAssertEqual(value?.address, address)
            print("IDENTITY_PUBLIC \(chain.rawValue) \(expected): \(value?.name == expected ? "PASS" : "FAIL")")
        }
        let registry = ContractIdentityClient()
        for (address, expected) in [
            ("0x0000000000001ff3684f28c67538d4d072c22734", "AllowanceHolder"),
            (EVMPermissionRemoval.permit2, "Permit2"),
            ("0x111111125421ca6dc452d289314280a0f8842a65", "AggregationRouterV6")
        ] {
            let value = try await registry.verifiedContract(network: .ethereum, address: address)
            XCTAssertEqual(value?.name, expected)
            print("IDENTITY_REGISTRY \(expected): \(value?.name == expected ? "PASS" : "FAIL")")
        }
    }
}

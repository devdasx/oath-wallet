import Foundation
import Synchronization
import Testing
import WalletCore
@testable import Aperture

/// All URLs are intercepted. The keys are disposable fixture bytes; this suite
/// never reads a wallet vault or submits a transaction to a network.
@Suite(.serialized)
struct SendPreparationConcurrencyTests {
    @Test(arguments: ["eth", "bsc", "arbitrum", "base", "polygon", "optimism",
                      "avalanche", "gnosis", "linea", "scroll", "taiko", "telos", "xlayer"])
    func evmMetadataOverlapsStateReadsAndBroadcastsOnce(network: String) async throws {
        try await runEVM(network: network, invalidMetadata: false)
    }

    @Test
    func invalidMetadataStillPreventsSigningAndBroadcast() async throws {
        try await runEVM(network: "eth", invalidMetadata: true)
    }

    private func runEVM(network: String, invalidMetadata: Bool) async throws {
        let fixture = try makeFixture(network: network, coin: .ethereum, token: true)
        let chainID = try #require(ReceiveNetworkCatalog.network(for: network)?.chainID)
        let probe = PreparationProbe(kind: .evm(chainID, invalidMetadata), sender: fixture.material.account.address)
        let session = PreparationURLProtocol.session(probe: probe)
        defer { session.invalidateAndCancel() }
        let endpoint = try #require(URL(string: "https://preparation.example/evm"))
        let rpc = try SendEVMRPCClient(networkID: network, session: session,
                                      endpoints: [endpoint], submissionEndpoints: [endpoint])
        do {
            let receipt = try await SendEVMTransactionService(rpc: rpc).submit(
                draft: fixture.draft, material: fixture.material, reservation: probe)
            #expect(!invalidMetadata)
            #expect(receipt.amountAtomic == "1000000")
            #expect(receipt.networkID == network)
            let reservedHash = await probe.reservedHash
            #expect(receipt.transactionHash == reservedHash)
        } catch let error as SendTransactionSubmissionError {
            #expect(invalidMetadata)
            guard case .tokenMetadataMismatch = error else { throw error }
        }
        #expect(await probe.allIndependentRequestsStarted)
        #expect(await probe.broadcasts == (invalidMetadata ? 0 : 1))
        #expect(await probe.reservations == (invalidMetadata ? 0 : 1))
    }

    @Test(arguments: [false, true])
    func solanaFeeAndRentOverlapWithoutSkippingAffordability(insufficient: Bool) async throws {
        let fixture = try makeFixture(network: "solana", coin: .solana, token: false)
        let probe = PreparationProbe(kind: .solana(insufficient), sender: fixture.material.account.address)
        let session = PreparationURLProtocol.session(probe: probe)
        defer { session.invalidateAndCancel() }
        let endpoint = try #require(URL(string: "https://preparation.example/solana"))
        let rpc = SendSolanaRPCClient(session: session, endpoints: [endpoint])
        do {
            let receipt = try await SendSolanaTransactionService(rpc: rpc).submit(
                draft: fixture.draft, material: fixture.material, reservation: probe)
            #expect(!insufficient)
            #expect(receipt.amountAtomic == "1000000000")
            #expect(receipt.networkFeeAtomic == "5000")
        } catch let error as SendTransactionSubmissionError {
            #expect(insufficient)
            guard case .insufficientNetworkFeeBalance = error else { throw error }
        }
        #expect(await probe.allIndependentRequestsStarted)
        #expect(await probe.broadcasts == (insufficient ? 0 : 1))
        #expect(await probe.reservations == (insufficient ? 0 : 1))
    }

    @Test(arguments: [false, true])
    func nearTokenReadsOverlapWithoutSkippingAccessKeyValidation(restricted: Bool) async throws {
        let fixture = try makeFixture(network: "near", coin: .near, token: true)
        let probe = PreparationProbe(kind: .near(restricted), sender: fixture.material.account.address)
        let endpoint = try #require(URL(string: "https://preparation.example/near"))
        let transport = try NEARJSONRPCTransport(endpoint: endpoint,
            router: AdaptiveProviderRouter(persistsHealth: false)) { request in
                let data = try await probe.response(request)
                return (data, HTTPURLResponse(url: endpoint, statusCode: 200,
                                              httpVersion: nil, headerFields: nil)!)
            }
        do {
            let receipt = try await SendNEARTransactionService(api: NEARAPIClient(transport: transport)).submit(
                draft: fixture.draft, material: fixture.material, reservation: probe)
            #expect(!restricted)
            #expect(receipt.amountAtomic == "1000000")
        } catch let error as SendTransactionSubmissionError {
            #expect(restricted)
            guard case let .provider(_, code, _) = error,
                  code == "near_access_key_not_full_access" else { throw error }
        }
        #expect(await probe.allIndependentRequestsStarted)
        #expect(await probe.broadcasts == (restricted ? 0 : 1))
        #expect(await probe.reservations == (restricted ? 0 : 1))
    }

    private func makeFixture(network: String, coin: CoinType, token: Bool) throws
        -> (draft: SendDraft, material: SendResolvedSigningMaterial) {
        let key = try #require(PrivateKey(data: Data(repeating: 7, count: 32)))
        let sender = coin.deriveAddress(privateKey: key)
        let receiver = coin.deriveAddress(privateKey: try #require(PrivateKey(data: Data(repeating: 8, count: 32))))
        let blockchain: WalletBlockchain = network == "solana" ? .solana : network == "near" ? .near : .ethereum
        let asset = SendAssetChoice(id: network + (token ? ":token" : ":native"), name: "Fixture", symbol: "FIX",
            networkID: network, networkName: network, blockchain: blockchain,
            contractAddress: token ? (network == "near" ? "wrap.near" : "0x0000000000000000000000000000000000000001") : nil,
            decimals: token ? 6 : 9, logoSource: .nativeCoin(blockchain: blockchain),
            networkLogoSource: .nativeCoin(blockchain: blockchain), balance: 2, fiatValue: 0,
            balanceAtomic: token ? "2000000" : "2000000000", sourceAddress: sender)
        let account = DBWalletAccountRecord(id: "fixture-account", walletID: "fixture-wallet", networkID: network,
            address: sender, normalizedAddress: sender, label: nil, derivationPath: nil, accountIndex: 0,
            publicKey: nil, isWatchOnly: false, isEnabled: true, createdAt: 1, updatedAt: 1, lastSyncedAt: nil)
        return (SendDraft(request: .manualEntry(networkID: network), asset: asset,
                          recipient: receiver, amount: "1", note: nil),
                SendResolvedSigningMaterial(walletID: account.walletID, account: account, privateKey: key.data))
    }
}

private actor PreparationProbe: SendSpendSubmissionReserving {
    enum Kind: Sendable { case evm(Int, Bool), solana(Bool), near(Bool) }
    let kind: Kind
    let sender: String
    var seen: Set<String> = []
    var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var broadcasts = 0
    var reservations = 0
    var reservedHash: String?

    init(kind: Kind, sender: String) { self.kind = kind; self.sender = sender }

    var expected: Set<String> {
        switch kind {
        case .evm: ["decimals", "eth_chainId", "eth_getTransactionCount", "eth_getBalance", "eth_estimateGas", "tokenBalance"]
        case .solana: ["getFeeForMessage", "getMinimumBalanceForRentExemption", "recipient"]
        case .near: ["view_access_key", "sender", "recipient", "EXPERIMENTAL_protocol_config", "ft_balance_of", "storage_balance_of"]
        }
    }
    var allIndependentRequestsStarted: Bool { expected.isSubset(of: seen) }

    // No sleeps: each independent response is held until every required read
    // has actually started. Reintroducing a serial dependency fails by timeout.
    private func arrive(_ name: String) async throws {
        guard expected.contains(name) else { return }
        seen.insert(name)
        if allIndependentRequestsStarted {
            let pending = waiters.values
            waiters.removeAll()
            for continuation in pending { continuation.resume() }
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func markSubmissionStarted(receipt: SendTransactionReceipt) throws {
        #expect(allIndependentRequestsStarted)
        #expect(broadcasts == 0)
        reservations += 1
        reservedHash = receipt.transactionHash
    }

    func response(_ request: URLRequest) async throws -> Data {
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            data = body
        } else { throw URLError(.badServerResponse) }
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let method = try #require(body["method"] as? String)
        let params = body["params"] as? [Any] ?? []
        let nearParams = body["params"] as? [String: Any] ?? [:]
        let call = (params.first as? [String: Any])?["data"] as? String ?? ""
        var name = method
        switch kind {
        case .evm:
            if call.hasPrefix("0x313ce567") { name = "decimals" }
            if call.hasPrefix("0x70a08231") { name = "tokenBalance" }
        case .solana:
            if method == "getAccountInfo", params.first as? String != sender { name = "recipient" }
        case .near:
            if method == "query" {
                name = nearParams["method_name"] as? String ?? nearParams["request_type"] as? String ?? method
                if name == "view_account" { name = nearParams["account_id"] as? String == sender ? "sender" : "recipient" }
            }
        }
        try await arrive(name)
        let result: Any
        switch kind {
        case let .evm(chainID, invalidMetadata):
            switch name {
            case "decimals": result = "0x" + SendEVMRollupFee.word(invalidMetadata ? 18 : 6)
            case "tokenBalance": result = "0x" + SendEVMRollupFee.word(2_000_000)
            case "eth_chainId": result = "0x" + String(chainID, radix: 16)
            case "eth_getTransactionCount": result = "0x0"
            case "eth_getBalance": result = "0x8ac7230489e80000"
            case "eth_estimateGas": result = "0xc350"
            case "eth_call": result = "0x" + SendEVMRollupFee.word(0) // Rollup oracle only.
            case "eth_sendRawTransaction":
                try recordBroadcast()
                let encoded = try #require(params.first as? String)
                let raw = try #require(Data(hexString: String(encoded.dropFirst(2))))
                result = "0x" + Hash.keccak256(data: raw).hexString
                #expect(result as? String == reservedHash)
            default: throw URLError(.unsupportedURL)
            }
        case let .solana(insufficient):
            switch name {
            case "getLatestBlockhash": result = ["value": ["blockhash": String(repeating: "1", count: 32)]]
            case "getAccountInfo", "recipient":
                result = ["value": ["lamports": 2_000_000_000, "space": 0, "data": ["", "base64"], "owner": String(repeating: "1", count: 32)]]
            case "getFeeForMessage": result = ["value": insufficient ? 3_000_000_000 : 5000]
            case "getMinimumBalanceForRentExemption": result = 890880
            case "sendTransaction":
                try recordBroadcast()
                let options = try #require(params.last as? [String: Any])
                #expect(options["skipPreflight"] as? Bool != true)
                let encoded = try #require(params.first as? String)
                let signature = try SendSolanaTransactionService.locallyEmbeddedSignature(fromBase64Transaction: encoded)
                result = Base58.encodeNoCheck(data: signature)
                #expect(result as? String == reservedHash)
            default: throw URLError(.unsupportedURL)
            }
        case let .near(restricted):
            switch name {
            case "view_access_key": result = ["nonce": 1, "block_hash": String(repeating: "1", count: 32), "permission": restricted ? "FunctionCall" : "FullAccess"]
            case "sender", "recipient": result = ["amount": "100000000000000000000000000", "locked": "0", "storage_usage": 100]
            case "EXPERIMENTAL_protocol_config": result = ["chain_id": "mainnet", "runtime_config": ["storage_amount_per_byte": "10000000000000000000"]]
            case "ft_balance_of": result = ["result": Array(Data("\"2000000\"".utf8))]
            case "storage_balance_of": result = ["result": Array(Data("{\"total\":\"1000\",\"available\":\"0\"}".utf8))]
            case "send_tx":
                try recordBroadcast()
                #expect(nearParams["wait_until"] as? String == "EXECUTED")
                let encoded = try #require(nearParams["signed_tx_base64"] as? String)
                #expect(try #require(Data(base64Encoded: encoded)).count > 65)
                result = ["transaction": ["hash": try #require(reservedHash)], "status": ["SuccessValue": ""]]
            default: throw URLError(.unsupportedURL)
            }
        }
        return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": body["id"] ?? 1, "result": result])
    }

    private func recordBroadcast() throws {
        #expect(allIndependentRequestsStarted)
        #expect(reservations == 1)
        broadcasts += 1
        #expect(broadcasts == 1)
    }
}

private final class PreparationURLProtocol: URLProtocol, @unchecked Sendable {
    private static let probe = Mutex<PreparationProbe?>(nil)
    private let work = Mutex<Task<Void, Never>?>(nil)

    static func session(probe: PreparationProbe) -> URLSession {
        Self.probe.withLock { $0 = probe }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PreparationURLProtocol.self]
        return URLSession(configuration: config)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let task = Task { @Sendable [self] in
            do {
                let probe = try #require(Self.probe.withLock { $0 })
                let data = try await probe.response(self.request)
                try Task.checkCancellation()
                let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 200,
                                                           httpVersion: nil, headerFields: nil))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        work.withLock { $0 = task }
    }
    override func stopLoading() { work.withLock { $0?.cancel() } }
}

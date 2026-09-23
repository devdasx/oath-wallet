import Foundation
import GRDB
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct NEARSupportTests {
    private static let mnemonic =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    fileprivate static let derivedAddress =
        "5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412"

    @Test
    func walletCoreDerivesPublishedImplicitAccountVector() throws {
        let wallet = try #require(
            BIP39Mnemonic.hdWallet(mnemonic: Self.mnemonic)
        )
        let key = try #require(
            wallet.getKey(
                coin: .near,
                derivationPath: NEARConstants.derivationPath
            )
        )
        let material = try NEARAddress.material(
            privateKey: key,
            derivationPath: NEARConstants.derivationPath
        )

        #expect(material.address == Self.derivedAddress)
        #expect(material.derivationPath == "m/44'/397'/0'")
        #expect(material.publicKey.hasPrefix("ed25519:"))
        #expect(NEARAddress.isValid("root.near"))
        #expect(!NEARAddress.isValid("Root.near"))
        #expect(!NEARAddress.isValid("bad..near"))
    }

    @Test
    func nearPaymentURIUsesMainnetAndTwentyFourDecimals() throws {
        let request = try SendPaymentRequestParser.parse(
            "near:alice.near?amount=1.250000000000000000000000"
        )

        #expect(request.source == .nearURI)
        #expect(request.recipient == "alice.near")
        #expect(request.candidateNetworkIDs == [NEARConstants.networkID])
        #expect(request.requestedNetworkID == NEARConstants.networkID)
        #expect(request.requestedAsset == .native)
        #expect(request.requestedAmount == .userUnits("1.25"))
        #expect(
            SendAddressValidator.isValid(
                "alice.near",
                for: NEARConstants.networkID
            )
        )
        #expect(throws: SendPaymentRequestError.invalidAmount) {
            try SendPaymentRequestParser.parse(
                "near:alice.near?amount=0.0000000000000000000000001"
            )
        }
    }

    @Test
    func amountConversionAndUInt128EncodingAreLossless() throws {
        #expect(
            try NEARAPIClient.userUnits(
                atomic: "1250000000000000000000000",
                decimals: 24
            ) == "1.25"
        )
        #expect(
            try NEARAPIClient.userUnits(atomic: "1", decimals: 24)
                == "0.000000000000000000000001"
        )
        #expect(
            try SendNEARTransactionService.uint128LittleEndian("1")
                == Data([1] + Array(repeating: 0, count: 15))
        )
        #expect(
            throws: SendTransactionSubmissionError.amountOutOfRange
        ) {
            try SendNEARTransactionService.uint128LittleEndian(
                "340282366920938463463374607431768211456"
            )
        }
    }

    @Test
    func storageReserveMatchesMainnetConsensusRules() throws {
        let config = NEARProtocolConfig(
            chainID: "mainnet",
            storageAmountPerByte: "10000000000000000000"
        )
        #expect(try SendNEARTransactionService.storageReserve(
            accountState: NEARAccountState(
                amount: "1", locked: "0", storageUsage: 770
            ),
            protocolConfig: config
        ) == "0")
        #expect(try SendNEARTransactionService.storageReserve(
            accountState: NEARAccountState(
                amount: "1", locked: "10000000000000000000",
                storageUsage: 771
            ),
            protocolConfig: config
        ) == "7700000000000000000000")
    }

    @Test
    func transportPreservesNestedUnknownAccountCause() async throws {
        let fixture = NEARRPCFixture(mode: .unknownAccount)
        let transport = try Self.transport(fixture: fixture)
        do {
            _ = try await transport.request(
                method: "query",
                parameters: .object([
                    "request_type": .string("view_account")
                ])
            )
            Issue.record("Expected the fixture account to be unknown.")
        } catch let error as NEARProviderError {
            guard case let .rpc(code, message) = error else {
                Issue.record("Unexpected NEAR error: \(error)")
                return
            }
            #expect(code == -32_000)
            #expect(message == "unknown_account")
        }
    }

    @Test
    func transportFallsBackAfterTransientRPCErrorReturnedWithHTTP422()
        async throws
    {
        let primary = try #require(
            URL(string: "https://near-fee-primary.example.test")
        )
        let fallback = try #require(
            URL(string: "https://near-fee-fallback.example.test")
        )
        let probe = NEARFeeFallbackProbe(
            primary: primary,
            fallback: fallback
        )
        let transport = try NEARJSONRPCTransport(
            endpoints: [primary, fallback],
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            try await probe.response(for: request)
        }

        let result = try await transport.request(
            method: "gas_price",
            parameters: .array([.null])
        )

        #expect(result.objectValue?["gas_price"]?.stringValue == "100000000")
        #expect(await probe.requestedHosts() == [
            "near-fee-primary.example.test",
            "near-fee-fallback.example.test"
        ])
    }

    @Test
    func currentSendTxRequestPreservesFinalExecutionFailure()
        async throws
    {
        let fixture = NEARSubmissionFixture(mode: .executionFailed)
        let endpoint = try #require(
            URL(string: "https://near-submit.example.test")
        )
        let transport = try NEARJSONRPCTransport(
            endpoint: endpoint,
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            try await fixture.response(for: request)
        }
        let client = NEARAPIClient(transport: transport)

        let result = try await client.submit(
            signedTransaction: Data([1, 2, 3])
        )

        #expect(result.transactionHash == "fixture-near-hash")
        #expect(!result.succeeded)
        #expect(
            result.providerStatus
                == "actionerror_kind_functioncallerror_executionerror"
        )
        #expect(await fixture.requestedMethod == "send_tx")
        #expect(await fixture.requestedWaitUntil == "EXECUTED")
        #expect(await fixture.requestedSignedTransaction == "AQID")
    }

    @Test
    func signedSubmissionNeverFailsOverAfterAmbiguousFailure() async throws {
        let fixture = NEARSubmissionFixture(mode: .timedOut)
        let primary = try #require(
            URL(string: "https://near-submit-primary.example.test")
        )
        let fallback = try #require(
            URL(string: "https://near-submit-fallback.example.test")
        )
        let transport = try NEARJSONRPCTransport(
            endpoints: [primary, fallback],
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            try await fixture.response(for: request)
        }

        do {
            _ = try await transport.request(
                method: "send_tx",
                parameters: .object([
                    "signed_tx_base64": .string("AQID"),
                    "wait_until": .string("EXECUTED")
                ])
            )
            Issue.record("Timed-out NEAR submission unexpectedly succeeded.")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected NEAR submission error: \(error)")
        }

        #expect(await fixture.requestedHosts.count == 1)
        #expect(
            await fixture.requestedHosts
                == ["near-submit-primary.example.test"]
        )
    }

    @Test
    func submissionErrorClassifierOnlyRetriesProvenPreflightRejections() {
        #expect(
            NEARSubmissionErrorClassifier
                .isDefinitivePreSubmissionRejection(
                    .rpc(code: -32_700, message: "parse_error")
                )
        )
        #expect(
            !NEARSubmissionErrorClassifier
                .isDefinitivePreSubmissionRejection(
                    .rpc(code: -32_000, message: "invalid_transaction")
                )
        )
        #expect(
            NEARSubmissionErrorClassifier
                .isDefinitivePreSubmissionRejection(
                    .rpc(code: -32_000, message: "expired_transaction")
                )
        )
        #expect(
            NEARSubmissionErrorClassifier
                .isDefinitivePreSubmissionRejection(
                    .rpc(code: -32_000, message: "invalid_signature")
                )
        )
        #expect(
            !NEARSubmissionErrorClassifier
                .isDefinitivePreSubmissionRejection(
                    .rpc(code: -32_603, message: "internal_error")
                )
        )
        #expect(
            !NEARSubmissionErrorClassifier
                .isDefinitivePreSubmissionRejection(
                    .rpc(code: -32_000, message: "timeout_error")
                )
        )
        #expect(
            !NEARSubmissionErrorClassifier
                .isDefinitivePreSubmissionRejection(
                    .http(status: 503, code: "unavailable")
                )
        )
    }

    @Test
    func providerLoadsNativeTokenAndNativeAndTokenHistory()
        async throws
    {
        NEARFixtureURLProtocol.install(mode: .full)
        let fixture = NEARRPCFixture(mode: .funded)
        let client = NEARAPIClient(
            transport: try Self.transport(fixture: fixture),
            session: Self.fixtureSession(),
            historyRouter: AdaptiveProviderRouter(persistsHealth: false)
        )
        let probe = NEARBalanceSnapshotProbe()
        let snapshot = try await client.loadSnapshot(
            material: Self.material
        ) { partial in
            await probe.record(partial)
        }
        let accountState = try await client.accountState(
            accountID: Self.derivedAddress
        )
        let protocolConfig = try await client.protocolConfig()

        #expect(await probe.recordCount == 2)
        #expect(accountState.storageUsage == 100)
        #expect(protocolConfig.chainID == "mainnet")
        #expect(await probe.firstBalanceCount == 1)
        #expect(await probe.firstNativeAtomicAmount
            == "2000000000000000000000000")
        #expect(await probe.historyCount == 0)
        #expect(snapshot.balancesAreAuthoritative)
        #expect(snapshot.historyIsAuthoritative)
        #expect(snapshot.providerFailureCodes.isEmpty)
        #expect(snapshot.balances.count == 2)
        #expect(snapshot.balances[0].amountText == "2")
        let token = try #require(snapshot.balances.first { $0.metadata != nil })
        #expect(token.metadata?.contractID == "usdt.tether-token.near")
        #expect(token.metadata?.symbol == "USDt")
        #expect(token.amountText == "1.5")
        #expect(snapshot.history.count == 2)
        #expect(
            snapshot.history.contains {
                $0.metadata == nil && $0.signedAmountText == "-1"
            }
        )
        #expect(
            snapshot.history.contains {
                $0.metadata?.symbol == "USDt"
                    && $0.signedAmountText == "1.5"
            }
        )
    }

    @Test
    func unfundedAccountProducesAuthoritativeNativeZero() async throws {
        NEARFixtureURLProtocol.install(mode: .empty)
        let fixture = NEARRPCFixture(mode: .unknownAccount)
        let client = NEARAPIClient(
            transport: try Self.transport(fixture: fixture),
            session: Self.fixtureSession(),
            historyRouter: AdaptiveProviderRouter(persistsHealth: false)
        )
        let snapshot = try await client.loadSnapshot(material: Self.material)

        #expect(snapshot.balancesAreAuthoritative)
        #expect(snapshot.historyIsAuthoritative)
        #expect(snapshot.providerFailureCodes.isEmpty)
        #expect(snapshot.balances.count == 1)
        #expect(snapshot.balances[0].atomicAmount == "0")
        #expect(snapshot.balances[0].amountText == "0")
    }

    @Test
    func unavailableTokenIndexIsPartialAndPreservesCachedTokens()
        async throws
    {
        // The production catalog is runtime/database backed; seed this test's
        // token explicitly rather than depending on a previous app sync.
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer { ReceiveAssetCatalogRuntime.install(previous.tokens, revision: previous.revision) }
        ReceiveAssetCatalogRuntime.install([
            ReceiveToken(id: "near-usdt-fixture", name: "Tether", symbol: "USDT", rank: 1,
                isStablecoin: true, variants: [ReceiveTokenVariant(
                    networkID: "near", contractAddress: "usdt.tether-token.near", decimals: 6,
                    networkRank: 1, logoURL: nil
                )])
        ], revision: 1)
        NEARFixtureURLProtocol.install(mode: .indexUnavailable)
        let fixture = NEARRPCFixture(mode: .funded)
        let client = NEARAPIClient(
            transport: try Self.transport(fixture: fixture),
            session: Self.fixtureSession(),
            historyRouter: AdaptiveProviderRouter(persistsHealth: false)
        )
        let partial = try await client.loadSnapshot(material: Self.material)

        #expect(!partial.balancesAreAuthoritative)
        #expect(
            await fixture.requestedTokenContracts.contains(
                "usdt.tether-token.near"
            )
        )
        let requestedTokenContracts = await fixture.requestedTokenContracts
        #expect(
            partial.balances.count == 2,
            "Failures: \(partial.providerFailureCodes); contracts: \(requestedTokenContracts)"
        )
        #expect(
            partial.balances.contains {
                $0.metadata?.contractID == "usdt.tether-token.near"
                    && $0.atomicAmount == "1500000"
            }
        )
        #expect(
            partial.providerFailureCodes.contains(
                "near_http_503_near_fast_account_read"
            )
        )

        let database = try WalletDatabase.temporary()
        let walletID = "near-preservation-wallet"
        try await Self.insertWalletAndAccount(
            database: database,
            walletID: walletID
        )
        let metadata = NEARTokenMetadata(
            contractID: "custom.example.near",
            name: "Custom Token",
            symbol: "CUSTOM",
            decimals: 8,
            iconURL: nil,
            isVerified: true,
            rank: 20
        )
        let authoritative = NEARWalletSnapshot(
            material: Self.material,
            balances: [
                NEARAssetBalance(
                    metadata: nil,
                    amountText: "2",
                    atomicAmount: "2000000000000000000000000"
                ),
                NEARAssetBalance(
                    metadata: metadata,
                    amountText: "5",
                    atomicAmount: "5000000"
                )
            ],
            history: [],
            balancesAreAuthoritative: true,
            historyIsAuthoritative: true,
            providerFailureCodes: []
        )
        try await database.saveNEARSnapshot(
            authoritative,
            walletID: walletID
        )
        try await database.saveNEARSnapshot(partial, walletID: walletID)

        let storedToken = try await database.pool.read { connection in
            try DBAccountAssetRecord.fetchOne(
                connection,
                key: [
                    "accountID": "\(walletID):near:0",
                    "assetID": metadata.assetID
                ]
            )
        }
        #expect(storedToken?.balance == "5")
        #expect(storedToken?.balanceAtomic == "5000000")
    }

    @Test
    func walletCoreSignsNativeMainnetTransaction() throws {
        let wallet = try #require(
            BIP39Mnemonic.hdWallet(mnemonic: Self.mnemonic)
        )
        let key = try #require(
            wallet.getKey(
                coin: .near,
                derivationPath: NEARConstants.derivationPath
            )
        )
        let deposit = try SendNEARTransactionService.uint128LittleEndian(
            "1000000000000000000000000"
        )
        let output: NEARSigningOutput = AnySigner.sign(
            input: NEARSigningInput.with {
                $0.signerID = Self.derivedAddress
                $0.nonce = 9
                $0.receiverID = "receiver.near"
                $0.blockHash = Data(repeating: 7, count: 32)
                $0.actions = [
                    NEARAction.with {
                        $0.transfer = .with {
                            $0.deposit = deposit
                        }
                    }
                ]
                $0.privateKey = key.data
                $0.publicKey = key.getPublicKeyEd25519().data
            },
            coin: .near
        )

        #expect(output.error == .ok)
        #expect(output.hash.count == 32)
        #expect(!output.signedTransaction.isEmpty)
        #expect(!Base58.encodeNoCheck(data: output.hash).isEmpty)
    }

    private static var material: NEARAccountMaterial {
        NEARAccountMaterial(
            address: derivedAddress,
            publicKey: "ed25519:fixture",
            derivationPath: NEARConstants.derivationPath
        )
    }

    private static func transport(
        fixture: NEARRPCFixture
    ) throws -> NEARJSONRPCTransport {
        let host = "near-test-\(UUID().uuidString.lowercased()).example"
        return try NEARJSONRPCTransport(
            endpoint: URL(string: "https://\(host)/near")!,
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            try await fixture.response(for: request)
        }
    }

    private static func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NEARFixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func insertWalletAndAccount(
        database: WalletDatabase,
        walletID: String
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await database.pool.write { connection in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "NEAR Test Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: false,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: nil,
                archivedAt: nil
            ).insert(connection)
            try DBWalletAccountRecord(
                id: "\(walletID):near:0",
                walletID: walletID,
                networkID: NEARConstants.networkID,
                address: material.address,
                normalizedAddress: material.address,
                label: NEARConstants.accountLabel,
                derivationPath: NEARConstants.derivationPath,
                accountIndex: 0,
                publicKey: material.publicKey,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(connection)
        }
    }
}

private actor NEARSubmissionFixture {
    enum Mode: Sendable {
        case executionFailed
        case timedOut
    }

    private let mode: Mode
    private(set) var requestedHosts: [String] = []
    private(set) var requestedMethod: String?
    private(set) var requestedWaitUntil: String?
    private(set) var requestedSignedTransaction: String?

    init(mode: Mode) {
        self.mode = mode
    }

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        requestedHosts.append(request.url?.host ?? "")
        if mode == .timedOut {
            throw URLError(.timedOut)
        }
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        requestedMethod = object["method"] as? String
        let parameters = object["params"] as? [String: Any]
        requestedWaitUntil = parameters?["wait_until"] as? String
        requestedSignedTransaction =
            parameters?["signed_tx_base64"] as? String
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        )
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "aperture",
            "result": [
                "transaction": ["hash": "fixture-near-hash"],
                "status": [
                    "Failure": [
                        "ActionError": [
                            "index": 0,
                            "kind": [
                                "FunctionCallError": [
                                    "ExecutionError": "contract panic"
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        return (
            try JSONSerialization.data(withJSONObject: payload),
            response
        )
    }
}

private actor NEARFeeFallbackProbe {
    private let primary: URL
    private let fallback: URL
    private var hosts: [String] = []

    init(primary: URL, fallback: URL) {
        self.primary = primary
        self.fallback = fallback
    }

    func response(
        for request: URLRequest
    ) throws -> (Data, URLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        hosts.append(url.host ?? "")
        if url == primary {
            return try Self.response(
                url: url,
                status: 422,
                object: [
                    "jsonrpc": "2.0",
                    "id": "aperture",
                    "error": [
                        "code": -32_000,
                        "message": "Server error",
                        "data": "DB Not Found Error: UNKNOWN_BLOCK"
                    ]
                ]
            )
        }
        guard url == fallback else {
            throw URLError(.unsupportedURL)
        }
        return try Self.response(
            url: url,
            status: 200,
            object: [
                "jsonrpc": "2.0",
                "id": "aperture",
                "result": ["gas_price": "100000000"]
            ]
        )
    }

    func requestedHosts() -> [String] { hosts }

    private static func response(
        url: URL,
        status: Int,
        object: [String: Any]
    ) throws -> (Data, URLResponse) {
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (
            try JSONSerialization.data(withJSONObject: object),
            response
        )
    }
}

private actor NEARBalanceSnapshotProbe {
    private(set) var recordCount = 0
    private(set) var historyCount = -1
    private(set) var firstBalanceCount = -1
    private(set) var firstNativeAtomicAmount: String?

    func record(_ snapshot: NEARWalletSnapshot) {
        if recordCount == 0 {
            firstBalanceCount = snapshot.balances.count
            firstNativeAtomicAmount = snapshot.balances.first {
                $0.metadata == nil
            }?.atomicAmount
        }
        recordCount += 1
        historyCount = snapshot.history.count
    }
}

private actor NEARRPCFixture {
    enum Mode: Sendable, Equatable {
        case funded
        case unknownAccount
    }

    private let mode: Mode
    private var tokenContracts: [String] = []

    init(mode: Mode) { self.mode = mode }

    var requestedTokenContracts: [String] { tokenContracts }

    func response(for request: URLRequest) throws -> (Data, URLResponse) {
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let method = try #require(object["method"] as? String)
        let params = object["params"] as? [String: Any]
        let result: Any

        if method == "EXPERIMENTAL_protocol_config" {
            result = [
                "chain_id": "mainnet",
                "runtime_config": [
                    "storage_amount_per_byte": "10000000000000000000"
                ]
            ]
        } else if method == "query",
           params?["request_type"] as? String == "view_account" {
            if mode == .unknownAccount {
                return try envelope(
                    request: request,
                    payload: [
                        "jsonrpc": "2.0",
                        "id": "aperture",
                        "error": [
                            "code": -32_000,
                            "message": "Server error",
                            "data": [
                                "cause": ["name": "UNKNOWN_ACCOUNT"]
                            ]
                        ]
                    ]
                )
            }
            result = [
                "amount": "2000000000000000000000000",
                "locked": "0",
                "storage_usage": 100
            ]
        } else if method == "query",
                  params?["request_type"] as? String == "call_function" {
            if params?["method_name"] as? String == "ft_balance_of" {
                let contractID = params?["account_id"] as? String
                if let contractID { tokenContracts.append(contractID) }
                let balance = contractID == "usdt.tether-token.near"
                    ? "1500000" : "0"
                let balanceData = try JSONSerialization.data(
                    withJSONObject: balance,
                    options: [.fragmentsAllowed]
                )
                result = ["result": Array(balanceData)]
            } else {
                let metadata: [String: Any] = [
                    "spec": "ft-1.0.0",
                    "name": "Tether USD",
                    "symbol": "USDt",
                    "decimals": 6
                ]
                let metadataData = try JSONSerialization.data(
                    withJSONObject: metadata
                )
                result = ["result": Array(metadataData)]
            }
        } else {
            throw NEARProviderError.invalidResponse("fixture_method")
        }
        return try envelope(
            request: request,
            payload: [
                "jsonrpc": "2.0",
                "id": "aperture",
                "result": result
            ]
        )
    }

    private func envelope(
        request: URLRequest,
        payload: [String: Any]
    ) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (
            try JSONSerialization.data(withJSONObject: payload),
            response
        )
    }
}

private final class NEARFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable {
        case full
        case empty
        case indexUnavailable
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode: Mode = .empty

    static func install(mode: Mode) {
        lock.lock()
        self.mode = mode
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let fixtureMode = Self.mode
        Self.lock.unlock()
        guard let url = request.url else {
            fail(URLError(.badURL))
            return
        }

        if url.host == "api.fastnear.com" {
            switch fixtureMode {
            case .full:
                respond(
                    status: 200,
                    object: [
                        "state": [
                            "balance": "2000000000000000000000000"
                        ],
                        "tokens": [[
                            "balance": "1500000",
                            "contract_id": "usdt.tether-token.near"
                        ]]
                    ]
                )
            case .empty:
                respond(status: 404, object: [:])
            case .indexUnavailable:
                respond(status: 503, object: ["error": "unavailable"])
            }
            return
        }
        if url.host == "api.nearblocks.io" {
            if url.path.hasSuffix("/txns")
                || url.path.hasSuffix("/receipts")
                || url.path.hasSuffix("/ft-txns") {
                respond(
                    status: 200,
                    object: [
                        "data": [],
                        "meta": ["next_page": NSNull()]
                    ]
                )
            } else {
                fail(URLError(.unsupportedURL))
            }
            return
        }
        guard url.host == "tx.main.fastnear.com" else {
            fail(URLError(.unsupportedURL))
            return
        }
        if url.path == "/v0/account" {
            respond(
                status: 200,
                object: fixtureMode == .full
                    ? Self.historyPage : [
                        "account_txs": [],
                        "resume_token": NSNull()
                    ]
            )
        } else if url.path == "/v0/transactions" {
            respond(status: 200, object: Self.historyDetails)
        } else {
            fail(URLError(.unsupportedURL))
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, object: Any) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else {
            fail(URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }

    private static var historyPage: [String: Any] {
        [
            "account_txs": [
                [
                    "transaction_hash": "native-hash",
                    "tx_block_timestamp": "1700000000000000000",
                    "tx_block_height": 100,
                    "tx_index": 0,
                    "is_success": true
                ],
                [
                    "transaction_hash": "token-hash",
                    "tx_block_timestamp": "1700000001000000000",
                    "tx_block_height": 101,
                    "tx_index": 0,
                    "is_success": true
                ]
            ],
            "resume_token": NSNull()
        ]
    }

    private static var historyDetails: [String: Any] {
        let tokenArguments = try! JSONSerialization.data(
            withJSONObject: [
                "receiver_id": NEARSupportTests.derivedAddress,
                "amount": "1500000"
            ]
        ).base64EncodedString()
        return [
            "transactions": [
                [
                    "transaction": [
                        "hash": "native-hash",
                        "signer_id": NEARSupportTests.derivedAddress,
                        "receiver_id": "receiver.near",
                        "nonce": 7,
                        "actions": [[
                            "Transfer": [
                                "deposit": "1000000000000000000000000"
                            ]
                        ]]
                    ],
                    "execution_outcome": [
                        "outcome": ["tokens_burnt": "100000000000000000000"]
                    ],
                    "receipts": []
                ],
                [
                    "transaction": [
                        "hash": "token-hash",
                        "signer_id": "sender.near",
                        "receiver_id": "usdt.tether-token.near",
                        "nonce": 8,
                        "actions": [[
                            "FunctionCall": [
                                "method_name": "ft_transfer",
                                "args": tokenArguments
                            ]
                        ]]
                    ],
                    "execution_outcome": [
                        "outcome": ["tokens_burnt": "90000000000000000000"]
                    ],
                    "receipts": []
                ]
            ]
        ]
    }
}

import Foundation
import GRDB
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct AptosSupportTests {
    fileprivate static let owner =
        "0xe9c4d0b6fe32a5cc8ebd1e9ad5b54a0276a57f2d081dcb5e30342319963626c3"
    fileprivate static let recipient =
        "0xd503b95164384a5ebbccbb5c4bdc8b4a5893d9651e9953abda8e1c22fcc1181d"
    private static let privateKeyHex =
        "088baa019f081d6eab8dff5c447f9ce2f83c1babf3d03686299eaf6a1e89156e"
    static let tokenType =
        "0xabc::managed_coin::USDC"

    @Test
    func submissionClassifierDoesNotRetryConsumedSequenceEvidence() {
        #expect(
            !AptosSubmissionErrorClassifier.isDefinitiveRejection(
                .http(status: 400, code: "sequence_number_too_old")
            )
        )
        #expect(
            !AptosSubmissionErrorClassifier.isDefinitiveRejection(
                .http(status: 400, code: "invalid_transaction_update")
            )
        )
        #expect(
            AptosSubmissionErrorClassifier.isDefinitiveRejection(
                .http(status: 400, code: "invalid_signature")
            )
        )
        #expect(
            !AptosSubmissionErrorClassifier.isDefinitiveRejection(
                .http(status: 503, code: "internal_error")
            )
        )
    }

    @Test
    func submissionAcceptsOfficialPendingTransactionResponseWithoutType()
        async throws {
        AptosFixtureURLProtocol.prepare(mode: .submission)
        let result = try await Self.fixtureClient(mode: .submission).submit(
            signedTransaction: Data([0x01, 0x02, 0x03])
        )

        #expect(
            result.transactionHash
                == "0xf7f59c6de4f60d970f0c00148133b97865ae703be19a3698b478a1278b6350a8"
        )
    }

    @Test
    func walletCoreDerivesPublishedAptosAccountVector() throws {
        let keyData = try #require(Data(hexString: Self.privateKeyHex))
        let key = try #require(PrivateKey(data: keyData))
        let material = try AptosAddress.material(
            privateKey: key,
            derivationPath: AptosConstants.derivationPath
        )

        #expect(material.address == Self.owner)
        #expect(material.derivationPath == "m/44'/637'/0'/0'/0'")
        #expect(material.publicKey.count == 64)
        #expect(AptosAddress.canonical("0x1")?.count == 66)
        #expect(AptosAddress.canonical("0x0") == nil)
        #expect(AptosAddress.canonical("0xnot-hex") == nil)
    }

    @Test
    func mnemonicIdentityUsesWalletCoreCoinDerivation() throws {
        let phrase = "abandon abandon abandon abandon abandon abandon "
            + "abandon abandon abandon abandon abandon about"
        let hdWallet = try #require(
            BIP39Mnemonic.hdWallet(mnemonic: phrase)
        )
        let material = try AptosAddress.material(hdWallet: hdWallet)
        let walletCoreAddress = try #require(
            AptosAddress.canonical(
                hdWallet.getAddressForCoin(coin: .aptos)
            )
        )

        #expect(material.address == walletCoreAddress)
        #expect(material.derivationPath == AptosConstants.derivationPath)
        #expect(material.publicKey.count == 64)
    }

    @Test
    func fullWalletBootstrapNeverAssignsEVMIdentityToAptos() {
        let networks = [
            Self.network(id: "eth", chainID: 1),
            Self.network(
                id: AptosConstants.networkID,
                chainID: Int64(AptosConstants.databaseChainID)
            ),
            Self.network(id: XRPConstants.networkID, chainID: -144),
            Self.network(id: NEARConstants.networkID, chainID: -397)
        ]

        let selected = WalletDatabase.accountNetworks(
            from: networks,
            privateKeyNetwork: nil
        )

        #expect(selected.map(\.id) == ["eth"])
        #expect(WalletBlockchain.ethereum.isEVM)
        #expect(!WalletBlockchain.aptos.isEVM)
        #expect(!WalletBlockchain.xrp.isEVM)
        #expect(!WalletBlockchain.near.isEVM)
    }

    @Test
    func ensureAccountRepairsLegacyPaddedEVMIdentity() async throws {
        let keyData = try #require(Data(hexString: Self.privateKeyHex))
        let expected = try AptosAddress.material(
            privateKey: try #require(PrivateKey(data: keyData)),
            derivationPath: nil
        )
        let secretReference = try WalletSecretVault.shared.store(
            keyData,
            kind: .privateKey
        )
        defer {
            try? WalletSecretVault.shared.deleteIfPresent(
                reference: secretReference
            )
        }
        let database = try WalletDatabase.temporary()
        let walletID = "aptos-legacy-evm-identity"
        let legacyAccountID = "legacy-random-account"
        let legacyAddress = try #require(
            AptosAddress.canonical(
                "0x2271ba2bd6b40952889d3ecb8bd0faadfc8805bb"
            )
        )
        let now = Date().timeIntervalSince1970
        try await database.pool.write { connection in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Legacy Aptos Wallet",
                kind: DatabaseWalletKind.importedPrivateKey.rawValue,
                secretKeyReference: secretReference,
                isSelected: false,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: nil,
                archivedAt: nil
            ).insert(connection)
            try DBWalletAccountRecord(
                id: legacyAccountID,
                walletID: walletID,
                networkID: AptosConstants.networkID,
                address: legacyAddress,
                normalizedAddress: legacyAddress,
                label: nil,
                derivationPath: nil,
                accountIndex: 0,
                publicKey: String(repeating: "0", count: 66),
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(connection)
        }

        let repaired = try await database.ensureAptosAccount(
            walletID: walletID
        )
        let accounts = try await database.pool.read { connection in
            try DBWalletAccountRecord
                .filter(Column("walletID") == walletID)
                .filter(Column("networkID") == AptosConstants.networkID)
                .fetchAll(connection)
        }

        #expect(repaired == expected)
        #expect(accounts.count == 1)
        #expect(accounts.first?.id == "\(walletID):aptos:0")
        #expect(accounts.first?.address == expected.address)
        #expect(accounts.first?.publicKey == expected.publicKey)
    }

    @Test
    func ensureAccountReusesVerifiedPersistedIdentityWithoutSecretAccess()
        async throws {
        let keyData = try #require(Data(hexString: Self.privateKeyHex))
        let expected = try AptosAddress.material(
            privateKey: try #require(PrivateKey(data: keyData)),
            derivationPath: AptosConstants.derivationPath
        )
        let database = try WalletDatabase.temporary()
        let walletID = "aptos-persisted-fast-path"
        try await Self.insertWalletAndAccount(
            database: database,
            walletID: walletID,
            accountMaterial: expected
        )
        let emptyVault = WalletSecretVault(
            service: "com.aperture.wallet.tests.aptos.\(UUID().uuidString)"
        )
        defer { try? emptyVault.deleteAll() }

        let startedAt = ContinuousClock.now
        let loaded = try await database.ensureAptosAccount(
            walletID: walletID,
            vault: emptyVault
        )

        #expect(loaded == expected)
        #expect(startedAt.duration(to: .now) < .milliseconds(500))
    }

    @Test
    func assetTypesAndPaymentRequestsAreCanonicalAndMainnetOnly()
        throws
    {
        #expect(
            AptosAssetType.canonical(
                "0x0000000000000000000000000000000000000000000000000000000000000001::aptos_coin::AptosCoin"
            ) == AptosConstants.nativeCoinType
        )
        #expect(
            AptosAssetType.assetID(AptosConstants.nativeCoinType)
                == AptosConstants.nativeAssetID
        )
        #expect(
            AptosAssetType.assetID("0xabc::managed_coin::USDC")
                == "aptos:0xabc::managed_coin::USDC"
        )
        #expect(
            AssetIdentityKey.make(
                networkID: AptosConstants.networkID,
                contractAddress: "0xabc::managed_coin::USDC"
            ) == "aptos:0xabc::managed_coin::USDC"
        )
        #expect(AptosAssetType.canonical("0x1::bad-name::TOKEN") == nil)

        let request = try SendPaymentRequestParser.parse(
            "aptos:\(Self.recipient)?amount=1.25000000"
        )
        #expect(request.source == .aptosURI)
        #expect(request.recipient == Self.recipient)
        #expect(request.candidateNetworkIDs == [AptosConstants.networkID])
        #expect(request.requestedNetworkID == AptosConstants.networkID)
        #expect(request.requestedAsset == .native)
        #expect(request.requestedAmount == .userUnits("1.25"))
        #expect(
            SendAddressValidator.isValid(
                Self.recipient,
                for: AptosConstants.networkID
            )
        )
        #expect(throws: SendPaymentRequestError.invalidAmount) {
            try SendPaymentRequestParser.parse(
                "aptos:\(Self.recipient)?amount=0.000000001"
            )
        }
    }

    @Test
    func amountConversionIsLossless() throws {
        #expect(
            try AptosAPIClient.userUnits(
                atomic: "125000000",
                decimals: 8
            ) == "1.25"
        )
        #expect(
            try AptosAPIClient.userUnits(atomic: "1", decimals: 8)
                == "0.00000001"
        )
        #expect(
            try AptosAPIClient.userUnits(
                atomic: "11120868786",
                decimals: 8
            ) == "111.20868786"
        )
        #expect(
            try AptosAPIClient.userUnits(
                atomic: "11120000000",
                decimals: 8
            ) == "111.2"
        )
        #expect(
            try SendAtomicAmount.fromUserUnits("1.25", decimals: 8)
                == "125000000"
        )
    }

    @Test
    func sendReloadsTheExactIndexedAssetBalance() async throws {
        AptosFixtureURLProtocol.prepare(mode: .full)
        let state = try await Self.fixtureClient(mode: .full).assetSendState(
            address: Self.owner,
            assetType: Self.tokenType
        )

        #expect(state.atomicAmount == "1500000")
        #expect(!state.isFrozen)
    }

    @Test
    func providerPublishesNativeThenTokensAndMapsOutgoingRecipient()
        async throws
    {
        AptosFixtureURLProtocol.prepare(mode: .full)
        let client = Self.fixtureClient(mode: .full)
        let probe = AptosSnapshotProbe()
        let snapshot = try await client.loadSnapshot(
            material: Self.material
        ) { partial in
            await probe.record(partial)
        }

        #expect(await probe.recordCount == 2)
        #expect(await probe.firstBalanceCount == 1)
        #expect(await probe.lastBalanceCount == 2)
        #expect(snapshot.balancesAreAuthoritative)
        #expect(snapshot.historyIsAuthoritative)
        #expect(snapshot.providerFailureCodes.isEmpty)
        #expect(snapshot.balances.count == 2)
        #expect(snapshot.balances[0].metadata == AptosTokenCatalog.native)
        #expect(snapshot.balances[0].amountText == "2")
        let token = try #require(
            snapshot.balances.first { $0.metadata.symbol == "USDC" }
        )
        #expect(token.amountText == "1.5")
        #expect(token.atomicAmount == "1500000")
        let activity = try #require(snapshot.history.first)
        #expect(activity.transactionVersion == 42)
        #expect(activity.signedAmountText == "-1.5")
        #expect(activity.sender == Self.owner)
        #expect(activity.recipient == Self.recipient)
        #expect(activity.networkFeeText == "0.00001")
    }

    @Test
    func failedTokenIndexIsPartialAndPreservesCachedTokenBalance()
        async throws
    {
        AptosFixtureURLProtocol.prepare(mode: .indexUnavailable)
        let partial = try await Self.fixtureClient(
            mode: .indexUnavailable
        ).loadSnapshot(
            material: Self.material
        )

        #expect(!partial.balancesAreAuthoritative)
        #expect(!partial.historyIsAuthoritative)
        #expect(partial.balances.count == 1)
        #expect(partial.balances[0].atomicAmount == "200000000")
        #expect(
            partial.providerFailureCodes.contains(
                "aptos_http_503_indexer"
            )
        )

        let database = try WalletDatabase.temporary()
        let walletID = "aptos-preservation-wallet"
        try await Self.insertWalletAndAccount(
            database: database,
            walletID: walletID
        )
        let metadata = Self.tokenMetadata
        let authoritative = AptosWalletSnapshot(
            material: Self.material,
            balances: [
                AptosAssetBalance(
                    metadata: AptosTokenCatalog.native,
                    amountText: "2",
                    atomicAmount: "200000000"
                ),
                AptosAssetBalance(
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
        try await database.saveAptosSnapshot(
            authoritative,
            walletID: walletID
        )
        try await database.saveAptosSnapshot(partial, walletID: walletID)

        let assetID = try #require(
            AptosAssetType.assetID(metadata.assetType)
        )
        let storedToken = try await database.pool.read { connection in
            try DBAccountAssetRecord.fetchOne(
                connection,
                key: [
                    "accountID": "\(walletID):aptos:0",
                    "assetID": assetID
                ]
            )
        }
        #expect(storedToken?.balance == "5")
        #expect(storedToken?.balanceAtomic == "5000000")
    }

    @Test
    func malformedTokenBalanceCannotBecomeAuthoritativeZero()
        async throws
    {
        AptosFixtureURLProtocol.prepare(mode: .malformedBalance)
        let snapshot = try await Self.fixtureClient(
            mode: .malformedBalance
        ).loadSnapshot(material: Self.material)

        #expect(!snapshot.balancesAreAuthoritative)
        #expect(
            snapshot.providerFailureCodes.contains(
                "aptos_balance_item_invalid"
            )
        )
        #expect(snapshot.balances.count == 1)
        #expect(snapshot.balances[0].metadata == AptosTokenCatalog.native)
        #expect(snapshot.balances[0].amountText == "2")
    }

    @Test
    func failedIndexerFallsBackToVerifiedOutgoingRESTTransfers()
        async throws
    {
        AptosFixtureURLProtocol.prepare(
            mode: .indexUnavailableWithRESTTransfer
        )
        let snapshot = try await Self.fixtureClient(
            mode: .indexUnavailableWithRESTTransfer
        ).loadSnapshot(material: Self.material)

        #expect(!snapshot.balancesAreAuthoritative)
        #expect(!snapshot.historyIsAuthoritative)
        #expect(snapshot.providerFailureCodes == ["aptos_http_503_indexer"])
        let item = try #require(snapshot.history.first)
        #expect(item.transactionVersion == 42)
        #expect(item.metadata == AptosTokenCatalog.native)
        #expect(item.signedAmountText == "-0.015")
        #expect(item.recipient == Self.recipient)
        #expect(item.networkFeeText == "0.00001")
    }

    @Test
    func balancePaginationRequestsConsecutivePages() async throws {
        AptosFixtureURLProtocol.prepare(mode: .paginatedBalances)

        let snapshot = try await Self.fixtureClient(
            mode: .paginatedBalances
        ).loadSnapshot(
            material: Self.material
        )

        #expect(
            AptosFixtureURLProtocol.recordedBalanceCursors(
                mode: .paginatedBalances
            )
                == [
                    "",
                    AptosFixtureURLProtocol.pageAssetType(99)
                ]
        )
        #expect(snapshot.balancesAreAuthoritative)
        #expect(snapshot.balances.contains { $0.metadata.symbol == "PAGE2" })
    }

    @Test
    func walletCoreSignsNativeMainnetTransaction() throws {
        let privateKey = try #require(Data(hexString: Self.privateKeyHex))
        let output: AptosSigningOutput = AnySigner.sign(
            input: AptosSigningInput.with {
                $0.sender = Self.owner
                $0.sequenceNumber = 7
                $0.maxGasAmount = 20_000
                $0.gasUnitPrice = 100
                $0.expirationTimestampSecs = 2_000_000_000
                $0.chainID = AptosConstants.chainID
                $0.privateKey = privateKey
                $0.transfer = .with {
                    $0.to = Self.recipient
                    $0.amount = 100_000_000
                }
            },
            coin: .aptos
        )

        #expect(output.error == .ok)
        #expect(!output.encoded.isEmpty)
        #expect(output.encoded.count > 64)
    }

    @Test
    func aptosUserTransactionHashMatchesCanonicalWalletCoreVector() throws {
        // Trust Wallet Core 4.7.3 Aptos/TWAnySignerTests.cpp `TxSign`.
        let signedTransaction = try #require(Data(hexString:
            "07968dab936c1bad187c60ce4082f307d030d780e91e694ae03aef16aba73f3063000000000000000200000000000000000000000000000000000000000000000000000000000000010d6170746f735f6163636f756e74087472616e7366657200022007968dab936c1bad187c60ce4082f307d030d780e91e694ae03aef16aba73f3008e803000000000000fe4d3200000000006400000000000000c2276ada00000000210020ea526ba1710343d953461ff68641f1b7df5f23b9042ffa2d2a798d3adb3f3d6c405707246db31e2335edc4316a7a656a11691d1d1647f6e864d1ab12f43428aaaf806cf02120d0b608cdd89c5c904af7b137432aacdd60cc53f9fad7bd33578e01"
        ))

        #expect(
            SendAptosTransactionService.transactionHash(signedTransaction)
                == "0xb4d62afd3862116e060dd6ad9848ccb50c2bc177799819f1d29c059ae2042467"
        )
    }

    private static var material: AptosAccountMaterial {
        AptosAccountMaterial(
            address: owner,
            publicKey: "fixture",
            derivationPath: AptosConstants.derivationPath
        )
    }

    private static func fixtureClient(
        mode: AptosFixtureURLProtocol.Mode
    ) -> AptosAPIClient {
        let session = fixtureSession()
        return AptosAPIClient(
            rest: AptosRESTTransport(
                baseURL: URL(string: "https://example.test/v1")!,
                session: session
            ),
            indexer: AptosIndexerTransport(
                endpoint: URL(
                    string: "https://\(mode.fixtureHost)/graphql"
                )!,
                session: session,
                router: AdaptiveProviderRouter()
            )
        )
    }

    private static func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AptosFixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func insertWalletAndAccount(
        database: WalletDatabase,
        walletID: String,
        accountMaterial: AptosAccountMaterial = material
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await database.pool.write { connection in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Aptos Test Wallet",
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
                id: "\(walletID):aptos:0",
                walletID: walletID,
                networkID: AptosConstants.networkID,
                address: accountMaterial.address,
                normalizedAddress: accountMaterial.address,
                label: AptosConstants.accountLabel,
                derivationPath: accountMaterial.derivationPath,
                accountIndex: 0,
                publicKey: accountMaterial.publicKey,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(connection)
        }
    }
}

private final class AptosFixtureURLProtocol: URLProtocol,
    @unchecked Sendable {
    enum Mode: Hashable, Sendable {
        case full
        case indexUnavailable
        case indexUnavailableWithRESTTransfer
        case paginatedBalances
        case malformedBalance
        case submission

        var fixtureHost: String {
            switch self {
            case .full: "aptos-full.example.test"
            case .indexUnavailable: "aptos-unavailable.example.test"
            case .indexUnavailableWithRESTTransfer:
                "aptos-rest-fallback.example.test"
            case .paginatedBalances: "aptos-pages.example.test"
            case .malformedBalance: "aptos-malformed.example.test"
            case .submission: "aptos-submission.example.test"
            }
        }

        init?(fixtureHost: String?) {
            switch fixtureHost {
            case Mode.full.fixtureHost: self = .full
            case Mode.indexUnavailable.fixtureHost:
                self = .indexUnavailable
            case Mode.indexUnavailableWithRESTTransfer.fixtureHost:
                self = .indexUnavailableWithRESTTransfer
            case Mode.paginatedBalances.fixtureHost:
                self = .paginatedBalances
            case Mode.malformedBalance.fixtureHost:
                self = .malformedBalance
            case Mode.submission.fixtureHost:
                self = .submission
            default: return nil
            }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var balanceCursors: [Mode: [String]] = [:]
    nonisolated(unsafe) private static var activeMode: Mode = .full

    static func prepare(mode: Mode) {
        lock.lock()
        activeMode = mode
        balanceCursors[mode] = []
        lock.unlock()
    }

    static func recordedBalanceCursors(mode: Mode) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return balanceCursors[mode] ?? []
    }

    static func storageID(_ value: Int) -> String {
        "0x" + String(repeating: "0", count: 64 - String(value, radix: 16).count)
            + String(value, radix: 16)
    }

    static func pageAssetType(_ index: Int) -> String {
        "0x2::managed_coin::Page\(String(format: "%03d", index))"
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            fail(URLError(.badURL))
            return
        }
        let fixtureMode = Mode(fixtureHost: url.host)
        if url.path == "/graphql" {
            guard let fixtureMode else {
                fail(URLError(.unsupportedURL))
                return
            }
            if fixtureMode == .indexUnavailable
                || fixtureMode == .indexUnavailableWithRESTTransfer {
                respond(status: 503, object: ["error": "unavailable"])
                return
            }
            respondGraphQL(mode: fixtureMode)
            return
        }
        if url.path == "/v1/view" {
            respond(status: 200, object: ["200000000"])
            return
        }
        if url.path == "/v1/transactions" {
            respond(
                status: 202,
                object: [
                    "hash": "0xf7f59c6de4f60d970f0c00148133b97865ae703be19a3698b478a1278b6350a8",
                    "sender": AptosSupportTests.owner,
                    "sequence_number": "7",
                    "max_gas_amount": "20000",
                    "gas_unit_price": "100",
                    "expiration_timestamp_secs": "2000000000",
                    "payload": [
                        "type": "entry_function_payload",
                        "function": "0x1::aptos_account::transfer",
                        "type_arguments": [],
                        "arguments": [AptosSupportTests.recipient, "1"]
                    ]
                ]
            )
            return
        }
        if url.path == "/v1/transactions/by_version/42" {
            respond(status: 200, object: Self.transaction)
            return
        }
        if url.path == "/v1/accounts/\(AptosSupportTests.owner)" {
            Self.lock.lock()
            let mode = Self.activeMode
            Self.lock.unlock()
            respond(
                status: 200,
                object: [
                    "sequence_number": mode
                        == .indexUnavailableWithRESTTransfer ? "1" : "0",
                    "authentication_key": AptosSupportTests.owner
                ]
            )
            return
        }
        if url.path
            == "/v1/accounts/\(AptosSupportTests.owner)/transactions" {
            Self.lock.lock()
            let mode = Self.activeMode
            Self.lock.unlock()
            respond(
                status: 200,
                object: mode == .indexUnavailableWithRESTTransfer
                    ? [Self.transaction]
                    : []
            )
            return
        }
        fail(URLError(.unsupportedURL))
    }

    override func stopLoading() {}

    private func respondGraphQL(mode: Mode) {
        guard let body = Self.bodyData(from: request),
              let object = try? JSONSerialization.jsonObject(with: body)
                    as? [String: Any],
              let query = object["query"] as? String
        else {
            fail(URLError(.cannotParseResponse))
            return
        }
        if query.contains("current_fungible_asset_balances") {
            let variables = object["variables"] as? [String: Any]
            if query.contains("query AptosAssetBalance") {
                let assetType = variables?["assetType"] as? String
                respond(
                    status: 200,
                    object: [
                        "data": [
                            "current_fungible_asset_balances":
                                Self.balances.filter {
                                    $0["asset_type"] as? String == assetType
                                        && $0["is_primary"] as? Bool == true
                                }
                        ]
                    ]
                )
                return
            }
            let cursor = variables?["afterAsset"] as? String ?? ""
            Self.lock.lock()
            Self.balanceCursors[mode, default: []].append(cursor)
            Self.lock.unlock()
            let balances: [[String: Any]]
            if mode == .paginatedBalances {
                balances = cursor.isEmpty
                    ? (0..<AptosConstants.balancePageSize).map { index in
                        var balance = Self.balances[1]
                        let type = Self.pageAssetType(index)
                        balance["storage_id"] = Self.storageID(index + 1)
                        balance["asset_type"] = type
                        var metadata = balance["metadata"] as! [String: Any]
                        metadata["asset_type"] = type
                        balance["metadata"] = metadata
                        return balance
                    }
                    : cursor == Self.pageAssetType(
                        AptosConstants.balancePageSize - 1
                    )
                        ? [Self.pageTwoBalance]
                        : []
            } else if mode == .malformedBalance {
                balances = [Self.balances[0], Self.malformedBalance]
            } else {
                balances = query.contains("is_primary: { _eq: true }")
                    ? Self.balances.filter {
                        $0["is_primary"] as? Bool == true
                    }
                    : Self.balances
            }
            respond(
                status: 200,
                object: [
                    "data": [
                        "current_fungible_asset_balances": balances
                    ]
                ]
            )
        } else if query.contains("fungible_asset_activities") {
            let activities = mode == .paginatedBalances
                || mode == .malformedBalance
                ? []
                : [Self.activity]
            respond(
                status: 200,
                object: [
                    "data": [
                        "fungible_asset_activities": activities
                    ]
                ]
            )
        } else {
            fail(URLError(.unsupportedURL))
        }
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: bufferSize
        )
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

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
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }

    private static var balances: [[String: Any]] {
        [
            [
                "storage_id": storageID(1),
                "amount": 200_000_000,
                "asset_type": AptosConstants.nativeCoinType,
                "token_standard": "v1",
                "is_primary": true,
                "is_frozen": false,
                "metadata": [
                    "asset_type": AptosConstants.nativeCoinType,
                    "name": "Aptos",
                    "symbol": "APT",
                    "decimals": 8,
                    "icon_uri": NSNull(),
                    "token_standard": "v1"
                ]
            ],
            [
                "storage_id": storageID(2),
                "amount": 1_500_000,
                "asset_type": AptosSupportTests.tokenType,
                "token_standard": "v1",
                "is_primary": true,
                "is_frozen": false,
                "metadata": [
                    "asset_type": AptosSupportTests.tokenType,
                    "name": "USD Coin",
                    "symbol": "USDC",
                    "decimals": 6,
                    "icon_uri": NSNull(),
                    "token_standard": "v1"
                ]
            ],
            [
                "storage_id": storageID(3),
                "amount": 500_000,
                "asset_type": AptosSupportTests.tokenType,
                "token_standard": "v1",
                "is_primary": false,
                "is_frozen": false,
                "metadata": [
                    "asset_type": AptosSupportTests.tokenType,
                    "name": "USD Coin",
                    "symbol": "USDC",
                    "decimals": 6,
                    "icon_uri": NSNull(),
                    "token_standard": "v1"
                ]
            ]
        ]
    }

    private static var activity: [String: Any] {
        [
            "transaction_version": 42,
            "event_index": 0,
            "owner_address": AptosSupportTests.owner,
            "asset_type": AptosSupportTests.tokenType,
            "amount": 1_500_000,
            "type": "withdraw",
            "is_transaction_success": true,
            "entry_function_id_str": "0x1::coin::transfer",
            "transaction_timestamp": "2026-08-02T00:00:00Z",
            "metadata": [
                "asset_type": AptosSupportTests.tokenType,
                "name": "USD Coin",
                "symbol": "USDC",
                "decimals": 6,
                "icon_uri": NSNull(),
                "token_standard": "v1"
            ]
        ]
    }

    private static var pageTwoBalance: [String: Any] {
        let assetType = "0x2::managed_coin::PageTwo"
        return [
            "storage_id": storageID(AptosConstants.balancePageSize + 1),
            "amount": "7",
            "asset_type": assetType,
            "token_standard": "v1",
            "is_primary": true,
            "is_frozen": false,
            "metadata": [
                "asset_type": assetType,
                "name": "Page Two Token",
                "symbol": "PAGE2",
                "decimals": 0,
                "icon_uri": NSNull(),
                "token_standard": "v1"
            ]
        ]
    }

    private static var malformedBalance: [String: Any] {
        var value = balances[1]
        value["amount"] = "provider-error"
        return value
    }

    private static var transaction: [String: Any] {
        [
            "version": "42",
            "hash": "0x" + String(repeating: "a", count: 64),
            "sender": AptosSupportTests.owner,
            "gas_used": "10",
            "gas_unit_price": "100",
            "success": true,
            "timestamp": "1785628800000000",
            "payload": [
                "function": "0x1::aptos_account::transfer",
                "type_arguments": [],
                "arguments": [
                    AptosSupportTests.recipient,
                    "1500000"
                ]
            ]
        ]
    }
}

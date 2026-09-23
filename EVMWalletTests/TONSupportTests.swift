import Foundation
import GRDB
import Testing
import UIKit
@testable import Aperture

struct TONSupportTests {
    private static let walletID = "ton-support-wallet"
    private static let accountID = "\(walletID):ton:0"
    private static let friendlyAddress =
        "UQBm--PFwDv1yCeS-QTJ-L8oiUpqo9IT1BwgVptlSq3ts4DV"
    private static let testnetAddress =
        "0QBm--PFwDv1yCeS-QTJ-L8oiUpqo9IT1BwgVptlSq3tsztf"
    private static let rawAddress =
        "0:66fbe3c5c03bf5c82792f904c9f8bf28894a6aa3d213d41c20569b654aadedb3"
    private static let transactionRecipientRawAddress =
        "0:fb6a33122ff12df188578ee80ed58c904fd105cc73b6166a0e0781b938bad40d"
    private static let expectedBroadcastHash = String(repeating: "0", count: 64)
    private static let remoteJettonAddress =
        "0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe"
    private static let remoteJettonLogoURL =
        "oath-asset://catalog/token-ton-0b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe.png"
    private static let remoteJetton = TONTokenDefinition(
        address: remoteJettonAddress,
        name: "Tether USD",
        symbol: "USD₮",
        decimals: 6,
        rank: 1
    )

    private static func installRemoteJettonCatalog() {
        ReceiveAssetCatalogRuntime.install(
            [
                ReceiveToken(
                    id: "ton-usdt",
                    name: remoteJetton.name,
                    symbol: remoteJetton.symbol,
                    rank: 3_000,
                    isStablecoin: true,
                    variants: [
                        ReceiveTokenVariant(
                            networkID: TONConstants.networkID,
                            contractAddress: remoteJettonAddress,
                            decimals: remoteJetton.decimals,
                            networkRank: remoteJetton.rank,
                            logoURL: remoteJettonLogoURL,
                            marketDataID: "tether"
                        )
                    ]
                )
            ],
            revision: 1
        )
    }

    @Test
    func receiveNetworkLabelUsesGramFormerlyTONCopy() {
        #expect(
            ReceiveNetworkLabelText.localized(
                networkName: "Gram",
                blockchain: .ton
            ) == "On {logo}Gram formerly (TON) Network"
        )
        #expect(
            ReceiveNetworkLabelText.localized(
                networkName: "Ethereum",
                blockchain: .ethereum
            ) == "On {logo}Ethereum Network"
        )
    }

    @Test
    func addressNormalizationAcceptsMainnetAndRejectsTestnet() throws {
        #expect(
            TONAddress.rawAddress(from: Self.friendlyAddress)
                == Self.rawAddress
        )
        #expect(
            TONAddress.rawAddress(from: Self.rawAddress)
                == Self.rawAddress
        )
        #expect(TONAddress.rawAddress(from: Self.testnetAddress) == nil)
        #expect(
            TONAddress.rawAddress(
                from: "1:" + String(repeating: "0", count: 64)
            ) == nil
        )
        #expect(
            TONAddress.rawAddress(
                from: "-0:" + String(repeating: "0", count: 64)
            ) == nil
        )

        let bounceable = try #require(
            TONAddress.userFriendlyAddress(
                from: Self.rawAddress,
                bounceable: true
            )
        )
        #expect(TONAddress.matches(bounceable, Self.friendlyAddress))
        #expect(
            SendAddressValidator.isValid(
                Self.friendlyAddress,
                for: TONConstants.networkID
            )
        )
        #expect(
            !SendAddressValidator.isValid(
                Self.testnetAddress,
                for: TONConstants.networkID
            )
        )
    }

    @Test
    func transactionDisplayAddressesAreUserFriendlyMainnetAddresses()
        throws
    {
        for raw in [Self.rawAddress, Self.transactionRecipientRawAddress] {
            let displayed = try #require(
                TONAddress.mainnetDisplayAddress(from: raw)
            )
            #expect(displayed.hasPrefix("UQ"))
            #expect(TONAddress.rawAddress(from: displayed) == raw)
        }
    }

    @Test
    func tonPaymentURIUsesNanogramsAndPreservesMemo() throws {
        let request = try SendPaymentRequestParser.parse(
            """
            ton://transfer/\(Self.friendlyAddress)\
            ?amount=1250000000&text=Invoice%2042
            """
        )

        #expect(request.source == .tonURI)
        #expect(request.recipient == Self.friendlyAddress)
        #expect(request.candidateNetworkIDs == [TONConstants.networkID])
        #expect(request.requestedNetworkID == TONConstants.networkID)
        #expect(request.requestedAsset == .native)
        #expect(request.requestedAmount == .atomicUnits("1250000000"))
        #expect(request.memo == "Invoice 42")
    }

    @Test
    func tonPaymentURIRejectsTestnetAndDecimalAtomicAmounts() {
        #expect(
            throws: SendPaymentRequestError.invalidMainnetAddress
        ) {
            try SendPaymentRequestParser.parse(
                "ton://transfer/\(Self.testnetAddress)"
            )
        }
        #expect(throws: SendPaymentRequestError.invalidAmount) {
            try SendPaymentRequestParser.parse(
                """
                ton://transfer/\(Self.friendlyAddress)\
                ?amount=1.5
                """
            )
        }
    }

    @Test
    func providerTransportPreservesStructuredFailureCode()
        async throws
    {
        let baseURL = try #require(
            URL(string: "https://wallet.example")
        )
        let transport = try TONAPITransport(
            baseURL: baseURL,
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            let response = try #require(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (
                Data(
                    """
                    {"error":{"code":"ton_provider_timeout"}}
                    """.utf8
                ),
                response
            )
        }

        do {
            let _: TONAPISeqno = try await transport.request(
                path: "seqno",
                body: ["address": .string(Self.friendlyAddress)]
            )
            Issue.record("Expected the provider request to fail.")
        } catch let TONProviderError.server(status, code) {
            #expect(status == 503)
            #expect(code == "ton_provider_timeout")
        } catch {
            Issue.record("Unexpected provider error: \(error)")
        }
    }

    @Test
    func broadcastSeparatesPreflightAndSubmissionProviders()
        async throws
    {
        let baseURL = try #require(
            URL(string: "https://wallet.example")
        )
        let recorder = TONBroadcastRequestRecorder()
        let transport = try TONAPITransport(
            baseURL: baseURL,
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            try await recorder.response(for: request)
        }

        try await transport.broadcast(
            boc: "te6cckEBAQEAAgAAAA==",
            expectedHash: Self.expectedBroadcastHash
        )

        let requests = await recorder.requests
        #expect(requests.map(\.url.absoluteString) == [
            "https://tonapi.io/v2/wallet/emulate",
            "https://toncenter.com/api/v2/sendBocReturnHash"
        ])
        #expect(requests.allSatisfy {
            $0.body == #"{"boc":"te6cckEBAQEAAgAAAA=="}"#
        })
    }

    @Test
    func broadcastContinuesWhenOptionalEmulationIsRateLimited()
        async throws
    {
        let baseURL = try #require(
            URL(string: "https://wallet.example")
        )
        let recorder = TONBroadcastRequestRecorder(
            emulationStatus: 429
        )
        let transport = try TONAPITransport(
            baseURL: baseURL,
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            try await recorder.response(for: request)
        }

        try await transport.broadcast(
            boc: "te6cckEBAQEAAgAAAA==",
            expectedHash: Self.expectedBroadcastHash
        )
        let requestCount = await recorder.requests.count
        #expect(requestCount == 2)
    }

    @Test
    func broadcastClassifiesTONCenterUnpackFailureAsDefinitive()
        async throws
    {
        let baseURL = try #require(
            URL(string: "https://wallet.example")
        )
        let transport = try TONAPITransport(
            baseURL: baseURL,
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            let isEmulation = request.url?.host == "tonapi.io"
            let status = isEmulation ? 200 : 500
            let payload = isEmulation
                ? #"{"trace":{},"risk":{},"event":{}}"#
                : #"{"ok":false,"error":"Failed to unpack Message","code":500}"#
            let response = try #require(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json"
                    ]
                )
            )
            return (Data(payload.utf8), response)
        }

        do {
            try await transport.broadcast(
                boc: "te6cckEBAQEAAgAAAA==",
                expectedHash: Self.expectedBroadcastHash
            )
            Issue.record("Expected the broadcast to be rejected.")
        } catch let TONProviderError.server(status, code) {
            #expect(status == 422)
            #expect(code == "ton_broadcast_rejected_invalid_boc")
        } catch {
            Issue.record("Unexpected provider error: \(error)")
        }
    }

    @Test
    func broadcastStopsWhenEmulationTraceReportsActionFailure()
        async throws
    {
        let baseURL = try #require(URL(string: "https://wallet.example"))
        let recorder = TONBroadcastRequestRecorder(
            emulationActionResultCode: 37
        )
        let transport = try TONAPITransport(
            baseURL: baseURL, router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            try await recorder.response(for: request)
        }

        do {
            try await transport.broadcast(
                boc: "te6cckEBAQEAAgAAAA==",
                expectedHash: Self.expectedBroadcastHash
            )
            Issue.record("Failed TON emulation unexpectedly broadcast.")
        } catch let TONProviderError.server(status, code) {
            #expect(status == 422)
            #expect(code == "ton_preflight_rejected_action_37")
        } catch {
            Issue.record("Unexpected TON emulation error: \(error)")
        }
        #expect(await recorder.requests.count == 1)
    }

    @Test
    func broadcastRejectsProviderHashMismatchAsAmbiguousEvidence()
        async throws
    {
        let baseURL = try #require(URL(string: "https://wallet.example"))
        let recorder = TONBroadcastRequestRecorder(
            broadcastHash: Data(repeating: 1, count: 32)
                .base64EncodedString()
        )
        let transport = try TONAPITransport(
            baseURL: baseURL, router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            try await recorder.response(for: request)
        }

        do {
            try await transport.broadcast(
                boc: "te6cckEBAQEAAgAAAA==",
                expectedHash: Self.expectedBroadcastHash
            )
            Issue.record("Mismatched TON provider hash was accepted.")
        } catch let TONProviderError.invalidResponse(code) {
            #expect(code == "broadcast_success_invalid")
        } catch {
            Issue.record("Unexpected TON hash mismatch error: \(error)")
        }
    }

    @Test
    func snapshotPaginatesHistoryAndNormalizesFriendlyAddresses()
        async throws
    {
        let baseURL = try #require(
            URL(string: "https://wallet.example")
        )
        let stub = TONPaginationStub(
            ownerFriendlyAddress: Self.friendlyAddress,
            ownerRawAddress: Self.rawAddress
        )
        let transport = try TONAPITransport(
            baseURL: baseURL,
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            let data = try await stub.response(for: request)
            guard let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ) else {
                throw URLError(.badServerResponse)
            }
            return (data, response)
        }
        let progressiveProbe = TONBalanceSnapshotProbe()
        let snapshot = try await TONAPIClient(
            transport: transport
        ).loadSnapshot(material: material) { balanceSnapshot in
            await progressiveProbe.record(balanceSnapshot)
        }

        #expect(await progressiveProbe.recordCount == 3)
        #expect(await progressiveProbe.nativeAtomicAmount == "25094973665")
        #expect(await progressiveProbe.historyCount == 0)
        #expect(snapshot.nativeAtomicAmount == "25094973665")
        #expect(snapshot.nativeAmountText == "25.094973665")
        #expect(snapshot.history.count == 1)
        #expect(snapshot.history.first?.from == Self.rawAddress)
        #expect(snapshot.history.first?.amountText == "1")
        let cursors = await stub.eventCursors
        #expect(cursors == [nil, "900"])
    }

    @Test
    func blockedHistoryDoesNotDelayProgressiveBalancePublication()
        async throws
    {
        let baseURL = try #require(
            URL(string: "https://wallet.example")
        )
        let historyGate = TONHistoryGate()
        let stub = TONPaginationStub(
            ownerFriendlyAddress: Self.friendlyAddress,
            ownerRawAddress: Self.rawAddress,
            historyGate: historyGate
        )
        let transport = try TONAPITransport(
            baseURL: baseURL,
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            let data = try await stub.response(for: request)
            guard let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ) else {
                throw URLError(.badServerResponse)
            }
            return (data, response)
        }
        let progressiveProbe = TONBalanceSnapshotProbe()
        let snapshotTask = Task {
            try await TONAPIClient(
                transport: transport
            ).loadSnapshot(material: material) { balanceSnapshot in
                await progressiveProbe.record(balanceSnapshot)
            }
        }

        defer { snapshotTask.cancel() }
        try await historyGate.waitUntilBlocked()
        let balanceDeadlineEndpoint = AdaptiveProviderEndpoint(
            serviceID: "ton_progressive_balance_test",
            endpointURL: try #require(
                URL(string: "https://wallet.example/balance")
            ),
            baselinePriority: 0
        )
        try await ProviderRequestDeadline.run(
            seconds: 1,
            endpoint: balanceDeadlineEndpoint
        ) {
            try await progressiveProbe.wait(until: 3)
        }
        #expect(await progressiveProbe.nativeAtomicAmount == "25094973665")
        #expect(await progressiveProbe.historyCount == 0)

        await historyGate.release()
        let snapshot = try await snapshotTask.value
        #expect(snapshot.history.count == 1)
    }

    @Test
    func remoteJettonCatalogMatchesReceiveCatalogAndStorageArtwork() throws {
        Self.installRemoteJettonCatalog()
        let curated = TONTokenCatalog.all
        let receive = ReceiveAssetCatalog.tokens(
            for: TONConstants.networkID
        )

        #expect(curated.count == 1)
        #expect(Set(curated.map(\.address)).count == curated.count)
        #expect(curated.map(\.rank) == Array(1...curated.count))
        #expect(
            Set(
                receive.flatMap(\.variants)
                    .compactMap(\.contractAddress)
            ) == Set(curated.map(\.address))
        )
        #expect(UIImage(named: "NetworkLogoTON") != nil)
        #expect(UIImage(named: "NativeCoinGram") != nil)
        #expect(
            AssetLogoSource.nativeCoin(
                blockchain: .ton
            ).bundledAssetName == "NativeCoinGram"
        )
        #expect(
            ReceiveNetworkCatalog.all.first {
                $0.id == TONConstants.networkID
            }?.logoSource.bundledAssetName == "NetworkLogoTON"
        )

        let selection = try #require(
            ReceiveAssetCatalog.selection(
                assetIdentity: "ton:\(Self.remoteJettonAddress)"
            )
        )
        #expect(
            selection.variant.logoSource.remoteLogoURL?.absoluteString
                == Self.remoteJettonLogoURL
        )
    }

    @Test
    func tonNativeAssetUsesTheRemoteCatalog() {
        #expect(WalletHomeAssetCatalog.availableAssets(from: [], remoteCatalogAssets: []).isEmpty)
        let remoteAsset = WalletAsset(
            id: "ton:native", name: "Gram", symbol: "GRAM",
            logoSource: .nativeCoin(blockchain: .ton), network: .ton,
            balance: 0, fiatValue: 0, decimals: TONConstants.decimals
        )
        let available = WalletHomeAssetCatalog.availableAssets(from: [], remoteCatalogAssets: [remoteAsset])
        let nativeID = "\(TONConstants.networkID):native"
        let native = available.first {
            AssetIdentityKey.canonical($0.id) == nativeID
        }

        #expect(native?.network == .ton)
        #expect(native?.name == "Gram")
        #expect(native?.symbol == "GRAM")
        #expect(native?.decimals == TONConstants.decimals)
        #expect(
            WalletHomeAssetCatalog.mainScreenAssets(
                from: available
            ).contains {
                AssetIdentityKey.canonical($0.id) == nativeID
            }
        )
    }

    @Test
    func successfulSnapshotResetsMissingCuratedJettonBalance()
        async throws
    {
        let database = try WalletDatabase.temporary()
        try await seedWallet(database)
        let token = Self.remoteJetton
        let first = TONWalletSnapshot(
            material: material,
            nativeAmountText: "2",
            nativeAtomicAmount: "2000000000",
            nativeUSDPriceText: "3",
            tokens: [
                TONTokenBalance(
                    definition: token,
                    walletAddress: Self.friendlyAddress,
                    amountText: "5",
                    atomicAmount: "5000000",
                    usdPriceText: "1"
                )
            ],
            history: []
        )
        try await database.saveTONSnapshot(
            first,
            walletID: Self.walletID
        )
        #expect(
            try await holding(
                database,
                assetID: "ton:\(token.address)"
            )?.balance == "5"
        )
        #expect(
            try await database.tonJettonWallet(
                walletID: Self.walletID,
                assetID: "ton:\(token.address)"
            ) == Self.friendlyAddress
        )

        let second = TONWalletSnapshot(
            material: material,
            nativeAmountText: "1",
            nativeAtomicAmount: "1000000000",
            nativeUSDPriceText: "3",
            tokens: [],
            history: []
        )
        try await database.saveTONSnapshot(
            second,
            walletID: Self.walletID
        )

        let reset = try #require(
            try await holding(
                database,
                assetID: "ton:\(token.address)"
            )
        )
        #expect(reset.balance == "0")
        #expect(reset.balanceAtomic == "0")
        #expect(reset.fiatUSDValue == "0")
        #expect(
            try await database.tonJettonWallet(
                walletID: Self.walletID,
                assetID: "ton:\(token.address)"
            ) == nil
        )
    }

    @Test
    func snapshotPersistsUserFriendlyTransactionAddresses() async throws {
        let database = try WalletDatabase.temporary()
        try await seedWallet(database)
        let hash = String(repeating: "b", count: 64)
        try await database.saveTONSnapshot(
            TONWalletSnapshot(
                material: material,
                nativeAmountText: "1",
                nativeAtomicAmount: "1000000000",
                nativeUSDPriceText: nil,
                tokens: [],
                history: [
                    TONHistoryItem(
                        id: "friendly-address-event",
                        transactionHash: hash,
                        timestamp: 1_700_000_000,
                        failed: false,
                        from: Self.rawAddress,
                        to: Self.transactionRecipientRawAddress,
                        assetAddress: nil,
                        assetName: "Gram",
                        assetSymbol: "GRAM",
                        decimals: TONConstants.decimals,
                        amountText: "1",
                        atomicAmount: "1000000000"
                    )
                ]
            ),
            walletID: Self.walletID
        )

        let record = try await database.pool.read { connection in
            try DBTransactionRecord
                .filter(Column("transactionHash") == hash)
                .fetchOne(connection)
        }
        #expect(
            record?.fromAddress
                == TONAddress.mainnetDisplayAddress(from: Self.rawAddress)
        )
        #expect(
            record?.toAddress == TONAddress.mainnetDisplayAddress(
                from: Self.transactionRecipientRawAddress
            )
        )
        #expect(record?.counterpartyAddress == record?.toAddress)
    }

    @Test
    func partialJettonReadUpdatesGramWithoutErasingTokens()
        async throws
    {
        let database = try WalletDatabase.temporary()
        try await seedWallet(database)
        let token = Self.remoteJetton
        try await database.saveTONSnapshot(
            TONWalletSnapshot(
                material: material,
                nativeAmountText: "1",
                nativeAtomicAmount: "1000000000",
                nativeUSDPriceText: "2",
                tokens: [
                    TONTokenBalance(
                        definition: token,
                        walletAddress: Self.friendlyAddress,
                        amountText: "5",
                        atomicAmount: "5000000",
                        usdPriceText: "1"
                    )
                ],
                history: []
            ),
            walletID: Self.walletID
        )

        try await database.saveTONSnapshot(
            TONWalletSnapshot(
                material: material,
                nativeAmountText: "25.094973665",
                nativeAtomicAmount: "25094973665",
                nativeUSDPriceText: "1.4235",
                tokens: [],
                history: [],
                jettonsAreAuthoritative: false,
                eventsAreAuthoritative: false,
                providerFailureCodes: ["ton_jettons_429"]
            ),
            walletID: Self.walletID
        )

        #expect(
            try await holding(
                database,
                assetID: TONConstants.nativeAssetID
            )?.balance == "25.094973665"
        )
        #expect(
            try await holding(
                database,
                assetID: "ton:\(token.address)"
            )?.balance == "5"
        )
        #expect(
            try await database.tonJettonWallet(
                walletID: Self.walletID,
                assetID: "ton:\(token.address)"
            ) == Self.friendlyAddress
        )
    }

    private var material: TONAccountMaterial {
        TONAccountMaterial(
            address: Self.friendlyAddress,
            rawAddress: Self.rawAddress,
            bounceableAddress: Self.friendlyAddress,
            publicKey: Data(repeating: 7, count: 32)
                .base64EncodedString(),
            derivationPath: TONConstants.derivationPath
        )
    }

    private func holding(
        _ database: WalletDatabase,
        assetID: String
    ) async throws -> DBAccountAssetRecord? {
        try await database.pool.read { connection in
            try DBAccountAssetRecord.fetchOne(
                connection,
                key: [
                    "accountID": Self.accountID,
                    "assetID": assetID
                ]
            )
        }
    }

    private func seedWallet(_ database: WalletDatabase) async throws {
        try await database.pool.write { connection in
            let now = Date().timeIntervalSince1970
            try DBWalletRecord(
                id: Self.walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "TON Test Wallet",
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
                id: Self.accountID,
                walletID: Self.walletID,
                networkID: TONConstants.networkID,
                address: Self.friendlyAddress,
                normalizedAddress: Self.rawAddress,
                label: TONConstants.accountLabel,
                derivationPath: TONConstants.derivationPath,
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

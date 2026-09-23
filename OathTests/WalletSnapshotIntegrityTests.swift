import Foundation
import GRDB
import Testing
@testable import Aperture

struct WalletSnapshotIntegrityTests {
    private let evmAddress =
        "0x1111111111111111111111111111111111111111"
    private let evmContract =
        "0x3333333333333333333333333333333333333333"

    @Test
    func tokenSnapshotDiscardsProviderFiatAndUsesResolvedContractPrice() throws {
        let provider = AnkrBalanceResult(
            totalBalanceUsd: "4929445140.85",
            assets: [AnkrBalanceAsset(
                blockchain: "base", tokenName: "SAND", tokenSymbol: "SAND",
                tokenDecimals: 18, tokenType: "ERC20",
                contractAddress: "0xac531eb26ca1d21b85126de8fb87e80e09002dcf",
                balance: "138295198634.16446765731119248",
                balanceRawInteger: nil, balanceUsd: "4929445140.85",
                tokenPrice: "0.03556", thumbnail: ""
            )], nextPageToken: nil
        )
        let identity = "base:0xac531eb26ca1d21b85126de8fb87e80e09002dcf"
        let unpriced = try AnkrAPIClient.makeSnapshot(
            address: evmAddress, balanceResult: provider, transfers: [], rawTransactions: []
        )
        #expect(unpriced.assets.first?.fiatValue == 0)
        let priced = try AnkrAPIClient.makeSnapshot(
            address: evmAddress, balanceResult: provider, transfers: [], rawTransactions: [],
            historicalTokenPrices: [identity: try #require(Decimal(string: "0.000000000003152"))]
        )
        let holding = try #require(priced.assets.first)
        #expect(holding.fiatValue > Decimal(string: "0.43")!)
        #expect(holding.fiatValue < Decimal(string: "0.44")!)
        #expect(holding.balanceText == "138295198634.16446765731119248")
    }

    @Test
    func ankrMissingFiatValueRetainsLosslessBalance() throws {
        let snapshot = try AnkrAPIClient.makeSnapshot(
            address: evmAddress,
            balanceResult: balanceResult(balanceUSD: nil),
            transfers: [],
            rawTransactions: []
        )

        let asset = try #require(snapshot.assets.first)
        let authority = try #require(snapshot.evmBalanceAuthority)
        #expect(snapshot.assets.count == 1)
        #expect(asset.balanceText == "1")
        #expect(asset.balanceAtomic == "1000000000000000000")
        #expect(asset.fiatValue == 0)
        #expect(authority.providerAssetCount == 1)
        #expect(authority.mappedAssetCount == 1)
        #expect(authority.unavailableFiatAssetCount == 1)
        #expect(authority.isAuthoritative)
    }

    @Test
    func ankrMalformedFiatValueRetainsLosslessBalance() throws {
        let snapshot = try AnkrAPIClient.makeSnapshot(
            address: evmAddress,
            balanceResult: balanceResult(balanceUSD: "not-a-price"),
            transfers: [],
            rawTransactions: []
        )

        let asset = try #require(snapshot.assets.first)
        let authority = try #require(snapshot.evmBalanceAuthority)
        #expect(asset.balanceText == "1")
        #expect(asset.fiatValue == 0)
        #expect(authority.unavailableFiatAssetCount == 1)
        #expect(authority.isAuthoritative)
    }

    @Test
    func ankrMalformedBalanceRejectsEntireSnapshot() {
        let malformedAsset = AnkrBalanceAsset(
            blockchain: "eth",
            tokenName: "Integrity Token",
            tokenSymbol: "INT",
            tokenDecimals: 18,
            tokenType: "ERC20",
            contractAddress: evmContract,
            balance: "not-a-balance",
            balanceRawInteger: nil,
            balanceUsd: "10",
            tokenPrice: "10",
            thumbnail: ""
        )

        #expect(
            throws: AnkrBalanceSnapshotError.invalidAsset(
                index: 0,
                field: "balance"
            )
        ) {
            try AnkrAPIClient.makeSnapshot(
                address: evmAddress,
                balanceResult: AnkrBalanceResult(
                    totalBalanceUsd: "10",
                    assets: [malformedAsset],
                    nextPageToken: nil
                ),
                transfers: [],
                rawTransactions: []
            )
        }
    }

    @Test
    func ankrUnconsumedPageRejectsEntireSnapshot() {
        #expect(throws: AnkrBalanceSnapshotError.incompletePagination) {
            try AnkrAPIClient.makeSnapshot(
                address: evmAddress,
                balanceResult: AnkrBalanceResult(
                    totalBalanceUsd: "0",
                    assets: [],
                    nextPageToken: "next-page"
                ),
                transfers: [],
                rawTransactions: []
            )
        }
    }

    @Test
    func ankrZeroBalanceRetainsHistoricalNativeTransaction() throws {
        let transactionHash =
            "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let snapshot = try AnkrAPIClient.makeSnapshot(
            address: evmAddress,
            balanceResult: AnkrBalanceResult(
                totalBalanceUsd: "0",
                assets: [],
                nextPageToken: nil
            ),
            transfers: [],
            rawTransactions: [
                historicalNativeTransaction(
                    hash: transactionHash,
                    value: "0xde0b6b3a7640000"
                )
            ]
        )

        let transaction = try #require(snapshot.transactions.first)
        #expect(snapshot.totalBalance == 0)
        #expect(snapshot.assets.isEmpty)
        #expect(snapshot.transactions.count == 1)
        #expect(transaction.assetSymbol == "ETH")
        #expect(transaction.assetAmount == 1)
        #expect(transaction.fiatValue == nil)
        #expect(transaction.assetLogoSource == .nativeCoin(blockchain: .ethereum))
        #expect(transaction.metadata.transactionHash == transactionHash)
        #expect(transaction.metadata.blockchainIdentifier == "eth")
    }

    @Test
    func ankrZeroValueContractCallWithoutTokenTransferIsRetained() throws {
        let snapshot = try AnkrAPIClient.makeSnapshot(
            address: evmAddress,
            balanceResult: AnkrBalanceResult(
                totalBalanceUsd: "0",
                assets: [],
                nextPageToken: nil
            ),
            transfers: [],
            rawTransactions: [
                historicalNativeTransaction(
                    hash:
                        "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    value: "0x0"
                )
            ]
        )

        let transaction = try #require(snapshot.transactions.first)
        #expect(snapshot.transactions.count == 1)
        #expect(transaction.assetAmount == 0)
        #expect(transaction.assetSymbol == "ETH")
    }

    @Test
    func ankrZeroBalanceRetainsPricedCatalogTokenTransfer() throws {
        let contract =
            "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
        let transfer = AnkrTokenTransfer(
            blockHeight: 16,
            fromAddress:
                "0x2222222222222222222222222222222222222222",
            toAddress: evmAddress,
            contractAddress: contract,
            value: "1",
            valueRawInteger: "1000000",
            blockchain: "eth",
            tokenName: "USD Coin",
            tokenSymbol: "USDC",
            tokenDecimals: 6,
            thumbnail: nil,
            transactionHash:
                "0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            logIndex: 0,
            timestamp: 1_700_000_000,
            direction: "in"
        )
        let emptyBalance = AnkrBalanceResult(
            totalBalanceUsd: "0",
            assets: [],
            nextPageToken: nil
        )

        let unpriced = try AnkrAPIClient.makeSnapshot(
            address: evmAddress,
            balanceResult: emptyBalance,
            transfers: [transfer],
            rawTransactions: []
        )
        let priced = try AnkrAPIClient.makeSnapshot(
            address: evmAddress,
            balanceResult: emptyBalance,
            transfers: [transfer],
            rawTransactions: [],
            historicalTokenPrices: ["eth:\(contract)": 1]
        )

        #expect(unpriced.transactions.isEmpty)
        let transaction = try #require(priced.transactions.first)
        #expect(priced.transactions.count == 1)
        #expect(transaction.assetSymbol == "USDC")
        #expect(transaction.assetAmount == 1)
        #expect(transaction.fiatValue == 1)
    }

    @Test
    func ankrTokenTransferUsesEventRecipientInsteadOfContractCallTarget()
        throws
    {
        let recipient =
            "0x2222222222222222222222222222222222222222"
        let contract =
            "0xc2132d05d31c914a87c6611c10748aeb04b58e8f"
        let transactionHash =
            "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        let transfer = AnkrTokenTransfer(
            blockHeight: 16,
            fromAddress: evmAddress,
            toAddress: recipient,
            contractAddress: contract,
            value: "5",
            valueRawInteger: "5000000",
            blockchain: "polygon",
            tokenName: "USDT0",
            tokenSymbol: "USDT0",
            tokenDecimals: 6,
            thumbnail: nil,
            transactionHash: transactionHash,
            logIndex: 0,
            timestamp: 1_700_000_000,
            direction: "out"
        )
        let rawTransaction = AnkrRawTransaction(
            blockHash:
                "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            blockNumber: "0x10",
            from: evmAddress,
            gas: "0x15f90",
            gasPrice: "0x3b9aca00",
            gasUsed: "0x11170",
            to: contract,
            value: "0x0",
            hash: transactionHash,
            input: "0xa9059cbb",
            nonce: "0x1",
            status: "0x1",
            blockchain: "polygon",
            timestamp: "0x6553f100",
            transactionIndex: "0x0",
            type: "0x2"
        )

        let snapshot = try AnkrAPIClient.makeSnapshot(
            address: evmAddress,
            balanceResult: AnkrBalanceResult(
                totalBalanceUsd: "0",
                assets: [],
                nextPageToken: nil
            ),
            transfers: [transfer],
            rawTransactions: [rawTransaction],
            historicalTokenPrices: ["polygon:\(contract)": 1]
        )

        let transaction = try #require(snapshot.transactions.first)
        #expect(snapshot.transactions.count == 1)
        #expect(transaction.metadata.fromAddress == evmAddress)
        #expect(transaction.metadata.toAddress == recipient)
        #expect(transaction.metadata.contractAddress == contract)
        #expect(transaction.metadata.toAddress != rawTransaction.to)
    }

    @Test
    func unverifiedEVMSnapshotCannotResetCachedHolding() async throws {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedEVMHolding(database)
        let unverified = WalletHomeSnapshot(
            totalBalance: 0,
            assets: [],
            transactions: []
        )

        await #expect(
            throws: WalletSnapshotPersistenceError
                .unverifiedBalanceSnapshot
        ) {
            try await database.saveWalletSnapshot(
                unverified,
                address: evmAddress
            )
        }

        let retained = try await database.pool.read { db in
            try DBAccountAssetRecord.fetchOne(
                db,
                key: [
                    "accountID": fixture.accountID,
                    "assetID": fixture.assetID
                ]
            )
        }
        #expect(retained?.balance == "7")
        #expect(retained?.balanceAtomic == "7000000000000000000")
        #expect(retained?.fiatUSDValue == "14")
        #expect(retained?.isPinned == true)
        #expect(retained?.isHidden == false)
    }

    @Test
    func failedEVMNetworkRetainsBalanceWhileSuccessfulNetworkAdvances()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let eth = try await seedHolding(
            database,
            accountID: "integrity-eth-account",
            networkID: "eth",
            address: evmAddress,
            assetID: "eth:integrity-unpinned",
            contract: evmContract,
            balance: "7",
            atomic: "7000000",
            fiat: "14",
            isPinned: false
        )
        let polygon = try await seedHolding(
            database,
            accountID: "integrity-polygon-account",
            networkID: "polygon",
            address: evmAddress,
            assetID: "polygon:integrity-unpinned",
            contract:
                "0x4444444444444444444444444444444444444444",
            balance: "8",
            atomic: "8000000",
            fiat: "16",
            isPinned: false
        )
        let ethOnlySnapshot = WalletHomeSnapshot(
            totalBalance: 0,
            assets: [],
            transactions: [],
            evmBalanceAuthority: EVMBalanceSnapshotAuthority(
                providerAssetCount: 0,
                mappedAssetCount: 0,
                unavailableFiatAssetCount: 0,
                hasMorePages: false,
                authoritativeNetworkIDs: ["eth"]
            )
        )

        try await database.saveWalletSnapshot(
            ethOnlySnapshot,
            address: evmAddress
        )

        let stored = try await database.pool.read { connection in
            (
                eth: try DBAccountAssetRecord.fetchOne(
                    connection,
                    key: [
                        "accountID": eth.accountID,
                        "assetID": eth.assetID
                    ]
                ),
                polygon: try DBAccountAssetRecord.fetchOne(
                    connection,
                    key: [
                        "accountID": polygon.accountID,
                        "assetID": polygon.assetID
                    ]
                )
            )
        }
        #expect(stored.eth?.balance == "0")
        #expect(stored.eth?.balanceAtomic == "0")
        #expect(stored.polygon?.balance == "8")
        #expect(stored.polygon?.balanceAtomic == "8000000")
        #expect(stored.polygon?.fiatUSDValue == "16")
    }

    @Test
    func solanaCompleteEmptyTokenProgramsAreAuthoritative() throws {
        let snapshot = try SolanaAPIClient.makeBalanceSnapshot(
            material: solanaMaterial(),
            responses: completeSolanaResponses()
        )

        #expect(snapshot.solAtomicBalance == "123")
        #expect(snapshot.tokenBalances.isEmpty)
        #expect(snapshot.balanceAuthority == .complete)
        #expect(snapshot.balanceAuthority.isComplete)
    }

    @Test
    func solanaMissingBatchResponseRejectsSnapshot() {
        let partial = Array(completeSolanaResponses().prefix(2))

        #expect(throws: SolanaProviderError.self) {
            try SolanaAPIClient.makeBalanceSnapshot(
                material: solanaMaterial(),
                responses: partial
            )
        }
    }

    @Test
    func solanaNullTokenResultIsNotAnEmptyTokenSnapshot() {
        var responses = completeSolanaResponses()
        responses[1] = SolanaRPCResponse(
            result: .null,
            error: nil,
            id: 2
        )

        #expect(throws: SolanaProviderError.self) {
            try SolanaAPIClient.makeBalanceSnapshot(
                material: solanaMaterial(),
                responses: responses
            )
        }
    }

    @Test
    func solanaMalformedTokenRowRejectsSnapshot() {
        var responses = completeSolanaResponses()
        responses[1] = SolanaRPCResponse(
            result: .object([
                "value": .array([
                    .object(["pubkey": .string("token-account")])
                ])
            ]),
            error: nil,
            id: 2
        )

        #expect(throws: SolanaProviderError.self) {
            try SolanaAPIClient.makeBalanceSnapshot(
                material: solanaMaterial(),
                responses: responses
            )
        }
    }

    @Test
    func partialSolanaBatchCannotReplaceCachedHolding() async throws {
        let database = try WalletDatabase.temporary()
        let fixture = try await seedSolanaHolding(database)
        let partial = Array(completeSolanaResponses().prefix(2))

        #expect(throws: SolanaProviderError.self) {
            try SolanaAPIClient.makeBalanceSnapshot(
                material: solanaMaterial(),
                responses: partial
            )
        }

        let retained = try await database.pool.read { db in
            try DBAccountAssetRecord.fetchOne(
                db,
                key: [
                    "accountID": fixture.accountID,
                    "assetID": fixture.assetID
                ]
            )
        }
        #expect(retained?.balance == "9")
        #expect(retained?.balanceAtomic == "9000000")
        #expect(retained?.fiatUSDValue == "9")
        #expect(retained?.isPinned == true)
    }

    @Test
    func partialBalanceFetchUpdatesOnlySuccessfullyFetchedAssets()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let accountID = "integrity-wallet:near:0"
        let address = "integrity.near"
        let failedMetadata = NEARTokenMetadata(
            contractID: "failed-token.near",
            name: "Failed Token",
            symbol: "FAIL",
            decimals: 6,
            iconURL: nil,
            isVerified: true,
            rank: 10
        )
        let confirmedZeroMetadata = NEARTokenMetadata(
            contractID: "confirmed-zero.near",
            name: "Confirmed Zero Token",
            symbol: "ZERO",
            decimals: 6,
            iconURL: nil,
            isVerified: true,
            rank: 20
        )
        _ = try await seedHolding(
            database,
            accountID: accountID,
            networkID: NEARConstants.networkID,
            address: address,
            assetID: failedMetadata.assetID,
            contract: failedMetadata.contractID,
            balance: "7",
            atomic: "7000000",
            fiat: "14"
        )
        _ = try await seedHolding(
            database,
            accountID: accountID,
            networkID: NEARConstants.networkID,
            address: address,
            assetID: confirmedZeroMetadata.assetID,
            contract: confirmedZeroMetadata.contractID,
            balance: "5",
            atomic: "5000000",
            fiat: "10"
        )
        let material = NEARAccountMaterial(
            address: address,
            publicKey: "fixture-public-key",
            derivationPath: NEARConstants.derivationPath
        )
        let partial = NEARWalletSnapshot(
            material: material,
            balances: [
                NEARAssetBalance(
                    metadata: nil,
                    amountText: "3",
                    atomicAmount: "3000000000000000000000000"
                ),
                // A failed provider row must be ignored even if a fallback
                // layer accidentally supplied a zero placeholder.
                NEARAssetBalance(
                    metadata: failedMetadata,
                    amountText: "0",
                    atomicAmount: "0"
                )
            ],
            history: [],
            balancesAreAuthoritative: false,
            historyIsAuthoritative: false,
            providerFailureCodes: ["near_token_rpc_failed"],
            successfulBalanceAssetIDs: [
                NEARConstants.nativeAssetID,
                confirmedZeroMetadata.assetID
            ]
        )

        try await database.saveNEARSnapshot(
            partial,
            walletID: "integrity-wallet"
        )

        let stored = try await database.pool.read { connection in
            (
                native: try DBAccountAssetRecord.fetchOne(
                    connection,
                    key: [
                        "accountID": accountID,
                        "assetID": NEARConstants.nativeAssetID
                    ]
                ),
                failed: try DBAccountAssetRecord.fetchOne(
                    connection,
                    key: [
                        "accountID": accountID,
                        "assetID": failedMetadata.assetID
                    ]
                ),
                confirmedZero: try DBAccountAssetRecord.fetchOne(
                    connection,
                    key: [
                        "accountID": accountID,
                        "assetID": confirmedZeroMetadata.assetID
                    ]
                )
            )
        }
        #expect(stored.native?.balance == "3")
        #expect(stored.failed?.balance == "7")
        #expect(stored.failed?.balanceAtomic == "7000000")
        #expect(stored.failed?.fiatUSDValue == "14")
        #expect(stored.confirmedZero?.balance == "0")
        #expect(stored.confirmedZero?.balanceAtomic == "0")
        #expect(stored.confirmedZero?.fiatUSDValue == "0")
    }

    private func balanceResult(
        balanceUSD: String?
    ) -> AnkrBalanceResult {
        AnkrBalanceResult(
            totalBalanceUsd: "not-a-total",
            assets: [
                AnkrBalanceAsset(
                    blockchain: "eth",
                    tokenName: "Ether",
                    tokenSymbol: "ETH",
                    tokenDecimals: 18,
                    tokenType: "NATIVE",
                    contractAddress: "",
                    balance: "1",
                    balanceRawInteger: "1000000000000000000",
                    balanceUsd: balanceUSD,
                    tokenPrice: nil,
                    thumbnail: ""
                )
            ],
            nextPageToken: nil
        )
    }

    private func historicalNativeTransaction(
        hash: String,
        value: String
    ) -> AnkrRawTransaction {
        AnkrRawTransaction(
            blockHash:
                "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            blockNumber: "0x10",
            from: "0x2222222222222222222222222222222222222222",
            gas: "0x5208",
            gasPrice: "0x3b9aca00",
            gasUsed: "0x5208",
            to: evmAddress,
            value: value,
            hash: hash,
            input: value == "0x0" ? "0x12345678" : "0x",
            nonce: "0x1",
            status: "0x1",
            blockchain: "eth",
            timestamp: "0x6553f100",
            transactionIndex: "0x0",
            type: "0x2"
        )
    }

    private func solanaMaterial() -> SolanaAccountMaterial {
        SolanaAccountMaterial(
            kind: .phantom,
            address: "11111111111111111111111111111111",
            publicKey: "11111111111111111111111111111111",
            derivationPath: SolanaDerivationKind.phantom.derivationPath
        )
    }

    private func completeSolanaResponses() -> [SolanaRPCResponse] {
        [
            SolanaRPCResponse(
                result: .object(["value": .number(123)]),
                error: nil,
                id: 1
            ),
            SolanaRPCResponse(
                result: .object(["value": .array([])]),
                error: nil,
                id: 2
            ),
            SolanaRPCResponse(
                result: .object(["value": .array([])]),
                error: nil,
                id: 3
            )
        ]
    }

    private func seedEVMHolding(
        _ database: WalletDatabase
    ) async throws -> (accountID: String, assetID: String) {
        try await seedHolding(
            database,
            accountID: "integrity-evm-account",
            networkID: "eth",
            address: evmAddress,
            assetID: "eth:integrity-token",
            contract: evmContract,
            balance: "7",
            atomic: "7000000000000000000",
            fiat: "14"
        )
    }

    private func seedSolanaHolding(
        _ database: WalletDatabase
    ) async throws -> (accountID: String, assetID: String) {
        try await seedHolding(
            database,
            accountID: "integrity-solana-account",
            networkID: SolanaConstants.networkID,
            address: solanaMaterial().address,
            assetID: "solana:integrity-token",
            contract: "IntegrityMint11111111111111111111111111111",
            balance: "9",
            atomic: "9000000",
            fiat: "9"
        )
    }

    private func seedHolding(
        _ database: WalletDatabase,
        accountID: String,
        networkID: String,
        address: String,
        assetID: String,
        contract: String,
        balance: String,
        atomic: String,
        fiat: String,
        isPinned: Bool = true
    ) async throws -> (accountID: String, assetID: String) {
        try await database.pool.write { db in
            let now = Date().timeIntervalSince1970
            if try DBWalletRecord.fetchOne(
                db,
                key: "integrity-wallet"
            ) == nil {
                try DBWalletRecord(
                    id: "integrity-wallet",
                    profileID: WalletDatabase.defaultProfileID,
                    name: "Integrity Wallet",
                    kind: DatabaseWalletKind.created.rawValue,
                    secretKeyReference: "opaque-keychain-reference",
                    isSelected: true,
                    sortOrder: 0,
                    createdAt: now,
                    updatedAt: now,
                    lastOpenedAt: now,
                    archivedAt: nil
                ).insert(db)
            }
            if try DBWalletAccountRecord.fetchOne(
                db,
                key: accountID
            ) == nil {
                try DBWalletAccountRecord(
                    id: accountID,
                    walletID: "integrity-wallet",
                    networkID: networkID,
                    address: address,
                    normalizedAddress: address.lowercased(),
                    label: nil,
                    derivationPath: nil,
                    accountIndex: 0,
                    publicKey: nil,
                    isWatchOnly: false,
                    isEnabled: true,
                    createdAt: now,
                    updatedAt: now,
                    lastSyncedAt: nil
                ).insert(db)
            }
            try DBAssetRecord(
                id: assetID,
                networkID: networkID,
                assetType: DatabaseAssetType.fungibleToken.rawValue,
                contractAddress: contract,
                normalizedContractAddress: contract.lowercased(),
                name: "Integrity Token",
                symbol: "INT",
                decimals: 6,
                trustWalletBlockchain: networkID,
                trustWalletContractAddress: contract,
                isVerified: true,
                isSpam: false,
                createdAt: now,
                updatedAt: now,
                metadataUpdatedAt: nil
            ).insert(db)
            try DBAccountAssetRecord(
                accountID: accountID,
                assetID: assetID,
                balance: balance,
                balanceAtomic: atomic,
                fiatUSDValue: fiat,
                isEnabled: true,
                isPinned: isPinned,
                isHidden: false,
                sortOrder: 5,
                firstSeenAt: now,
                lastSeenAt: now,
                updatedAt: now
            ).insert(db)
        }
        return (accountID, assetID)
    }
}

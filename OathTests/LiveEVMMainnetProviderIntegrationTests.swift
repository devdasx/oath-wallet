#if LIVE_MAINNET_TESTS
import CryptoKit
import Foundation
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct LiveMainnetProviderIntegrationTests {
    private static let fixtureMnemonic =
        "abandon abandon abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon about"
    private static let evmFixtureAddress =
        "0x0000000000000000000000000000000000000001"
    private static let activeEVMFixtureAddress =
        "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
    /// One minute before a verified transaction on each network. Keeping the
    /// cursor chain-specific exercises real history without downloading years
    /// of unrelated public activity during every live audit refresh.
    private static let evmHistoryCursorByNetwork: [String: Int64] = [
        "arbitrum": 1_787_937_239,
        "avalanche": 1_787_695_163,
        "base": 1_786_366_787,
        "bsc": 1_787_350_143,
        "eth": 1_788_261_119,
        "gnosis": 1_779_151_010,
        "linea": 1_782_299_879,
        "optimism": 1_787_206_373,
        "polygon": 1_787_774_223,
        "scroll": 1_768_454_263,
        "taiko": 1_736_462_615,
        "telos": 1_725_649_941,
        "xlayer": 1_727_280_662,
        "arc": 1_789_000_000
    ]

    @Test
    func ethereumDefaultRPCCompletesEverySendPreflightRead()
        async throws {
        let address =
            "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
        let client = try SendEVMRPCClient(networkID: "eth")

        async let chainID = client.chainID()
        async let nonce = client.transactionCount(address: address)
        async let balance = client.nativeBalance(address: address)
        async let gas = client.estimateGas(
            from: address,
            to: address,
            value: "0x0",
            data: nil
        )
        let values = try await (chainID, nonce, balance, gas)

        #expect(values.0 == "0x1")
        #expect(Self.isHexQuantity(values.1))
        #expect(Self.isHexQuantity(values.2))
        #expect(Self.isHexQuantity(values.3))
        #expect(Int(values.3.dropFirst(2), radix: 16) ?? 0 > 0)
    }

    @Test
    func everyEVMMainnetSupportsNativeAndCatalogTokenBalances()
        async throws
    {
        let networks = ReceiveNetworkCatalog.all.filter { network in
            SendAddressValidator.evmNetworks.contains(where: {
                $0.id == network.id
            })
        }
        #expect(!networks.isEmpty)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var nextNetworkIndex = 0
            let maximumConcurrentNetworks = min(4, networks.count)

            func addNetworkTask(_ network: ReceiveNetwork) {
                group.addTask {
                    try await Self.verifyEVMNetwork(network)
                }
            }

            while nextNetworkIndex < maximumConcurrentNetworks {
                addNetworkTask(networks[nextNetworkIndex])
                nextNetworkIndex += 1
            }

            while try await group.next() != nil {
                if nextNetworkIndex < networks.count {
                    addNetworkTask(networks[nextNetworkIndex])
                    nextNetworkIndex += 1
                }
            }
        }
    }

    private static func verifyEVMNetwork(
        _ network: ReceiveNetwork
    ) async throws {
            let client = try SendEVMRPCClient(networkID: network.id)
            let chainID = try await client.chainID()
            #expect(
                Int(chainID.dropFirst(2), radix: 16) == network.chainID,
                "Wrong mainnet chain ID for \(network.id)"
            )
            let nativeBalance = try await client.nativeBalance(
                address: Self.evmFixtureAddress
            )
            #expect(
                Self.isHexQuantity(nativeBalance),
                "Invalid native balance for \(network.id)"
            )

            let variants = Self.uniqueEVMTokenVariants(networkID: network.id)
            #expect(!variants.isEmpty)
            for variant in variants {
                let contract = try #require(variant.contractAddress)
                let tokenBalance = try await client.tokenBalance(
                    ownerAddress: Self.evmFixtureAddress,
                    contractAddress: contract
                )
                #expect(
                    Self.isHexQuantity(tokenBalance),
                    "Invalid token balance for \(network.id):\(contract)"
                )
            }
    }

    @Test
    func ankrAdvancedAPIBalanceHandlesEveryVerifiedSupportedMainnet()
        async throws
    {
        let configuration = try AnkrConfiguration.runtime()
        let transport = AnkrRPCTransport(
            endpoint: configuration.multichainEndpoint
        )
        let chains = AnkrAPIClient.advancedBalanceMainnetChains.sorted()
        #expect(chains.count == 12)
        #expect(!chains.contains("scroll"))
        #expect(!chains.contains("arc"))
        let result: AnkrBalanceResult = try await transport.call(
            method: "ankr_getAccountBalance",
            parameters: AnkrBalanceParameters(
                blockchain: chains,
                walletAddress: Self.evmFixtureAddress,
                onlyWhitelisted: true,
                nativeFirst: true,
                pageSize: 1_000,
                pageToken: nil
            )
        )
        #expect(
            Decimal(
                string: result.totalBalanceUsd,
                locale: Locale(identifier: "en_US_POSIX")
            ) != nil
        )
    }

    @Test
    func ankrHistoryMethodsHandleEveryEVMMainnetAndActiveHistory()
        async throws
    {
        let allChains = ReceiveNetworkCatalog.all
            .filter { network in
                SendAddressValidator.evmNetworks.contains(where: {
                    $0.id == network.id
                })
            }
            .map(\.id)
        try #require(allChains.count == 14)
        try await auditEVMChains(allChains)
    }

    @Test
    func optimismDenseHistoryRefreshPerformanceRegression() async throws {
        try await auditEVMChains(["optimism"])
    }

    private func auditEVMChains(_ chains: [String]) async throws {
        for chain in chains {
            let historyCursor = try #require(
                Self.evmHistoryCursorByNetwork[chain]
            )
            for refresh in 1...5 {
                let startedAt = ContinuousClock.now
                let outcome: AnkrWalletLoadOutcome
                do {
                    outcome = try await AnkrAPIClient.localBuild()
                        .loadNetworkWithOutcome(
                            address: Self.activeEVMFixtureAddress,
                            networkID: chain,
                            historyFromTimestamp: historyCursor
                        )
                } catch {
                    Issue.record(
                        "\(chain) EVM refresh \(refresh) failed: \(error)"
                    )
                    throw error
                }
                let elapsed = startedAt.duration(to: .now)
                print(
                    "[ChainBenchmark] \(chain) refresh=\(refresh) "
                        + "elapsed=\(elapsed) "
                        + "assets=\(outcome.snapshot.assets.count) "
                        + "history=\(outcome.snapshot.persistenceTransactions.count)"
                )
                try #require(
                    outcome.snapshot.evmBalanceAuthority?
                        .authoritativeNetworkIDs == Set([chain])
                )
                try #require(outcome.failures.isEmpty)
                try #require(!outcome.snapshot.assets.isEmpty)
                try #require(
                    outcome.snapshot.assets.allSatisfy { asset in
                        AssetNetworkSelectorOption.networkID(
                            for: asset.network
                        ) == chain
                    }
                )
                try #require(
                    outcome.snapshot.persistenceTransactions.allSatisfy {
                        WalletDatabase.transactionNetworkID($0) == chain
                    }
                )
                try #require(
                    !outcome.snapshot.persistenceTransactions.isEmpty,
                    "\(chain) returned no transaction history"
                )
            }
        }
    }

    @Test
    func scrollPublicNodeBalanceCompletesFiveRealRefreshes()
        async throws
    {
        if ReceiveAssetCatalog.tokens(for: "scroll").isEmpty {
            let database = try WalletDatabaseRuntime.require()
            try await AssetCatalogSyncService.shared.synchronizeAndWait(
                database: database
            )
        }
        try #require(!ReceiveAssetCatalog.tokens(for: "scroll").isEmpty)
        let client = PublicNodeEVMBalanceClient.scroll()
        for refresh in 1...5 {
            let startedAt = ContinuousClock.now
            let balance = try await client.accountBalance(
                address: Self.activeEVMFixtureAddress
            )
            print(
                "[ChainBenchmark] scroll-publicnode refresh=\(refresh) "
                    + "elapsed=\(startedAt.duration(to: .now)) "
                    + "assets=\(balance.assets.count)"
            )
            #expect(balance.nextPageToken == nil)
            #expect(
                balance.assets.contains {
                    $0.blockchain == "scroll"
                        && $0.tokenType == "NATIVE"
                        && $0.balanceRawInteger != nil
                }
            )
        }
    }

    @Test
    func trackedCustomTokenBalancesUseEveryEVMMainnet()
        async throws
    {
        let networks = ReceiveNetworkCatalog.all.filter { network in
            SendAddressValidator.evmNetworks.contains(where: {
                $0.id == network.id
            })
        }
        let targets = try networks.flatMap { network in
            try Self.uniqueEVMTokenVariants(networkID: network.id).map {
                variant in
                let contract = try #require(variant.contractAddress)
                return TrackedEVMTokenBalanceTarget(
                    holdingID: TrackedEVMTokenHoldingID(
                        accountID: "live:\(network.id)",
                        assetID: "custom:\(network.id):\(contract.lowercased())"
                    ),
                    networkID: network.id,
                    expectedChainID: network.chainID,
                    ownerAddress: Self.evmFixtureAddress,
                    contractAddress: contract,
                    decimals: variant.decimals
                )
            }
        }

        let batch = try await TrackedEVMTokenBalanceService()
            .loadBalances(for: targets)

        #expect(batch.failedHoldingIDs.isEmpty)
        #expect(batch.updates.count == targets.count)
        #expect(
            batch.updates.allSatisfy {
                !$0.balanceAtomic.isEmpty
                    && $0.balanceAtomic.allSatisfy(\.isNumber)
            }
        )
    }

    @Test
    func tronLoadsNativeAndAllBundledTRC20Balances()
        async throws
    {
        let wallet = try #require(
            HDWallet(
                mnemonic: Self.fixtureMnemonic,
                passphrase: ""
            )
        )
        let key = wallet.getKeyForCoin(coin: .tron)
        let address = CoinType.tron.deriveAddress(privateKey: key)
        let hexAddress = try #require(
            TronValueParser.accountHexAddress(address)
        )
        let trackedTokens = TronTokenCatalog.tokens.map { token in
            TronTrackedToken(
                identity: token.id,
                type: token.type,
                name: token.name,
                symbol: token.symbol,
                decimals: token.decimals
            )
        }
        let snapshot = try await TronAPIClient.shared.loadSnapshot(
            material: TronAccountMaterial(
                address: address,
                hexAddress: hexAddress,
                publicKey: key.getPublicKeySecp256k1(compressed: false)
                    .data.base64EncodedString()
            ),
            trackedTokens: trackedTokens
        )
        #expect(snapshot.trxBalance >= 0)
        let bundledIdentities = Set(
            TronTokenCatalog.tokens
                .filter { $0.type == "trc20" }
                .map(\.id)
        )
        #expect(
            bundledIdentities.isSubset(
                of: snapshot.queriedTRC20Identities
            )
        )
        #expect(
            snapshot.providerFailures.allSatisfy {
                $0.stage == .historyEnrichment
            }
        )
    }

    @Test
    func solanaLoadsBothSupportedDerivationAccounts()
        async throws
    {
        let wallet = try #require(
            HDWallet(
                mnemonic: Self.fixtureMnemonic,
                passphrase: ""
            )
        )
        let materials = try SolanaDerivationKind.allCases.map { kind in
            let key = try #require(
                wallet.getKey(
                    coin: .solana,
                    derivationPath: kind.derivationPath
                )
            )
            let address = CoinType.solana.deriveAddress(privateKey: key)
            #expect(CoinType.solana.validate(address: address))
            return SolanaAccountMaterial(
                kind: kind,
                address: address,
                publicKey: key.getPublicKeyEd25519()
                    .data.base64EncodedString(),
                derivationPath: kind.derivationPath
            )
        }
        let snapshot = try await SolanaAPIClient.shared.loadSnapshot(
            accounts: SolanaAccountSet(
                primary: try #require(materials.first),
                alternatives: Array(materials.dropFirst())
            ),
            historyCursors: [:]
        )
        #expect(
            snapshot.addressSnapshots.count
                == SolanaDerivationKind.allCases.count
        )
        #expect(
            snapshot.addressSnapshots.allSatisfy {
                $0.solBalance >= 0 && $0.balanceAuthority.isComplete
            }
        )
    }

    @Test
    func suiGraphQLLoadsBalancesHistoryCoinObjectsAndGasPrice()
        async throws
    {
        let address =
            "0xdfc88cd008c89a4a4a60199b27e503cd5e248b5191be8e953856b43e87ae3393"
        let client = SuiAPIClient.shared
        let snapshot = try await client.loadSnapshot(
            material: SuiAccountMaterial(
                address: address,
                publicKey: "live-public-fixture",
                derivationPath: SuiConstants.derivationPath
            )
        )

        #expect(snapshot.balancesAreAuthoritative)
        #expect(!snapshot.balances.isEmpty)
        #expect(
            snapshot.balances.contains {
                $0.metadata.coinType == SuiConstants.nativeCoinType
            }
        )
        #expect(!snapshot.history.isEmpty)
        #expect(
            snapshot.history.allSatisfy {
                !$0.transactionHash.isEmpty
                    && !$0.amountText.isEmpty
                    && SuiCoinType.canonical(
                        $0.metadata.coinType
                    ) != nil
            }
        )

        let nativeObjects = try await client.coinObjects(
            address: address,
            coinType: SuiConstants.nativeCoinType
        )
        #expect(!nativeObjects.isEmpty)
        #expect(
            nativeObjects.allSatisfy {
                !$0.objectID.isEmpty
                    && !$0.digest.isEmpty
                    && $0.version > 0
            }
        )
        #expect(try await client.referenceGasPrice() > 0)
    }

    @Test
    func everyBitcoinFamilyMainnetHasWorkingProviders()
        async throws
    {
        let materials = try BitcoinFamilyDerivationService().derive(
            mnemonic: Self.fixtureMnemonic
        )
        #expect(materials.count == BitcoinFamilyChain.allCases.count)

        for material in materials {
            let snapshot: BitcoinFamilyChainSnapshot
            do {
                snapshot = try await BitcoinFamilySyncService.shared
                    .loadSnapshotWithFallback(material)
            } catch {
                let diagnostic = BitcoinFamilyErrorDiagnostics.description(
                    for: error
                )
                Issue.record(
                    "\(material.chain.rawValue) snapshot providers failed: \(diagnostic)"
                )
                snapshot = BitcoinFamilyChainSnapshot(
                    material: material,
                    balanceAtomic: .zero,
                    history: []
                )
            }
            #expect(!snapshot.balanceAtomic.isNegative)

            let scriptHash = Data(
                SHA256.hash(data: material.scriptPubKey)
            )
            .reversed()
            .map { String(format: "%02x", $0) }
            .joined()
            let balance: JSONValue
            do {
                balance = try await BitcoinFamilyElectrumClient.shared.call(
                    chain: material.chain,
                    method: "blockchain.scripthash.get_balance",
                    params: [AnyEncodable(scriptHash)]
                )
            } catch {
                let diagnostic = BitcoinFamilyErrorDiagnostics.description(
                    for: error
                )
                Issue.record(
                    "\(material.chain.rawValue) Electrum balance failed: \(diagnostic)"
                )
                continue
            }
            #expect(balance.object?["confirmed"]?.atomicInteger != nil)
            #expect(balance.object?["unconfirmed"]?.atomicInteger != nil)
            let unspent = try await BitcoinFamilyElectrumClient.shared.call(
                chain: material.chain,
                method: "blockchain.scripthash.listunspent",
                params: SendBitcoinUTXORepository.listUnspentParameters(
                    chain: material.chain,
                    scriptHash: scriptHash
                )
            )
            #expect(unspent.array != nil)
        }
    }

    @Test
    func everyBitcoinFamilyMainnetPublishesActiveBalanceAndHistoryIndexes()
        async throws
    {
        let fixtures: [(BitcoinFamilyChain, String)] = [
            (.bitcoin, "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"),
            (
                .bitcoinCash,
                "bitcoincash:qrmfkegyf83zh5kauzwgygf82sdahd5a55x9wse7ve"
            ),
            (.litecoin, "MQd1fJwqBJvwLuyhr17PhEFx1swiqDbPQS"),
            (.dogecoin, "DEgDVFa2DoW1533dxeDVdTxQFhMzs1pMke")
        ]

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (chain, address) in fixtures {
                group.addTask {
                    #expect(chain.coin.validate(address: address))
                    let script = BitcoinScript.lockScriptForAddress(
                        address: address,
                        coin: chain.coin
                    ).data
                    let material = BitcoinFamilyAccountMaterial(
                        chain: chain,
                        address: address,
                        derivationPath: nil,
                        publicKey: "live-public-fixture",
                        scriptPubKey: script
                    )
                    let scriptHash = BitcoinFamilySyncService
                        .electrumScriptHash(material)
                    async let balanceValue = BitcoinFamilyElectrumClient
                        .shared.call(
                            chain: chain,
                            method: "blockchain.scripthash.get_balance",
                            params: [AnyEncodable(scriptHash)]
                        )
                    async let historyValue = BitcoinFamilyElectrumClient
                        .shared.call(
                            chain: chain,
                            method: "blockchain.scripthash.get_history",
                            params: [AnyEncodable(scriptHash)],
                            maximumResponseBytes:
                                BitcoinFamilyElectrumClient
                                .maximumHistoryResponseBytes
                        )
                    let (balance, history) = try await (
                        balanceValue,
                        historyValue
                    )
                    #expect(balance.object?["confirmed"]?.atomicInteger != nil)
                    #expect(balance.object?["unconfirmed"]?.atomicInteger != nil)
                    #expect(!(history.array ?? []).isEmpty)
                }
            }
            try await group.waitForAll()
        }
    }

    private static func isHexQuantity(_ value: String) -> Bool {
        value.hasPrefix("0x")
            && !value.dropFirst(2).isEmpty
            && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private static func uniqueEVMTokenVariants(
        networkID: String
    ) -> [ReceiveTokenVariant] {
        var seen = Set<String>()
        return ReceiveAssetCatalog.tokens(for: networkID)
            .flatMap(\.variants)
            .filter { variant in
                guard variant.networkID == networkID,
                      let contract = variant.contractAddress
                else { return false }
                return seen.insert(contract.lowercased()).inserted
            }
    }

}

#endif

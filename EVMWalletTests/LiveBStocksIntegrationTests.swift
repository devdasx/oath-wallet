#if LIVE_MAINNET_TESTS
import Foundation
import Testing
import WalletCore
@testable import Aperture

/// bStocks end to end against BNB Smart Chain and the live catalog: the
/// family arrives from the bundled catalog, balances and history load for real holders
/// through the app's own clients, and sending is exercised up to the node's
/// own rejection of an unfunded transaction.
@Suite(.serialized)
struct LiveBStocksIntegrationTests {
    private static let tesla = "0x5b1910eaad6450e50f816082aa078c41f10c292f"
    /// A retail account (a thousand-odd transactions) holding a little TSLAB
    /// with recent transfers. Exchange hot wallets are avoided on purpose:
    /// one of their thousands of tokens can fail provider validation and
    /// sink the whole load.
    private static let holder = "0x9e229b12cc9081d6a510b29ccbd6311743e277ed"
    /// Used only for a gas estimate; it holds tens of thousands of TSLAB.
    private static let largeHolder = "0x8894e0a0c962cb723c1976a4421c95949be2d4e3"

    private static func installLiveCatalog() async throws -> [ReceiveToken] {
        let database = try WalletDatabase.temporary()
        try await AssetCatalogSyncService().synchronizeAndWait(database: database)
        let tokens = try await database.pool.read { db in
            try WalletAssetCatalogPersistence.loadCachedTokens(in: db)
        }
        ReceiveAssetCatalogRuntime.install(tokens, revision: 1)
        return tokens
    }

    @Test
    func remoteCatalogListsTheFamilyWithLogosAndMarketIDs() async throws {
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer { ReceiveAssetCatalogRuntime.install(previous.tokens, revision: previous.revision) }

        let tokens = try await Self.installLiveCatalog()
        let members = tokens.flatMap(\.variants).filter { $0.family == .bStocks }

        #expect(members.count >= 75)
        #expect(members.allSatisfy { $0.networkID == "bsc" && $0.decimals == 18 })
        // The CoinGecko-listed members carry a logo and a market id; the few
        // known only from CoinMarketCap are priced by contract for now.
        #expect(members.filter { $0.logoURL != nil && $0.marketDataID != nil }.count >= 70)
        #expect(members.contains { $0.contractAddress?.lowercased() == Self.tesla })
        // The family chip leads with BNB, the coin that pays the gas.
        let chip = ReceiveAssetSearchIndex.candidates(networkID: "family:bstocks")
        #expect(chip.count == members.count + 1)
        #expect(chip.first?.variant.contractAddress == nil)
        #expect(chip.first?.token.symbol == "BNB")
        #expect(ReceiveAssetCatalog.family(forAssetIdentity: "bsc:\(Self.tesla)") == .bStocks)
    }

    @Test
    func holdersBalancesAndHistoryLoadThroughTheBNBChainPath() async throws {
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer { ReceiveAssetCatalogRuntime.install(previous.tokens, revision: previous.revision) }
        _ = try await Self.installLiveCatalog()
        let client = try AnkrAPIClient.localBuild()
        let cursor = Int64(Date().timeIntervalSince1970) - 3 * 86_400

        let outcome = try await client.loadNetworkWithOutcome(
            address: Self.holder,
            networkID: "bsc",
            historyFromTimestamp: cursor
        )
        #expect(outcome.failures.isEmpty, "\(outcome.failures)")
        let holding = try #require(
            outcome.snapshot.assets.first { $0.id == "bsc:\(Self.tesla)" }
        )
        #expect(holding.symbol == "TSLAB")
        #expect(holding.balance > 0)
        #expect(holding.family == .bStocks)
        #expect(holding.familyLogoSource == .family(.bStocks))
        #expect(holding.networkLogoSource == .network(blockchain: .smartchain))

        // History shows a token transfer only once its fiat value is known,
        // and a load prices at most a couple of dozen distinct tokens, so a
        // hyperactive account may leave one specific bStock unpriced. The
        // family as a whole must still appear, priced through its CoinGecko
        // ids, and every such row must belong to a member.
        let familyTransfers = outcome.snapshot.transactions.filter {
            guard let contract = $0.metadata.contractAddress else { return false }
            return ReceiveAssetCatalog.family(
                forAssetIdentity: "bsc:\(contract.lowercased())"
            ) == .bStocks
        }
        #expect(
            !familyTransfers.isEmpty,
            "transactions=\(outcome.snapshot.transactions.count) symbols=\(Set(outcome.snapshot.transactions.map(\.assetSymbol)).sorted()) pricedIdentities=\(outcome.historicalTokenPrices.count)"
        )
        #expect(familyTransfers.allSatisfy { $0.assetSymbol.hasSuffix("B") })
        #expect(familyTransfers.allSatisfy { $0.fiatValue != nil })
        #expect(familyTransfers.allSatisfy { $0.metadata.blockchainIdentifier == "bsc" })
    }

    @Test
    func sendPreflightAndUnfundedBroadcastAgainstBNBChain() async throws {
        let client = try SendEVMRPCClient(networkID: "bsc")
        let recipient = "0x000000000000000000000000000000000000dead"
        // transfer(address,uint256): one whole TSLAB from the large holder.
        let data = "0xa9059cbb"
            + String(repeating: "0", count: 24) + recipient.dropFirst(2)
            + String(repeating: "0", count: 49) + "de0b6b3a7640000"
        let gas = try await client.estimateGas(
            from: Self.largeHolder,
            to: Self.tesla,
            value: "0x0",
            data: data
        )
        #expect(Int(gas.dropFirst(2), radix: 16) ?? 0 > 21_000)

        let key = PrivateKey()
        let output: EthereumSigningOutput = AnySigner.sign(
            input: EthereumSigningInput.with {
                $0.chainID = Data([0x38])
                $0.nonce = Data([0])
                $0.txMode = .legacy
                $0.gasPrice = Data([0x3b, 0x9a, 0xca, 0x00])
                $0.gasLimit = Data([0x01, 0x00, 0x00])
                $0.toAddress = Self.tesla
                $0.privateKey = key.data
                $0.transaction.erc20Transfer = .with {
                    $0.to = recipient
                    $0.amount = Data([1])
                }
            },
            coin: .smartChain
        )
        try #require(output.error == .ok, "\(output.errorMessage)")
        do {
            let hash = try await client.broadcast(
                rawTransaction: "0x" + output.encoded.hexString
            )
            Issue.record("unfunded transaction was accepted: \(hash)")
        } catch {
            let description = String(describing: error).lowercased()
            #expect(
                description.contains("insufficient funds")
                    || description.contains("insufficient balance"),
                "\(description)"
            )
        }
    }
}
#endif

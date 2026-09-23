#if LIVE_MAINNET_TESTS
import Foundation
import GRDB
import Testing
@testable import Aperture

/// Read-only public mainnet transactions; never signs or broadcasts anything.
@Suite(.serialized)
struct LiveSendTransactionStatusIntegrationTests {
    @Test
    func realReplacedBitcoinTransactionIsNotPending() async throws {
        let original = "212a538fe6a35fa69b1d3eab3f3671261ca39ea74c0453a360f109591dbcffcb"
        #expect(try await SendBitcoinExactStatus().status(hash: original) == .notFound)
        let database = try WalletDatabase.temporary()
        let asset = try SendRecipientHistoryTestFixtures.asset(networkID: "bitcoin")
        let scope = try await SendRecipientHistoryTestFixtures.seed(database, asset: asset)
        let record = SendRecipientHistoryTestFixtures.transaction(id: "public-rbf", hash: original, scope: scope,
            kind: "received", direction: "incoming", status: "pending")
        try await SendRecipientHistoryTestFixtures.save([record], in: database)
        let target = try #require(try await database.pool.read { try WalletDatabase.pendingStatusTargets(in: $0).first })
        let status = try await PendingTransactionReconciler(database: database).status(for: target)
        #expect(status == .replaced || status == .canceled)
        let replacement = try #require(try await database.pool.read {
            try DBTransactionRecord.fetchOne($0, key: record.id)?.replacementTransactionHash
        })
        print("LIVE_RBF original=\(original) replacement=\(replacement) status=\(status.rawValue)")
    }

    @Test
    func reportedBitcoinAddressHasNoCurrentPaymentOrBalance() async throws {
        let address = "bc1qvusd3lrnaz2jdxf0tj9ftug6yk54yw57twp7c2"
        let session = URLSession(configuration: .ephemeral)
        for base in ["https://mempool.space/api", "https://blockstream.info/api"] {
            let (data, response) = try await session.data(for: URLRequest(url: URL(string: base + "/address/" + address)!))
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            for key in ["chain_stats", "mempool_stats"] {
                let stats = try #require(value.object?[key]?.object)
                #expect(stats["funded_txo_sum"]?.exactInt64 == 0)
                #expect(stats["spent_txo_sum"]?.exactInt64 == 0)
                #expect(stats["tx_count"]?.exactInt64 == 0)
            }
            print("LIVE_ZERO provider=\(base) address=\(address) confirmed=0 mempool=0 transactions=0")
        }
    }

    struct Fixture: Sendable {
        let network: String
        let hash: String
    }
    static let fixtures: [Fixture] = [
        .init(network: "arc", hash: "0xc39c2a5b967427e2f9b3f58dd7b348f66324f4c0fe8b57490aa426a314db1df9"),
        .init(network: "eth", hash: "0x1fc8defb3a59e2f755922b368f17ca7ff542f441e353cc4d250ce581fb7f0f9d"),
        .init(network: "bsc", hash: "0x5b265f9a27eb503a624e848fb18612c701ae0b71d8a7e0da3d9ee1e6d57f184c"),
        .init(network: "arbitrum", hash: "0x001c6f1377be8533ef614e4742cf4deaa23dfbced308bf290fd54f87530a69cd"),
        .init(network: "base", hash: "0x050a55be66028ea9b9cf877f5bd46c0a265aa93eb62f17941d6e0d6084ccf468"),
        .init(network: "polygon", hash: "0xc30da28db79cfed945117e923a5459bcc582448b1520c4cff476b14c3136ecad"),
        .init(network: "optimism", hash: "0x30d0d6f641ace39ce018a6ea224aa71eda7d30b4b4f3159775f8085b7c08a9f2"),
        .init(network: "avalanche", hash: "0x2c4db67886e6fc93898bc02f0daa4d7841b172077f51fec999a40e225e8e9db2"),
        .init(network: "gnosis", hash: "0xaf88e281a9f8a91cce797d169ee22ea5356aba4d8a3e7bdb39c36cc0bb60b320"),
        .init(network: "linea", hash: "0xbf4f439efaff6105fc4056f895d2234afba15c5e738258be35c88e9c1a99792d"),
        .init(network: "scroll", hash: "0x9c698c069fa29208dd16634f739dbabcd4874fe0afdc6f8f0bce96829d1ba664"),
        .init(network: "taiko", hash: "0x24fbb2a28bfb1d736884574bacbc5175d4a2050215d435bf930bbcd6e3d1dd24"),
        .init(network: "telos", hash: "0xf4ac2f0dc91535a57c1753ab09ae785da3e20c9e285d0601b8a5254965fb76d0"),
        .init(network: "xlayer", hash: "0xa571599ac1c768b21addcfd6584a3bb6855909d26a3f75e99fd24f81a3f00393"),
        .init(network: "bitcoin", hash: "14451b9b84fbf6da82e657f99942c9133a1202bb036440e12b31153a11f3c988"),
        .init(network: "bitcoin_cash", hash: "e70931d40d8a518d91c6029bc31367bc74ba72858bafb864af1b592ca3c6c2bb"),
        .init(network: "litecoin", hash: "b3f83886b9438c8d2572ad913cf881e30602f37357d8bcadeaff25422e81be69"),
        .init(network: "dogecoin", hash: "59524ebe5c7f7c4758e9bca50b49e6ffc72e615d8caef7354d5c3dbfad37ee5b"),
        .init(network: "solana", hash: "3uqECqL29L4SCkKiFNYY1sMFf2Di74fjnTsF9EMt7bmLgWH8DhRw9PzLK62NcUW7e4TaGKCHWejtot3aevXMgPPY"),
        .init(network: "tron", hash: "4143baf9405828e7ed88aff28fde5de6f22b71cea28d18bc7934c7b131e22549"),
        .init(network: "ton", hash: "cdc66226bd0ce4a0e2fa96923eb66f28e6311a3b0ee68ae2f52f7a87d7447282"),
        .init(network: "sui", hash: "Auxh58uWkyeA99yWP6WdJ5tK1UTcJc4nw3GT3Jcw1B2k"),
        .init(network: "xrp", hash: "008BC97D25C3EB3EA827EFD05F7936BC00E1F57054035E4EAC6CF6D128EC7C73"),
        .init(network: "near", hash: "BaQqYWtjb3T8dL745gohGhNQGWci5DsfjodBAtkC2gGs"),
        .init(network: "aptos", hash: "0x45e0dec68c265f59ccee967aafeacdb18342e921a86ff034e5619356b9a585cf"),
        .init(network: "stellar", hash: "3a00ff3daf8d232ee6f97e417bb7cfc9e74d551f35ff5d401795f2bd8bfef342")
    ]

    @Test(arguments: fixtures)
    func exactLookupConfirmsMainnet(fixture: Fixture) async throws {
        let receipt = SendTransactionReceipt(transactionHash: fixture.hash, accountID: "public-read-only",
            networkID: fixture.network,
            fromAddress: fixture.network == "near" ? "omni-relayer.bridge.near" : "",
            toAddress: "", assetID: "", assetSymbol: "", amount: "0", amountAtomic: "0",
            networkFee: nil, networkFeeAtomic: nil, networkFeeSymbol: "", submittedAt: Date())
        let start = ContinuousClock.now
        do {
            let status = try await SendStatusRequestPool.shared.status(for: receipt)
            print("LIVE_STATUS network=\(fixture.network) status=\(status.rawValue) elapsed=\(start.duration(to: .now))")
            #expect(status == .confirmed)
        } catch {
            print("LIVE_STATUS network=\(fixture.network) error=\(SendTransactionStatusService.diagnosticCode(error)) elapsed=\(start.duration(to: .now))")
            throw error
        }
    }
}
#endif

#if LIVE_MAINNET_TESTS
import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct LiveSendNetworkFeeIntegrationTests {
    @Test
    func workerReturnsLiveValidatedFeesForEveryRoutedMainnet()
        async throws
    {
        let baseURL = try #require(URL(
            string: "https://aperture-notifications.devdas98x.workers.dev"
        ))
        let client = try SendNetworkFeeAPIClient(baseURL: baseURL)

        #expect(SendNetworkFeeAPIClient.workerQuoteNetworkIDs.count == 20)
        for networkID in SendNetworkFeeAPIClient
            .workerQuoteNetworkIDs.sorted() {
            let quote = try await client.quote(for: networkID)
            #expect(
                quote.provider
                    != SendNetworkFeeAPIClient.builtInDefaultProvider,
                "Expected a live worker fee for \(networkID); received \(quote.provider)."
            )
            #expect(
                SendNetworkFeeAPIClient.isValid(
                    quote,
                    expectedNetworkID: networkID
                ),
                "Invalid live worker fee for \(networkID)."
            )
        }
    }

    @Test
    func directRPCsReturnLiveValidatedFeesForEveryDirectMainnet()
        async throws
    {
        #expect(SendNetworkFeeAPIClient.directQuoteNetworkIDs.count == 5)
        for networkID in SendNetworkFeeAPIClient
            .directQuoteNetworkIDs.sorted() {
            let quote = try await SendNetworkFeeAPIClient.quote(
                for: networkID
            )
            #expect(
                quote.provider
                    != SendNetworkFeeAPIClient.builtInDefaultProvider,
                "Expected a live direct fee for \(networkID); received \(quote.provider)."
            )
            #expect(
                SendNetworkFeeAPIClient.isValid(
                    quote,
                    expectedNetworkID: networkID
                ),
                "Invalid live direct fee for \(networkID)."
            )
        }
        #expect(
            SendNetworkFeeAPIClient.directQuoteNetworkIDs.union(
                SendNetworkFeeAPIClient.workerQuoteNetworkIDs
            ) == SendNetworkFeeAPIClient.supportedQuoteNetworkIDs
        )
        #expect(SendNetworkFeeAPIClient.supportedQuoteNetworkIDs.count == 25)
    }

    @Test
    func verifiedHTTPSAPIsReturnLiveFeesForEveryBitcoinFamilyMainnet()
        async throws
    {
        for chain in BitcoinFamilyChain.allCases {
            let quote: SendNetworkFeeQuote
            do {
                quote = try await SendBitcoinFamilyHTTPAPIClient.quote(
                    for: chain
                )
            } catch {
                Issue.record(
                    "HTTPS fee API failed for \(chain.networkID): \(error)"
                )
                continue
            }
            #expect(!quote.provider.contains("electrum"))
            #expect(
                SendNetworkFeeAPIClient.isValid(
                    quote,
                    expectedNetworkID: chain.networkID
                ),
                "Invalid HTTPS fee for \(chain.networkID)."
            )
            if chain == .dogecoin {
                for tier in quote.tiers {
                    #expect(
                        UInt64(tier.primaryValue) ?? 0 >= 1_000,
                        "Dogecoin fee is below its relay minimum."
                    )
                }
            }
        }
    }
}
#endif

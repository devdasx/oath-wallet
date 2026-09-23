import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct SendRecipientNameLiveTests {
    @Test
    func liveMainnetNameServicesResolveRepresentativeRecords()
        async throws
    {
        guard
            ProcessInfo.processInfo.environment[
                "APERTURE_RUN_LIVE_NAME_TESTS"
            ] == "1"
        else {
            return
        }

        let resolver = SendRecipientNameResolver()
        let directENS = try await resolver.resolve(
            "ur.integration-tests.eth",
            networkID: "eth"
        )
        #expect(
            directENS.lowercased()
                == "0x2222222222222222222222222222222222222222"
        )

        let ccipReadENS = try await resolver.resolve(
            "test.offchaindemo.eth",
            networkID: "eth"
        )
        #expect(
            ccipReadENS.lowercased()
                == "0x779981590e7ccc0cfae8040ce7151324747cdb97"
        )

        let bitcoinENS = try await resolver.resolve(
            "gregskril.eth",
            networkID: "bitcoin"
        )
        #expect(
            SendAddressValidator.isValid(
                bitcoinENS,
                for: "bitcoin"
            )
        )
        let solanaENS = try await resolver.resolve(
            "gregskril.eth",
            networkID: "solana"
        )
        #expect(
            SendAddressValidator.isValid(
                solanaENS,
                for: "solana"
            )
        )

        let solanaName = try await resolver.resolve(
            "bonfida.sol",
            networkID: "solana"
        )
        #expect(
            SendAddressValidator.isValid(
                solanaName,
                for: "solana"
            )
        )

        let bnbName = try await resolver.resolve(
            "spaceid.bnb",
            networkID: "bsc"
        )
        #expect(
            SendAddressValidator.isValid(
                bnbName,
                for: "bsc"
            )
        )
        let arbitrumName = try await resolver.resolve(
            "0x5206.arb",
            networkID: "arbitrum"
        )
        #expect(
            SendAddressValidator.isValid(
                arbitrumName,
                for: "arbitrum"
            )
        )
    }
}

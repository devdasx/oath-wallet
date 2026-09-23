import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct SendRecipientNameEntryValidationTests {
    private static let ethereumAddress =
        "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
    private static let replacementEthereumAddress =
        "0x2222222222222222222222222222222222222222"

    @Test
    @MainActor
    func completeNameStartsResolutionDuringRecipientEntry() async {
        let calls = ResolutionCallRecorder()
        let model = SendRecipientNameResolutionModel {
            name,
            networkID in
            await calls.record(name: name, networkID: networkID)
            return Self.ethereumAddress
        }

        model.schedule(
            sourceRecipient: "vitalik.eth",
            networkID: "eth",
            debounce: .zero
        )

        #expect(
            model.isResolving(
                sourceRecipient: "vitalik.eth",
                networkID: "eth"
            )
        )
        #expect(
            model.validatedRecipient(
                sourceRecipient: "vitalik.eth",
                networkID: "eth"
            ) == nil
        )

        await model.waitForScheduledResolution()

        #expect(
            await calls.values()
                == [ResolutionCall(name: "vitalik.eth", networkID: "eth")]
        )
        #expect(
            model.validatedRecipient(
                sourceRecipient: "vitalik.eth",
                networkID: "eth"
            ) == Self.ethereumAddress
        )
        #expect(
            model.issue(
                sourceRecipient: "vitalik.eth",
                networkID: "eth"
            ) == nil
        )
    }

    @Test
    @MainActor
    func everySupportedNameRouteStartsEntryTimeResolution() async throws {
        let calls = ResolutionCallRecorder()
        let model = SendRecipientNameResolutionModel {
            name,
            networkID in
            await calls.record(name: name, networkID: networkID)
            throw SendRecipientNameError.notFound
        }
        let names = [
            "vitalik.eth",
            "bonfida.sol",
            "spaceid.bnb",
            "spaceid.four",
            "0x5206.arb",
            "resolver.gno",
            "resolver.taiko",
            "alice@spaceid"
        ]
        var expected = Set<ResolutionCall>()

        for name in names {
            let descriptor = try #require(
                try SendRecipientNameParser.descriptor(for: name)
            )
            for networkID in descriptor.candidateNetworkIDs {
                let call = ResolutionCall(
                    name: descriptor.input,
                    networkID: networkID
                )
                expected.insert(call)
                model.schedule(
                    sourceRecipient: name,
                    networkID: networkID,
                    debounce: .zero
                )
                #expect(
                    model.isResolving(
                        sourceRecipient: name,
                        networkID: networkID
                    )
                )
                await model.waitForScheduledResolution()
                #expect(
                    model.issue(
                        sourceRecipient: name,
                        networkID: networkID
                    ) == .notFound
                )
            }
        }

        #expect(Set(await calls.values()) == expected)
        let ensNetworks = try #require(
            try SendRecipientNameParser.descriptor(for: "vitalik.eth")
        ).candidateNetworkIDs
        #expect(
            Set(ensNetworks)
                == Set(ENSAddressCodec.supportedNetworkIDs)
        )
    }

    @Test
    @MainActor
    func directAddressNeverStartsNameResolution() async {
        let calls = ResolutionCallRecorder()
        let model = SendRecipientNameResolutionModel {
            name,
            networkID in
            await calls.record(name: name, networkID: networkID)
            return Self.ethereumAddress
        }

        model.schedule(
            sourceRecipient: Self.ethereumAddress,
            networkID: "eth",
            debounce: .zero
        )
        await model.waitForScheduledResolution()

        #expect(await calls.values().isEmpty)
        #expect(
            model.validatedRecipient(
                sourceRecipient: Self.ethereumAddress,
                networkID: "eth"
            ) == Self.ethereumAddress
        )
    }

    @Test
    @MainActor
    func resolutionFailureBlocksTheCurrentNameAndCanRetry() async {
        let attempts = ResolutionAttemptCounter()
        let model = SendRecipientNameResolutionModel {
            _,
            _ in
            let attempt = await attempts.increment()
            if attempt == 1 {
                throw SendRecipientNameError.serviceUnavailable
            }
            return Self.ethereumAddress
        }

        model.schedule(
            sourceRecipient: "vitalik.eth",
            networkID: "eth",
            debounce: .zero
        )
        await model.waitForScheduledResolution()

        #expect(
            model.issue(
                sourceRecipient: "vitalik.eth",
                networkID: "eth"
            ) == .serviceUnavailable
        )
        #expect(
            model.canRetry(
                sourceRecipient: "vitalik.eth",
                networkID: "eth"
            )
        )
        #expect(
            model.validatedRecipient(
                sourceRecipient: "vitalik.eth",
                networkID: "eth"
            ) == nil
        )

        model.retry()
        await model.waitForScheduledResolution()

        #expect(
            model.validatedRecipient(
                sourceRecipient: "vitalik.eth",
                networkID: "eth"
            ) == Self.ethereumAddress
        )
        #expect(await attempts.value() == 2)
    }

    @Test
    @MainActor
    func staleResolutionCannotReplaceNewerRecipient() async {
        let resolver = ControlledNameResolver(
            oldAddress: Self.ethereumAddress,
            newAddress: Self.replacementEthereumAddress
        )
        let model = SendRecipientNameResolutionModel {
            name,
            networkID in
            await resolver.resolve(name: name, networkID: networkID)
        }

        model.schedule(
            sourceRecipient: "old.eth",
            networkID: "eth",
            debounce: .zero
        )
        await resolver.waitUntilOldRequestStarts()

        model.schedule(
            sourceRecipient: "new.eth",
            networkID: "eth",
            debounce: .zero
        )
        await model.waitForScheduledResolution()
        await resolver.finishOldRequest()
        await Task.yield()

        #expect(
            model.validatedRecipient(
                sourceRecipient: "new.eth",
                networkID: "eth"
            ) == Self.replacementEthereumAddress
        )
        #expect(
            model.validatedRecipient(
                sourceRecipient: "old.eth",
                networkID: "eth"
            ) == nil
        )
    }

    @Test
    @MainActor
    func wrongNetworkAndMalformedNamesNeverCallAResolver() async {
        let calls = ResolutionCallRecorder()
        let model = SendRecipientNameResolutionModel {
            name,
            networkID in
            await calls.record(name: name, networkID: networkID)
            return Self.ethereumAddress
        }
        let inputs = ["bonfida.sol", "wallet..eth", "wallet.example"]

        for input in inputs {
            model.schedule(
                sourceRecipient: input,
                networkID: "eth",
                debounce: .zero
            )
            await model.waitForScheduledResolution()
            #expect(
                model.validatedRecipient(
                    sourceRecipient: input,
                    networkID: "eth"
                ) == nil
            )
        }

        #expect(await calls.values().isEmpty)
    }

    @Test
    @MainActor
    func resolvedNameWaitsForRequiredRecipientPreflight() async throws {
        let asset = SendAssetChoice(
            id: "solana:native",
            name: "Solana",
            symbol: SolanaConstants.nativeSymbol,
            networkID: SolanaConstants.networkID,
            networkName: "Solana",
            blockchain: .solana,
            contractAddress: nil,
            decimals: SolanaConstants.decimals,
            logoSource: .nativeCoin(blockchain: .solana),
            networkLogoSource: .network(blockchain: .solana),
            balance: 10,
            fiatValue: 0
        )
        let sourceName = "bonfida.sol"
        let resolvedAddress =
            "mvines9iiHiQTysrwkJjGf2gb9Ex9jXJX8ns3qwf2kN"
        let model = SendRecipientRequirementModel { _, _ in .none }

        #expect(
            !model.allowsReview(
                asset: asset,
                sourceRecipient: sourceName,
                assetAmount: "1",
                baseFormIsValid: true
            )
        )

        let input = try #require(
            SendRecipientRequirementInput(
                asset: asset,
                sourceRecipient: sourceName,
                checkedRecipient: resolvedAddress
            )
        )
        model.schedule(input: input, asset: asset, debounce: .zero)
        await model.waitForScheduledRefresh()

        #expect(
            model.allowsReview(
                asset: asset,
                sourceRecipient: sourceName,
                assetAmount: "1",
                baseFormIsValid: true
            )
        )
    }
}

private struct ResolutionCall: Hashable, Sendable {
    let name: String
    let networkID: String
}

private actor ResolutionCallRecorder {
    private var calls: [ResolutionCall] = []

    func record(name: String, networkID: String) {
        calls.append(ResolutionCall(name: name, networkID: networkID))
    }

    func values() -> [ResolutionCall] {
        calls
    }
}

private actor ResolutionAttemptCounter {
    private var attempts = 0

    func increment() -> Int {
        attempts += 1
        return attempts
    }

    func value() -> Int {
        attempts
    }
}

private actor ControlledNameResolver {
    private let oldAddress: String
    private let newAddress: String
    private var oldContinuation: CheckedContinuation<String, Never>?

    init(oldAddress: String, newAddress: String) {
        self.oldAddress = oldAddress
        self.newAddress = newAddress
    }

    func resolve(name: String, networkID: String) async -> String {
        guard name == "old.eth" else { return newAddress }
        return await withCheckedContinuation { continuation in
            oldContinuation = continuation
        }
    }

    func waitUntilOldRequestStarts() async {
        while oldContinuation == nil {
            await Task.yield()
        }
    }

    func finishOldRequest() {
        let continuation = oldContinuation
        oldContinuation = nil
        continuation?.resume(returning: oldAddress)
    }
}

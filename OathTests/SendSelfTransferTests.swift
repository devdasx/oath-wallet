import Foundation
import Testing
@testable import Aperture

@MainActor
struct SendSelfTransferTests {
    @Test(arguments: AssetNetworkSelectorOption.allSupported)
    func nativeRulesCoverEverySupportedNetwork(network: AssetNetworkSelectorOption) throws {
        let asset = try asset(networkID: network.id)
        let sender = try #require(asset.sourceAddress)
        let expected: SendRecipientValidationIssue? = ["tron", "xrp"].contains(network.id)
            ? .selfTransferNotSupported : nil
        #expect(SendFlowPlanner.recipientIssue(sender, asset: asset) == expected)
        let model = SendRecipientEntryModel(draft: draft(asset, recipient: sender))
        #expect(model.canContinue == (expected == nil))
        #expect(model.displayedRecipientIssue == expected)
    }

    @Test(arguments: AssetNetworkSelectorOption.allSupported.filter {
        BitcoinFamilyChain(rawValue: $0.id) == nil
    })
    func tokenRulesAreSeparateFromNativeRules(network: AssetNetworkSelectorOption) throws {
        let asset = try asset(networkID: network.id, token: true)
        let expected: SendRecipientValidationIssue? = ["near", "xrp"].contains(network.id)
            ? .selfTransferNotSupported : nil
        let sender = try #require(asset.sourceAddress)
        #expect(SendFlowPlanner.recipientIssue(sender, asset: asset) == expected)
        #expect(SendRecipientEntryModel(draft: draft(asset, recipient: sender)).canContinue == (expected == nil))
    }

    @Test(arguments: ["tron", "xrp", "near-token"])
    func allEntryMethodsBlockSelfAndRecoverAfterCorrection(kind: String) throws {
        let asset = try blockedAsset(kind)
        let sender = try #require(asset.sourceAddress)
        let other = differentRecipient(kind)
        #expect(SendAddressValidator.isValid(other, for: asset.networkID))
        let model = SendRecipientEntryModel(draft: draft(asset))
        #expect(model.displayedRecipientIssue == nil)

        model.setRecipient(sender)
        assertBlocked(model)
        model.setRecipient(other)
        #expect(model.canContinue)

        #expect(model.paste(sender))
        assertBlocked(model)
        #expect(model.paste(other))
        #expect(model.canContinue)

        model.applyScannedRecipient(sender)
        assertBlocked(model)
        model.applyScannedRecipient(other)
        #expect(model.canContinue)

        let identity = try #require(SendRecipientIdentity(address: sender, networkID: asset.networkID))
        model.applyRecentRecipient(.init(id: identity, address: sender, sendCount: 1, lastSentAt: .now))
        assertBlocked(model)
        model.setRecipient(other)
        #expect(model.continueDraft()?.recipient == other)
    }

    @Test(arguments: ["tron", "xrp", "near-token"])
    func prefilledRoutesCannotSkipRecipientWithAnAmount(kind: String) throws {
        let asset = try blockedAsset(kind)
        let sender = try #require(asset.sourceAddress)
        let request = SendPaymentRequest(
            source: .bareAddress, recipient: sender, candidateNetworkIDs: [asset.networkID],
            requestedNetworkID: asset.networkID,
            requestedAsset: asset.contractAddress.map { .contract($0) } ?? .native,
            requestedAmount: .userUnits("1"), label: nil, message: nil, memo: nil, references: []
        )
        for route in [
            try SendFlowPlanner.initialRoute(for: request, choices: [asset]),
            try SendFlowPlanner.recipientEntryRoute(afterSelecting: asset, for: request),
            SendFlowPlanner.amountEntryRoute(afterRecipient: draft(asset, recipient: sender))
        ] {
            guard case let .recipient(_, failure) = route else {
                Issue.record("A forbidden self-transfer skipped Recipient")
                continue
            }
            #expect(failure?.recipientIssue == .selfTransferNotSupported)
        }
        let review = SendFlowPlanner.reviewDraft(
            from: draft(asset), recipient: sender, amount: "1", note: nil
        )
        guard case let .failure(failure) = review else {
            Issue.record("A forbidden self-transfer reached Review")
            return
        }
        #expect(failure.recipientIssue == .selfTransferNotSupported)
    }

    @Test
    func tronPaymentURIKeepsAmountButShowsRecipientError() throws {
        let asset = try asset(networkID: "tron")
        let sender = try #require(asset.sourceAddress)
        let model = SendRecipientEntryModel(draft: draft(asset))
        #expect(model.paste("tron:\(sender)?amount=1"))
        #expect(model.requestedAmount == "1")
        assertBlocked(model)
    }

    @Test
    func resolvedNameCannotBypassSelfTransferRule() async throws {
        let asset = try asset(networkID: "tron")
        let sender = try #require(asset.sourceAddress)
        let other = differentRecipient("tron")
        let resolution = SendRecipientNameResolutionModel { name, network in
            #expect(network == "tron")
            return name == "self.eth" ? sender : other
        }
        let model = SendRecipientEntryModel(
            draft: draft(asset, recipient: "self.eth"), nameResolution: resolution
        )
        model.scheduleNameResolution()
        #expect(!model.canContinue)
        await resolution.waitForScheduledResolution()
        #expect(model.resolvedRecipient == sender)
        assertBlocked(model)
        model.setRecipient("recipient.eth")
        await resolution.waitForScheduledResolution()
        #expect(model.continueDraft()?.recipient == other)
    }

    @Test(arguments: [
        "rnBFvgZphmN39GWzUJeUitaP22Fr9be75H",
        "X76UnYEMbQfEs3mUqgtjp4zFy9exgThRj7XVZ6UxsdrBptF",
        "X76UnYEMbQfEs3mUqgtjp4zFy9exgTsM93nriVZAPufrpE3",
        "X76UnYEMbQfEs3mUqgtjp4zFy9exgSxWAqcQwu9z2r5d7Tm"
    ])
    func xrpAliasesAndTagsDoNotChangeSenderIdentity(recipient: String) throws {
        for token in [false, true] {
            let asset = try asset(networkID: "xrp", token: token)
            let model = SendRecipientEntryModel(draft: draft(asset, recipient: recipient))
            model.setMemo("12345")
            assertBlocked(model)
            #expect(SendFlowPlanner.recipientIssue("  \(recipient)  ", asset: asset) == .selfTransferNotSupported)
        }
    }

    @Test
    func malformedOrMissingSourceDoesNotInventSelfTransferAndBase58KeepsCase() throws {
        let native = try asset(networkID: "tron")
        let sender = try #require(native.sourceAddress)
        #expect(SendFlowPlanner.recipientIssue(sender.lowercased(), asset: native) == .invalidForNetwork)
        #expect(SendSelfTransferPolicy.recipientIssue(sender, asset: native, sourceAddress: "invalid") == nil)
        let missingSource = try asset(networkID: "tron", source: "")
        #expect(SendSelfTransferPolicy.recipientIssue(sender, asset: missingSource) == nil)
        #expect(SendFlowPlanner.recipientIssue("", asset: native) == .required)
    }

    @Test(arguments: ["tron", "xrp", "xrp-token", "near-token"])
    func submissionRejectsUsingActualSigningAccountBeforeAnyNetworkWork(kind: String) async throws {
        let networkID = kind.replacingOccurrences(of: "-token", with: "")
        let sender = SendEntryTestFixtures.address(for: try #require(
            AssetNetworkSelectorOption.allSupported.first { $0.id == networkID }
        ).blockchain)
        // Deliberately stale source metadata: the service must compare the
        // actual signing account, not trust only the earlier screen's draft.
        let asset = try asset(networkID: networkID, token: kind.hasSuffix("-token"), source: differentRecipient(kind))
        let draft = draft(asset, recipient: sender)
        let material = material(networkID: networkID, address: sender)
        let reservation = NoSelfTransferReservation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoSelfTransferNetwork.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        await #expect(throws: SendTransactionSubmissionError.selfTransferNotSupported) {
            switch networkID {
            case "tron":
                _ = try await SendTronTransactionService(api: .init(session: session)).submit(
                    draft: draft, material: material, reservation: reservation
                )
            case "xrp":
                let transport = try XRPJSONRPCTransport(endpoint: URL(string: "https://xrp.invalid")) { _ in
                    Issue.record("Self-transfer reached XRP provider")
                    throw URLError(.badURL)
                }
                _ = try await SendXRPTransactionService(api: .init(transport: transport), quoteLoader: { _ in
                    Issue.record("Self-transfer requested XRP fees")
                    throw URLError(.badURL)
                }).submit(draft: draft, material: material, reservation: reservation)
            default:
                let transport = try NEARJSONRPCTransport(endpoint: URL(string: "https://near.invalid")) { _ in
                    Issue.record("Self-transfer reached NEAR provider")
                    throw URLError(.badURL)
                }
                _ = try await SendNEARTransactionService(api: .init(transport: transport, session: session)).submit(
                    draft: draft, material: material, reservation: reservation
                )
            }
        }
    }

    @Test
    func tronFeeEstimationRejectsSelfBeforeAPIRequest() async throws {
        let asset = try asset(networkID: "tron")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NoSelfTransferNetwork.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = SendTronTransactionService(api: .init(session: session))
        await #expect(throws: SendTransactionSubmissionError.selfTransferNotSupported) {
            _ = try await service.estimatedNetworkFeeAtomic(
                draft: draft(asset, recipient: try #require(asset.sourceAddress)),
                fee: .init(model: .tronProtocol, primaryValue: "100", secondaryValue: "1000")
            )
        }
    }

    private func assertBlocked(_ model: SendRecipientEntryModel) {
        #expect(model.displayedRecipientIssue == .selfTransferNotSupported)
        #expect(!model.canContinue)
        #expect(model.continueDraft() == nil)
    }

    private func blockedAsset(_ kind: String) throws -> SendAssetChoice {
        try asset(networkID: kind.replacingOccurrences(of: "-token", with: ""), token: kind.hasSuffix("-token"))
    }

    private func asset(networkID: String, token: Bool = false, source: String? = nil) throws -> SendAssetChoice {
        let network = try #require(AssetNetworkSelectorOption.allSupported.first { $0.id == networkID })
        let native = try SendEntryTestFixtures.nativeChoice(for: network)
        let contract: String? = token ? (networkID == "near" ? "wrap.near" : "token-fixture") : nil
        return SendAssetChoice(
            id: native.id, name: native.name, symbol: native.symbol,
            networkID: network.id, networkName: native.networkName, blockchain: native.blockchain,
            contractAddress: contract, decimals: native.decimals,
            logoSource: native.logoSource, networkLogoSource: native.networkLogoSource,
            balance: native.balance, fiatValue: native.fiatValue,
            sourceAddress: source ?? SendEntryTestFixtures.address(for: network.blockchain)
        )
    }

    private func differentRecipient(_ kind: String) -> String {
        switch kind {
        case "tron": "TJRabPrwbZy45sbavfcjinPJC18kjpRTv8"
        case "xrp", "xrp-token": "rPEPPER7kfTD9w2To4CQk6UCfuHM9c6GDY"
        default: "bob.near"
        }
    }

    private func draft(_ asset: SendAssetChoice, recipient: String = "") -> SendDraft {
        SendEntryTestFixtures.draft(asset: asset, recipient: recipient, amount: "1")
    }

    private func material(networkID: String, address: String) -> SendResolvedSigningMaterial {
        let account = DBWalletAccountRecord(
            id: UUID().uuidString, walletID: "fixture", networkID: networkID,
            address: address, normalizedAddress: address, label: nil, derivationPath: nil,
            accountIndex: 0, publicKey: nil, isWatchOnly: false, isEnabled: true,
            createdAt: Date().timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970, lastSyncedAt: nil
        )
        return .init(walletID: account.walletID, account: account, privateKey: Data())
    }
}

private struct NoSelfTransferReservation: SendSpendSubmissionReserving {
    func pendingSpendResources() async throws -> Set<SendSpendResource> {
        Issue.record("Self-transfer reached resource allocation")
        return []
    }
    func markSubmissionStarted(receipt: SendTransactionReceipt) async throws {
        Issue.record("Self-transfer reached broadcast")
        throw URLError(.badURL)
    }
}

private final class NoSelfTransferNetwork: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Issue.record("Self-transfer made an unexpected network request")
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
    }
    override func stopLoading() {}
}

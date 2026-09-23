import Foundation
import Testing
@testable import Aperture

@MainActor
struct SendRecipientEntryTests {
    @Test
    func everyChainHasAnIndependentPromptInEveryShippedLanguage() throws {
        let networks = AssetNetworkSelectorOption.allSupported
        let keys = networks.map { SendRecipientPlaceholder.key(for: $0.id) }
        #expect(Set(keys).count == networks.count)
        #expect(!keys.contains("send.recipient.placeholder"))
        let languages = Set(Bundle.main.localizations.filter { $0 != "Base" }).sorted()
        #expect(languages.count == 57)
        for language in languages {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for network in networks {
                let key = SendRecipientPlaceholder.key(for: network.id)
                let prompt = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
                #expect(prompt != "MISSING", "\(language): \(key)")
                #expect(!prompt.isEmpty && !prompt.contains("%@"))
                #expect(prompt.contains("sp1…") == (network.blockchain == .bitcoin))
                #expect(prompt.contains(".sol") == (network.blockchain == .solana))
                let isEVM = SendAddressValidator.evmNetworks.contains { $0.id == network.id }
                if !isEVM {
                    #expect(!prompt.contains(".eth") && !prompt.contains("ENS"),
                            "\(language): \(network.id) must advertise its own chain formats")
                } else {
                    #expect(prompt.contains(".eth"))
                }
                #expect(!prompt.contains(".ens"))
                for (suffix, owner) in [
                    (".bnb", "bsc"), (".four", "bsc"),
                    (".arb", "arbitrum"), (".gno", "gnosis"),
                    (".taiko", "taiko")
                ] {
                    #expect(prompt.contains(suffix) == (network.id == owner),
                            "\(language): wrong network for \(suffix)")
                }
                switch network.blockchain {
                case .bitcoin: #expect(prompt.contains("bc1…"))
                case .bitcoincash: #expect(prompt.contains("bitcoincash:…"))
                case .litecoin: #expect(prompt.contains("ltc1…"))
                case .dogecoin: #expect(prompt.contains("D…"))
                case .tron: #expect(prompt.contains("T…"))
                case .solana: #expect(prompt.contains("Base58"))
                default: break
                }
                if network.blockchain == .stellar {
                    #expect(prompt.contains("G…") && !prompt.contains("M…"))
                }
                if network.blockchain == .ton {
                    #expect(prompt.contains("EQ…") && prompt.contains("UQ…"))
                    #expect(!prompt.contains(".ton"))
                }
                #expect(prompt.filter { $0 == "\u{2068}" }.count
                    == prompt.filter { $0 == "\u{2069}" }.count)
            }
        }
        #expect(SendRecipientPlaceholder.key(for: "unknown") == "send.recipient.placeholder")
    }

    @Test(arguments: AssetNetworkSelectorOption.allSupported)
    func everySupportedNetworkStartsWithRecipientThenAmount(
        network: AssetNetworkSelectorOption
    ) throws {
        let asset = try SendEntryTestFixtures.nativeChoice(for: network)
        guard case let .recipient(draft, failure) = SendFlowPlanner.manualEntryRoute(for: asset) else {
            Issue.record("Manual Send must begin with Recipient")
            return
        }
        #expect(failure == nil)
        #expect(draft.recipient.isEmpty)
        #expect(draft.amount == nil)
        let model = SendRecipientEntryModel(draft: draft)
        #expect(!model.canContinue)
        model.setRecipient(SendEntryTestFixtures.address(for: network.blockchain))
        #expect(model.canContinue)
        let recipientDraft = try #require(model.continueDraft())
        #expect(recipientDraft.amount == nil)
        guard case let .amount(amountDraft, amountFailure) = SendFlowPlanner.amountEntryRoute(
            afterRecipient: recipientDraft
        ) else {
            Issue.record("Valid Recipient must push Amount, never Review")
            return
        }
        #expect(amountDraft == recipientDraft)
        #expect(amountFailure == nil)
    }

    @Test
    func invalidRecipientCannotContinueEvenWithAnAmount() {
        let model = SendRecipientEntryModel(draft: SendEntryTestFixtures.draft(recipient: "bad", amount: "1"))
        #expect(model.continueDraft() == nil)
        #expect(model.displayedRecipientIssue == .invalidForNetwork)
        model.setRecipient(String(repeating: "a", count: 256))
        #expect(model.recipient == "bad")
        model.setRecipient("bad\naddress")
        #expect(model.recipient == "bad")
    }

    @Test
    func supportedNameMustResolveBeforeRecipientCanContinue() async throws {
        let address = SendEntryTestFixtures.address(for: .ethereum)
        let resolver = SendRecipientNameResolutionModel { name, network in
            #expect(name == "vitalik.eth")
            #expect(network == "eth")
            return address
        }
        let model = SendRecipientEntryModel(
            draft: SendEntryTestFixtures.draft(recipient: ""), nameResolution: resolver
        )
        model.setRecipient("vitalik.eth")
        #expect(model.isResolvingName)
        #expect(!model.canContinue)
        #expect(model.continueDraft() == nil)
        await resolver.waitForScheduledResolution()
        #expect(model.canContinue)
        #expect(model.continueDraft()?.recipient == address)
        model.setRecipient("missing.eth")
        #expect(!model.canContinue)
        resolver.cancel()
    }

    @Test
    func unsuccessfulNameResolutionStaysOnRecipientWithActionableError() async {
        let resolver = SendRecipientNameResolutionModel { _, _ in
            throw SendRecipientNameError.notFound
        }
        let model = SendRecipientEntryModel(
            draft: SendEntryTestFixtures.draft(recipient: ""), nameResolution: resolver
        )
        model.setRecipient("missing.eth")
        await resolver.waitForScheduledResolution()
        #expect(!model.canContinue)
        #expect(model.displayedRecipientIssue == .name(.notFound))
        #expect(model.continueDraft() == nil)
    }

    @Test
    func pastePreservesPaymentAmountAndMetadataForFollowingScreen() throws {
        let network = try #require(AssetNetworkSelectorOption.allSupported.first { $0.id == "bitcoin" })
        let asset = try SendEntryTestFixtures.nativeChoice(for: network)
        let model = SendRecipientEntryModel(draft: SendEntryTestFixtures.draft(asset: asset, recipient: ""))
        let recipient = SendEntryTestFixtures.address(for: .bitcoin)
        #expect(model.paste("bitcoin:\(recipient)?amount=0.12345678&label=Invoice&message=Order"))
        #expect(model.canContinue)
        let draft = try #require(model.continueDraft())
        #expect(draft.amount == "0.12345678")
        #expect(draft.request.label == "Invoice")
        #expect(draft.request.message == "Order")
        guard case let .amount(next, _) = SendFlowPlanner.amountEntryRoute(afterRecipient: draft) else {
            Issue.record("Pasting on Recipient must still push Amount")
            return
        }
        #expect(next == draft)
        #expect(SendAmountEntryState(draft: next).input == "0.12345678")
    }

    @Test
    func wrongNetworkPasteDoesNotReplaceRecipientOrAmount() {
        let original = SendEntryTestFixtures.draft(amount: "0.1")
        let model = SendRecipientEntryModel(draft: original)
        #expect(!model.paste(SendEntryTestFixtures.address(for: .bitcoin)))
        #expect(model.actionError != nil)
        #expect(model.recipient == original.recipient)
        #expect(model.requestedAmount == "0.1")
        #expect(!model.canContinue)
        #expect(model.continueDraft() == nil)
        #expect(model.paste(original.recipient))
        #expect(model.canContinue)
    }

    @Test
    func scanReplacesOnlyRecipientAndRetainsNoteFeeMemoAndAmount() throws {
        let network = try #require(AssetNetworkSelectorOption.allSupported.first { $0.id == "xrp" })
        let asset = try SendEntryTestFixtures.nativeChoice(for: network)
        let model = SendRecipientEntryModel(draft: SendEntryTestFixtures.draft(
            asset: asset, recipient: "", amount: "1.5", memo: "123"
        ))
        model.note = "Payment"
        model.feePolicy = .preset(.economy)
        model.applyScannedRecipient(SendEntryTestFixtures.address(for: .xrp))
        let next = try #require(model.continueDraft())
        #expect(next.amount == "1.5")
        #expect(next.note == "Payment")
        #expect(next.request.memo == "123")
        #expect(next.feePolicy == model.feePolicy)
    }

    @Test
    func destinationTagRejectsUnicodeAndOutOfRangeValuesBeforeAmountStep() throws {
        let network = try #require(AssetNetworkSelectorOption.allSupported.first { $0.id == "xrp" })
        let asset = try SendEntryTestFixtures.nativeChoice(for: network)
        let model = SendRecipientEntryModel(draft: SendEntryTestFixtures.draft(asset: asset))
        model.setMemo("١٢٣")
        #expect(model.networkMemo.isEmpty)
        model.setMemo("4294967296")
        #expect(model.hasInvalidMemo)
        #expect(!model.canContinue)
        model.setMemo("4294967295")
        #expect(model.canContinue)
        #expect(model.continueDraft()?.request.memo == "4294967295")
    }

    @Test
    func stellarMemoIsCarriedToAmountAndReview() throws {
        let network = try #require(AssetNetworkSelectorOption.allSupported.first { $0.id == "stellar" })
        let asset = try SendEntryTestFixtures.nativeChoice(for: network)
        let model = SendRecipientEntryModel(draft: SendEntryTestFixtures.draft(asset: asset, amount: "2"))
        model.setMemo("Invoice 123")
        let next = try #require(model.continueDraft())
        let amount = SendAmountEntryState(draft: next)
        let review = try #require(amount.reviewDraft(from: next, currency: SendEntryTestFixtures.currency))
        #expect(review.request.memo == "Invoice 123")
    }

    @Test
    func explicitMaxSurvivesAddressOnlyPasteButNotPaymentAmountReplacement() throws {
        let draft = SendEntryTestFixtures.draft(amount: "2").replacingMaximumBalance(true)
        let model = SendRecipientEntryModel(draft: draft)
        let recipient = SendEntryTestFixtures.address(for: .ethereum)
        #expect(model.paste(recipient))
        #expect(model.continueDraft()?.usesMaximumBalance == true)
        #expect(model.paste("ethereum:\(recipient)@1?value=100000000000000000"))
        #expect(model.continueDraft()?.amount == "0.1")
        #expect(model.continueDraft()?.usesMaximumBalance == false)
    }
}

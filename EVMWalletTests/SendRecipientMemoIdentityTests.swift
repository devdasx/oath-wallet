import Foundation
import Testing
@testable import Aperture

@Suite("Exact recent-recipient memo identity")
struct SendRecipientMemoIdentityTests {
    private typealias Fixtures = SendRecipientHistoryTestFixtures
    private let classicXRP = SendEntryTestFixtures.address(for: .xrp)
    private let taggedXRP = "X76UnYEMbQfEs3mUqgtjp4zFy9exgThRj7XVZ6UxsdrBptF"
    private let zeroTagXRP = "X76UnYEMbQfEs3mUqgtjp4zFy9exgTsM93nriVZAPufrpE3"
    private let taglessXRP = "X76UnYEMbQfEs3mUqgtjp4zFy9exgSxWAqcQwu9z2r5d7Tm"

    @Test(arguments: AssetNetworkSelectorOption.allSupported)
    func onlyMemoSupportingSignersPersistMemoMetadata(network: AssetNetworkSelectorOption) throws {
        let supportsMemo = ["xrp", "stellar", "ton", "solana"].contains(network.id)
        #expect(SendRecipientNetworkMemo.isSupported(network.id) == supportsMemo)
        let saved = try #require(SendRecipientIdentity(
            address: SendEntryTestFixtures.address(for: network.blockchain), networkID: network.id, memo: "42"
        ))
        #expect(saved.networkMemo == (supportsMemo ? "42" : nil))
        #expect(saved.memoRecorded)
    }

    @Test
    func xrpEmbeddedTagsAndClassicTagsIdentifyTheSameRouting() throws {
        let canonical = try #require(SendRecipientIdentity(address: classicXRP, networkID: "xrp", memo: "12345"))
        #expect(SendRecipientIdentity(address: taggedXRP, networkID: "xrp") == canonical)
        #expect(SendRecipientIdentity(address: taggedXRP, networkID: "xrp", memo: "0000012345") == canonical)
        #expect(SendRecipientIdentity(address: classicXRP, networkID: "xrp", memo: " 12345 ") == canonical)
        let zero = try #require(SendRecipientIdentity(address: zeroTagXRP, networkID: "xrp"))
        #expect(zero.networkMemo == "0")
        #expect(zero == SendRecipientIdentity(address: classicXRP, networkID: "xrp", memo: "0"))
        #expect(zero != SendRecipientIdentity(address: classicXRP, networkID: "xrp"))
        #expect(SendRecipientIdentity(address: taglessXRP, networkID: "xrp")
            == SendRecipientIdentity(address: classicXRP, networkID: "xrp"))
        #expect(SendRecipientIdentity(address: taggedXRP, networkID: "xrp", memo: "9") == nil)
        #expect(SendRecipientIdentity(address: taglessXRP, networkID: "xrp", memo: "0") == nil)
        #expect(SendRecipientIdentity(address: classicXRP, networkID: "xrp", memo: "4294967295")?.networkMemo
            == "4294967295")
    }

    @Test(arguments: ["4294967296", "-1", "1.5", "1e2", "١٢٣", "１２３", "123x", "12345678901"])
    func invalidXRPTagsCannotBecomeSavedRecipients(memo: String) {
        #expect(SendRecipientIdentity(address: classicXRP, networkID: "xrp", memo: memo) == nil)
    }

    @Test
    func stellarMemoMatchesSignerByteLimitAndNormalization() throws {
        let address = SendEntryTestFixtures.address(for: .stellar)
        let exactLimit = String(repeating: "é", count: 14)
        #expect(exactLimit.utf8.count == 28)
        #expect(SendRecipientIdentity(address: address, networkID: "stellar", memo: exactLimit)?.networkMemo == exactLimit)
        #expect(SendRecipientIdentity(address: address, networkID: "stellar", memo: exactLimit + "x") == nil)
        #expect(SendRecipientIdentity(address: address, networkID: "stellar", memo: "account\n123") == nil)
        #expect(SendRecipientIdentity(address: address, networkID: "stellar", memo: "  Ab 12 \n")?.networkMemo == "Ab 12")
        #expect(SendRecipientIdentity(address: address, networkID: "stellar", memo: " \n")?.networkMemo == nil)
        #expect(SendRecipientIdentity(address: address, networkID: "stellar", memo: "Ab 12")
            != SendRecipientIdentity(address: address, networkID: "stellar", memo: "ab 12"))
    }

    @Test(arguments: ["stellar", "solana", "ton"])
    func visuallyEquivalentUnicodeMemosKeepDistinctOnChainBytes(networkID: String) throws {
        let asset = try Fixtures.asset(networkID: networkID)
        let address = SendEntryTestFixtures.address(for: asset.blockchain)
        let composed = try #require(SendRecipientIdentity(address: address, networkID: networkID, memo: "Café"))
        let decomposed = try #require(SendRecipientIdentity(address: address, networkID: networkID, memo: "Cafe\u{301}"))
        #expect(composed.networkMemo == decomposed.networkMemo) // Swift canonical String equality.
        #expect(composed != decomposed) // Routing equality must instead be byte-exact.
        #expect(Set([composed, decomposed]).count == 2)
        #expect(composed.memoIdentityKey != decomposed.memoIdentityKey)
    }

    @Test
    func tonAndSolanaRememberTheActualCommentWithoutTrimmingMeaningfulWhitespace() throws {
        for networkID in ["ton", "solana"] {
            let asset = try Fixtures.asset(networkID: networkID)
            let address = SendEntryTestFixtures.address(for: asset.blockchain)
            #expect(SendRecipientIdentity(address: address, networkID: networkID, memo: " A\nB ")?.networkMemo == " A\nB ")
            #expect(SendRecipientIdentity(address: address, networkID: networkID, memo: "")?.networkMemo == nil)
            let long = String(repeating: "a", count: 501)
            #expect(SendRecipientIdentity(address: address, networkID: networkID, memo: long)?.networkMemo?.count
                == (networkID == "ton" ? 500 : 501))
        }
    }

    @Test(arguments: ["xrp", "stellar", "ton", "solana"])
    func unknownLegacyMemoIsNotProofOfASendWithoutAMemo(networkID: String) throws {
        let asset = try Fixtures.asset(networkID: networkID)
        let address = SendEntryTestFixtures.address(for: asset.blockchain)
        let unknown = try Fixtures.recent(address: address, networkID: networkID, memoRecorded: false)
        let known = try Fixtures.recent(address: address, networkID: networkID)
        #expect(unknown.id != known.id)
        #expect(unknown.memoText == WalletLocalization.string("send.recipient.history.memo_not_saved"))
        let snapshot = SendRecipientHistorySnapshot(recipientsByIdentity: [unknown.id: unknown])
        #expect(snapshot.assessment(address: address, networkID: networkID) == .newRecipient)
        #expect(snapshot.assessment(address: address, networkID: networkID, memo: "42") == .newRecipient)
        #expect(SendRecipientIdentity(address: address, networkID: networkID, memo: "42", memoRecorded: false) == nil)
    }

    @Test @MainActor
    func differentRoutingEntriesKeepDifferentStableMonogramColors() throws {
        let entries = try ["1", "2", "3", "0"].map {
            try Fixtures.recent(address: classicXRP, networkID: "xrp", memo: $0)
        }
        let colors = SendRecentRecipientAppearance.colors(for: entries)
        #expect(Set(colors.values).count == entries.count)
        #expect(colors == SendRecentRecipientAppearance.colors(for: entries.reversed()))
    }

    @Test(arguments: ["xrp", "stellar", "ton", "solana"]) @MainActor
    func selectingRecentRecipientRestoresItsMemoAndPreservesTheRestOfTheSend(networkID: String) throws {
        let asset = try Fixtures.asset(networkID: networkID)
        let address = SendEntryTestFixtures.address(for: asset.blockchain)
        let memo = networkID == "xrp" ? "0" : "Client A-001"
        let original = SendEntryTestFixtures.draft(asset: asset, amount: "1.25", memo: "456")
            .replacingMaximumBalance(true)
        let model = SendRecipientEntryModel(draft: original)
        model.note = "Private local note"
        model.applyRecentRecipient(try Fixtures.recent(address: address, networkID: networkID, memo: memo))
        let continued = try #require(model.continueDraft())
        #expect(continued.recipient == address)
        #expect(continued.request.memo == memo)
        #expect(model.networkMemo == memo)
        #expect(continued.amount == "1.25")
        #expect(continued.note == "Private local note")
        #expect(continued.usesMaximumBalance)
        #expect(continued.feePolicy == original.feePolicy)
        #expect(continued.bitcoinFamilyOptions == original.bitcoinFamilyOptions)
        #expect(continued.asset.id == original.asset.id)

        // Clearing the saved memo must also clear the payment request metadata,
        // including TON/Solana where there is no separate memo text field.
        for recorded in [true, false] {
            model.applyRecentRecipient(try Fixtures.recent(
                address: address, networkID: networkID, memoRecorded: recorded
            ))
            #expect(model.networkMemo.isEmpty)
            #expect(model.activeRequest.memo == nil)
            #expect(model.continueDraft()?.request.memo == nil)
        }
    }

    @Test @MainActor
    func wrongNetworkAndTamperedRecipientCannotReplaceTheSelectedRouting() throws {
        let asset = try Fixtures.asset(networkID: "xrp")
        let model = SendRecipientEntryModel(draft: SendEntryTestFixtures.draft(asset: asset, memo: "42"))
        model.scheduleNameResolution()
        let saved = try Fixtures.recent(address: classicXRP, networkID: "xrp", memo: "123")
        model.applyRecentRecipient(SendRecentRecipient(
            id: saved.id, address: "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh", sendCount: 1, lastSentAt: .now
        ))
        model.applyRecentRecipient(try Fixtures.recent(
            address: SendEntryTestFixtures.address(for: .stellar), networkID: "stellar", memo: "abc"
        ))
        #expect(model.recipient == classicXRP)
        #expect(model.continueDraft()?.request.memo == "42")
    }
}

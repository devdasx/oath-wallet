import Foundation
import Testing
import WalletCore
@testable import Aperture

struct SendBitcoinOPReturnTests {
    @Test
    func countsExactUTF8BytesAndRejectsWholeOversizedEdit() {
        let message = "Aperture ₿ 🙂"
        var editor = SendBitcoinOPReturnEditorState(message: message)
        #expect(editor.byteCount == Data(message.utf8).count)
        #expect(
            editor.remainingByteCount
                == SendBitcoinOPReturn.maximumPayloadBytes
                    - Data(message.utf8).count
        )

        let maximum = String(
            repeating: "a",
            count: SendBitcoinOPReturn.maximumPayloadBytes
        )
        let acceptedMaximum = editor.replaceMessage(maximum)
        #expect(acceptedMaximum)
        #expect(editor.message == maximum)
        #expect(editor.byteCount == 99_994)
        #expect(editor.remainingByteCount == 0)

        let oversized = maximum + "🙂"
        let acceptedOversized = editor.replaceMessage(oversized)
        #expect(!acceptedOversized)
        #expect(editor.message == maximum)
    }

    @Test
    func buildsCanonicalScriptsWithoutChangingPayload() throws {
        let directMessage = String(repeating: "x", count: 75)
        let directResult = try SendBitcoinOPReturn.scriptPubKey(
            for: directMessage
        )
        let direct = try #require(directResult)
        #expect(direct.prefix(2) == Data([0x6a, 75]))
        #expect(direct.dropFirst(2) == Data(directMessage.utf8))

        let maximumMessage = String(repeating: "y", count: 80)
        let maximumResult = try SendBitcoinOPReturn.scriptPubKey(
            for: maximumMessage
        )
        let maximum = try #require(maximumResult)
        #expect(maximum.count == 83)
        #expect(maximum.prefix(3) == Data([0x6a, 0x4c, 80]))
        #expect(maximum.dropFirst(3) == Data(maximumMessage.utf8))
        #expect(
            throws: SendBitcoinFamilyOptionsError.opReturnTooLarge
        ) {
            try SendBitcoinOPReturn.scriptPubKey(
                for: String(repeating: "z", count: 99_995)
            )
        }
    }

    @Test
    func normalizationPreservesWhitespaceAndIsBitcoinOnly() throws {
        let exactMessage = "  exact message\n"
        let options = SendBitcoinFamilyOptions.automatic
            .replacingOPReturnMessage(exactMessage)
        #expect(
            try options.normalized(for: .bitcoin).opReturnMessage
                == exactMessage
        )
        #expect(
            throws: SendBitcoinFamilyOptionsError.opReturnUnsupported
        ) {
            try options.normalized(for: .litecoin)
        }
        #expect(
            try SendBitcoinFamilyOptions.automatic
                .replacingOPReturnMessage("")
                .normalized(for: .bitcoin)
                .opReturnMessage == nil
        )
    }

    @Test
    func templateFeeIncludesCompleteSerializedOutput() throws {
        let message = "payload 🙂"
        let base = SendDraft(
            request: .manualEntry(networkID: "bitcoin"),
            asset: Self.bitcoinAsset(),
            recipient:
                "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh",
            amount: "0.1",
            note: nil
        )
        let withMessage = base.replacingBitcoinFamilyOptions(
            .automatic.replacingOPReturnMessage(message)
        )
        let scriptResult = try SendBitcoinOPReturn.scriptPubKey(
            for: message
        )
        let script = try #require(scriptResult)

        #expect(
            SendNetworkFeeEstimator.templateUTXOVirtualBytes(
                draft: withMessage
            ) == SendNetworkFeeEstimator.templateUTXOVirtualBytes(
                draft: base
            ) + UInt64(9 + script.count)
        )
    }

    @Test
    func walletCoreLegacyInputReceivesExactPayload() throws {
        let sourceKey = try #require(
            PrivateKey(data: Data(repeating: 0x11, count: 32))
        )
        let recipientKey = try #require(
            PrivateKey(data: Data(repeating: 0x22, count: 32))
        )
        let sender = CoinType.bitcoin.deriveAddress(privateKey: sourceKey)
        let recipient = CoinType.bitcoin.deriveAddress(
            privateKey: recipientKey
        )
        let message = "exact UTF-8 🙂"
        let options = SendBitcoinFamilyOptions.automatic
            .replacingOPReturnMessage(message)
        let draft = SendDraft(
            request: .manualEntry(networkID: "bitcoin"),
            asset: Self.bitcoinAsset(sourceAddress: sender),
            recipient: recipient,
            amount: "0.0005",
            note: nil,
            bitcoinFamilyOptions: options
        )

        let input = try SendBitcoinTransactionService.signingInput(
            draft: draft,
            accountMarker: nil,
            nestedSegwitPublicKey: nil,
            chain: .bitcoin,
            outputs: [Self.output()],
            requestedAtomic: 50_000,
            byteFee: 2,
            options: options,
            senderAddress: sender,
            recipientAddress: recipient
        )

        #expect(input.outputOpReturn == Data(message.utf8))
        let plan: BitcoinTransactionPlan = AnySigner.plan(
            input: input,
            coin: .bitcoin
        )
        #expect(plan.error == .ok)
        #expect(plan.fee > 0)
    }

    private static func output() -> SendBitcoinUTXO {
        SendBitcoinUTXO(
            networkID: "bitcoin",
            outpoint: SendBitcoinOutpoint(
                transactionHash: String(repeating: "a", count: 64),
                outputIndex: 0
            ),
            valueAtomic: "100000",
            blockHeight: 1,
            confirmations: 1
        )
    }

    private static func bitcoinAsset(
        sourceAddress: String? = nil
    ) -> SendAssetChoice {
        SendAssetChoice(
            id: "bitcoin:native",
            name: "Bitcoin",
            symbol: "BTC",
            networkID: "bitcoin",
            networkName: "Bitcoin",
            blockchain: .bitcoin,
            contractAddress: nil,
            decimals: 8,
            logoSource: .nativeCoin(blockchain: .bitcoin),
            networkLogoSource: .network(blockchain: .bitcoin),
            balance: 1,
            fiatValue: 0,
            balanceAtomic: "100000000",
            sourceAddress: sourceAddress
        )
    }
}

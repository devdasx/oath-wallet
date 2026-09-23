import Testing
@testable import Aperture

@Suite("Send transaction identity details")
struct SendTransactionIdentityDetailTests {
    @Test @MainActor
    func copyWritesTheFullUnabridgedTransactionID() {
        let pasteboard = InMemoryTransactionPasteboard()
        let transactionID = String(repeating: "abcdef0123456789", count: 4)

        SendTransactionIdentityClipboard.copy(
            transactionID,
            to: pasteboard
        )

        #expect(pasteboard.string == transactionID)
    }

    @Test
    func transactionIDExposesCopyShareAndMainnetExplorerActions() throws {
        let detail = SendTransactionIdentityDetail(
            kind: .transactionID,
            value: "abc123",
            networkID: "litecoin"
        )

        #expect(detail.showsTransactionActions)
        #expect(
            try #require(detail.explorerURL).absoluteString
                == "https://litecoinspace.org/tx/abc123"
        )
        #expect(
            detail.transactionSharingPayload
                == "abc123\nhttps://litecoinspace.org/tx/abc123"
        )
    }

    @Test
    func recipientDetailDoesNotExposeTransactionActions() {
        let detail = SendTransactionIdentityDetail(
            kind: .recipient,
            value: "ltc1qrecipient",
            networkID: "litecoin"
        )

        #expect(!detail.showsTransactionActions)
        #expect(detail.explorerURL == nil)
        #expect(detail.transactionSharingPayload == nil)
    }

    @Test
    func unsafeTransactionHashStillCopiesButDoesNotOpenAURL() {
        let detail = SendTransactionIdentityDetail(
            kind: .transactionID,
            value: "abc?network=testnet",
            networkID: "litecoin"
        )

        #expect(detail.showsTransactionActions)
        #expect(detail.explorerURL == nil)
        #expect(detail.transactionSharingPayload == nil)
    }

    @Test
    func walletTransactionHashSharesItsFullMainnetURL() throws {
        let transactionHash = String(repeating: "a", count: 64)
        let hashDetail = WalletTransactionIdentityDetail(
            kind: .transactionHash,
            value: transactionHash,
            networkID: "dogecoin"
        )

        #expect(
            try #require(hashDetail.explorerURL).absoluteString
                == "https://dogechain.info/tx/\(transactionHash)"
        )
        #expect(
            hashDetail.transactionSharingPayload
                == "\(transactionHash)\nhttps://dogechain.info/tx/"
                    + transactionHash
        )

        let addressDetail = WalletTransactionIdentityDetail(
            kind: .fromAddress,
            value: "DFullSenderAddress",
            networkID: "dogecoin"
        )
        #expect(addressDetail.explorerURL == nil)
        #expect(addressDetail.transactionSharingPayload == nil)
    }

    @Test
    func receivedTransactionOrdersFromBeforeToInOverview() {
        #expect(
            WalletTransactionKind.received(assetSymbol: "ETH")
                .transactionDetailsAddressOrder
                == [.fromAddress, .toAddress]
        )
    }

    @Test
    func outgoingTransactionOrdersFromBeforeToInOverview() {
        #expect(
            WalletTransactionKind.sent(assetSymbol: "ETH")
                .transactionDetailsAddressOrder
                == [.fromAddress, .toAddress]
        )
        #expect(
            WalletTransactionKind.selfTransfer(assetSymbol: "ETH")
                .transactionDetailsAddressOrder
                == [.fromAddress, .toAddress]
        )
        #expect(
            WalletTransactionKind.swapped(sourceSymbol: "ETH", destinationSymbol: "USDC")
                .transactionDetailsAddressOrder
                == [.fromAddress, .toAddress]
        )
    }
}

@MainActor
private final class InMemoryTransactionPasteboard:
    SendTransactionIdentityPasteboard
{
    var string: String?
}

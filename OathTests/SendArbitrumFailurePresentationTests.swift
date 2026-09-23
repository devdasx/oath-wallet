import Foundation
import Testing
@testable import Aperture

struct SendArbitrumFailurePresentationTests {
    @Test(arguments: [
        "insufficient funds for transfer",
        "insufficient funds for gas * price + value: balance 0, tx cost 123",
        "insufficient funds for gas * price + value + l1Fees",
        "failed with 50000181 gas: insufficient funds for gas * price + value: address 0x123 have 0 want 1",
        " INSUFFICIENT FUNDS "
    ])
    func affordabilityRejectionsExplainETHForNativeAndTokens(message: String) {
        for error in [
            SendTransactionSubmissionError.provider(networkID: "arbitrum", code: "rpc_-32000", message: message),
            .broadcastRejected(code: "rpc_-32000", message: message)
        ] {
            #expect(error.insufficientFundsMessageKey(networkID: "arbitrum", isNative: false)
                == "send.submit.error.arbitrum_eth_fee")
            #expect(error.insufficientFundsMessageKey(networkID: "arbitrum", isNative: true)
                == "send.submit.error.arbitrum_eth_total")
            #expect(!error.submissionMayHaveSucceeded)
        }
    }

    @Test
    func tokenShortageDoesNotClaimETHIsMissing() {
        let error = SendTransactionSubmissionError.insufficientAssetBalance
        #expect(error.insufficientFundsMessageKey(networkID: "arbitrum", isNative: false) == nil)
        #expect(error.insufficientFundsMessageKey(networkID: "arbitrum", isNative: true)
            == "send.submit.error.arbitrum_eth_total")
        #expect(SendTransactionSubmissionError.insufficientNetworkFeeBalance
            .insufficientFundsMessageKey(networkID: "arbitrum", isNative: false)
            == "send.submit.error.arbitrum_eth_fee")
    }

    @Test(arguments: [
        SendTransactionSubmissionError.provider(networkID: "arbitrum", code: "rpc_-32000", message: "execution reverted: insufficient funds"),
        .provider(networkID: "arbitrum", code: "http_401", message: "insufficient funds"),
        .provider(networkID: "eth", code: "rpc_-32000", message: "insufficient funds"),
        .provider(networkID: "arbitrum", code: "rpc_-32000", message: "rate limit exceeded"),
        .broadcastOutcomeUnknown(networkID: "arbitrum", code: "timed_out"),
        .signing(code: "invalid_key", message: "insufficient funds")
    ])
    func unrelatedAndUncertainErrorsRemainUnchanged(error: SendTransactionSubmissionError) {
        #expect(error.insufficientFundsMessageKey(networkID: "arbitrum", isNative: false) == nil)
        #expect(error.localizedFailureMessage(networkID: "arbitrum", isNative: false) == error.localizedMessage)
    }

    @Test
    func originalErrorAndOtherNetworksArePreserved() {
        let error = SendTransactionSubmissionError.provider(
            networkID: "arbitrum", code: "rpc_-32000", message: "insufficient funds for transfer"
        )
        #expect(error.diagnosticCode == "provider_arbitrum_rpc__32000")
        #expect(error.insufficientFundsMessageKey(networkID: "base", isNative: false) == nil)
        #expect(error.localizedFailureMessage(networkID: "arbitrum", isNative: false)
            == WalletLocalization.string("send.submit.error.arbitrum_eth_fee"))
        #expect(error.allowsRetry)
    }
}

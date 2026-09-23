import Foundation
import Testing
@testable import Aperture

@MainActor
struct BitcoinOPReturnReviewTests {
    @Test(arguments: [false, true])
    func oversizedTemplateCannotReachAuthorization(customFee: Bool) throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84], value: 1_000_000)
        var draft = fixture.draft(options: .automatic.replacingOPReturnMessage(
            String(repeating: "x", count: 99_994)
        ))
        if customFee {
            draft = draft.replacingFeePolicy(.custom(.init(
                model: .utxoPerVByte, primaryValue: "2", secondaryValue: nil, totalBudgetAtomic: "300000"
            )))
        }
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
        #expect(!state.canContinue)
        #expect(state.feeForAuthorization() == nil)
        #expect(state.errorMessage == WalletLocalization.string("send.bitcoin.op_return.error.transaction_too_large"))
    }

    @Test
    func exactSizeFailureBlocksFallbackAndEditingRecovers() async throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84], value: 1_000_000)
        let draft = fixture.draft(options: .automatic.replacingOPReturnMessage(
            String(repeating: "x", count: 99_800)
        ))
        let state = SendReviewFeeState(draft: draft, nativeUnitUSDPrice: nil)
        #expect(!state.canContinue)
        await state.refresh(draft: draft, quoteLoader: { network in
            try SendNetworkFeeAPIClient.defaultQuote(for: network)
        }, estimateLoader: { _, _ in
            try SendBitcoinTransactionPolicy.validateWeight(400_001)
            return .init(atomicAmount: "200000", nativeDecimals: 8)
        }, priceLoader: { nil })
        #expect(!state.canContinue)
        #expect(state.feeForAuthorization() == nil)
        #expect(state.errorMessage == WalletLocalization.string("send.bitcoin.op_return.error.transaction_too_large"))
        let edited = draft.replacingBitcoinFamilyOptions(.automatic.replacingOPReturnMessage("shorter"))
        state.reset(draft: edited)
        #expect(!state.canContinue)
        #expect(state.errorMessage == nil)
        #expect(state.feeForAuthorization() == nil)
        await state.refresh(draft: edited, quoteLoader: { network in
            try SendNetworkFeeAPIClient.defaultQuote(for: network)
        }, estimateLoader: { _, _ in
            .init(atomicAmount: "200000", nativeDecimals: 8)
        }, priceLoader: { nil })
        #expect(state.canContinue)
        #expect(state.feeForAuthorization() != nil)
    }
}

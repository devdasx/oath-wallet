#if LIVE_MAINNET_TESTS
import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct LiveEVMApprovalAccessIntegrationTests {
    private static let owner =
        "0xb92fe925dc43a0ecde6c8b1a2709c170ec4fff4f"
    private static let contract =
        "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"

    @Test
    func deployedProxyDiscoversMainnetApprovalHistory() async throws {
        let provider = try EVMApprovalLogProvider.configured()
        let page = try await provider.page(
            networkID: "eth",
            ownerAddress: Self.owner,
            pageToken: nil
        )
        let ownerTopic = try #require(
            EVMApprovalLogProvider.addressTopic(Self.owner)
        )

        #expect(!page.logs.isEmpty)
        #expect(page.logs.allSatisfy { log in
            log.topics.count >= 2 && log.topics[1] == ownerTopic
        })
        #expect(page.logs.contains { log in
            log.contractAddress == Self.contract
                && log.topics.first
                    == EVMApprovalLogProvider.approvalTopic
        })
    }

    @Test
    func mainnetReadsAllowanceAndEstimatesZeroValueRevoke()
        async throws
    {
        let rpc = try SendEVMRPCClient(networkID: "eth")
        let calldata = try EVMApprovalABI.allowanceCall(
            ownerAddress: Self.owner,
            spenderAddress: Self.owner
        )
        let output = try await rpc.callContract(
            contractAddress: Self.contract,
            data: calldata
        )
        let allowance = try EVMApprovalABI.unsignedInteger(output)
        #expect(allowance.allSatisfy { $0.isASCII && $0.isNumber })

        let revoke = EVMOnChainApproval(
            id: EVMOnChainApproval.stableID(
                accountID: "live-fixture",
                networkID: "eth",
                contractAddress: Self.contract,
                spenderAddress: Self.owner,
                kind: .tokenAllowance,
                tokenID: nil
            ),
            accountID: "live-fixture",
            networkID: "eth",
            ownerAddress: Self.owner,
            contractAddress: Self.contract,
            spenderAddress: Self.owner,
            kind: .tokenAllowance,
            tokenID: nil,
            amountAtomic: allowance,
            tokenName: "Wrapped Ether",
            tokenSymbol: "WETH",
            decimals: 18,
            transactionHash: nil,
            blockNumber: nil,
            discoveredAt: .distantPast,
            lastValidatedAt: Date(),
            pendingRevocationTransactionHash: nil,
            pendingRevocationSubmittedAt: nil
        )
        let gas = try await rpc.estimateGas(
            from: Self.owner,
            to: Self.contract,
            value: "0x0",
            data: try EVMApprovalABI.revokeCalldata(approval: revoke)
        )
        let gasUnits = try SendAtomicAmount.uint64(
            SendAtomicAmount.decimalFromHexQuantity(gas)
        )
        #expect(gasUnits > 21_000)
    }
}
#endif

#if LIVE_MAINNET_TESTS
import Foundation
import Testing
import WalletCore
@testable import Aperture

/// Arc (chain id 5042) end to end through the app's own clients: PublicNode
/// balances, Blockscout history through the Worker proxy, send preflight
/// reads, the fee floor, and the broadcast path up to the node's own
/// rejection. Runs only with `-D LIVE_MAINNET_TESTS`; the history cases need
/// `BLOCKSCOUT_ARC_PROXY_URL` to point at a reachable Worker.
@Suite(.serialized)
struct LiveArcNetworkIntegrationTests {
    /// A public address holding a small USDC balance with a handful of Arc
    /// transfers, all of them through the ERC-20 facade of native USDC.
    private static let lightAddress =
        "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
    /// Hardhat's first default account: publicly known, empty on Arc, but
    /// with dozens of Arc transactions behind it in both directions.
    private static let busyAddress =
        "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    /// 2025-09-04, well before the first Arc mainnet block.
    private static let historyCursor: Int64 = 1_757_000_000
    /// Provider snapshots key the native asset by the zero address.
    private static let nativeIdentity =
        "arc:0x0000000000000000000000000000000000000000"

    @Test
    func lightAddressBalanceAndHistoryMapToTheSingleUSDCAsset()
        async throws
    {
        let outcome = try await AnkrAPIClient.localBuild()
            .loadNetworkWithOutcome(
                address: Self.lightAddress,
                networkID: ArcNetworkConstants.networkID,
                historyFromTimestamp: Self.historyCursor
            )

        #expect(outcome.failures.isEmpty, "\(outcome.failures)")
        let native = try #require(
            outcome.snapshot.assets.first {
                $0.id == Self.nativeIdentity
            }
        )
        // Provider snapshots name a native asset after its network; the
        // symbol is what identifies USDC here.
        #expect(native.symbol == "USDC")
        #expect(native.network == .arc)
        #expect(native.balance > 0)
        #expect(native.decimals == 18)

        let transactions = outcome.snapshot.transactions
        #expect(!transactions.isEmpty)
        for transaction in transactions {
            #expect(transaction.assetSymbol == "USDC", "\(transaction.id)")
            // Facade transfers are folded into the native asset: no
            // transaction may carry the 0x3600… contract.
            #expect(transaction.metadata.contractAddress == nil, "\(transaction.id)")
            #expect(transaction.metadata.blockchainIdentifier == "arc", "\(transaction.id)")
            #expect(transaction.metadata.transactionHash?.hasPrefix("0x") == true)
        }
        // A contract call can legitimately move nothing; the transfers must.
        #expect(transactions.contains { $0.assetAmount != 0 })
    }

    @Test
    func busyAddressHistoryPagesBothDirectionsWithoutDuplicates()
        async throws
    {
        let outcome = try await AnkrAPIClient.localBuild()
            .loadNetworkWithOutcome(
                address: Self.busyAddress,
                networkID: ArcNetworkConstants.networkID,
                historyFromTimestamp: Self.historyCursor
            )

        #expect(outcome.failures.isEmpty, "\(outcome.failures)")
        let transactions = outcome.snapshot.transactions
        #expect(transactions.count >= 20)
        // A transaction may carry several distinct transfers, but the same
        // transfer (facade echo of a native value) must never appear twice.
        let transferKeys = transactions.map { transaction in
            [
                transaction.metadata.transactionHash ?? "",
                transaction.metadata.fromAddress ?? "",
                transaction.metadata.toAddress ?? "",
                "\(transaction.assetAmount)"
            ].map { $0.lowercased() }.joined(separator: "|")
        }
        #expect(Set(transferKeys).count == transferKeys.count)
        var sent = 0
        var received = 0
        for transaction in transactions {
            switch transaction.kind {
            case .sent: sent += 1
            case .received: received += 1
            default: break
            }
            #expect(
                transaction.metadata.contractAddress?.lowercased()
                    != ArcNetworkConstants.usdcInterfaceContract.lowercased(),
                "\(transaction.id)"
            )
        }
        #expect(sent > 0)
        #expect(received > 0)
    }

    @Test
    func sendPreflightReadsSucceedAgainstArc() async throws {
        let client = try SendEVMRPCClient(
            networkID: ArcNetworkConstants.networkID
        )

        async let chainID = client.chainID()
        async let nonce = client.transactionCount(address: Self.busyAddress)
        async let balance = client.nativeBalance(address: Self.lightAddress)
        async let gas = client.estimateGas(
            from: Self.lightAddress,
            to: Self.busyAddress,
            value: "0x1",
            data: nil
        )
        let values = try await (chainID, nonce, balance, gas)

        #expect(Int(values.0.dropFirst(2), radix: 16) == ArcNetworkConstants.chainID)
        #expect(Int(values.1.dropFirst(2), radix: 16) ?? 0 >= 242)
        #expect(Int(values.2.dropFirst(2), radix: 16) ?? 0 > 0)
        #expect(Int(values.3.dropFirst(2), radix: 16) ?? 0 >= 21_000)
    }

    @Test
    func feeQuoteHonoursTheBaseFeeFloor() async throws {
        let quote = try await SendNetworkFeeAPIClient.quote(
            for: ArcNetworkConstants.networkID
        )

        #expect(quote.networkID == ArcNetworkConstants.networkID)
        // The Worker must answer; the built-in default is only a fallback.
        #expect(
            quote.provider != SendNetworkFeeAPIClient.builtInDefaultProvider,
            "\(quote.provider)"
        )
        #expect(quote.tiers.count == 3)
        for tier in quote.tiers {
            #expect(tier.model == .evmEIP1559, "\(tier.preset)")
            let maximumFee = try #require(UInt64(tier.primaryValue))
            #expect(
                maximumFee >= ArcNetworkConstants.minimumMaximumFeeWei,
                "\(quote.provider) \(tier.preset): \(tier.primaryValue)"
            )
        }
    }

    @Test
    func unfundedBroadcastIsRejectedByTheNodeNotTheApp() async throws {
        // A fresh key has no funds on Arc, so the node must refuse the
        // transaction for that reason alone: the envelope, chain id and
        // endpoint were all accepted up to that point.
        let key = PrivateKey()
        let output: EthereumSigningOutput = AnySigner.sign(
            input: EthereumSigningInput.with {
                $0.chainID = Data([0x13, 0xb2])
                $0.nonce = Data([0])
                $0.txMode = .enveloped
                $0.gasLimit = Data([0x52, 0x08])
                $0.maxInclusionFeePerGas = Data([0x3b, 0x9a, 0xca, 0x00])
                $0.maxFeePerGas = Data([0x09, 0x50, 0x2f, 0x90, 0x00])
                $0.toAddress = Self.lightAddress
                $0.privateKey = key.data
                $0.transaction.transfer = .with {
                    $0.amount = Data([1])
                }
            },
            coin: .ethereum
        )
        try #require(output.error == .ok, "\(output.errorMessage)")
        let client = try SendEVMRPCClient(
            networkID: ArcNetworkConstants.networkID
        )

        do {
            let hash = try await client.broadcast(
                rawTransaction: "0x" + output.encoded.hexString
            )
            Issue.record("unfunded transaction was accepted: \(hash)")
        } catch {
            let description = String(describing: error).lowercased()
            #expect(
                description.contains("insufficient funds")
                    || description.contains("insufficient balance"),
                "\(description)"
            )
        }
    }
}
#endif

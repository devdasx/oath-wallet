import Foundation
import Testing
@testable import Aperture

struct SendNetworkFeeAuditTests {
    @Test(arguments: SendNetworkFeeAPIClient.supportedQuoteNetworkIDs.sorted())
    func everyDefaultFitsItsProductionModel(networkID: String) throws {
        let quote = try SendNetworkFeeAPIClient.defaultQuote(for: networkID)
        #expect(SendNetworkFeeAPIClient.isValid(quote, expectedNetworkID: networkID))
        for tier in quote.tiers {
            #expect(SendNetworkFeeValidation.isValid(tier, networkID: networkID))
            let fee = try SendResolvedNetworkFee.resolve(policy: .preset(tier.preset), quote: quote)
            #expect(fee.primaryValue == tier.primaryValue)
            let estimate = try SendNetworkFeeEstimator.templateEstimate(draft: draft(networkID), fee: fee)
            #expect(SendAtomicAmount.isCanonical(estimate.atomicAmount))
            #expect(estimate.atomicAmount != "0")
        }
    }

    @Test
    func malformedOrUnsendableProviderFeesAreRejected() async throws {
        let invalid: [(String, String, String?)] = [
            ("dogecoin", "999", nil), ("bitcoin", "9223372036854775808", nil),
            ("xrp", "9", nil), ("xrp", "9223372036854775808", nil),
            ("stellar", "99", nil), ("stellar", "4294967296", nil),
            ("aptos", "2000001", "100"), ("aptos", "99", "100"),
            ("near", "1", "100000000"),
            ("sui", "18446744073709551616", "1000"),
            ("ton", "1", "18446744073709551616"),
            ("tron", "100", "0"), ("solana", "18446744073709551616", nil),
            ("eth", "0", "0"), ("eth", "1", "2"),
            ("eth", SendNetworkFeeValidation.uint256Maximum + "0", "1"),
            ("bitcoin", "01", nil), ("bitcoin", "١", nil)
        ]
        for (network, primary, secondary) in invalid {
            let fallback = try SendNetworkFeeAPIClient.defaultQuote(for: network)
            let bad = SendNetworkFeeQuote(networkID: network, provider: "invalid-provider",
                fetchedAt: Date(), expiresAt: Date().addingTimeInterval(30),
                tiers: fallback.tiers.map {
                    SendNetworkFeeTier(preset: $0.preset, model: $0.model,
                                       primaryValue: primary, secondaryValue: secondary)
                })
            #expect(!SendNetworkFeeAPIClient.isValid(bad, expectedNetworkID: network))
            #expect(throws: (any Error).self) {
                try SendResolvedNetworkFee.resolve(policy: .preset(.standard), quote: bad)
            }
            let resolved = try await SendNetworkFeeAPIClient.quoteWithFallback(for: network, timeout: .seconds(3)) { bad }
            #expect(resolved.provider == SendNetworkFeeAPIClient.builtInDefaultProvider)
        }
    }

    @Test
    func customFeesCannotBypassProtocolValidation() {
        for (network, model, primary, secondary) in [
            ("dogecoin", SendNetworkFeeCustomModel.utxoPerVByte, "1", nil),
            ("eth", .evmEIP1559, "0", "0"),
            ("solana", .solanaPriority, "18446744073709551616", nil)
        ] {
            #expect(!SendNetworkFeeCustomValue(model: model, primaryValue: primary,
                secondaryValue: secondary, totalBudgetAtomic: "1000000").isValid(for: network))
        }
    }

    @Test
    func solanaUsesCeilingAndLosslessIntermediateArithmetic() throws {
        let native = try draft("solana")
        let price = SendResolvedNetworkFee(model: .solanaPriority, primaryValue: "1", secondaryValue: nil)
        #expect(try SendNetworkFeeEstimator.templateEstimate(draft: native, fee: price).atomicAmount == "5001")
        let huge = SendResolvedNetworkFee(model: .solanaPriority,
            primaryValue: String(UInt64.max), secondaryValue: nil)
        #expect(try SendNetworkFeeEstimator.templateEstimate(draft: native, fee: huge).atomicAmount
            == "3689348814741915323")
    }

    @Test(arguments: ["base", "optimism", "scroll"])
    func rollupTemplateIncludesSeparateReserve(network: String) throws {
        let input = try draft(network)
        let fee = try SendSubmissionNetworkFee.resolve(draft: input)
        let execution = try SendAtomicAmount.multiply(fee.primaryValue, by: 25_200)
        let expected = SendAtomicAmount.add(execution, SendEVMRollupFee.defaultReserve(networkID: network))
        #expect(try SendNetworkFeeEstimator.templateEstimate(draft: input, fee: fee).atomicAmount == expected)
    }

    @Test(arguments: ["base", "optimism"])
    func opOracleAccountsForDataAndOperatorCharge(network: String) async throws {
        let reserve = try await SendEVMRollupFee.reserve(networkID: network, isToken: true,
            gasLimit: 78_000, call: { address, data in
                #expect(address == "0x420000000000000000000000000000000000000F")
                if data.hasPrefix("0xf1c7a58b") {
                    #expect(data == "0xf1c7a58b" + SendEVMRollupFee.word(324))
                    return "0x" + SendEVMRollupFee.word(101)
                }
                #expect(data == "0x275aedd2" + SendEVMRollupFee.word(78_000))
                return "0x" + SendEVMRollupFee.word(20)
            })
        #expect(reserve == "146") // ceil((101 + 20) * 1.2)
    }

    @Test
    func scrollOracleUsesPaddedABIBytesAndNoOperatorCall() async throws {
        let reserve = try await SendEVMRollupFee.reserve(networkID: "scroll", isToken: true,
            gasLimit: 78_000, call: { address, data in
                #expect(address == "0x5300000000000000000000000000000000000002")
                #expect(data == "0x49948e0e" + SendEVMRollupFee.word(32)
                    + SendEVMRollupFee.word(324) + String(repeating: "ff", count: 324)
                    + String(repeating: "00", count: 28))
                return "0x" + SendEVMRollupFee.word(100)
            })
        #expect(reserve == "120")
    }

    @Test
    func oracleFailureKeepsReserveButCancellationPropagates() async throws {
        for malformed in [false, true] {
            let result = try await SendEVMRollupFee.reserve(networkID: "scroll", isToken: false,
                gasLimit: 25_200, call: { _, _ in
                    if malformed { return "0x" }
                    throw URLError(.notConnectedToInternet)
                })
            #expect(result == SendEVMRollupFee.defaultReserve(networkID: "scroll"))
        }
        await #expect(throws: CancellationError.self) {
            try await SendEVMRollupFee.reserve(networkID: "base", isToken: false,
                gasLimit: 25_200, call: { _, _ in throw CancellationError() })
        }
        let noDoubleCharge = try await SendEVMRollupFee.reserve(networkID: "arbitrum", isToken: false,
            gasLimit: 25_200, call: { _, _ in
                Issue.record("Arbitrum includes posting costs in its gas estimate")
                throw CancellationError()
            })
        #expect(noDoubleCharge == "0")
    }

    @Test
    func customTotalIncludesRollupReserveWithoutIncreasingBudget() throws {
        let value = try SendNetworkFeeCustomLocalConverter.customValue(targetAtomicAmount: "1000",
            model: .evmEIP1559, basis: .eip1559(units: 100, minimumRate: 1,
                suggestedPriorityRate: "2", additionalReserve: "300"))
        #expect(value.primaryValue == "7")
        #expect(value.totalBudgetAtomic == "1000")
        #expect(throws: SendNetworkFeeInputError.belowNetworkMinimum) {
            try SendNetworkFeeCustomLocalConverter.customValue(targetAtomicAmount: "300",
                model: .evmLegacy, basis: .linear(units: 100, minimumRate: 1, additionalReserve: "300"))
        }
        let remaining = try SendNativeTransferAmountResolver.resolve(requestedAtomic: "5000",
            balanceAtomic: "5000", unavailableAtomic: "1000", usesMaximumBalance: true)
        #expect(remaining == "4000")
    }

    @Test
    func taprootAndWrappedSegwitHaveDifferentInputSizes() throws {
        let taproot = try draft("bitcoin", source: "bc1ptest", recipient: "bc1ptest")
        let segwit = try draft("bitcoin", source: "bc1qtest", recipient: "bc1qtest")
        let litecoin = try draft("litecoin", source: "Mtest", recipient: "Mtest")
        #expect(SendNetworkFeeEstimator.templateUTXOVirtualBytes(draft: taproot) == 154)
        #expect(SendNetworkFeeEstimator.templateUTXOVirtualBytes(draft: segwit) == 140)
        #expect(SendNetworkFeeEstimator.templateUTXOVirtualBytes(draft: litecoin) == 165)
    }

    @Test
    func sendMaxSubtractsRollupCostsBeforeBothGasProbes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RollupMaximumFeeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let rpc = try SendEVMRPCClient(networkID: "base", session: session,
            endpoints: [#require(URL(string: "https://rollup-fee.invalid"))])
        let fee = SendResolvedNetworkFee(model: .evmEIP1559,
            primaryValue: "1", secondaryValue: "0")
        let gas = try await SendEVMTransactionService.maximumNativeGasLimit(
            rpc: rpc, nativeBalance: "1000000", fee: fee,
            senderAddress: "0x1111111111111111111111111111111111111111",
            transactionTarget: "0x2222222222222222222222222222222222222222",
            networkID: "base")
        #expect(gas == 25_200)
    }

    @Test(arguments: ["1000", "999000"])
    func nativeGasSimulationCapsTheRequestedAmountBeforeFees(requested: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RollupMaximumFeeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let rpc = try SendEVMRPCClient(networkID: "base", session: session,
            endpoints: [#require(URL(string: "https://rollup-fee.invalid/" + requested))])
        let fee = SendResolvedNetworkFee(model: .evmEIP1559, primaryValue: "1", secondaryValue: "0")
        let gas = try await SendEVMTransactionService.maximumNativeGasLimit(rpc: rpc, nativeBalance: "1000000",
            fee: fee, senderAddress: "0x1111111111111111111111111111111111111111",
            transactionTarget: "0x2222222222222222222222222222222222222222", networkID: "base",
            requestedAtomic: requested)
        #expect(gas == 25200)
    }

    private func draft(_ networkID: String, source: String? = nil, recipient: String = "recipient") throws -> SendDraft {
        let network = ReceiveNetworkCatalog.all.first { $0.id == networkID }
        let bitcoin = BitcoinFamilyChain(rawValue: networkID)
        let blockchain = try #require(network?.blockchain ?? bitcoin?.blockchain)
        let quote = try SendNetworkFeeAPIClient.defaultQuote(for: networkID)
        let model = try #require(quote.tier(for: .standard)?.model)
        return SendDraft(request: .manualEntry(networkID: networkID), asset: SendAssetChoice(
            id: "\(networkID):native", name: "Native", symbol: network?.symbol ?? bitcoin?.symbol ?? "COIN",
            networkID: networkID, networkName: "Mainnet", blockchain: blockchain, contractAddress: nil,
            decimals: SendNetworkFeeEstimator.nativeDecimals(for: model),
            logoSource: .nativeCoin(blockchain: blockchain), networkLogoSource: .network(blockchain: blockchain),
            balance: 1, fiatValue: 1, sourceAddress: source),
            recipient: recipient, amount: "0.01", note: nil)
    }
}

private final class RollupMaximumFeeURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let url = try #require(request.url)
            let body = try #require(request.httpBody ?? Self.body(request.httpBodyStream))
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let id = try #require(object["id"] as? Int)
            let params = try #require(object["params"] as? [Any])
            let fields = try #require(params.first as? [String: String])
            let result: String
            if object["method"] as? String == "eth_call" {
                let data = try #require(fields["data"])
                result = "0x" + SendEVMRollupFee.word(data.hasPrefix("0xf1c7a58b") ? 1000 : 0)
            } else {
                #expect(object["method"] as? String == "eth_estimateGas")
                // Live oracle reserve = ceil(1000 * 1.2) = 1200 wei.
                let cap = request.url?.lastPathComponent
                let expected: String
                if cap == "1000" { expected = "1000" }
                else if cap == "999000" { expected = fields["gasPrice"] == "0x0" ? "998800" : "973600" }
                else { expected = fields["gasPrice"] == "0x0" ? "998800" : "973600" }
                #expect(fields["value"] == (try SendAtomicAmount.hexQuantity(expected)))
                result = "0x5208"
            }
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
            let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private static func body(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

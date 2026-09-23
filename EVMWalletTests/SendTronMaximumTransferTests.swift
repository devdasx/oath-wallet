import Foundation
import Testing
@testable import Aperture

struct SendTronMaximumTransferTests {
    @Test(arguments: [false, true])
    func inactiveRecipientReservesActivationBeforeAskingNode(stakedBandwidth: Bool) async throws {
        let fixture = TronMaximumFixture(stakedBandwidth: stakedBandwidth ? 10_000 : 0)
        defer { fixture.close() }
        let estimate = try await fixture.service.estimatedNetworkFee(draft: draft(), fee: fee())
        let expectedFee = stakedBandwidth ? "1000000" : "1100000"
        #expect(estimate.atomicAmount == expectedFee)
        #expect(estimate.nativeTransferAmountAtomic == (stakedBandwidth ? "9000000" : "8900000"))
        #expect(fixture.nativeAmounts.first == 9_000_000)
        #expect(fixture.nativeAmounts.last == UInt64(estimate.nativeTransferAmountAtomic!))
        #expect(fixture.nativeAmounts.allSatisfy { $0 + 1_000_000 <= fixture.balance })
        #expect(fixture.ownerBalanceReads == 1)
        #expect(fixture.broadcastRequests == 0)
    }

    @Test(arguments: [false, true])
    func activeRecipientPricesSerializedBandwidth(freeBandwidth: Bool) async throws {
        let fixture = TronMaximumFixture(recipientActive: true, freeBandwidth: freeBandwidth ? 10_000 : 0)
        defer { fixture.close() }
        let estimate = try await fixture.service.estimatedNetworkFee(draft: draft(), fee: fee())
        // 200 raw bytes + 134 protobuf/signature/result bytes at 1000 SUN/byte.
        #expect(estimate.atomicAmount == (freeBandwidth ? "0" : "334000"))
        #expect(estimate.nativeTransferAmountAtomic == (freeBandwidth ? "10000000" : "9666000"))
    }

    @Test
    func savedProtocolPricesDetermineTheReviewedAmountWithoutAnotherQuote() async throws {
        let fixture = TronMaximumFixture(recipientActive: true)
        defer { fixture.close() }
        let parameters = SendTronProtocolParameters(energyPrice: 125, bandwidthPrice: 1500,
            accountCreationFee: 1_000_000, accountCreationBandwidthFee: 100_000,
            accountCreationBandwidthRate: 1)
        let savedFee = SendResolvedNetworkFee(model: .tronProtocol, primaryValue: "125",
            secondaryValue: "1500", tronParameters: parameters)
        let estimate = try await fixture.service.estimatedNetworkFee(draft: draft(), fee: savedFee)
        // The saved 1500 SUN/byte rate, not the built-in 1000, prices all 334 bytes.
        #expect(estimate.atomicAmount == "501000")
        #expect(estimate.nativeTransferAmountAtomic == "9499000")
        #expect(fixture.nativeAmounts.last == 9_499_000)
        #expect(fixture.broadcastRequests == 0)
    }

    @Test
    func freeBandwidthCannotPayNewAccountBandwidthCharge() async throws {
        let fixture = TronMaximumFixture(freeBandwidth: 10_000)
        defer { fixture.close() }
        let estimate = try await fixture.service.estimatedNetworkFee(draft: draft(), fee: fee())
        #expect(estimate.atomicAmount == "1100000")
        #expect(estimate.nativeTransferAmountAtomic == "8900000")
    }

    @Test(arguments: ["1", "10"])
    func manuallyEnteredAmountUsesSameFeeReservation(amount: String) async throws {
        let fixture = TronMaximumFixture()
        defer { fixture.close() }
        let estimate = try await fixture.service.estimatedNetworkFee(
            draft: draft(amount: amount, maximum: false), fee: fee())
        #expect(estimate.nativeTransferAmountAtomic == (amount == "1" ? "1000000" : "8900000"))
        #expect(fixture.nativeAmounts.allSatisfy { $0 + 1_000_000 <= fixture.balance })
    }

    @Test(arguments: [UInt64(0), 999_999, 1_000_000, 1_050_000, 1_100_000])
    func cannotSendWhenActivationConsumesBalance(balance: UInt64) async throws {
        let fixture = TronMaximumFixture(balance: balance)
        defer { fixture.close() }
        await #expect(throws: SendTransactionSubmissionError.insufficientNetworkFeeBalance) {
            try await fixture.service.estimatedNetworkFee(draft: draft(), fee: fee())
        }
        if balance <= 1_000_000 { #expect(fixture.nativeAmounts.isEmpty) }
        #expect(fixture.broadcastRequests == 0)
    }

    @Test
    func oneSunAfterAllActivationCostsIsPreserved() async throws {
        let fixture = TronMaximumFixture(balance: 1_100_001)
        defer { fixture.close() }
        let estimate = try await fixture.service.estimatedNetworkFee(draft: draft(), fee: fee())
        #expect(estimate.nativeTransferAmountAtomic == "1")
        #expect(estimate.atomicAmount == "1100000")
        #expect(fixture.nativeAmounts.last == 1)
    }

    @Test
    func shrinkingSerializationDoesNotOscillateBetweenAmounts() async throws {
        let fixture = TronMaximumFixture(recipientActive: true, shorterAfterDeduction: true)
        defer { fixture.close() }
        let estimate = try await fixture.service.estimatedNetworkFee(draft: draft(), fee: fee())
        #expect(estimate.atomicAmount == "334000")
        #expect(estimate.nativeTransferAmountAtomic == "9666000")
        #expect(fixture.nativeAmounts == [10_000_000, 9_666_000])
    }

    @Test
    func estimatorReturnsPreparedAmountAndCannotSkipCustomBudgetValidation() async throws {
        let fixture = TronMaximumFixture()
        defer { fixture.close() }
        let estimator = SendNetworkFeeEstimator(database: try WalletDatabase.temporary(), tronService: fixture.service)
        let result = try await estimator.estimate(draft: draft(), fee: fee(budget: "1100000"))
        #expect(result.nativeTransferAmountAtomic == "8900000")
        #expect(result.atomicAmount == "1100000")
        await #expect(throws: SendTransactionSubmissionError.feeQuoteUnavailable("custom_fee_budget_below_required")) {
            try await estimator.estimate(draft: draft(), fee: fee(budget: "300000"))
        }
        #expect(fixture.broadcastRequests == 0)
    }

    @Test
    func reviewFreezesNetAmountEvenIfBalanceIncreasesLater() async throws {
        let fixture = TronMaximumFixture()
        defer { fixture.close() }
        let original = draft()
        let estimate = try await fixture.service.estimatedNetworkFee(draft: original, fee: fee())
        let reviewed = estimate.applyingNativeAmount(to: original)
        #expect(reviewed.amount == "8.9")
        #expect(!reviewed.usesMaximumBalance)
        let later = TronMaximumFixture(balance: 20_000_000)
        defer { later.close() }
        let preparedAgain = try await later.service.estimatedNetworkFee(draft: reviewed, fee: fee())
        #expect(preparedAgain.nativeTransferAmountAtomic == "8900000")
        #expect(later.nativeAmounts == [8_900_000])
    }

    @Test(arguments: [UInt64(0), 999_999, 1_000_000, 10_000_000])
    func tokenMaxKeepsEntireTokenAmountAndNeedsSeparateTRX(balance: UInt64) async throws {
        // 10,000 energy * 100 SUN, with sufficient bandwidth resources.
        let fixture = TronMaximumFixture(balance: balance, freeBandwidth: 10_000)
        defer { fixture.close() }
        if balance < 1_000_000 {
            await #expect(throws: SendReviewFundingIssue.self) {
                try await fixture.service.estimatedNetworkFee(draft: draft(token: true), fee: fee())
            }
        } else {
            let result = try await fixture.service.estimatedNetworkFee(draft: draft(token: true), fee: fee())
            #expect(result.atomicAmount == "1000000")
            #expect(result.nativeTransferAmountAtomic == nil)
        }
        // 12,345,678 token atoms, not the stale 10 tokens in the draft.
        #expect(fixture.tokenAmounts == ["12345678"])
        #expect(fixture.nativeAmounts.isEmpty)
        #expect(fixture.recipientAccountReads == 0)
        #expect(fixture.broadcastRequests == 0)
    }

    @Test
    func tokenMaxIncludesPaidBandwidthAsWellAsEnergy() async throws {
        let fixture = TronMaximumFixture(balance: 1_333_999)
        defer { fixture.close() }
        await #expect(throws: SendReviewFundingIssue.self) {
            try await fixture.service.estimatedNetworkFee(draft: draft(token: true), fee: fee())
        }
        let exact = TronMaximumFixture(balance: 1_334_000)
        defer { exact.close() }
        let result = try await exact.service.estimatedNetworkFee(draft: draft(token: true), fee: fee())
        #expect(result.atomicAmount == "1334000")
        #expect(exact.tokenAmounts == ["12345678"])
    }

    @Test
    func onlyExactNativeTransferBalanceRejectionBecomesFundingIssue() {
        let rejection = "class org.tron.core.exception.ContractValidateException : Validate TransferContract error, balance is not sufficient."
        #expect(SendReviewFundsValidator.isFundingFailure(
            .provider(networkID: "tron", code: "provider_error", message: rejection), draft: draft()))
        for error in [
            SendTransactionSubmissionError.provider(networkID: "tron", code: "provider_error", message: "contract validate failed"),
            .provider(networkID: "tron", code: "provider_error", message: "REVERT: balance is not sufficient"),
            .provider(networkID: "tron", code: "http_401", message: rejection),
            .provider(networkID: "eth", code: "provider_error", message: rejection)
        ] {
            #expect(!SendReviewFundsValidator.isFundingFailure(error, draft: draft()))
        }
        #expect(!SendReviewFundsValidator.isFundingFailure(
            .provider(networkID: "tron", code: "provider_error", message: rejection), draft: draft(token: true)))
    }

    @MainActor
    @Test(arguments: [UInt64(0), 600])
    func reportedUSDTBalanceCoversActualCostEvenBelowExecutionCap(freeBandwidth: UInt64) async throws {
        let fixture = TronMaximumFixture(balance: 13_451_051, freeBandwidth: freeBandwidth,
            energyRequired: 130_285, tokenBalance: 500_000_000)
        defer { fixture.close() }
        let input = draft(amount: "500", maximum: false, token: true)
        let database = try WalletDatabase.temporary()
        let estimator = SendNetworkFeeEstimator(database: database, tronService: fixture.service)
        let repository = SendNetworkFeeQuoteRepository { _ in
            Issue.record("Send must never fetch fee rates")
            throw URLError(.unsupportedURL)
        }
        let review = SendReviewFeeState(draft: input, nativeUnitUSDPrice: 1)
        // Reproduce the old placeholder shown in the screenshot.
        #expect(review.estimate?.atomicAmount == "6900000")
        await review.refresh(draft: input,
            quoteLoader: { try await repository.quote(for: $0, database: database) },
            estimateLoader: { try await estimator.estimate(draft: $0, fee: $1) }, priceLoader: { nil })
        #expect(review.canContinue)
        #expect(review.estimate?.atomicAmount == (freeBandwidth == 0 ? "13362500" : "13028500"))
        #expect(review.feeForAuthorization()?.tronParameters == .defaults)
        #expect(fixture.tokenAmounts == ["500000000"])
        #expect(fixture.broadcastRequests == 0)
        #expect(fixture.ownerBalanceReads == 1)
    }

    @MainActor
    @Test
    func insufficientTRXShowsActualEnergyAndBandwidthCostInsteadOfTemplate() async throws {
        let fixture = TronMaximumFixture(balance: 13_000_000, energyRequired: 130_285,
            tokenBalance: 500_000_000)
        defer { fixture.close() }
        let input = draft(amount: "500", maximum: false, token: true)
        let estimator = SendNetworkFeeEstimator(database: try WalletDatabase.temporary(), tronService: fixture.service)
        let review = SendReviewFeeState(draft: input, nativeUnitUSDPrice: 1)
        await review.refresh(draft: input,
            quoteLoader: { try SendNetworkFeeAPIClient.defaultQuote(for: $0) },
            estimateLoader: { try await estimator.estimate(draft: $0, fee: $1) }, priceLoader: { nil })
        #expect(!review.canContinue)
        #expect(review.feeForAuthorization() == nil)
        #expect(review.estimate?.atomicAmount == "13362500")
        #expect(review.usdValue == Decimal(string: "13.3625"))
        #expect(review.funding?.network.id == "tron")
        #expect(review.funding?.address == TronMaximumFixture.owner)
        // The fee options screen must retain this cost too.
        let displayed = try await estimator.estimateForDisplay(draft: input, fee: fee())
        #expect(displayed.atomicAmount == "13362500")
        #expect(fixture.broadcastRequests == 0)
    }

    @Test(arguments: [UInt64(65_000), 130_285])
    func availableEnergyOffsetsPaidTRXWithoutChargingTheFeeLimit(energyRemaining: UInt64) async throws {
        let fixture = TronMaximumFixture(balance: 6_528_500, freeBandwidth: 600,
            energyRequired: 130_285, energyRemaining: energyRemaining, tokenBalance: 500_000_000)
        defer { fixture.close() }
        let estimate = try await fixture.service.estimatedNetworkFee(
            draft: draft(amount: "500", maximum: false, token: true), fee: fee())
        #expect(estimate.atomicAmount == String((130_285 - energyRemaining) * 100))
        #expect(fixture.broadcastRequests == 0)
    }

    private func fee(budget: String? = nil) -> SendResolvedNetworkFee {
        SendResolvedNetworkFee(model: .tronProtocol, primaryValue: "100", secondaryValue: "1000",
            totalBudgetAtomic: budget, tronParameters: .defaults)
    }

    private func draft(amount: String = "10", maximum: Bool = true, token: Bool = false) -> SendDraft {
        SendDraft(request: .manualEntry(networkID: "tron"), asset: SendAssetChoice(
            id: token ? "tron:usdt" : "tron:native", name: token ? "Tether" : "TRON", symbol: token ? "USDT" : "TRX",
            networkID: "tron", networkName: "TRON", blockchain: .tron,
            contractAddress: token ? "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t" : nil, decimals: 6,
            logoSource: .nativeCoin(blockchain: .tron), networkLogoSource: .network(blockchain: .tron),
            balance: 10, fiatValue: 1, sourceAddress: TronMaximumFixture.owner),
            recipient: TronMaximumFixture.recipient, amount: amount, note: nil).replacingMaximumBalance(maximum)
    }
}

/// Each test has its own URLSession and fixture identifier, so parallel cases
/// cannot exchange balances, resources, or recorded unsigned requests.
private final class TronMaximumFixture: @unchecked Sendable {
    static let owner = "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
    static let recipient = "TVG297widoPatLk38LQiewz1U1iMKHW9LC"
    let balance: UInt64
    let recipientActive: Bool
    let freeBandwidth: UInt64
    let stakedBandwidth: UInt64
    let shorterAfterDeduction: Bool
    let energyRequired: UInt64
    let energyRemaining: UInt64
    let tokenBalance: UInt64
    private let lock = NSLock()
    private var recordedNative: [UInt64] = []
    private var recordedToken: [String] = []
    private var ownerReads = 0
    private var recipientReads = 0
    private var broadcasts = 0
    private let id = UUID().uuidString
    private let session: URLSession

    init(balance: UInt64 = 10_000_000, recipientActive: Bool = false,
         freeBandwidth: UInt64 = 0, stakedBandwidth: UInt64 = 0, shorterAfterDeduction: Bool = false,
         energyRequired: UInt64 = 10_000, energyRemaining: UInt64 = 0, tokenBalance: UInt64 = 12_345_678) {
        self.balance = balance
        self.energyRequired = energyRequired
        self.energyRemaining = energyRemaining
        self.tokenBalance = tokenBalance
        self.recipientActive = recipientActive
        self.freeBandwidth = freeBandwidth
        self.stakedBandwidth = stakedBandwidth
        self.shorterAfterDeduction = shorterAfterDeduction
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TronMaximumURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Aperture-Fixture": id]
        session = URLSession(configuration: configuration)
        TronMaximumURLProtocol.register(self, id: id)
    }

    var service: SendTronTransactionService {
        SendTronTransactionService(api: SendTronAPIClient(session: session,
            router: AdaptiveProviderRouter(persistsHealth: false)))
    }
    var nativeAmounts: [UInt64] { lock.withLock { recordedNative } }
    var tokenAmounts: [String] { lock.withLock { recordedToken } }
    var ownerBalanceReads: Int { lock.withLock { ownerReads } }
    var recipientAccountReads: Int { lock.withLock { recipientReads } }
    var broadcastRequests: Int { lock.withLock { broadcasts } }

    func close() {
        session.invalidateAndCancel()
        TronMaximumURLProtocol.remove(id: id)
    }

    func response(for request: URLRequest) throws -> Data {
        let body = try JSONSerialization.jsonObject(with: URLRequestBodyReader.data(from: request) ?? Data()) as! [String: Any]
        let method = request.url!.lastPathComponent
        let response: [String: Any] = try lock.withLock {
            switch method {
            case "getaccount":
                if body["address"] as? String == Self.owner {
                    ownerReads += 1
                    return ["address": Self.owner, "balance": balance]
                }
                recipientReads += 1
                return recipientActive ? ["address": Self.recipient, "balance": 1] : [:]
            case "getaccountresource":
                return ["freeNetLimit": freeBandwidth, "NetLimit": stakedBandwidth, "EnergyLimit": energyRemaining]
            case "getchainparameters":
                Issue.record("Send must use cached TRON protocol prices")
                return ["chainParameter": [
                    ["key": "getEnergyFee", "value": 100],
                    ["key": "getTransactionFee", "value": 1000],
                    ["key": "getCreateNewAccountFeeInSystemContract", "value": 1_000_000],
                    ["key": "getCreateAccountFee", "value": 100_000],
                    ["key": "getCreateNewAccountBandwidthRate", "value": 1]
                ]]
            case "createtransaction":
                let amount = try SendAtomicAmount.uint64(String(describing: body["amount"]!))
                recordedNative.append(amount)
                // The mainnet TransferActuator rejects this before returning
                // transaction bytes. This fixture reproduced the original bug.
                if amount > balance || (!recipientActive && balance - amount < 1_000_000) {
                    return ["Error": "class org.tron.core.exception.ContractValidateException : Validate TransferContract error, balance is not sufficient."]
                }
                return unsigned(type: "TransferContract", value: [
                    "owner_address": body["owner_address"]!, "to_address": body["to_address"]!, "amount": amount
                ], rawBytes: shorterAfterDeduction && amount < balance ? 199 : 200)
            case "triggerconstantcontract":
                #expect(body["function_selector"] as? String == "balanceOf(address)")
                return ["result": ["result": true], "constant_result": [String(tokenBalance, radix: 16)]]
            case "estimateenergy":
                return ["result": ["result": true], "energy_required": energyRequired]
            case "triggersmartcontract":
                let parameter = body["parameter"] as! String
                let amount = try SendAtomicAmount.decimalFromHexQuantity("0x" + String(parameter.suffix(64)))
                recordedToken.append(amount)
                let transaction = unsigned(type: "TriggerSmartContract", value: [
                    "owner_address": body["owner_address"]!, "contract_address": body["contract_address"]!,
                    "data": "a9059cbb" + parameter, "call_value": 0
                ], feeLimit: UInt64(String(describing: body["fee_limit"]!))!)
                return ["result": ["result": true], "transaction": transaction]
            default:
                if method.contains("broadcast") { broadcasts += 1 }
                Issue.record("Unexpected request in unsigned preparation: \(method)")
                throw URLError(.unsupportedURL)
            }
        }
        return try JSONSerialization.data(withJSONObject: response)
    }

    private func unsigned(type: String, value: [String: Any], rawBytes: Int = 200, feeLimit: UInt64? = nil) -> [String: Any] {
        var raw: [String: Any] = ["contract": [["type": type, "parameter": [
            "type_url": "type.googleapis.com/protocol." + type, "value": value
        ]]]]
        if let feeLimit { raw["fee_limit"] = feeLimit }
        return ["txID": String(repeating: "a", count: 64), "raw_data_hex": String(repeating: "00", count: rawBytes),
                "raw_data": raw, "visible": false]
    }
}

private final class TronMaximumURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: TronMaximumFixture] = [:]

    static func register(_ fixture: TronMaximumFixture, id: String) { lock.withLock { fixtures[id] = fixture } }
    static func remove(id: String) { _ = lock.withLock { fixtures.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let id = request.value(forHTTPHeaderField: "X-Aperture-Fixture") ?? ""
            let fixture = Self.lock.withLock { Self.fixtures[id] }
            guard let fixture else { throw URLError(.resourceUnavailable) }
            let data = try fixture.response(for: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

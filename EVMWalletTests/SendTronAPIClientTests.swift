import Foundation
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct SendTronAPIClientTests {
    @Test
    func nativeTransferUsesHexAddressesForWalletCoreSigning() async throws {
        let ownerAddress = "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
        let recipientAddress = "TE4qktKPi9FYDDvydfrikbXu6JFU5uCtYf"
        let ownerHexAddress = try #require(
            TronValueParser.accountHexAddress(ownerAddress)
        )
        let recipientHexAddress = try #require(
            TronValueParser.accountHexAddress(recipientAddress)
        )
        TronSendURLProtocol.install(
            statusCode: 200,
            response: [
                "txID": String(repeating: "a", count: 64),
                "raw_data_hex": "00",
                "raw_data": [
                    "contract": [[
                        "parameter": [
                            "value": [
                                "owner_address": ownerHexAddress,
                                "to_address": recipientHexAddress,
                                "amount": 9_007_199_254_740_993
                            ],
                            "type_url": "type.googleapis.com/protocol.TransferContract"
                        ],
                        "type": "TransferContract"
                    ]]
                ],
                "visible": false
            ]
        )
        let session = Self.session()
        defer {
            session.invalidateAndCancel()
        }

        let transaction = try await SendTronAPIClient(
            session: session,
            router: AdaptiveProviderRouter(persistsHealth: false),
            retrySleep: { _ in }
        ).createNativeTransfer(
            ownerAddress: ownerAddress,
            recipientAddress: recipientAddress,
            amountAtomic: 9_007_199_254_740_993
        )
        let request = try #require(TronSendURLProtocol.lastRequest())
        let body = try #require(
            JSONSerialization.jsonObject(with: request.body)
                as? [String: Any]
        )

        #expect(
            request.url.absoluteString.hasSuffix(
                "/v1/provider/ankr/tron/rest/wallet/createtransaction"
            )
        )
        #expect(body["owner_address"] as? String == ownerHexAddress)
        #expect(body["to_address"] as? String == recipientHexAddress)
        #expect(body["amount"] as? String == "9007199254740993")
        #expect(body["visible"] as? Bool == false)
        #expect(transaction.transactionID == String(repeating: "a", count: 64))

        let signingObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(transaction.json.utf8)
            ) as? [String: Any]
        )
        #expect(signingObject["visible"] as? Bool == false)
    }

    @Test
    func trc20TransferCanonicalizesBase58ResponseForWalletCoreSigning()
        async throws
    {
        let ownerAddress = "TQKxPyP7uoJAWS49GtWHLYNLCDMamFtwwD"
        let recipientAddress = "TPSovt4buv51PZXEN15zLosbk2ajEdW7G4"
        let contractAddress = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
        let ownerHexAddress = try #require(
            TronValueParser.accountHexAddress(ownerAddress)
        )
        let contractHexAddress = try #require(
            TronValueParser.accountHexAddress(contractAddress)
        )
        let transferData =
            "a9059cbb00000000000000000000000093d205c6556c055eddaa206e44435a"
            + "c4ce18ec9e0000000000000000000000000000000000000000000000000000"
            + "000009d5049a"
        let transactionID =
            "4c695aeaf4612c9c0213eace26dfc4f1cd405d5b12b543c0605cd17e83ee9ffd"
        let rawDataHex =
            "0a027d6f2208558e4d14cb9f6e2640a0fbac9580345aae01081f12a9010a31"
            + "747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e5472"
            + "6967676572536d617274436f6e747261637412740a15419d7e4df964d58b5434"
            + "05b740e1cb8695bbfa2268121541a614f803b6fd780986a42c78ec9c7f77e6d"
            + "ed13c2244a9059cbb00000000000000000000000093d205c6556c055eddaa206"
            + "e44435ac4ce18ec9e0000000000000000000000000000000000000000000000"
            + "000000000009d5049a70bfaba99580349001c0c39307"
        TronSendURLProtocol.install(
            statusCode: 200,
            response: [
                "result": ["result": true],
                "transaction": [
                    "txID": transactionID,
                    "raw_data_hex": rawDataHex,
                    "raw_data": [
                        "ref_block_bytes": "7d6f",
                        "ref_block_hash": "558e4d14cb9f6e26",
                        "expiration": 1_786_751_172_000,
                        "contract": [[
                            "parameter": [
                                "value": [
                                    "owner_address": ownerAddress,
                                    "contract_address": contractAddress,
                                    "data": transferData
                                ],
                                "type_url": "type.googleapis.com/protocol.TriggerSmartContract"
                            ],
                            "type": "TriggerSmartContract"
                        ]],
                        "timestamp": 1_786_751_112_639,
                        "fee_limit": 15_000_000
                    ],
                    "visible": true
                ]
            ]
        )
        let session = Self.session()
        defer {
            session.invalidateAndCancel()
        }

        let transaction = try await SendTronAPIClient(
            session: session,
            router: AdaptiveProviderRouter(persistsHealth: false),
            retrySleep: { _ in }
        ).createTRC20Transfer(
            ownerAddress: ownerAddress,
            recipientAddress: recipientAddress,
            contractAddress: contractAddress,
            amountAtomic: "164955290",
            feeLimit: 15_000_000
        )
        let request = try #require(TronSendURLProtocol.lastRequest())
        let body = try #require(
            JSONSerialization.jsonObject(with: request.body)
                as? [String: Any]
        )

        #expect(body["owner_address"] as? String == ownerHexAddress)
        #expect(body["contract_address"] as? String == contractHexAddress)
        #expect(body["fee_limit"] as? String == "15000000")
        #expect(body["visible"] as? Bool == false)
        #expect(transaction.transactionID == transactionID)

        let signingObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(transaction.json.utf8)
            ) as? [String: Any]
        )
        let signingRawData = try #require(
            signingObject["raw_data"] as? [String: Any]
        )
        let signingContracts = try #require(
            signingRawData["contract"] as? [[String: Any]]
        )
        let signingParameter = try #require(
            signingContracts.first?["parameter"] as? [String: Any]
        )
        let signingValue = try #require(
            signingParameter["value"] as? [String: Any]
        )
        #expect(signingObject["visible"] as? Bool == false)
        #expect(signingValue["owner_address"] as? String == ownerHexAddress)
        #expect(
            signingValue["contract_address"] as? String
                == contractHexAddress
        )
        #expect(signingValue["data"] as? String == transferData)

        let output: TronSigningOutput = AnySigner.sign(
            input: TronSigningInput.with {
                $0.rawJson = transaction.json
                $0.privateKey = Data(repeating: 1, count: 32)
            },
            coin: .tron
        )
        #expect(output.error == .ok, "\(output.errorMessage)")
        #expect(output.errorMessage.isEmpty)
        #expect(output.id.hexString.lowercased() == transactionID)
        #expect(!output.json.isEmpty)
    }

    @Test
    func broadcastUsesProxyWrapperAndKeepsRateLimitOutcomeAmbiguous() async throws {
        TronSendURLProtocol.install(
            statusCode: 429,
            response: [
                "error": [
                    "code": "provider_rate_limited",
                    "message": "Provider rate limit reached."
                ]
            ]
        )
        let session = Self.session()
        defer {
            session.invalidateAndCancel()
        }
        let signedJSON = """
        {"raw_data":{"contract":[]},"raw_data_hex":"00","signature":["\
        \(String(repeating: "b", count: 130))"],"txID":"\
        \(String(repeating: "a", count: 64))","visible":true}
        """

        do {
            _ = try await SendTronAPIClient(
                session: session,
                router: AdaptiveProviderRouter(persistsHealth: false),
                retrySleep: { _ in }
            ).broadcast(signedJSON: signedJSON)
            Issue.record("Expected an ambiguous broadcast outcome.")
        } catch let error as SendTransactionSubmissionError {
            guard case let .broadcastOutcomeUnknown(_, code, _) = error else {
                Issue.record("Expected outcome unknown, received \(error).")
                return
            }
            #expect(code == "provider_rate_limited")
            #expect(error.submissionMayHaveSucceeded)
            #expect(!error.allowsRetry)
        }

        let requests = TronSendURLProtocol.requests()
        #expect(requests.count == 12) // Three providers, initial pass plus three retries.
        #expect(Set(requests.map { $0.url.host() }).count == 3)
        for request in requests {
            if request.url.path().contains("/v1/provider/") {
                let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
                #expect(body["signed_transaction_json"] as? String == signedJSON)
            } else {
                #expect(request.body == Data(signedJSON.utf8))
            }
        }
    }

    @Test
    func duplicateBroadcastStaysUncertainUntilAcceptedOrObservedOnChain() async throws {
        TronSendURLProtocol.install(
            statusCode: 200,
            response: [
                "result": false,
                "code": "DUP_TRANSACTION_ERROR",
                "message": "Transaction already exists."
            ]
        )
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let transactionID = String(repeating: "c", count: 64)
        let signedJSON = """
        {"raw_data":{"contract":[]},"raw_data_hex":"00","signature":["\
        \(String(repeating: "b", count: 130))"],"txID":"\
        \(transactionID)","visible":false}
        """

        do {
            _ = try await SendTronAPIClient(
                session: session,
                router: AdaptiveProviderRouter(persistsHealth: false),
                retrySleep: { _ in }
            ).broadcast(signedJSON: signedJSON)
            Issue.record("A duplicate response alone is not proof of acceptance.")
        } catch let error as SendTransactionSubmissionError {
            #expect(error.submissionMayHaveSucceeded)
            #expect(!error.allowsRetry)
        }
        #expect(TronSendURLProtocol.requests().count == 12)
    }

    @Test
    func nodeAvailabilityBroadcastCodesRemainOutcomeUnknown() async throws {
        for code in [
            "SERVER_BUSY",
            "NO_CONNECTION",
            "NOT_ENOUGH_EFFECTIVE_CONNECTION",
            "BLOCK_UNSOLIDIFIED",
            "OTHER_ERROR"
        ] {
            #expect(
                SendTronBroadcastErrorClassifier
                    .outcomeMayBeUnknown(code: code)
            )
        }
        #expect(
            !SendTronBroadcastErrorClassifier
                .outcomeMayBeUnknown(code: "SIGERROR")
        )

        TronSendURLProtocol.install(
            statusCode: 200,
            response: [
                "result": false,
                "code": "SERVER_BUSY",
                "message": "Server is busy."
            ]
        )
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let transactionID = String(repeating: "d", count: 64)
        let signedJSON = """
        {"raw_data":{"contract":[]},"raw_data_hex":"00","signature":["\
        \(String(repeating: "b", count: 130))"],"txID":"\
        \(transactionID)","visible":false}
        """

        do {
            _ = try await SendTronAPIClient(
                session: session,
                router: AdaptiveProviderRouter(persistsHealth: false),
                retrySleep: { _ in }
            ).broadcast(signedJSON: signedJSON)
            Issue.record("A busy TRON node unexpectedly accepted the send.")
        } catch let error as SendTransactionSubmissionError {
            guard case let .broadcastOutcomeUnknown(
                networkID,
                code,
                _
            ) = error else {
                Issue.record("Expected an outcome-unknown TRON send.")
                return
            }
            #expect(networkID == TronConstants.networkID)
            #expect(code.uppercased() == "SERVER_BUSY")
            #expect(!error.allowsRetry)
        }
    }

    @Test
    func broadcastCancellationRemainsAmbiguousButReadCancellationDoesNot() {
        let broadcastFailure = SendTronAPIClient.normalizedPostFailure(
            CancellationError(),
            isBroadcast: true
        )
        guard let submission = broadcastFailure
                as? SendTransactionSubmissionError,
              case let .broadcastOutcomeUnknown(networkID, code, _) =
                submission
        else {
            Issue.record("Expected an ambiguous cancelled broadcast.")
            return
        }
        #expect(networkID == TronConstants.networkID)
        #expect(code == "cancelled_after_broadcast_started")
        #expect(submission.submissionMayHaveSucceeded)
        #expect(!submission.allowsRetry)

        let readFailure = SendTronAPIClient.normalizedPostFailure(
            CancellationError(),
            isBroadcast: false
        )
        #expect(readFailure is CancellationError)
    }

    @Test
    func accountExistenceDistinguishesInactiveAndActiveAddresses()
        async throws
    {
        let address = "TPSovt4buv51PZXEN15zLosbk2ajEdW7G4"
        let session = Self.session()
        defer {
            session.invalidateAndCancel()
        }
        let client = SendTronAPIClient(
            session: session,
            router: AdaptiveProviderRouter(persistsHealth: false),
            retrySleep: { _ in }
        )

        TronSendURLProtocol.install(statusCode: 200, response: [:])
        let inactive = try await client.accountExists(address: address)
        #expect(!inactive)

        TronSendURLProtocol.install(
            statusCode: 200,
            response: ["address": address]
        )
        let active = try await client.accountExists(address: address)
        #expect(active)
    }

    @Test
    func protocolParametersComeFromThePublicMainnetEndpoint() async throws {
        TronSendURLProtocol.install(
            statusCode: 200,
            response: [
                "chainParameter": [
                    ["key": "getRemoveThePowerOfTheGr", "value": -1],
                    ["key": "getEnergyFee", "value": 100],
                    ["key": "getTransactionFee", "value": 1_000],
                    ["key": "getCreateAccountFee", "value": 100_000],
                    [
                        "key": "getCreateNewAccountFeeInSystemContract",
                        "value": 1_000_000
                    ],
                    [
                        "key": "getCreateNewAccountBandwidthRate",
                        "value": 1
                    ]
                ]
            ]
        )
        let session = Self.session()
        defer {
            session.invalidateAndCancel()
        }

        let parameters = try await SendTronAPIClient(
            session: session,
            router: AdaptiveProviderRouter(persistsHealth: false),
            retrySleep: { _ in }
        ).protocolParameters()
        let request = try #require(TronSendURLProtocol.lastRequest())

        #expect(request.url.absoluteString.hasSuffix(
            "api.trongrid.io/wallet/getchainparameters"
        ))
        #expect(parameters.energyPrice == 100)
        #expect(parameters.bandwidthPrice == 1_000)
        #expect(parameters.accountCreationFee == 1_000_000)
        #expect(parameters.accountCreationBandwidthFee == 100_000)
        #expect(parameters.accountCreationBandwidthRate == 1)
    }

    @Test
    func bandwidthAccountingMatchesJavaTronConsensusRules() throws {
        let transaction = SendTronUnsignedTransaction(
            json: "{}",
            transactionID: String(repeating: "a", count: 64),
            rawDataBytes: 134
        )
        let parameters = SendTronProtocolParameters(
            energyPrice: 100,
            bandwidthPrice: 1_000,
            accountCreationFee: 1_000_000,
            accountCreationBandwidthFee: 100_000,
            accountCreationBandwidthRate: 1
        )
        let pooledButIndividuallyInsufficient = SendTronAccountResource(
            freeBandwidthRemaining: 200,
            stakedBandwidthRemaining: 100,
            energyRemaining: 0
        )

        let transactionBytes = try SendTronTransactionService
            .signedTransactionBandwidthBytes(rawDataBytes: 134)
        let paidActiveFee = try SendTronTransactionService.paidBandwidthFee(
            transaction: transaction,
            resource: pooledButIndividuallyInsufficient,
            parameters: parameters,
            createsAccount: false
        )
        let paidInactiveFee = try SendTronTransactionService
            .nativeTransferFee(
                transaction: transaction,
                resource: pooledButIndividuallyInsufficient,
                parameters: parameters,
                recipientActive: false
            )
        let coveredByFree = try SendTronTransactionService.paidBandwidthFee(
            transaction: transaction,
            resource: SendTronAccountResource(
                freeBandwidthRemaining: 268,
                stakedBandwidthRemaining: 0,
                energyRemaining: 0
            ),
            parameters: parameters,
            createsAccount: false
        )
        let inactiveCoveredByStaked = try SendTronTransactionService
            .nativeTransferFee(
                transaction: transaction,
                resource: SendTronAccountResource(
                    freeBandwidthRemaining: 10_000,
                    stakedBandwidthRemaining: 268,
                    energyRemaining: 0
                ),
                parameters: parameters,
                recipientActive: false
            )

        #expect(transactionBytes == 268)
        #expect(paidActiveFee == 268_000)
        #expect(paidInactiveFee == 1_100_000)
        #expect(coveredByFree == 0)
        #expect(inactiveCoveredByStaked == 1_000_000)
    }

    @Test
    func tokenFeeLimitCoversFullEstimatedEnergy() throws {
        let automatic = try SendTronTransactionService.energyFeeLimit(
            estimatedEnergy: 72_000,
            energyPrice: 100,
            customValue: nil
        )
        let exactCustom = try SendTronTransactionService.energyFeeLimit(
            estimatedEnergy: 72_000,
            energyPrice: 100,
            customValue: 7_200_000
        )

        #expect(automatic == 8_640_000)
        #expect(exactCustom == 7_200_000)
        #expect(throws: SendTransactionSubmissionError.self) {
            try SendTronTransactionService.energyFeeLimit(
                estimatedEnergy: 72_000,
                energyPrice: 100,
                customValue: 1_000_000
            )
        }
    }


    @Test(arguments: [200, 400], ["hex", "base64", "plain"])
    func signatureRejectionDecodesTheNodeReason(
        status: Int, encoding: String
    ) async throws {
        let reason = "Validate signature error: sig error"
        let hex = "56616c6964617465207369676e6174757265206572726f723a20736967206572726f72"
        let message = encoding == "hex" ? hex
            : encoding == "base64" ? Data(reason.utf8).base64EncodedString() : reason
        TronSendURLProtocol.install(
            statusCode: status,
            response: ["result": false, "code": "SIGERROR", "message": message]
        )
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let signedJSON = """
        {"raw_data":{"contract":[]},"raw_data_hex":"00","signature":["\
        \(String(repeating: "b", count: 130))"],"txID":"\
        \(String(repeating: "a", count: 64))","visible":false}
        """
        do {
            _ = try await SendTronAPIClient(
                session: session,
                router: AdaptiveProviderRouter(persistsHealth: false),
                retrySleep: { _ in }
            ).broadcast(signedJSON: signedJSON)
            Issue.record("An invalid signature must remain a rejected broadcast.")
        } catch let error as SendTransactionSubmissionError {
            guard case let .broadcastRejected(code, decoded, _) = error else {
                Issue.record("Expected the concrete signature rejection, got \(error)")
                return
            }
            #expect(code.lowercased() == "sigerror")
            #expect(decoded == reason)
            #expect(error.diagnosticCode == "broadcast_sigerror")
            let description = error.localizedMessage
            #expect(!description.contains(reason))
            #expect(!description.contains(hex))
            #expect(description.contains(WalletLocalization.string("send.submit.error.tron_signature")))
            #expect(!SendTronBroadcastErrorClassifier.outcomeMayBeUnknown(code: code))
        }
        #expect(TronSendURLProtocol.requests().count == 1)
    }

    @Test
    func legacySignatureErrorsHideTheirTechnicalDetails() throws {
        let error = SendTransactionSubmissionError.broadcastRejected(
            code: "sigerror",
            message: "56616c6964617465207369676e6174757265206572726f723a20736967206572726f72"
        )
        let description = error.localizedMessage
        #expect(!description.contains("Validate signature error: sig error"))
        #expect(!description.contains("56616c6964617465"))
        #expect(description.contains(WalletLocalization.string("send.submit.error.tron_signature")))
    }

    @Test
    func unrelatedBroadcastErrorsRetainTheirOriginalMeaning() {
        let reason = "execution reverted: TransferHelper: TRANSFER_FROM_FAILED"
        let error = SendTransactionSubmissionError.broadcastRejected(
            code: "rpc_3", message: reason
        )
        #expect(error.localizedMessage == WalletLocalization.string("send.submit.error.try_again"))
        #expect(error.diagnosticCode == "broadcast_rpc_3")
        #expect(error.allowsRetry)
    }

    @Test(arguments: [429, 503, 200])
    func temporaryReadsRecoverUsingADifferentProvider(status: Int) async throws {
        TronSendURLProtocol.installResponses([
            (status, ["Error": "request rate exceeded the allowed_rps(3)"]),
            (200, ["balance": 42])
        ])
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let balance = try await SendTronAPIClient(
            session: session, router: AdaptiveProviderRouter(persistsHealth: false),
            retrySleep: { _ in }
        ).accountBalance(address: "TPSovt4buv51PZXEN15zLosbk2ajEdW7G4")
        #expect(balance == 42)
        let requests = TronSendURLProtocol.requests()
        #expect(requests.count == 2)
        #expect(requests.first?.url.host() != requests.last?.url.host())
    }

    @Test
    func exhaustedReadRateLimitsRemainSafeToRetryWithFriendlyCopy() async throws {
        TronSendURLProtocol.installRaw(statusCode: 429, response: Data("Too many requests".utf8))
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await SendTronAPIClient(
                session: session, router: AdaptiveProviderRouter(persistsHealth: false),
                retrySleep: { _ in }
            ).accountBalance(address: "TPSovt4buv51PZXEN15zLosbk2ajEdW7G4")
            Issue.record("Expected an exhausted rate limit failure.")
        } catch let error as SendTransactionSubmissionError {
            #expect(error.allowsRetry)
            #expect(!error.submissionMayHaveSucceeded)
            #expect(error.localizedMessage == WalletLocalization.string("send.submit.error.try_again"))
            #expect(error.diagnosticCode == "provider_tron_http_429")
        }
        #expect(TronSendURLProtocol.requests().count == 12)
    }

    @Test
    func broadcastRecoversAfterEveryProviderFailsTheFirstPass() async throws {
        let transactionID = String(repeating: "a", count: 64)
        let signedJSON = """
        {"txID":"\(transactionID)","raw_data_hex":"00","signature":["unchanged"]}
        """
        TronSendURLProtocol.installResponses([
            (503, ["Error": "temporarily unavailable"]),
            (429, ["Error": "rate limit exceeded"]),
            (200, ["result": false, "code": "SERVER_BUSY"]),
            (200, ["result": true, "txid": transactionID])
        ])
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let result = try await SendTronAPIClient(
            session: session, router: AdaptiveProviderRouter(persistsHealth: false),
            retrySleep: { _ in }
        ).broadcast(signedJSON: signedJSON)
        #expect(result == transactionID)
        let requests = TronSendURLProtocol.requests()
        #expect(requests.count == 4)
        #expect(requests.first?.body == requests.last?.body)
        #expect(requests.first?.url == requests.last?.url)
    }

    @Test
    func allChainsHideProviderMessagesAndDiagnosticCodes() {
        for networkID in ["tron", "eth", "base", "arbitrum", "bitcoin", "solana", "xrp", "ton", "near"] {
            let error = SendTransactionSubmissionError.provider(
                networkID: networkID, code: "http_429", message: "Secret provider implementation details"
            )
            #expect(error.localizedFailureMessage(networkID: networkID, isNative: true)
                == WalletLocalization.string("send.submit.error.try_again"))
            #expect(!error.localizedMessage.contains(error.diagnosticCode))
        }
    }

    @Test
    func providerMessageDecoderPreservesMalformedAndNonTextData() {
        for raw in ["", "abc", "0x123", "fffe", "0001", "/w==", "AAE=",
                    "Signature rejected by node."] {
            #expect(SendTronProviderMessage.decode(raw) == raw)
        }
        #expect(SendTronProviderMessage.decode("0X536967206572726F72") == "Sig error")
        let oversized = String(repeating: "41", count: 9_000)
        #expect(SendTronProviderMessage.decode(oversized) == oversized)
    }

    @Test
    func encodedReasonsAreDecodedBeforeDisplayTruncation() {
        let reason = "Validate signature error: " + String(repeating: "x", count: 400)
        let decoded = SendTronProviderMessage.decode(Data(reason.utf8).base64EncodedString())
        let safe = SendTransactionSubmissionError.sanitizedMessage(decoded)
        #expect(decoded == reason)
        #expect(safe.hasPrefix("Validate signature error: "))
        #expect(safe.count == 300)
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TronSendURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class TronSendURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    struct RecordedRequest: Sendable {
        let url: URL
        let body: Data
    }

    private struct Fixture: Sendable {
        let statusCode: Int
        let response: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures = [Fixture(
        statusCode: 500,
        response: Data()
    )]
    nonisolated(unsafe) private static var recordedRequests: [RecordedRequest] = []

    static func install(
        statusCode: Int,
        response: [String: Any]
    ) {
        installResponses([(statusCode, response)])
    }

    static func installResponses(_ responses: [(Int, [String: Any])]) {
        lock.lock()
        defer { lock.unlock() }
        fixtures = responses.map { statusCode, response in Fixture(
            statusCode: statusCode,
            response: try! JSONSerialization.data(
                withJSONObject: response
            )
        ) }
        recordedRequests = []
    }

    static func installRaw(statusCode: Int, response: Data) {
        lock.lock()
        defer { lock.unlock() }
        fixtures = [Fixture(statusCode: statusCode, response: response)]
        recordedRequests = []
    }

    static func lastRequest() -> RecordedRequest? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return recordedRequests.last
    }

    static func requests() -> [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let fixture: Fixture
        Self.lock.lock()
        fixture = Self.fixtures[0]
        if Self.fixtures.count > 1 { Self.fixtures.removeFirst() }
        if let url = request.url {
            Self.recordedRequests.append(RecordedRequest(
                url: url,
                body: URLRequestBodyReader.data(from: request) ?? Data()
            ))
        }
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: fixture.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: fixture.response)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

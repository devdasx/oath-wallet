import Foundation
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct TONSubmissionSafetyTests {
    private static let expectedHash = String(repeating: "0", count: 64)

    @Test
    func walletCoreV4R2SigningMatchesTrustWalletGoldenVector() throws {
        let privateKey = try #require(
            Data(
                hexString:
                    "c38f49de2fb13223a9e7d37d5d0ffbdd89a5eb7c8b0ee4d1c299f2cefe7dc4a0"
            )
        )
        let transfer = TheOpenNetworkTransfer.with {
            $0.dest = "EQBm--PFwDv1yCeS-QTJ-L8oiUpqo9IT1BwgVptlSq3ts90Q"
            $0.amount = Data([0x0a])
            $0.mode = UInt32(
                TheOpenNetworkSendMode.payFeesSeparately.rawValue
                    | TheOpenNetworkSendMode.ignoreActionPhaseErrors.rawValue
            )
            $0.bounceable = true
        }
        let output: TheOpenNetworkSigningOutput = AnySigner.sign(
            input: TheOpenNetworkSigningInput.with {
                $0.messages = [transfer]
                $0.privateKey = privateKey
                $0.sequenceNumber = 6
                $0.expireAt = 1_671_132_440
                $0.walletVersion = .walletV4R2
            },
            coin: .ton
        )
        let expected =
            "te6cckEBBAEArQABRYgBsLf6vJOEq42xW0AoyWX0K+uBMUcXFDLFqmkDg6k1Io4MAQGcEUPkil2aZ4s8KKparSep/OKHMC8vuXafFbW2HGp/9AcTRv0J5T4dwyW1G0JpHw+g5Ov6QI3Xo0O9RFr3KidICimpoxdjm3UYAAAABgADAgFiYgAzffHi4B365BPJfIJk/F+URKU1UekJ6g4QK02ypVb22YhQAAAAAAAAAAAAAAAAAQMAAA08Nzs="

        #expect(output.error == .ok)
        #expect(output.encoded == expected)
        #expect(output.hash.count == 32)
    }

    @Test
    func jettonAmountsUseTheFullVarUInteger16TransferRange() throws {
        let aboveUInt64 = try SendTONTransactionService
            .jettonTransferAmountData("18446744073709551616")
        #expect(aboveUInt64 == Data([1] + [UInt8](repeating: 0, count: 8)))

        let maximum = try SendTONTransactionService
            .jettonTransferAmountData(
                "1329227995784915872903807060280344575"
            )
        #expect(maximum == Data(repeating: 0xff, count: 15))

        #expect(throws: SendTransactionSubmissionError.self) {
            try SendTONTransactionService.jettonTransferAmountData(
                "1329227995784915872903807060280344576"
            )
        }
        #expect(throws: SendTransactionSubmissionError.self) {
            try SendTONTransactionService.jettonTransferAmountData("0")
        }
    }

    @Test
    func jettonWalletAddressComesFromTheMasterContractMethod()
        async throws
    {
        let baseURL = try #require(URL(string: "https://wallet.example"))
        let directURL = try #require(URL(string: "https://tonapi.example/v2"))
        let expected =
            "0:dfb1716e46f40e5ab0f80d57e200316de507bf0fb7a9e22bfcc536ed86961565"
        let probe = TONSubmissionProbe()
        let transport = try TONAPITransport(
            baseURL: baseURL,
            directReadBaseURL: directURL,
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            await probe.record(request.url)
            return Self.response(
                request: request,
                status: 200,
                body: """
                    {"success":true,"exit_code":0,"stack":[],\
                    "decoded":{"jetton_wallet_address":"\(expected)"}}
                    """
            )
        }

        let actual = try await transport.verifiedJettonWalletAddress(
            masterAddress:
                "0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe",
            ownerAddress:
                "0:66fbe3c5c03bf5c82792f904c9f8bf28894a6aa3d213d41c20569b654aadedb3"
        )

        #expect(actual == expected)
        let recordedURLs = (await probe.urls).compactMap { $0 }
        let url = try #require(recordedURLs.first)
        #expect(
            url.path
                == "/v2/blockchain/accounts/0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe/methods/get_wallet_address"
        )
        #expect(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first?.value
                == "0:66fbe3c5c03bf5c82792f904c9f8bf28894a6aa3d213d41c20569b654aadedb3"
        )
    }

    @Test
    func signedBroadcastNeverRetriesAfterAmbiguousTimeout() async throws {
        let baseURL = try #require(URL(string: "https://wallet.example"))
        let probe = TONSubmissionProbe()
        let transport = try TONAPITransport(
            baseURL: baseURL,
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            await probe.record(request.url)
            if request.url?.host == "tonapi.io" {
                return Self.response(
                    request: request,
                    status: 429,
                    body: #"{"error":"rate limit exceeded"}"#
                )
            }
            throw URLError(.timedOut)
        }

        do {
            try await transport.broadcast(
                boc: "te6cckEBAQEAAgAAAA==",
                expectedHash: Self.expectedHash
            )
            Issue.record("Timed-out TON submission unexpectedly succeeded.")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
        #expect(await probe.count(host: "toncenter.com") == 1)
    }

    @Test
    func preflightCancellationNeverStartsBroadcast() async throws {
        let baseURL = try #require(URL(string: "https://wallet.example"))
        let probe = TONSubmissionProbe()
        let transport = try TONAPITransport(
            baseURL: baseURL,
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            await probe.record(request.url)
            throw CancellationError()
        }

        do {
            try await transport.broadcast(
                boc: "te6cckEBAQEAAgAAAA==",
                expectedHash: Self.expectedHash
            )
            Issue.record("Cancelled TON preflight unexpectedly succeeded.")
        } catch is CancellationError {
            // Safe: the signed BOC never reached the broadcast endpoint.
        }
        #expect(await probe.count(host: "tonapi.io") == 1)
        #expect(await probe.count(host: "toncenter.com") == 0)
    }

    @Test
    func broadcastCancellationIsAnUnknownOutcome() async throws {
        let baseURL = try #require(URL(string: "https://wallet.example"))
        let probe = TONSubmissionProbe()
        let transport = try TONAPITransport(
            baseURL: baseURL,
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            await probe.record(request.url)
            if request.url?.host == "tonapi.io" {
                return Self.response(
                    request: request,
                    status: 429,
                    body: #"{"error":"rate limit exceeded"}"#
                )
            }
            throw CancellationError()
        }

        do {
            try await transport.broadcast(
                boc: "te6cckEBAQEAAgAAAA==",
                expectedHash: Self.expectedHash
            )
            Issue.record("Cancelled TON broadcast unexpectedly succeeded.")
        } catch let error as TONProviderError {
            #expect(
                error.diagnosticDescription
                    == "ton_server_504_ton_broadcast_outcome_unknown_cancelled"
            )
            #expect(
                !TONSubmissionErrorClassifier
                    .isDefinitivePreSubmission(error)
            )
        }
        #expect(await probe.count(host: "toncenter.com") == 1)
    }

    @Test
    func preflightAllowsSuccessfulFundingOfUninitializedRecipient()
        async throws
    {
        let baseURL = try #require(URL(string: "https://wallet.example"))
        let probe = TONSubmissionProbe()
        let transport = try TONAPITransport(
            baseURL: baseURL,
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            await probe.record(request.url)
            if request.url?.host == "tonapi.io" {
                return Self.response(
                    request: request,
                    status: 200,
                    body: """
                        {"trace":{"transaction":{"success":true,
                        "aborted":false,"action_phase":{"success":true,
                        "result_code":0},"compute_phase":{"skipped":false,
                        "success":true,"exit_code":0}},"children":[
                        {"transaction":{"success":true,"aborted":true,
                        "compute_phase":{"skipped":true,
                        "skip_reason":"cskip_no_state"}}}]},"event":{
                        "actions":[{"type":"TonTransfer","status":"ok"}]}}
                        """
                )
            }
            return Self.response(
                request: request,
                status: 200,
                body: """
                    {"ok":true,"result":{"@type":"raw.extMessageInfo",
                    "hash":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                    "hash_norm":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}}
                    """
            )
        }

        try await transport.broadcast(
            boc: "te6cckEBAQEAAgAAAA==",
            expectedHash: Self.expectedHash
        )

        #expect(await probe.count(host: "tonapi.io") == 1)
        #expect(await probe.count(host: "toncenter.com") == 1)
    }

    @Test
    func preflightPreservesFailedChildVMExitCode() async throws {
        let baseURL = try #require(URL(string: "https://wallet.example"))
        let probe = TONSubmissionProbe()
        let transport = try TONAPITransport(
            baseURL: baseURL,
            router: AdaptiveProviderRouter(persistsHealth: false)
        ) { request in
            await probe.record(request.url)
            return Self.response(
                request: request,
                status: 200,
                body: """
                    {"trace":{"transaction":{"success":true,
                    "aborted":false,"action_phase":{"success":true,
                    "result_code":0},"compute_phase":{"skipped":false,
                    "success":true,"exit_code":0}},"children":[
                    {"transaction":{"success":false,"aborted":true,
                    "compute_phase":{"skipped":false,"success":false,
                    "exit_code":9}}}]},"event":{"actions":[
                    {"type":"TonTransfer","status":"failed"}]}}
                    """
            )
        }

        do {
            try await transport.broadcast(
                boc: "te6cckEBAQEAAgAAAA==",
                expectedHash: Self.expectedHash
            )
            Issue.record("Failed TON child execution was accepted.")
        } catch let TONProviderError.server(status, code) {
            #expect(status == 422)
            #expect(code == "ton_preflight_rejected_exit_9")
        } catch {
            Issue.record("Unexpected TON preflight error: \(error)")
        }
        #expect(await probe.count(host: "toncenter.com") == 0)
    }

    @Test
    func classifierNeverCallsTimeoutOrHashMismatchDefinite() {
        #expect(
            TONSubmissionErrorClassifier.isDefinitivePreSubmission(
                .server(
                    status: 422,
                    code: "ton_broadcast_rejected_invalid_boc"
                )
            )
        )
        #expect(
            !TONSubmissionErrorClassifier.isDefinitivePreSubmission(
                .server(
                    status: 429,
                    code: "ton_broadcast_rate_limited"
                )
            )
        )
        #expect(
            !TONSubmissionErrorClassifier.isDefinitivePreSubmission(
                .server(
                    status: 504,
                    code: "ton_broadcast_outcome_unknown_timeout"
                )
            )
        )
        #expect(
            !TONSubmissionErrorClassifier.isDefinitivePreSubmission(
                .invalidResponse("broadcast_success_invalid")
            )
        )
        #expect(
            !TONSubmissionErrorClassifier.isDefinitivePreSubmission(
                .server(
                    status: 422,
                    code: "ton_broadcast_rejected_seqno"
                )
            )
        )
        #expect(
            !TONSubmissionErrorClassifier.isDefinitivePreSubmission(
                .server(
                    status: 422,
                    code: "ton_broadcast_rejected_exit_33"
                )
            )
        )
        #expect(
            TONSubmissionErrorClassifier.isDefinitivePreSubmission(
                .server(
                    status: 422,
                    code: "ton_preflight_rejected_exit_33"
                )
            )
        )
    }

    private static func response(
        request: URLRequest,
        status: Int,
        body: String
    ) -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://invalid.example")!
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

private actor TONSubmissionProbe {
    private(set) var urls: [URL?] = []

    func record(_ url: URL?) {
        urls.append(url)
    }

    func count(host: String) -> Int {
        urls.count { $0?.host == host }
    }
}

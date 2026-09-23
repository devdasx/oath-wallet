import Foundation
import Testing
@testable import Aperture

struct SolanaAdaptiveProviderTransportTests {
    @Test
    func signedSubmissionClassifierOnlyCallsPreflightErrorsDefinitive() {
        #expect(
            SendSolanaSubmissionErrorClassifier
                .isDefinitiveRPCRejection(code: -32_002)
        )
        #expect(
            SendSolanaSubmissionErrorClassifier
                .isDefinitiveRPCRejection(code: -32_003)
        )
        #expect(
            !SendSolanaSubmissionErrorClassifier
                .isDefinitiveRPCRejection(code: -32_603)
        )
        #expect(
            !SendSolanaSubmissionErrorClassifier
                .isDefinitiveRPCRejection(code: -32_005)
        )
        #expect(
            SendSolanaSubmissionErrorClassifier.isAlreadyProcessedMessage(
                "This transaction has already been processed"
            )
        )
        #expect(
            !SendSolanaSubmissionErrorClassifier.isAlreadyProcessedMessage(
                "Transaction simulation failed: insufficient funds"
            )
        )
    }

    @Test
    func serverFailureFallsBackToNextRPC() async throws {
        let testID = UUID().uuidString.lowercased()
        let firstHost = "solana-first-\(testID).example"
        let secondHost = "solana-second-\(testID).example"
        let first = URL(string: "https://\(firstHost)")!
        let second = URL(string: "https://\(secondHost)")!
        let attempts = SolanaTransportAttemptRecorder()
        let transport = SolanaRPCTransport(
            endpoints: [first, second],
            timeoutSeconds: 0.2
        ) { request in
            let host = request.url?.host ?? "missing"
            await attempts.record(host)
            if request.url == first {
                return (
                    Data(#"{"message":"temporarily unavailable"}"#.utf8),
                    Self.response(url: first, status: 503)
                )
            }
            return (
                Data(#"[{"jsonrpc":"2.0","result":{"value":42},"id":1}]"#.utf8),
                Self.response(url: second, status: 200)
            )
        }

        let responses = try await transport.batch([
            SolanaRPCRequest(method: "getBalance", params: [], id: 1)
        ])

        #expect(responses.count == 1)
        #expect(await attempts.count(firstHost) == 1)
        #expect(await attempts.count(secondHost) == 1)
    }

    @Test
    func timeoutFallsBackWithoutWaitingForSlowRPC() async throws {
        let testID = UUID().uuidString.lowercased()
        let firstHost = "solana-timeout-\(testID).example"
        let secondHost = "solana-fast-\(testID).example"
        let first = URL(string: "https://\(firstHost)")!
        let second = URL(string: "https://\(secondHost)")!
        let attempts = SolanaTransportAttemptRecorder()
        let transport = SolanaRPCTransport(
            endpoints: [first, second],
            timeoutSeconds: 0.02
        ) { request in
            let url = try #require(request.url)
            await attempts.record(url.host ?? "missing")
            if url == first {
                try await Task.sleep(for: .seconds(2))
            }
            return (
                Data(#"[{"jsonrpc":"2.0","result":{"value":7},"id":1}]"#.utf8),
                Self.response(url: url, status: 200)
            )
        }

        let responses = try await transport.batch([
            SolanaRPCRequest(method: "getBalance", params: [], id: 1)
        ])

        #expect(responses.count == 1)
        #expect(await attempts.count(firstHost) == 1)
        #expect(await attempts.count(secondHost) == 1)
    }

    @Test
    func balanceBatchUsesTheFastestHealthyRPC() async throws {
        let testID = UUID().uuidString.lowercased()
        let slowHost = "solana-balance-slow-\(testID).example"
        let fastHost = "solana-balance-fast-\(testID).example"
        let slow = URL(string: "https://\(slowHost)")!
        let fast = URL(string: "https://\(fastHost)")!
        let attempts = SolanaTransportAttemptRecorder()
        let transport = SolanaRPCTransport(
            endpoints: [slow, fast],
            timeoutSeconds: 1
        ) { request in
            let url = try #require(request.url)
            await attempts.record(url.host ?? "missing")
            if url == slow {
                try await Task.sleep(for: .seconds(2))
            }
            return (
                Data(
                    #"[{"jsonrpc":"2.0","result":{"value":11},"id":1}]"#.utf8
                ),
                Self.response(url: url, status: 200)
            )
        }
        let started = ContinuousClock.now

        let responses = try await transport.batchBalance([
            SolanaRPCRequest(method: "getBalance", params: [], id: 1)
        ])

        #expect(responses.count == 1)
        #expect(ContinuousClock.now - started < .milliseconds(250))
        #expect(await attempts.count(slowHost) == 1)
        #expect(await attempts.count(fastHost) == 1)
    }

    @Test
    func rpcRateLimitFallsBackToNextRPC() async throws {
        let testID = UUID().uuidString.lowercased()
        let first = URL(string: "https://solana-rpc429-\(testID).example")!
        let second = URL(string: "https://solana-rpcok-\(testID).example")!
        let attempts = SolanaTransportAttemptRecorder()
        let transport = SolanaRPCTransport(
            endpoints: [first, second],
            timeoutSeconds: 0.2
        ) { request in
            let url = try #require(request.url)
            await attempts.record(url.host ?? "missing")
            let data: Data
            if url == first {
                data = Data(
                    #"[{"jsonrpc":"2.0","error":{"code":429,"message":"Too many requests"},"id":1}]"#.utf8
                )
            } else {
                data = Data(
                    #"[{"jsonrpc":"2.0","result":{"value":9},"id":1}]"#.utf8
                )
            }
            return (data, Self.response(url: url, status: 200))
        }

        let responses = try await transport.batch([
            SolanaRPCRequest(method: "getBalance", params: [], id: 1)
        ])

        #expect(responses.count == 1)
        #expect(await attempts.count(first.host ?? "") == 1)
        #expect(await attempts.count(second.host ?? "") == 1)
    }

    @Test
    func providerRequestBlockedFallsBackButInvalidParamsDoesNot() async throws {
        let testID = UUID().uuidString.lowercased()
        let blocked = URL(
            string: "https://solana-blocked-\(testID).example"
        )!
        let succeeding = URL(
            string: "https://solana-success-\(testID).example"
        )!
        let attempts = SolanaTransportAttemptRecorder()
        let fallbackTransport = SolanaRPCTransport(
            endpoints: [blocked, succeeding],
            timeoutSeconds: 0.2
        ) { request in
            let url = try #require(request.url)
            await attempts.record(url.host ?? "missing")
            let data = url == blocked
                ? Data(
                    #"[{"jsonrpc":"2.0","error":{"code":-32602,"message":"Request blocked"},"id":1}]"#.utf8
                )
                : Data(
                    #"[{"jsonrpc":"2.0","result":{"value":3},"id":1}]"#.utf8
                )
            return (data, Self.response(url: url, status: 200))
        }

        _ = try await fallbackTransport.batch([
            SolanaRPCRequest(method: "getBalance", params: [], id: 1)
        ])
        #expect(await attempts.count(succeeding.host ?? "") == 1)

        let invalidFirst = URL(
            string: "https://solana-invalid-\(testID).example"
        )!
        let unusedSecond = URL(
            string: "https://solana-unused-\(testID).example"
        )!
        let invalidAttempts = SolanaTransportAttemptRecorder()
        let invalidTransport = SolanaRPCTransport(
            endpoints: [invalidFirst, unusedSecond],
            timeoutSeconds: 0.2
        ) { request in
            let url = try #require(request.url)
            await invalidAttempts.record(url.host ?? "missing")
            let data = Data(
                #"[{"jsonrpc":"2.0","error":{"code":-32602,"message":"Invalid params"},"id":1}]"#.utf8
            )
            return (data, Self.response(url: url, status: 200))
        }

        await #expect(throws: AnkrAPIError.self) {
            _ = try await invalidTransport.batch([
                SolanaRPCRequest(method: "getBalance", params: [], id: 1)
            ])
        }
        #expect(await invalidAttempts.count(unusedSecond.host ?? "") == 0)
    }

    @Test
    func publicNodeTransactionBatchUsesBoundedSingletonRequests() async throws {
        let endpoint = URL(
            string: "https://solana-rpc.publicnode.com/\(UUID().uuidString)"
        )!
        let recorder = SolanaRequestShapeRecorder()
        let transport = SolanaRPCTransport(
            endpoints: [endpoint],
            timeoutSeconds: 1
        ) { request in
            let body = try #require(request.httpBody)
            let object = try #require(
                JSONSerialization.jsonObject(with: body)
                    as? [[String: Any]]
            )
            await recorder.record(batchSize: object.count)
            let id = try #require(object.first?["id"] as? Int)
            let data = try JSONSerialization.data(withJSONObject: [[
                "jsonrpc": "2.0",
                "result": ["slot": id],
                "id": id
            ]])
            return (data, Self.response(url: endpoint, status: 200))
        }

        let responses = try await transport.batch(
            (1...9).map {
                SolanaRPCRequest(
                    method: "getTransaction",
                    params: [],
                    id: $0
                )
            }
        )

        #expect(responses.compactMap(\.id) == Array(1...9))
        #expect(await recorder.invocationCount == 9)
        #expect(await recorder.maximumBatchSize == 1)
    }

    @Test
    func officialBalanceBatchUsesConcurrentSingletonRequests() async throws {
        let endpoint = URL(
            string: "https://api.mainnet-beta.solana.com"
        )!
        let recorder = SolanaRequestShapeRecorder()
        let transport = SolanaRPCTransport(
            endpoints: [endpoint],
            timeoutSeconds: 1
        ) { request in
            let body = try #require(request.httpBody)
            let object = try #require(
                JSONSerialization.jsonObject(with: body)
                    as? [[String: Any]]
            )
            await recorder.record(batchSize: object.count)
            let id = try #require(object.first?["id"] as? Int)
            let data = try JSONSerialization.data(withJSONObject: [[
                "jsonrpc": "2.0",
                "result": ["value": id],
                "id": id
            ]])
            return (data, Self.response(url: endpoint, status: 200))
        }
        let requests = (1...6).map { id in
            SolanaRPCRequest(
                method: id.isMultiple(of: 3)
                    ? "getBalance"
                    : "getTokenAccountsByOwner",
                params: [],
                id: id
            )
        }

        let responses = try await transport.batchBalance(requests)

        #expect(responses.compactMap(\.id) == Array(1...6))
        #expect(await recorder.invocationCount == 6)
        #expect(await recorder.maximumBatchSize == 1)
    }

    private static func response(
        url: URL,
        status: Int
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

private actor SolanaRequestShapeRecorder {
    private var batchSizes: [Int] = []

    func record(batchSize: Int) {
        batchSizes.append(batchSize)
    }

    var invocationCount: Int {
        batchSizes.count
    }

    var maximumBatchSize: Int {
        batchSizes.max() ?? 0
    }
}

private actor SolanaTransportAttemptRecorder {
    private var values: [String: Int] = [:]

    func record(_ value: String) {
        values[value, default: 0] += 1
    }

    func count(_ value: String) -> Int {
        values[value, default: 0]
    }
}

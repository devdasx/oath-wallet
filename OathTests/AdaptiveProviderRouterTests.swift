import Foundation
import Testing
@testable import Aperture

struct AdaptiveProviderRouterTests {
    @Test
    func defaultOverallBudgetDoesNotGrowWithEveryFallback() {
        #expect(
            AdaptiveProviderRouter.defaultOverallReadBudget(
                timeoutSeconds: 8,
                attemptCount: 1
            ) == 8
        )
        #expect(
            AdaptiveProviderRouter.defaultOverallReadBudget(
                timeoutSeconds: 8,
                attemptCount: 2
            ) == 16
        )
        #expect(
            AdaptiveProviderRouter.defaultOverallReadBudget(
                timeoutSeconds: 8,
                attemptCount: 8
            ) == 16
        )
    }

    @Test
    func providerCapacityMessageMakesNonstandardRPCCodeRetryable() {
        #expect(
            ProviderReliabilityClassification.isRetryableJSONRPCError(
                code: 30,
                message: "Request timeout on the free plan"
            )
        )
        #expect(
            ProviderReliabilityClassification.isRetryableJSONRPCError(
                code: -32_046,
                message: "Cannot fulfill request"
            )
        )
        #expect(
            ProviderReliabilityClassification.isRetryableJSONRPCError(
                code: -32_055,
                message: "No nodes available"
            )
        )
        #expect(
            !ProviderReliabilityClassification.isRetryableJSONRPCError(
                code: 30,
                message: "execution reverted"
            )
        )
        #expect(
            !ProviderReliabilityClassification.isRetryableJSONRPCError(
                code: -32_046,
                message: "execution reverted"
            )
        )
    }

    @Test
    func ethereumPendingNonceFallsBackAfterCannotFulfill() async throws {
        EVMRPCFailoverURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EVMRPCFailoverURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let suffix = UUID().uuidString.lowercased()
        let first = try #require(
            URL(string: "https://cannot-fulfill-\(suffix).invalid")
        )
        let second = try #require(
            URL(string: "https://healthy-\(suffix).invalid")
        )
        let client = try SendEVMRPCClient(
            networkID: "eth",
            session: session,
            endpoints: [first, second]
        )

        let nonce = try await client.transactionCount(
            address: "0x1111111111111111111111111111111111111111"
        )

        #expect(nonce == "0x2a")
        #expect(EVMRPCFailoverURLProtocol.requestCount == 2)
    }

    @Test
    func evmReadFallsBackAfterProviderRejectsWhitelistedMethod()
        async throws {
        EVMRPCFailoverURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EVMRPCFailoverURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let suffix = UUID().uuidString.lowercased()
        let first = try #require(
            URL(string: "https://method-blocked-\(suffix).invalid")
        )
        let second = try #require(
            URL(string: "https://healthy-\(suffix).invalid")
        )
        let client = try SendEVMRPCClient(
            networkID: "eth",
            session: session,
            endpoints: [first, second]
        )

        let balance = try await client.tokenBalance(
            ownerAddress: "0x1111111111111111111111111111111111111111",
            contractAddress: "0x2222222222222222222222222222222222222222"
        )

        #expect(balance == "0x2a")
        #expect(EVMRPCFailoverURLProtocol.requestCount == 2)
    }

    @Test
    func evmBroadcastUsesOnlyDedicatedSubmissionEndpoints() async throws {
        EVMRPCFailoverURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EVMRPCFailoverURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let suffix = UUID().uuidString.lowercased()
        let readEndpoint = try #require(
            URL(string: "https://read-only-\(suffix).invalid")
        )
        let submissionEndpoint = try #require(
            URL(string: "https://submission-\(suffix).invalid")
        )
        let client = try SendEVMRPCClient(
            networkID: "eth",
            session: session,
            endpoints: [readEndpoint],
            submissionEndpoints: [submissionEndpoint]
        )

        let transactionHash = try await client.broadcast(
            rawTransaction: "0x01"
        )

        #expect(transactionHash == "0x2a")
        #expect(
            EVMRPCFailoverURLProtocol.requestedHosts
                == [submissionEndpoint.host()]
        )
    }

    @Test
    func timedOutReadFallsBackToNextProvider() async throws {
        let serviceID = "router_read_\(UUID().uuidString)"
        let first = endpoint(
            serviceID: serviceID,
            host: "first.example",
            priority: 0
        )
        let second = endpoint(
            serviceID: serviceID,
            host: "second.example",
            priority: 1
        )
        let counter = ProviderAttemptCounter()
        let router = AdaptiveProviderRouter()

        let value = try await router.executeRead(
            serviceID: serviceID,
            attempts: [
                AdaptiveProviderAttempt(endpoint: first) {
                    await counter.record("first")
                    try await Task.sleep(for: .seconds(2))
                    return "late"
                },
                AdaptiveProviderAttempt(endpoint: second) {
                    await counter.record("second")
                    return "fallback"
                }
            ],
            timeoutSeconds: 0.02,
            shouldFallback: ProviderReliabilityClassification
                .isRetryableTransport
        )

        let firstCount = await counter.count("first")
        let secondCount = await counter.count("second")
        #expect(value == "fallback")
        #expect(firstCount == 1)
        #expect(secondCount == 1)
    }

    @Test
    func hedgedReadReturnsTheFastestHealthyProvider() async throws {
        let serviceID = "router_hedged_\(UUID().uuidString)"
        let slow = endpoint(
            serviceID: serviceID,
            host: "slow.example",
            priority: 0
        )
        let fast = endpoint(
            serviceID: serviceID,
            host: "fast.example",
            priority: 1
        )
        let counter = ProviderAttemptCounter()
        let router = AdaptiveProviderRouter()
        let started = ContinuousClock.now

        let value = try await router.executeHedgedRead(
            serviceID: serviceID,
            attempts: [
                AdaptiveProviderAttempt(endpoint: slow) {
                    await counter.record("slow")
                    try await Task.sleep(for: .seconds(2))
                    return "late"
                },
                AdaptiveProviderAttempt(endpoint: fast) {
                    await counter.record("fast")
                    return "fast"
                }
            ],
            timeoutSeconds: 1,
            maximumConcurrentAttempts: 2,
            shouldFallback: ProviderReliabilityClassification
                .isRetryableTransport
        )

        #expect(value == "fast")
        #expect(ContinuousClock.now - started < .milliseconds(250))
        #expect(await counter.count("slow") == 1)
        #expect(await counter.count("fast") == 1)
    }

    @Test
    func overallReadBudgetBoundsTheEntireFallbackChain() async {
        let serviceID = "router_budget_\(UUID().uuidString)"
        let first = endpoint(
            serviceID: serviceID,
            host: "first.example",
            priority: 0
        )
        let second = endpoint(
            serviceID: serviceID,
            host: "second.example",
            priority: 1
        )
        let counter = ProviderAttemptCounter()
        let router = AdaptiveProviderRouter()
        let started = ContinuousClock.now

        do {
            _ = try await router.executeRead(
                serviceID: serviceID,
                attempts: [
                    AdaptiveProviderAttempt(endpoint: first) {
                        await counter.record("first")
                        try await Task.sleep(for: .seconds(2))
                        return "late"
                    },
                    AdaptiveProviderAttempt(endpoint: second) {
                        await counter.record("second")
                        try await Task.sleep(for: .seconds(2))
                        return "late"
                    }
                ],
                timeoutSeconds: 0.06,
                overallTimeoutSeconds: 0.09,
                shouldFallback: ProviderReliabilityClassification
                    .isRetryableTransport
            )
            Issue.record("The read unexpectedly exceeded its budget")
        } catch let error as ProviderReliabilityError {
            guard case .timedOut = error else {
                Issue.record("Unexpected reliability error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected read-budget error: \(error)")
        }

        let elapsed = ContinuousClock.now - started
        let firstCount = await counter.count("first")
        let secondCount = await counter.count("second")
        #expect(elapsed < .milliseconds(250))
        #expect(firstCount == 1)
        #expect(secondCount == 1)
    }

    @Test
    func implicitReadBudgetBoundsLongFallbackLists() async {
        let serviceID = "router_implicit_budget_\(UUID().uuidString)"
        let endpoints = (0..<4).map {
            endpoint(
                serviceID: serviceID,
                host: "provider-\($0).example",
                priority: $0
            )
        }
        let router = AdaptiveProviderRouter()
        let started = ContinuousClock.now

        do {
            _ = try await router.executeRead(
                serviceID: serviceID,
                attempts: endpoints.map { endpoint in
                    AdaptiveProviderAttempt(endpoint: endpoint) {
                        try await Task.sleep(for: .seconds(2))
                        return "late"
                    }
                },
                timeoutSeconds: 0.04,
                shouldFallback: ProviderReliabilityClassification
                    .isRetryableTransport
            )
            Issue.record("The implicit read budget unexpectedly succeeded")
        } catch let error as ProviderReliabilityError {
            guard case .timedOut = error else {
                Issue.record("Unexpected reliability error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected implicit-budget error: \(error)")
        }

        #expect(ContinuousClock.now - started < .milliseconds(200))
    }

    @Test
    func measuredHealthReordersProviders() async {
        let serviceID = "router_order_\(UUID().uuidString)"
        let first = endpoint(
            serviceID: serviceID,
            host: "first.example",
            priority: 0
        )
        let second = endpoint(
            serviceID: serviceID,
            host: "second.example",
            priority: 1
        )
        let router = AdaptiveProviderRouter()

        await router.recordFailure(
            endpoint: first,
            latencyMilliseconds: 1_000
        )
        await router.recordFailure(
            endpoint: first,
            latencyMilliseconds: 1_000
        )
        await router.recordSuccess(
            endpoint: second,
            latencyMilliseconds: 50
        )

        let ordered = await router.ordered([first, second])
        #expect(ordered.first == second)
    }

    @Test
    func newlyAddedFallbackReceivesOneBoundedHealthProbe() async {
        let serviceID = "router_exploration_\(UUID().uuidString)"
        let primary = endpoint(
            serviceID: serviceID,
            host: "primary.example",
            priority: 0
        )
        let newFallback = endpoint(
            serviceID: serviceID,
            host: "new-fallback.example",
            priority: 1
        )
        let router = AdaptiveProviderRouter()

        await router.recordSuccess(
            endpoint: primary,
            latencyMilliseconds: 25
        )

        let beforeMeasurement = await router.ordered([primary, newFallback])
        #expect(beforeMeasurement.first == newFallback)

        await router.recordSuccess(
            endpoint: newFallback,
            latencyMilliseconds: 200
        )
        let afterMeasurement = await router.ordered([primary, newFallback])
        #expect(afterMeasurement.first == primary)
    }

    @Test
    func staleFailedProviderCanReenterForAHealthProbe() async {
        let serviceID = "router_stale_\(UUID().uuidString)"
        let recovered = endpoint(
            serviceID: serviceID,
            host: "recovered.example",
            priority: 0
        )
        let current = endpoint(
            serviceID: serviceID,
            host: "current.example",
            priority: 1
        )
        let router = AdaptiveProviderRouter()

        await router.recordFailure(
            endpoint: recovered,
            latencyMilliseconds: 1_000
        )
        await router.recordSuccess(
            endpoint: current,
            latencyMilliseconds: 50
        )

        let recent = await router.ordered([recovered, current])
        #expect(recent.first == current)

        let stale = await router.ordered(
            [recovered, current],
            now: Date().addingTimeInterval((6 * 60 * 60) + 1)
        )
        #expect(stale.first == recovered)
    }

    @Test
    func activeCooldownIsNeverBypassedForExploration() async {
        let serviceID = "router_cooldown_\(UUID().uuidString)"
        let failing = endpoint(
            serviceID: serviceID,
            host: "failing.example",
            priority: 0
        )
        let healthy = endpoint(
            serviceID: serviceID,
            host: "healthy.example",
            priority: 1
        )
        let router = AdaptiveProviderRouter()

        await router.recordFailure(
            endpoint: failing,
            latencyMilliseconds: 50
        )
        await router.recordFailure(
            endpoint: failing,
            latencyMilliseconds: 50
        )
        await router.recordSuccess(
            endpoint: healthy,
            latencyMilliseconds: 500
        )

        let ordered = await router.ordered([failing, healthy])
        #expect(ordered.first == healthy)
    }

    @Test
    func firstReliabilityFailureImmediatelyQuarantinesProvider() async {
        let serviceID = "router_first_failure_\(UUID().uuidString)"
        let failing = endpoint(
            serviceID: serviceID,
            host: "failing.example",
            priority: 0
        )
        let fallback = endpoint(
            serviceID: serviceID,
            host: "fallback.example",
            priority: 1
        )
        let router = AdaptiveProviderRouter()

        await router.recordFailure(
            endpoint: failing,
            latencyMilliseconds: 50
        )

        let ordered = await router.ordered([failing, fallback])
        #expect(ordered.first == fallback)
    }

    @Test
    func measuredLatencySelectsTheFasterHealthyProvider() async {
        let serviceID = "router_latency_\(UUID().uuidString)"
        let first = endpoint(
            serviceID: serviceID,
            host: "first.example",
            priority: 0
        )
        let second = endpoint(
            serviceID: serviceID,
            host: "second.example",
            priority: 1
        )
        let router = AdaptiveProviderRouter()

        await router.recordSuccess(
            endpoint: first,
            latencyMilliseconds: 800
        )
        await router.recordSuccess(
            endpoint: second,
            latencyMilliseconds: 100
        )

        let ordered = await router.ordered([first, second])
        #expect(ordered.first == second)
    }

    @Test
    func reliabilityOutweighsOneFastButFlakySample() async {
        let serviceID = "router_quality_\(UUID().uuidString)"
        let flaky = endpoint(
            serviceID: serviceID,
            host: "flaky.example",
            priority: 0
        )
        let reliable = endpoint(
            serviceID: serviceID,
            host: "reliable.example",
            priority: 1
        )
        let router = AdaptiveProviderRouter()

        await router.recordFailure(
            endpoint: flaky,
            latencyMilliseconds: 50
        )
        await router.recordSuccess(
            endpoint: flaky,
            latencyMilliseconds: 50
        )
        await router.recordSuccess(
            endpoint: reliable,
            latencyMilliseconds: 300
        )

        let ordered = await router.ordered([flaky, reliable])
        #expect(ordered.first == reliable)
    }

    @Test
    func deterministicReadFailureDoesNotTryFallback() async {
        let serviceID = "router_deterministic_\(UUID().uuidString)"
        let first = endpoint(
            serviceID: serviceID,
            host: "first.example",
            priority: 0
        )
        let second = endpoint(
            serviceID: serviceID,
            host: "second.example",
            priority: 1
        )
        let counter = ProviderAttemptCounter()
        let router = AdaptiveProviderRouter()
        let attempts: [AdaptiveProviderAttempt<String>] = [
            AdaptiveProviderAttempt(endpoint: first) {
                await counter.record("first")
                throw DeterministicProviderTestError.invalidRequest
            },
            AdaptiveProviderAttempt(endpoint: second) {
                await counter.record("second")
                return "must-not-read"
            }
        ]

        do {
            _ = try await router.executeRead(
                serviceID: serviceID,
                attempts: attempts,
                timeoutSeconds: 1,
                shouldFallback: ProviderReliabilityClassification
                    .isRetryableTransport
            )
            Issue.record("A deterministic failure unexpectedly succeeded")
        } catch DeterministicProviderTestError.invalidRequest {
            // Expected.
        } catch {
            Issue.record("Unexpected deterministic error: \(error)")
        }

        let firstCount = await counter.count("first")
        let secondCount = await counter.count("second")
        #expect(firstCount == 1)
        #expect(secondCount == 0)
    }

    @Test
    func submissionNeverAttemptsSecondProvider() async {
        let serviceID = "router_submit_\(UUID().uuidString)"
        let first = endpoint(
            serviceID: serviceID,
            host: "first.example",
            priority: 0
        )
        let second = endpoint(
            serviceID: serviceID,
            host: "second.example",
            priority: 1
        )
        let counter = ProviderAttemptCounter()
        let router = AdaptiveProviderRouter()
        let attempts: [AdaptiveProviderAttempt<String>] = [
            AdaptiveProviderAttempt(endpoint: first) {
                await counter.record("first")
                throw URLError(.timedOut)
            },
            AdaptiveProviderAttempt(endpoint: second) {
                await counter.record("second")
                return "must-not-submit"
            }
        ]

        do {
            _ = try await router.executeSubmission(
                serviceID: serviceID,
                attempts: attempts,
                timeoutSeconds: 1,
                isReliabilityFailure: ProviderReliabilityClassification
                    .isRetryableTransport
            )
            Issue.record("The timed-out submission unexpectedly succeeded")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected submission error: \(error)")
        }

        let firstCount = await counter.count("first")
        let secondCount = await counter.count("second")
        #expect(firstCount == 1)
        #expect(secondCount == 0)
    }

    @Test
    func submissionNeverUsesAnUnmeasuredEndpointForExploration() async throws {
        let serviceID = "router_submit_no_probe_\(UUID().uuidString)"
        let primary = endpoint(
            serviceID: serviceID,
            host: "primary.example",
            priority: 0
        )
        let unmeasuredFallback = endpoint(
            serviceID: serviceID,
            host: "unmeasured.example",
            priority: 1
        )
        let counter = ProviderAttemptCounter()
        let router = AdaptiveProviderRouter()

        await router.recordSuccess(
            endpoint: primary,
            latencyMilliseconds: 100
        )

        let value = try await router.executeSubmission(
            serviceID: serviceID,
            attempts: [
                AdaptiveProviderAttempt(endpoint: primary) {
                    await counter.record("primary")
                    return "submitted"
                },
                AdaptiveProviderAttempt(endpoint: unmeasuredFallback) {
                    await counter.record("unmeasured")
                    return "must-not-submit"
                }
            ],
            timeoutSeconds: 1,
            isReliabilityFailure: ProviderReliabilityClassification
                .isRetryableTransport
        )

        #expect(value == "submitted")
        #expect(await counter.count("primary") == 1)
        #expect(await counter.count("unmeasured") == 0)
    }

    @Test
    func explicitProviderIdentityIgnoresWalletPathAndCursor() {
        let serviceID = "router_identity_\(UUID().uuidString)"
        let origin = URL(string: "https://provider.example")!
        let first = AdaptiveProviderEndpoint(
            serviceID: serviceID,
            endpointURL: URL(
                string: "https://provider.example/accounts/wallet-a?cursor=1"
            )!,
            identityURL: origin,
            baselinePriority: 0
        )
        let second = AdaptiveProviderEndpoint(
            serviceID: serviceID,
            endpointURL: URL(
                string: "https://provider.example/accounts/wallet-b?cursor=2"
            )!,
            identityURL: origin,
            baselinePriority: 0
        )

        #expect(first.endpointID == second.endpointID)
    }

    @Test
    func operationScopedHealthDoesNotLeakAcrossResourceTypes() async {
        let baseServiceID = "router_scope_\(UUID().uuidString)"
        let balanceServiceID = AdaptiveProviderIdentity.scopedServiceID(
            baseServiceID,
            operation: "balance"
        )
        let historyServiceID = AdaptiveProviderIdentity.scopedServiceID(
            baseServiceID,
            operation: "history"
        )
        let balancePrimary = endpoint(
            serviceID: balanceServiceID,
            host: "primary.example",
            priority: 0
        )
        let balanceFallback = endpoint(
            serviceID: balanceServiceID,
            host: "fallback.example",
            priority: 1
        )
        let historyPrimary = endpoint(
            serviceID: historyServiceID,
            host: "primary.example",
            priority: 0
        )
        let router = AdaptiveProviderRouter()

        await router.recordFailure(
            endpoint: historyPrimary,
            latencyMilliseconds: 1_000
        )

        let balanceOrder = await router.ordered([
            balancePrimary,
            balanceFallback
        ])
        #expect(balanceServiceID != historyServiceID)
        #expect(balancePrimary.endpointID != historyPrimary.endpointID)
        #expect(balanceOrder.first == balancePrimary)
    }

    private func endpoint(
        serviceID: String,
        host: String,
        priority: Int
    ) -> AdaptiveProviderEndpoint {
        AdaptiveProviderEndpoint(
            serviceID: serviceID,
            endpointURL: URL(string: "https://\(host)")!,
            baselinePriority: priority
        )
    }
}

private enum DeterministicProviderTestError: Error {
    case invalidRequest
}

private actor ProviderAttemptCounter {
    private var values: [String: Int] = [:]

    func record(_ value: String) {
        values[value, default: 0] += 1
    }

    func count(_ value: String) -> Int {
        values[value, default: 0]
    }
}

private final class EVMRPCFailoverURLProtocol:
    URLProtocol,
    @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var hosts: [String?] = []

    static func reset() {
        lock.withLock {
            count = 0
            hosts = []
        }
    }

    static var requestCount: Int {
        lock.withLock { count }
    }

    static var requestedHosts: [String?] {
        lock.withLock { hosts }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest { request }

    override func startLoading() {
        guard
            let url = request.url,
            let body = request.httpBody
                ?? Self.readBodyStream(request.httpBodyStream),
            let object = try? JSONSerialization.jsonObject(with: body)
                as? [String: Any],
            let identifier = object["id"] as? Int
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.cannotParseResponse)
            )
            return
        }

        Self.lock.withLock {
            Self.count += 1
            Self.hosts.append(url.host())
        }
        let payload: [String: Any]
        if url.host?.hasPrefix("cannot-fulfill-") == true {
            payload = [
                "jsonrpc": "2.0",
                "id": identifier,
                "error": [
                    "code": -32_046,
                    "message": "Cannot fulfill request"
                ]
            ]
        } else if url.host?.hasPrefix("method-blocked-") == true {
            payload = [
                "jsonrpc": "2.0",
                "id": identifier,
                "error": [
                    "code": -32_601,
                    "message": "RPC method is not whitelisted"
                ]
            ]
        } else {
            payload = [
                "jsonrpc": "2.0",
                "id": identifier,
                "result": "0x2a"
            ]
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let responseBody = try! JSONSerialization.data(
            withJSONObject: payload
        )
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}

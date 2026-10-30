import Foundation
import XCTest
import OathDiagnostics
@testable import OathBitcoin

private actor BroadcastCalls {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

final class UTXOHTTPTests: XCTestCase, @unchecked Sendable {
    // Public deterministic, synthetic funding. No production wallet or network
    // is used by these signed-transaction/failure/latency regression tests.
    private func signed(_ chain: UTXONetwork) throws -> BitcoinSignedSend {
        let seed = Data(0..<32), wallet: BitcoinWalletDescriptor
        switch chain {
        case .bitcoin: wallet = try BitcoinKeys.wallet(seed: seed)
        case .bitcoincash: wallet = try BitcoinCashKeys.wallet(seed: seed)
        case .litecoin: wallet = try LitecoinKeys.wallet(seed: seed)
        case .dogecoin: wallet = try DogecoinKeys.wallet(seed: seed)
        }
        let receive = try BitcoinKeys.addresses(branch: wallet.branches.first { $0.change == 0 }!, range: 0..<2)
        let change = try BitcoinKeys.addresses(branch: wallet.branches.first { $0.change == 1 }!, range: 0..<1)[0]
        var funding = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 1, count: 32)
        funding += BitcoinWire.little(UInt32(0)) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        funding += BitcoinWire.little(UInt64(100_000_000)) + BitcoinWire.vector(Data(hex: receive[0].script)!) + BitcoinWire.little(UInt32(0))
        let coin = BitcoinSendCoin(accountID: "fixture", txid: try BitcoinTransactions.txid(funding, network: chain),
            vout: 0, value: 100_000_000, address: receive[0], previousTransaction: funding)
        let plan = try BitcoinSendPlan.make(coins: [coin], recipient: receive[1].address, amount: 50_000_000,
            change: change, ratePerKVByte: chain.sendFeeRates.lowerBound, chain: chain)
        if chain == .bitcoincash { return try BitcoinCashSendSigner.sign(plan) { _ in .seed(seed, account: 0) } }
        return try BitcoinSendSigner.sign(plan) { _ in .seed(seed, account: 0) }
    }
    func testDefaultReconciliationAvoidsDeniedBlockbookHostsWithoutRebroadcasting() async throws {
        for chain in [UTXONetwork.bitcoincash, .dogecoin, .litecoin] {
            let tx = try signed(chain), calls = BroadcastCalls()
            let client = UTXOBroadcastProvider(sources: { network in
                UTXOBroadcastProvider.liveSources(network).map { source in
                    .init(name: source.name, delay: .zero, submit: { _ in
                        await calls.add("unexpected-post"); throw URLError(.unsupportedURL)
                    }, lookup: { _ in
                        await calls.add(source.name)
                        if source.name.hasSuffix(".trezor.io") { throw UTXOAPIProvider.APIError.http(403) }
                        try await Task.sleep(for: .milliseconds(40))
                        return tx.raw
                    })
                }
            })
            let accepted = await client.submit(tx.raw, txid: tx.txid, network: chain, reconcileFirst: true)
            XCTAssertTrue(accepted)
            let contacted = await calls.values
            XCTAssertFalse(contacted.contains("unexpected-post"))
            XCTAssertFalse(contacted.contains { $0.hasSuffix(".trezor.io") }, "Denied infrastructure must not remain a default recovery route")
        }
    }

    func testReconciliationChecksIndependentTLSReadersBeforeAnyRebroadcast() async throws {
        for chain in UTXONetwork.allCases {
            let tx = try signed(chain), calls = BroadcastCalls()
            let client = UTXOBroadcastProvider(lastResort: { _ in [
                .init(name: "tls", delay: .zero, submit: { _ in await calls.add("post"); throw URLError(.unsupportedURL) },
                    lookup: { _ in await calls.add("tls-read"); return tx.raw })
            ] }, sources: { _ in [
                .init(name: "http", delay: .zero, submit: { _ in await calls.add("post"); throw URLError(.unsupportedURL) },
                    lookup: { _ in throw UTXOAPIProvider.APIError.http(403) })
            ] })
            let accepted = await client.submit(tx.raw, txid: tx.txid, network: chain, reconcileFirst: true)
            XCTAssertTrue(accepted)
            let attempts = await calls.values
            XCTAssertEqual(attempts, ["tls-read"], "An HTTP outage must not rebroadcast a transaction already visible through TLS")
        }
    }

    func testHedgedSubmissionBeatsSlowPrimaryAndUsesIdenticalBytesOnAllChains() async throws {
        for chain in UTXONetwork.allCases {
            let tx = try signed(chain), calls = BroadcastCalls()
            let client = UTXOBroadcastProvider { _ in [
                .init(name: "slow", delay: .zero, submit: { hex in
                    await calls.add(hex); try await Task.sleep(for: .seconds(10)); return tx.txid
                }, lookup: { _ in nil }),
                .init(name: "fallback", delay: .milliseconds(20), submit: { hex in
                    await calls.add(hex); return tx.txid
                }, lookup: { _ in nil })
            ] }
            let start = ContinuousClock.now
            let accepted = await client.submit(tx.raw, txid: tx.txid, network: chain)
            let elapsed = start.duration(to: .now)
            XCTAssertTrue(accepted); XCTAssertLessThan(elapsed, .milliseconds(500))
            let submitted = await calls.values
            XCTAssertEqual(submitted.count, 2); XCTAssertEqual(Set(submitted), [tx.raw.hex])
            print("HEDGED BROADCAST fixture chain=\(chain.rawValue) duration=\(elapsed) slow-primary=10s")
        }
    }
    func testDefaultPrimaryHeadStartDoesNotAddOneSecondToAnyChain() async throws {
        for chain in UTXONetwork.allCases {
            let tx=try signed(chain),calls=BroadcastCalls()
            let provider=UTXOBroadcastProvider(preferred:{_ in
                .init(name:"primary",delay:.zero,submit:{hex in
                    await calls.add(hex);try await Task.sleep(for:.seconds(10));return tx.txid
                },lookup:{_ in nil})
            },sources:{_ in [
                .init(name:"fallback",delay:.zero,submit:{hex in await calls.add(hex);return tx.txid},lookup:{_ in nil})
            ]})
            let start=ContinuousClock.now,accepted=await provider.submit(tx.raw,txid:tx.txid,network:chain)
            XCTAssertTrue(accepted);XCTAssertLessThan(start.duration(to:.now),.milliseconds(800))
            let bytes=await calls.values;XCTAssertEqual(bytes,[tx.raw.hex,tx.raw.hex])
        }
    }
    func testPreferredBroadcastSuccessSkipsEveryFallbackOnAllChains() async throws {
        for chain in UTXONetwork.allCases {
            let tx = try signed(chain), calls = BroadcastCalls()
            let provider = UTXOBroadcastProvider(preferred: { _ in
                .init(name: "primary", delay: .zero, submit: { hex in
                    XCTAssertEqual(hex, tx.raw.hex); await calls.add("primary"); return tx.txid
                }, lookup: { _ in nil })
            }, lastResort: { _ in [
                .init(name: "server", delay: .zero, submit: { _ in await calls.add("server"); return tx.txid }, lookup: { _ in nil })
            ] }, sources: { _ in [
                .init(name: "fallback", delay: .zero, submit: { _ in await calls.add("fallback"); return tx.txid }, lookup: { _ in nil })
            ] })
            let accepted = await provider.submit(tx.raw, txid: tx.txid, network: chain)
            XCTAssertTrue(accepted)
            let used = await calls.values; XCTAssertEqual(used, ["primary"])
        }
    }
    func testPrimaryOutageWrongResultOrStallUsesSameBytesInFastFallbackOnAllChains() async throws {
        for chain in UTXONetwork.allCases {
            let tx = try signed(chain)
            for mode in ["503", "stall", "wrong-hash"] {
                let calls = BroadcastCalls()
                let provider = UTXOBroadcastProvider(lookupDelay: .milliseconds(5), preferredDeadline: .milliseconds(30), preferred: { _ in
                    .init(name: "primary", delay: .zero, submit: { hex in
                        await calls.add(hex)
                        if mode == "stall" { try await Task.sleep(for: .seconds(10)) }
                        if mode == "wrong-hash" { return String(repeating: "a", count: 64) }
                        throw UTXOAPIProvider.APIError.http(503)
                    }, lookup: { _ in nil })
                }, sources: { _ in [
                    .init(name: "fallback", delay: .zero, submit: { hex in await calls.add(hex); return tx.txid }, lookup: { _ in nil })
                ] })
                let start = ContinuousClock.now, accepted = await provider.submit(tx.raw, txid: tx.txid, network: chain)
                XCTAssertTrue(accepted); XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
                let submitted = await calls.values; XCTAssertEqual(submitted, [tx.raw.hex, tx.raw.hex])
            }
        }
    }
    func testPrimaryLostResponseCanReconcileWithoutSubmittingToFallback() async throws {
        for chain in UTXONetwork.allCases {
            let tx = try signed(chain), calls = BroadcastCalls()
            let provider = UTXOBroadcastProvider(lookupDelay: .milliseconds(10), preferred: { _ in
                .init(name: "primary", delay: .zero, submit: { _ in
                    try await Task.sleep(for: .seconds(10)); return tx.txid
                }, lookup: { _ in tx.raw })
            }, sources: { _ in [
                .init(name: "fallback", delay: .zero, submit: { _ in await calls.add("fallback"); return tx.txid }, lookup: { _ in nil })
            ] })
            let accepted = await provider.submit(tx.raw, txid: tx.txid, network: chain)
            XCTAssertTrue(accepted)
            let used = await calls.values; XCTAssertTrue(used.isEmpty)
        }
    }
    func testPrimaryAndAPIFailureStillReachServerAndCancellationNeverDoes() async throws {
        for chain in UTXONetwork.allCases {
            let tx = try signed(chain), calls = BroadcastCalls()
            let provider = UTXOBroadcastProvider(lookupDelay: .milliseconds(5), preferred: { _ in
                .init(name: "primary", delay: .zero, submit: { _ in
                    await calls.add("primary"); throw UTXOAPIProvider.APIError.http(503)
                }, lookup: { _ in nil })
            }, lastResort: { _ in [
                .init(name: "server", delay: .zero, submit: { hex in
                    XCTAssertEqual(hex, tx.raw.hex)
                    let before = await calls.values; XCTAssertEqual(before, ["primary", "public"])
                    await calls.add("server"); return tx.txid
                }, lookup: { _ in nil })
            ] }, sources: { _ in [
                .init(name: "public", delay: .zero, submit: { _ in
                    await calls.add("public"); throw UTXOAPIProvider.APIError.http(503)
                }, lookup: { _ in nil })
            ] })
            let accepted = await provider.submit(tx.raw, txid: tx.txid, network: chain); XCTAssertTrue(accepted)
            let task = Task { await provider.submit(tx.raw, txid: tx.txid, network: chain) }
            task.cancel(); let canceled = await task.value; XCTAssertFalse(canceled)
            let used = await calls.values; XCTAssertEqual(used, ["primary", "public", "server"])
        }
    }
    func testLostResponseOrAlreadyKnownNeedsExactLookupOnAllChains() async throws {
        for chain in UTXONetwork.allCases {
            let tx = try signed(chain)
            for lost in [false, true] {
                let client = UTXOBroadcastProvider(lookupDelay: .milliseconds(10)) { _ in [
                    .init(name: "api", delay: .zero, submit: { _ in
                        if lost { try await Task.sleep(for: .seconds(10)) }
                        throw NSError(domain: "fixture", code: -27, userInfo: [NSLocalizedDescriptionKey: "already in block chain"])
                    }, lookup: { _ in tx.raw })
                ] }
                let start = ContinuousClock.now
                let accepted = await client.submit(tx.raw, txid: tx.txid, network: chain)
                XCTAssertTrue(accepted); XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
            }
        }
    }
    func testWrongHashOrBytesNeverBecomeSuccessAndAllFailuresRemainPending() async throws {
        for chain in UTXONetwork.allCases {
            let tx = try signed(chain)
            for raw in [Data?.none, Data([0])] {
                let client = UTXOBroadcastProvider(lookupDelay: .zero) { _ in [
                    .init(name: "wrong", delay: .zero, submit: { _ in String(repeating: "a", count: 64) }, lookup: { _ in raw }),
                    .init(name: "outage", delay: .zero, submit: { _ in throw URLError(.timedOut) }, lookup: { _ in nil })
                ] }
                let accepted = await client.submit(tx.raw, txid: tx.txid, network: chain)
                XCTAssertFalse(accepted)
            }
        }
    }
    func testDeadlineAndCancellationStopOutstandingRequests() async throws {
        let tx = try signed(.bitcoin), calls = BroadcastCalls()
        let client = UTXOBroadcastProvider(deadline: .milliseconds(30), lookupDelay: .zero) { _ in [
            .init(name: "hung", delay: .zero, submit: { hex in
                await calls.add(hex); try await Task.sleep(for: .seconds(10)); return tx.txid
            }, lookup: { _ in try await Task.sleep(for: .seconds(10)); return tx.raw })
        ] }
        let start = ContinuousClock.now
        let result = await client.submit(tx.raw, txid: tx.txid, network: .bitcoin)
        XCTAssertFalse(result); XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        let task = Task { await client.submit(tx.raw, txid: tx.txid, network: .bitcoin) }
        task.cancel(); let canceled = await task.value
        XCTAssertFalse(canceled)
        let count = await calls.values.count; XCTAssertEqual(count, 1)
        let invalid = await client.submit(tx.raw, txid: String(repeating: "b", count: 64), network: .bitcoin)
        XCTAssertFalse(invalid)
        let after = await calls.values.count; XCTAssertEqual(after, 1)
    }
    func testEveryProviderUsesCorrectHTTPSPostBodyAndResponseSchema() throws {
        for chain in UTXONetwork.allCases {
            let tx = try signed(chain), providers = UTXOAPIProvider.providers(for: chain)
            XCTAssertFalse(providers.isEmpty)
            XCTAssertGreaterThanOrEqual(providers.count + UTXOServerFallback.broadcasts(chain).count, 3)
            for api in providers {
                let request = try api.broadcastRequest(hex: tx.raw.hex)
                XCTAssertEqual(request.url?.scheme, "https"); XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertFalse(request.url!.absoluteString.contains(tx.raw.hex))
                XCTAssertLessThanOrEqual(request.timeoutInterval, 3)
                let body = request.httpBody!, reply: String, rawReply: String
                switch api.format {
                case .mempool, .blockstream:
                    XCTAssertEqual(body, Data(tx.raw.hex.utf8))
                    reply = tx.txid; rawReply = tx.raw.hex
                case .blockbook:
                    XCTAssertEqual(body, Data(tx.raw.hex.utf8)); XCTAssertTrue(request.url!.path.hasSuffix("sendtx"))
                    XCTAssertTrue(request.url!.absoluteString.hasSuffix("/"))
                    reply = "{\"result\":\"\(tx.txid)\"}"; rawReply = "{\"hex\":\"\(tx.raw.hex)\"}"
                case .blockcypher:
                    XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: body)["tx"], tx.raw.hex)
                    reply = "{\"tx\":{\"hash\":\"\(tx.txid)\"}}"; rawReply = "{\"hex\":\"\(tx.raw.hex)\"}"
                case .blockchair:
                    XCTAssertEqual(body, Data("data=\(tx.raw.hex)".utf8))
                    XCTAssertEqual(api.base.lastPathComponent, chain == .bitcoincash ? "bitcoin-cash" : chain.rawValue)
                    reply = "{\"context\":{\"code\":200},\"data\":{\"transaction_hash\":\"\(tx.txid)\"}}"
                    rawReply = "{\"context\":{\"code\":200},\"data\":{\"\(tx.txid)\":{\"raw_transaction\":\"\(tx.raw.hex)\"}}}"
                }
                XCTAssertEqual(try api.decodeBroadcast(Data(reply.utf8)), tx.txid)
                XCTAssertEqual(try api.decodeRaw(Data(rawReply.utf8), txid: tx.txid), tx.raw)
                XCTAssertThrowsError(try api.decodeBroadcast(Data("<html>unavailable</html>".utf8)))
                XCTAssertThrowsError(try api.decodeBroadcast(Data("{\"error\":\"already known\"}".utf8)))
                XCTAssertThrowsError(try api.decodeRaw(Data("<html>unavailable</html>".utf8), txid: tx.txid))
                XCTAssertNil(try api.decodeRaw(Data(), txid: tx.txid))
            }
        }
        XCTAssertEqual(UTXOAPIProvider.providers(for: .bitcoin).first?.base.host, "mempool.space")
    }
    func testFeeUnitConversionBoundsFreshnessAndMalformedProviderResults() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-13T16:00:00Z")!
        for chain in UTXONetwork.allCases {
            let book = UTXOAPIProvider(network: chain, base: URL(string: "https://fixture.invalid")!, format: .blockbook)
            XCTAssertEqual(try book.decodeFee(Data("{\"result\":\"0.01\"}".utf8)), 1_000_000)
            for value in ["-1", "1000.0", "NaN", "0.01oops", "0", "0.000000001"] {
                XCTAssertThrowsError(try book.decodeFee(Data("{\"result\":\"\(value)\"}".utf8)))
            }
            let chair = UTXOAPIProvider(network: chain, base: URL(string: "https://fixture.invalid")!, format: .blockchair)
            func quote(_ rate: String, date: String = "2026-10-13 15:59:00", code: Int = 200) -> Data {
                Data("{\"data\":{\"suggested_transaction_fee_per_byte_sat\":\(rate)},\"context\":{\"code\":\(code),\"cache\":{\"since\":\"\(date)\"}}}".utf8)
            }
            XCTAssertEqual(try chair.decodeFee(quote("1.25"), now: now), max(1250, chain.sendFeeRates.lowerBound))
            for data in [quote("500000"), quote("0"), quote("-1"), quote("1", date: "2026-10-12 00:00:00"),
                         quote("1", date: "2026-10-14 00:00:00"), quote("1", code: 429)] {
                XCTAssertThrowsError(try chair.decodeFee(data, now: now))
            }
        }
    }
    func testNestedProviderErrorsArePrivacyFilteredBeforePersistence() throws {
        let api = UTXOAPIProvider.providers(for: .bitcoincash)[0]
        let tx = try signed(.bitcoincash)
        let payload = try JSONSerialization.data(withJSONObject: ["context": ["code": 400,
            "error": "mandatory-script-verify-flag-failed " + tx.raw.hex]])
        do { _ = try api.decodeBroadcast(payload); XCTFail() }
        catch {
            let event = DiagnosticEvent(error: error, component: "send", operation: "broadcast_api",
                context: ["chain": "bitcoincash"], sessionID: UUID())
            let stored = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
            XCTAssertFalse(stored.contains(tx.raw.hex))
            XCTAssertTrue(stored.contains("mandatory-script-verify-flag-failed"))
        }
    }
    func testHTTPFailuresAndExpectedPropagationAbsence() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UTXOReplyProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func request(_ path: String) -> URLRequest { URLRequest(url: URL(string: "https://fixture.invalid/\(path)")!) }
        let missing = try await UTXOAPIProvider.fetch(request("missing"), limit: 100, allowMissing: true, session: session, budget: UTXOAPIBudget())
        XCTAssertTrue(missing.isEmpty)
        for path in ["missing", "limited", "unavailable", "oversized", "policy"] {
            do {
                _ = try await UTXOAPIProvider.fetch(request(path), limit: 100, session: session, budget: UTXOAPIBudget())
                XCTFail("Accepted \(path)")
            } catch {
                if path == "policy" { XCTAssertEqual(error.localizedDescription, "tx decode failed") }
            }
        }
    }
    func testPublicAPIBudgetHonorsCooldownWithoutBlockingOtherProviders() async throws {
        let budget = UTXOAPIBudget()
        try await budget.acquire("api.blockchair.com")
        await budget.limit("api.blockchair.com", status: 430, retryAfter: "300")
        await budget.release("api.blockchair.com")
        let start = ContinuousClock.now
        do { try await budget.acquire("api.blockchair.com"); XCTFail() }
        catch is UTXOAPIBudget.Deferred { }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
        try await budget.acquire("mempool.space"); await budget.release("mempool.space")
        let tx = try signed(.bitcoincash)
        let provider = UTXOBroadcastProvider(lookupDelay: .zero) { _ in [
            .init(name: "throttled", delay: .zero, submit: { _ in throw UTXOAPIBudget.Deferred.cooldown }, lookup: { _ in throw UTXOAPIBudget.Deferred.cooldown }),
            .init(name: "working", delay: .milliseconds(10), submit: { _ in tx.txid }, lookup: { _ in nil })
        ] }
        let accepted = await provider.submit(tx.raw, txid: tx.txid, network: .bitcoincash)
        XCTAssertTrue(accepted)
    }
    func testServersAreUnusedWhenAnyAPISucceedsOnAllChains() async throws {
        for chain in UTXONetwork.allCases {
            let calls = BroadcastCalls(), tx = try signed(chain), rate = chain.sendFeeRates.lowerBound
            let fee = UTXOFeeProvider(lastResort: { _ in [
                .init(name: "server", delay: .zero) { await calls.add("fee-server"); return rate }
            ] }) { _ in [
                .init(name: "failed-api", delay: .zero) { throw URLError(.timedOut) },
                .init(name: "working-api", delay: .milliseconds(10)) { rate }
            ] }
            let quote = try await fee.rate(for: chain); XCTAssertEqual(quote, rate)
            let client = UTXOBroadcastProvider(lookupDelay: .zero, lastResort: { _ in [
                .init(name: "server", delay: .zero, submit: { _ in await calls.add("broadcast-server"); return tx.txid },
                      lookup: { _ in await calls.add("lookup-server"); return tx.raw })
            ] }) { _ in [
                .init(name: "failed-api", delay: .zero, submit: { _ in throw URLError(.timedOut) }, lookup: { _ in nil }),
                .init(name: "working-api", delay: .milliseconds(10), submit: { _ in tx.txid }, lookup: { _ in nil })
            ] }
            let accepted = await client.submit(tx.raw, txid: tx.txid, network: chain); XCTAssertTrue(accepted)
            let contacts = await calls.values; XCTAssertTrue(contacts.isEmpty)
        }
    }
    func testServersStartOnlyAfterEveryAPIAttemptAndLookupFailsOnAllChains() async throws {
        for chain in UTXONetwork.allCases {
            let calls = BroadcastCalls(), tx = try signed(chain), rate = chain.sendFeeRates.lowerBound
            let fee = UTXOFeeProvider(lastResort: { _ in [
                .init(name: "server", delay: .zero) {
                    let finished = await calls.values
                    XCTAssertEqual(Set(finished), ["fee-api1", "fee-api2"])
                    return rate
                }
            ] }) { _ in (1...2).map { index in
                .init(name: "api", delay: .milliseconds(index * 10)) {
                    await calls.add("fee-api\(index)"); throw URLError(.timedOut)
                }
            } }
            let quote = try await fee.rate(for: chain); XCTAssertEqual(quote, rate)
            let client = UTXOBroadcastProvider(lookupDelay: .milliseconds(10), lastResort: { _ in [
                .init(name: "server", delay: .zero, submit: { hex in
                    let finished = await calls.values
                    XCTAssertEqual(Set(finished), ["fee-api1", "fee-api2", "submit-api1", "submit-api2", "lookup-api1", "lookup-api2"])
                    XCTAssertEqual(hex, tx.raw.hex)
                    return tx.txid
                }, lookup: { _ in nil })
            ] }) { _ in (1...2).map { index in
                .init(name: "api", delay: .milliseconds(index * 10), submit: { _ in
                    await calls.add("submit-api\(index)"); throw URLError(.timedOut)
                }, lookup: { _ in await calls.add("lookup-api\(index)"); return nil })
            } }
            let accepted = await client.submit(tx.raw, txid: tx.txid, network: chain); XCTAssertTrue(accepted)
        }
    }
    func testCanceledBroadcastNeverStartsServerFallback() async throws {
        let tx = try signed(.bitcoin), calls = BroadcastCalls()
        let client = UTXOBroadcastProvider(lookupDelay: .zero, lastResort: { _ in [
            .init(name: "server", delay: .zero, submit: { _ in await calls.add("server"); return tx.txid },
                  lookup: { _ in await calls.add("server"); return tx.raw })
        ] }) { _ in [
            .init(name: "hung-api", delay: .zero, submit: { _ in
                await calls.add("api"); try await Task.sleep(for: .seconds(10)); return tx.txid
            }, lookup: { _ in try await Task.sleep(for: .seconds(10)); return nil })
        ] }
        let task = Task { await client.submit(tx.raw, txid: tx.txid, network: .bitcoin) }
        // Wait for the request to begin, then cancel while it is in flight.
        for _ in 0..<100 {
            if await calls.values.contains("api") { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel(); let accepted = await task.value; XCTAssertFalse(accepted)
        let contacts = await calls.values; XCTAssertEqual(contacts, ["api"])
    }
    func testLiveServerFallbackAfterSimulatedAPIOutageForAllChains() async throws {
        guard ProcessInfo.processInfo.environment["OATH_UTXO_SERVER_FALLBACK_LIVE"] == "1" else {
            throw XCTSkip("Opt-in read-only TLS fee fallback; no wallet data, signing or broadcast")
        }
        let fee = UTXOFeeProvider(lastResort: UTXOServerFallback.fees) { _ in [
            .init(name: "simulated-api-outage", delay: .zero) { throw URLError(.cannotConnectToHost) }
        ] }
        for chain in UTXONetwork.allCases {
            let start = ContinuousClock.now
            let rate = try await fee.rate(for: chain)
            XCTAssertTrue(chain.sendFeeRates.contains(rate))
            XCTAssertLessThan(start.duration(to: .now), .seconds(4))
            print("LIVE SERVER FALLBACK chain=\(chain.rawValue) atomic/kVB=\(rate) duration=\(start.duration(to: .now))")
        }
    }
    func testLiveReadOnlyTransactionLookupAcrossAllChains() async throws {
        guard ProcessInfo.processInfo.environment["OATH_UTXO_HTTP_LIVE"] == "1" else {
            throw XCTSkip("Opt-in public transaction lookup only; never signs or broadcasts")
        }
        for chain in UTXONetwork.allCases {
            let providers = UTXOAPIProvider.providers(for: chain)
            let chair = providers.first { $0.format == .blockchair }!
            let request = URLRequest(url: URL(string: chair.base.absoluteString + "/transactions?limit=1")!)
            let data = try await UTXOAPIProvider.fetch(request, limit: 65_536)
            struct Transactions: Decodable {
                struct Transaction: Decodable { let hash: String }
                let data: [Transaction]
            }
            let txid = try XCTUnwrap(JSONDecoder().decode(Transactions.self, from: data).data.first?.hash)
            var verified = 0
            for api in providers {
                let start = ContinuousClock.now
                do {
                    let data = try await UTXOAPIProvider.fetch(api.lookupRequest(txid: txid), limit: 4_194_304, allowMissing: true)
                    if let raw = try api.decodeRaw(data, txid: txid) {
                        XCTAssertEqual(try BitcoinTransactions.txid(raw, network: chain), txid)
                        verified += 1
                        print("LIVE LOOKUP chain=\(chain.rawValue) host=\(api.base.host!) verified duration=\(start.duration(to: .now))")
                    } else { print("LIVE LOOKUP chain=\(chain.rawValue) host=\(api.base.host!) not propagated") }
                } catch {
                    print("LIVE LOOKUP chain=\(chain.rawValue) host=\(api.base.host!) unavailable errorType=\(type(of: error))")
                }
            }
            XCTAssertGreaterThan(verified, 0, "No HTTPS lookup verified for \(chain.rawValue)")
        }
    }
}

private final class UTXOReplyProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status: Int, body: Data
        switch request.url!.lastPathComponent {
        case "missing": status = 404; body = Data("not found".utf8)
        case "limited": status = 429; body = Data("{\"error\":\"rate limited\"}".utf8)
        case "unavailable": status = 503; body = Data("<html>unavailable</html>".utf8)
        case "policy": status = 400; body = Data("TX decode failed. arbitrary user supplied echo".utf8)
        default: status = 200; body = Data(repeating: 0, count: 101)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

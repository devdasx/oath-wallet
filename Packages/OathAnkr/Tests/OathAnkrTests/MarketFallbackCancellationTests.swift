import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor InterruptedMarketFeed: AnkrTransport {
    let failingHost: String
    let failure: any Error
    let emptyGecko: Bool
    var interrupted = true
    var requests: [String] = []
    init(host: String, failure: any Error = CancellationError(), emptyGecko: Bool = false) {
        failingHost = host; self.failure = failure; self.emptyGecko = emptyGecko
    }
    func resume() { interrupted = false }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let url = request.url!, host = url.host!
        requests.append(host)
        if host == failingHost && interrupted { throw failure }
        let json: [String: Any]
        switch host {
        case "api.coinbase.com":
            json = ["data": ["base": url.path.contains("SOL-USD") ? "SOL" : "TRX", "currency": "USD", "amount": "2"]]
        case "api.dexscreener.com": return (Data("[]".utf8), 200)
        case "api.geckoterminal.com":
            let refs = url.lastPathComponent.split(separator: ",").map(String.init)
            let values = emptyGecko ? [:] : Dictionary(uniqueKeysWithValues: refs.map { ($0, "2") })
            json = ["data": ["type": "simple_token_price", "attributes": ["token_prices": values]]]
        case "api.coingecko.com":
            let ref = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "contract_addresses" }!.value!
            json = [ref: ["usd": 2]]
        default: throw AnkrError.invalidResponse
        }
        return (try JSONSerialization.data(withJSONObject: json), 200)
    }
}

private actor HeldNativeMarketFeed: AnkrTransport {
    var pending: CheckedContinuation<Void, Never>?
    var hold = true
    var requests = 0
    func release() { hold = false; pending?.resume(); pending = nil }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests += 1
        if hold { await withCheckedContinuation { pending = $0 } }
        let code = request.url!.path.contains("SOL-USD") ? "SOL" : "TRX"
        return (Data("{\"data\":{\"base\":\"\(code)\",\"currency\":\"USD\",\"amount\":\"2\"}}".utf8), 200)
    }
}

@MainActor final class MarketFallbackCancellationTests: XCTestCase {
    func testIndependentNativeCancellationStopsBothChainsAndReleasesPermits() async throws {
        for solana in [true, false] {
            for failure in [CancellationError() as any Error, URLError(.cancelled)] {
                let feed = InterruptedMarketFeed(host: "api.coinbase.com", failure: failure)
                let sol = SolanaMarkets(transport: feed), tron = TronMarkets(transport: feed)
                XCTAssertFalse(Task.isCancelled)
                for _ in 0..<3 {
                    do {
                        if solana { _ = try await sol.nativePrice() } else { _ = try await tron.nativePrice() }
                        XCTFail("Cancelled read became a fallback success")
                    } catch { XCTAssertTrue(error is CancellationError) }
                }
                let requests = await feed.requests
                XCTAssertEqual(requests, Array(repeating: "api.coinbase.com", count: 3))
                await feed.resume()
                let amount = solana ? try await sol.nativePrice().usd : try await tron.nativePrice().usd
                XCTAssertEqual(amount, "2", "Cancellation must release both permits without a false backoff")
                XCTAssertFalse(Task.isCancelled)
            }
        }
    }

    func testIndependentTokenCancellationStopsAtEachFallbackBoundary() async throws {
        for solana in [true, false] {
            for host in ["api.dexscreener.com", "api.geckoterminal.com"] {
                for failure in [CancellationError() as any Error, URLError(.cancelled)] {
                    let feed = InterruptedMarketFeed(host: host, failure: failure)
                    do {
                        if solana { _ = try await SolanaMarkets(transport: feed).prices(mints: [SolanaIdentity.wrappedSOL]) }
                        else { _ = try await TronMarkets(transport: feed).prices(mints: [TronIdentity.usdt]) }
                        XCTFail("Cancelled token request returned prices or an empty success")
                    } catch { XCTAssertTrue(error is CancellationError) }
                    let requests = await feed.requests
                    XCTAssertEqual(requests, host == "api.dexscreener.com" ? [host] : ["api.dexscreener.com", host])
                }
            }
        }
    }

    func testTronCoinGeckoCancellationIsNotSwallowedByPerTokenOrBestEffortBoundary() async throws {
        for legacy in [true, false] {
            for failure in [CancellationError() as any Error, URLError(.cancelled)] {
                let feed = InterruptedMarketFeed(host: "api.coingecko.com", failure: failure, emptyGecko: true)
                let refs = legacy ? ["1002000", "1002001"] : [TronIdentity.usdt]
                do { _ = try await TronMarkets(transport: feed).prices(mints: refs); XCTFail("Cancelled batch returned an empty success") }
                catch { XCTAssertTrue(error is CancellationError) }
                let requests = await feed.requests
                XCTAssertEqual(requests, legacy ? ["api.coingecko.com"] : ["api.dexscreener.com", "api.geckoterminal.com", "api.coingecko.com"])
            }
        }
    }

    func testLateSuccessfulResponseCannotPublishAfterTaskCancellation() async throws {
        for solana in [true, false] {
            let feed = HeldNativeMarketFeed()
            let sol = SolanaMarkets(transport: feed), tron = TronMarkets(transport: feed)
            let work = Task { solana ? try await sol.nativePrice().usd : try await tron.nativePrice().usd }
            for _ in 0..<200 {
                if await feed.pending != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let pending = await feed.pending != nil
            XCTAssertTrue(pending)
            work.cancel()
            await feed.release()
            do { _ = try await work.value; XCTFail("Published a cancelled quote") }
            catch { XCTAssertTrue(error is CancellationError) }
            let requests = await feed.requests
            XCTAssertEqual(requests, 1)
            let recovered = solana ? try await sol.nativePrice().usd : try await tron.nativePrice().usd
            XCTAssertEqual(recovered, "2")
        }
    }

    func testRealNativeOutagesStillRecoverForBothChains() async throws {
        for solana in [true, false] {
            for error in [AnkrError.transport as any Error, URLError(.timedOut)] {
                let feed = InterruptedMarketFeed(host: "api.coinbase.com", failure: error)
                if solana {
                    let quote = try await SolanaMarkets(transport: feed).nativePrice()
                    XCTAssertEqual(quote.mint, "native"); XCTAssertEqual(quote.usd, "2"); XCTAssertEqual(quote.source, "GeckoTerminal")
                } else {
                    let quote = try await TronMarkets(transport: feed).nativePrice()
                    XCTAssertEqual(quote.mint, "native"); XCTAssertEqual(quote.usd, "2"); XCTAssertEqual(quote.source, "GeckoTerminal")
                }
                let requests = await feed.requests
                XCTAssertEqual(requests, ["api.coinbase.com", "api.dexscreener.com", "api.geckoterminal.com"])
            }
        }
    }
}

private actor MarketCancellationReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

@MainActor final class MarketFallbackCancellationDiagnosticsTests: XCTestCase {
    func testCancellationAndOutagesAreQuietButMalformedResponsesRemainCorrelated() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports = MarketCancellationReports()
        OathDiagnostics.configure(file: folder.appendingPathComponent("events.json"), transport: reports)
        for chain in ["solana", "tron"] {
            let countBeforeCancellation = await reports.events.count
            let feed = InterruptedMarketFeed(host: "api.coinbase.com")
            do {
                try await OathDiagnostics.withChain(chain) {
                    if chain == "solana" { _ = try await SolanaMarkets(transport: feed).nativePrice() }
                    else { _ = try await TronMarkets(transport: feed).nativePrice() }
                }
                XCTFail("Independent cancellation recovered")
            } catch { XCTAssertTrue(error is CancellationError) }
            let quiet = await reports.events
            XCTAssertEqual(quiet.count, countBeforeCancellation)
            let outage = InterruptedMarketFeed(host: "api.coinbase.com", failure: AnkrError.transport)
            let countBefore = await reports.events.count
            try await OathDiagnostics.withChain(chain) {
                if chain == "solana" { _ = try await SolanaMarkets(transport: outage).nativePrice() }
                else { _ = try await TronMarkets(transport: outage).nativePrice() }
            }
            // A non-availability failure still exercises both production
            // reporting boundaries before independent, identity-checked fallback.
            let malformed = InterruptedMarketFeed(host: "api.coinbase.com", failure: AnkrError.invalidResponse)
            try await OathDiagnostics.withChain(chain) {
                if chain == "solana" { _ = try await SolanaMarkets(transport: malformed).nativePrice() }
                else { _ = try await TronMarkets(transport: malformed).nativePrice() }
            }
            for _ in 0..<100 {
                if await reports.events.count >= countBefore + 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let events = Array(await reports.events.dropFirst(countBefore))
            XCTAssertEqual(events.count, 2)
            let operation = try XCTUnwrap(events.first?.operationID)
            XCTAssertTrue(events.allSatisfy { $0.error.domain == "OathAnkr.AnkrError" && $0.error.message == "invalidResponse" && $0.operationID == operation && $0.context["chain"] == chain && $0.privacyFiltered })
        }
    }
}

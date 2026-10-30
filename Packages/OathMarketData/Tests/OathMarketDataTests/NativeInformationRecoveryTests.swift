import XCTest
import OathDatabase
import OathDiagnostics
@testable import OathMarketData

private actor NativeInformationFeed: MarketTransport {
    let failure: any Error
    let date: Date
    var requests: [URL] = []
    let id: String, name: String, symbol: String
    var invalidIdentity = false
    init(network: String, date: Date, failure: any Error = MarketDataError.rateLimited) {
        self.date = date; self.failure = failure
        switch network {
        case "bitcoin": (id, name, symbol) = ("btc-bitcoin", "Bitcoin", "BTC")
        case "bitcoincash": (id, name, symbol) = ("bch-bitcoin-cash", "Bitcoin Cash", "BCH")
        case "sui": (id, name, symbol) = ("sui-sui", "Sui", "SUI")
        case "aptos": (id, name, symbol) = ("apt-aptos", "Aptos", "APT")
        case "xlayer": (id, name, symbol) = ("okb-okb", "OKB", "OKB")
        default: (id, name, symbol) = ("doge-dogecoin", "Dogecoin", "DOGE")
        }
    }
    func corruptIdentity() { invalidIdentity = true }
    func data(from url: URL) async throws -> Data {
        requests.append(url)
        if url.host == "api.coingecko.com" { throw failure }
        guard url.host == "api.coinpaprika.com", url.lastPathComponent == id else { throw MarketDataError.invalidResponse }
        let responseID = invalidIdentity ? "wrong-project" : id
        let fields: [String: Any]
        if url.path.contains("/coins/") {
            fields = ["id": responseID, "name": name, "symbol": symbol, "is_active": true,
                      "description": "A <b>public</b> network.", "logo": "https://static.coinpaprika.com/coin/\(id)/logo.png"]
        } else {
            fields = ["id": responseID, "name": name, "symbol": symbol,
                      "last_updated": ISO8601DateFormatter().string(from: date.addingTimeInterval(-90)),
                      "total_supply": 12345, "circulating_supply": 12000, "quotes": ["USD": ["market_cap": 67890]]]
        }
        return try JSONSerialization.data(withJSONObject: fields)
    }
}

private actor LiveNativeInformationFeed: MarketTransport {
    let live = URLSessionMarketTransport()
    var responses: [String: Data] = [:]
    var requests: [URL] = []
    func data(from url: URL) async throws -> Data {
        requests.append(url)
        if url.host == "api.coingecko.com" { throw MarketDataError.rateLimited }
        let data = try await live.data(from: url)
        responses[url.path] = data
        return data
    }
}

@MainActor final class NativeInformationRecoveryTests: XCTestCase {
    func testAffectedNativeInformationRecoversFromRateLimitAndTimeoutWithoutRepeatedRequests() async throws {
        for (network, decimals) in [("dogecoin", 8), ("bitcoin", 8), ("bitcoincash", 8), ("sui", 9), ("aptos", 8), ("xlayer", 18)] {
            for failure in [MarketDataError.rateLimited as any Error, URLError(.timedOut), DiagnosticDeferral.publicMarketCooldown] {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: folder) }
                let path = folder.appendingPathComponent("test.sqlite"), date = Date(timeIntervalSince1970: 1_792_222_000)
                let db = try await OathDatabase.open(at: path)
                let feed = NativeInformationFeed(network: network, date: date, failure: failure)
                let service = MarketDataService(database: db, transport: feed, now: { date })
                let asset = MarketAsset(id: network + ":native", networkID: network, reference: "native", decimals: decimals)
                let values = try await withThrowingTaskGroup(of: CachedMarketValue<AssetInformation>.self) { group in
                    for _ in 0..<12 { group.addTask { try await service.information(for: asset) } }
                    var values: [CachedMarketValue<AssetInformation>] = []
                    for try await value in group { values.append(value) }
                    return values
                }
                let first = try XCTUnwrap(values.first)
                XCTAssertEqual(first.value.symbol, ["bitcoin": "BTC", "bitcoincash": "BCH", "dogecoin": "DOGE", "sui": "SUI", "aptos": "APT", "xlayer": "OKB"][network])
                XCTAssertEqual(first.value.description, "A public network.")
                XCTAssertEqual(first.value.marketCaps?["usd"], 67890)
                XCTAssertEqual(first.fetchedAt, date.addingTimeInterval(-90))
                XCTAssertTrue(values.allSatisfy { $0.value == first.value && $0.fetchedAt == first.fetchedAt })
                let cached = try await service.information(for: asset)
                XCTAssertEqual(cached.value, first.value)
                let requests = await feed.requests
                XCTAssertEqual(requests.count, 3, "Concurrent screens and subsequent reads share one request per endpoint")
                let reopened = try await OathDatabase.open(at: path)
                let saved = try await MarketDataService(database: reopened).cachedInformation(for: asset)
                XCTAssertEqual(saved?.value, first.value)
                XCTAssertEqual(saved?.fetchedAt, first.fetchedAt)
            }
        }
    }

    func testWrongIdentityDoesNotPersistAndNativeMappingNeverAppliesToTokens() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let date = Date()
        let feed = NativeInformationFeed(network: "dogecoin", date: date)
        await feed.corruptIdentity()
        let service = MarketDataService(database: db, transport: feed, now: { date })
        let native = MarketAsset(id: "dogecoin:native", networkID: "dogecoin", reference: "native", decimals: 8)
        do { _ = try await service.information(for: native); XCTFail("Wrong project accepted") }
        catch { XCTAssertEqual(error as? MarketDataError, .invalidResponse) }
        let saved = try await service.cachedInformation(for: native)
        XCTAssertNil(saved)
        for asset in [MarketAsset(id: "wrong", networkID: "polygon", reference: "native", decimals: 6),
                      MarketAsset(id: "token", networkID: "polygon", reference: "0x1234", decimals: 18)] {
            let other = NativeInformationFeed(network: "dogecoin", date: date)
            do { _ = try await MarketDataService(database: db, transport: other).information(for: asset); XCTFail("Wrong asset recovered") }
            catch { XCTAssertEqual(error as? MarketDataError, .rateLimited) }
            let requests = await other.requests
            XCTAssertFalse(requests.contains { $0.host == "api.coinpaprika.com" })
        }
    }

    func testLiveAffectedInformationWithPrimaryThrottled() async throws {
        guard ProcessInfo.processInfo.environment["OATH_NATIVE_INFO_LIVE"] == "1" else { throw XCTSkip("Opt-in public metadata reads") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at: path), feed = LiveNativeInformationFeed()
        let service = MarketDataService(database: db, transport: feed)
        for (network, decimals, id, symbol) in [("dogecoin", 8, "doge-dogecoin", "DOGE"), ("bitcoin", 8, "btc-bitcoin", "BTC"), ("bitcoincash", 8, "bch-bitcoin-cash", "BCH")] {
            let asset = MarketAsset(id: network + ":native", networkID: network, reference: "native", decimals: decimals)
            let result = try await service.information(for: asset)
            XCTAssertEqual(result.value.providerID, "coinpaprika:" + id)
            XCTAssertEqual(result.value.symbol, symbol)
            XCTAssertGreaterThan(try XCTUnwrap(result.value.marketCaps?["usd"]), 0)
            let response = await feed.responses["/v1/tickers/" + id]
            let data = try XCTUnwrap(response)
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let timestamp = try XCTUnwrap(raw["last_updated"] as? String)
            XCTAssertEqual(result.fetchedAt, ISO8601DateFormatter().date(from: timestamp))
            let before = await feed.requests.count
            let repeated = try await service.information(for: asset)
            XCTAssertEqual(repeated.value, result.value)
            XCTAssertEqual(repeated.fetchedAt, result.fetchedAt)
            let after = await feed.requests.count
            XCTAssertEqual(after, before, "A second screen must not repeat provider requests")
            let reopened = try await OathDatabase.open(at: path)
            let saved = try await MarketDataService(database: reopened).cachedInformation(for: asset)
            XCTAssertEqual(saved?.value, result.value)
            XCTAssertEqual(saved?.fetchedAt, result.fetchedAt)
            print("OATH_NATIVE_INFO_LIVE \(network): identity=true timestamp=true repeatedReadRequests=0 offlineReopen=true")
        }
    }

    func testSuiAptosAndXLayerFailuresDoNotInventOrMisidentifyInformation() async throws {
        for (network, decimals) in [("sui", 9), ("aptos", 8), ("xlayer", 18)] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite")), date = Date()
            let native = MarketAsset(id: network + ":native", networkID: network, reference: "native", decimals: decimals)
            XCTAssertNotNil(NativeInformation.identity(for: native))
            XCTAssertNil(NativeInformation.identity(for: .init(id: "wrong", networkID: network, reference: "native", decimals: decimals + 1)))
            XCTAssertNil(NativeInformation.identity(for: .init(id: "token", networkID: network, reference: "0x1234", decimals: decimals)))
            let mismatched = NativeInformationFeed(network: network, date: date)
            await mismatched.corruptIdentity()
            let service = MarketDataService(database: db, transport: mismatched, now: { date })
            do { _ = try await service.information(for: native); XCTFail("Wrong project accepted") }
            catch { XCTAssertEqual(error as? MarketDataError, .invalidResponse) }
            let saved = try await service.cachedInformation(for: native)
            XCTAssertNil(saved)
            for failure in [CancellationError() as any Error, URLError(.cancelled), MarketDataError.invalidResponse] {
                let feed = NativeInformationFeed(network: network, date: date, failure: failure)
                do { _ = try await MarketDataService(database: db, transport: feed).information(for: native); XCTFail("Failure ignored") }
                catch {
                    if failure is CancellationError || (failure as? URLError)?.code == .cancelled { XCTAssertTrue(error is CancellationError) }
                    else { XCTAssertEqual(error as? MarketDataError, .invalidResponse) }
                }
                let calls = await feed.requests
                XCTAssertFalse(calls.contains { $0.host == "api.coinpaprika.com" })
            }
        }
    }

    func testLiveSuiAptosAndXLayerInformationWithPrimaryThrottled() async throws {
        guard ProcessInfo.processInfo.environment["OATH_EXTENDED_NATIVE_INFO_LIVE"] == "1" else { throw XCTSkip("Opt-in public metadata reads") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at: path), feed = LiveNativeInformationFeed()
        let service = MarketDataService(database: db, transport: feed)
        for (network, decimals, id, symbol) in [("sui", 9, "sui-sui", "SUI"), ("aptos", 8, "apt-aptos", "APT"), ("xlayer", 18, "okb-okb", "OKB")] {
            let asset = MarketAsset(id: network + ":native", networkID: network, reference: "native", decimals: decimals)
            let result = try await service.information(for: asset)
            XCTAssertEqual(result.value.providerID, "coinpaprika:" + id)
            XCTAssertEqual(result.value.symbol, symbol)
            let response = await feed.responses["/v1/tickers/" + id]
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(response)) as? [String: Any])
            let quotes = try XCTUnwrap(raw["quotes"] as? [String: Any])
            let usd = try XCTUnwrap(quotes["USD"] as? [String: Any])
            let cap = try XCTUnwrap(usd["market_cap"] as? NSNumber)
            XCTAssertEqual(NSDecimalNumber(decimal: try XCTUnwrap(result.value.marketCaps?["usd"])).doubleValue, cap.doubleValue, accuracy: 0.01)
            XCTAssertEqual(result.fetchedAt, ISO8601DateFormatter().date(from: try XCTUnwrap(raw["last_updated"] as? String)))
            let reopened = try await OathDatabase.open(at: path)
            let saved = try await MarketDataService(database: reopened).cachedInformation(for: asset)
            XCTAssertEqual(saved?.value, result.value)
            XCTAssertEqual(saved?.fetchedAt, result.fetchedAt)
            print("NATIVE_INFORMATION_LIVE network=\(network) identity=true marketCap=true timestamp=true persisted=true")
        }
    }

    func testExtendedNativeInformationRetainsOriginalFailureAndChainCorrelation() async throws {
        let reports = MarketTestDiagnostics.shared
        for (network, decimals) in [("sui", 9), ("aptos", 8), ("xlayer", 18)] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let database = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
            let id = UUID(), date = Date()
            let feed = NativeInformationFeed(network: network, date: date, failure: URLError(.timedOut))
            let asset = MarketAsset(id: "private-fixture", networkID: network, reference: "native", decimals: decimals)
            _ = try await OathDiagnostics.$operationID.withValue(id) {
                try await MarketDataService(database: database, transport: feed, now: { date }).information(for: asset)
            }
            for _ in 0..<100 {
                if await reports.events(for: id).count >= 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let events = await reports.events(for: id)
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(Set(events.map(\.operation)), ["market_load", "information_fallback"])
            XCTAssertTrue(events.allSatisfy { $0.error.domain == NSURLErrorDomain && $0.error.code == -1001 && $0.context["chain"] == network && $0.privacyFiltered })
            let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
            XCTAssertFalse(encoded.contains(asset.id))
            XCTAssertFalse(encoded.contains("https://"))
        }
    }
}

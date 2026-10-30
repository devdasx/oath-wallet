import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor DiscoveryTransport: AnkrTransport {
    var calls = 0
    let data: Data
    let status: Int
    init(_ data: Data, status: Int = 200) { self.data = data; self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        try await Task.sleep(for: .milliseconds(40))
        return (data, status)
    }
}

private actor SaturatedDiscoveryTransport: AnkrTransport {
    var calls = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        try await Task.sleep(for: .milliseconds(400))
        let id = request.url!.lastPathComponent
        return (Data("{\"id\":\"\(id)\"}".utf8), 200)
    }
}

final class TokenDiscoveryTests: XCTestCase, @unchecked Sendable {
    private let seed = Data(#"[{"id":"tether","name":"Tether","symbol":"usdt","platforms":{"ethereum":"0xdac17f958d2ee523a2206206994597c13d831ec7","tron":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t","solana":"Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB","near-protocol":"usdt.tether-token.near","the-open-network":"EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs","aptos":"0x357b0b74bc833e95a115ad22604854d6b0fca151cecd94111770e5d6ffc9dc2b","avalanche":"0x9702230a8ea53601f5cd2dc00fdbc13d4df4a8c7"}},{"id":"usd-coin","name":"USD Coin","symbol":"usdc","platforms":{"ethereum":"0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"}}]"#.utf8)
    private let all = Set(TokenDiscoveryNetworks.platforms.keys)

    func testAssetHubIssuerEntriesSurviveRefreshAndExistingNetworkCache() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let registered = Data(#"{"format":1,"entries":[{"network":"polkadot","reference":"assets:1337","coinID":"usd-coin","name":"USD Coin","symbol":"USDC","decimals":6},{"network":"polkadot","reference":"assets:1984","coinID":"tether","name":"Tether","symbol":"USDt","decimals":6},{"network":"polkadot","reference":"assets:42","coinID":"delisted","name":"Delisted","symbol":"OLD"}]}"#.utf8)
        let directory = Data(#"[{"id":"usd-coin","name":"USDC","symbol":"usdc","platforms":{"polkadot":"1337"}},{"id":"fixture","name":"Fixture","symbol":"FXT","platforms":{"polkadot":"1000085"}}]"#.utf8)
        let transport = DiscoveryTransport(directory)
        let catalog = TokenDiscoveryCatalog(transport: transport, directory: folder, seed: registered)
        let refreshed = await catalog.refreshIfNeeded()
        XCTAssertTrue(refreshed)
        for instance in [catalog, TokenDiscoveryCatalog(transport: transport, directory: folder, seed: registered)] {
            let tether = await instance.search("usdt", networks: ["polkadot"])
            XCTAssertEqual(tether.map(\.reference), ["assets:1984"])
            XCTAssertEqual(tether.first?.decimals, 6)
            let usdc = await instance.search("USDC", networks: ["polkadot"])
            XCTAssertEqual(usdc.map(\.reference), ["assets:1337"])
            XCTAssertEqual(usdc.first?.name, "USDC", "Preserve current directory metadata")
            XCTAssertEqual(usdc.first?.decimals, 6, "Retain exact issuer-registered scale through refresh")
            let removed = await instance.search("OLD", networks: ["polkadot"])
            XCTAssertTrue(removed.isEmpty, "Only issuer registrations supplement the directory")
            let extra = await instance.search("FXT", networks: ["polkadot"])
            XCTAssertEqual(extra.map(\.reference), ["assets:1000085"])
        }
        let calls = await transport.calls
        XCTAssertEqual(calls, 1)
    }

    func testNewEVMArtworkBatchIdentitiesCannotCrossNetworks() throws {
        let reference = "0x0000000000000000000000000000000000000001"
        for (network, platform) in [("chiliz", "chiliz-chain"), ("filecoin", "filecoin"),
                                    ("sei", "sei-evm"), ("zerog", "0g"), ("iotex", "iotx")] {
            func response(_ prefix: String) throws -> Data {
                try JSONSerialization.data(withJSONObject: ["data": [["id": prefix + "_" + reference,
                    "type": "token", "attributes": ["address": reference, "image_url": "https://cdn.example.org/token.png"]]]])
            }
            let images = try TokenBatchArtwork.decode(response(platform), network: network, requested: [reference])
            XCTAssertEqual(images[reference], "https://cdn.example.org/token.png")
            XCTAssertThrowsError(try TokenBatchArtwork.decode(response("eth"), network: network, requested: [reference]))
        }
        XCTAssertThrowsError(try TokenBatchArtwork.decode(Data("{\"data\":[]}".utf8), network: "polkadot", requested: ["assets:1337"]))
    }

    func testNativeCeloAliasIsExcludedFromRawDiscoveryWithoutHidingOtherTokens() throws {
        let reference = try XCTUnwrap(IndexedEVMChain.celo.nativeERC20)
        XCTAssertEqual(try TokenDiscoveryNetworks.canonical(reference.uppercased().replacingOccurrences(of: "0X", with: "0x"), network: "celo"), "native")
        XCTAssertEqual(try TokenDiscoveryNetworks.canonical(reference, network: "ethereum"), reference)
        let raw = Data("""
        [{"id":"celo","name":"Celo","symbol":"celo","platforms":{"celo":"\(reference)","ethereum":"\(reference)"}},
         {"id":"other-celo","name":"Celo","symbol":"celo","platforms":{"celo":"0x0000000000000000000000000000000000000001"}}]
        """.utf8)
        let entries = try TokenDiscoveryCatalog.decode(raw)
        XCTAssertEqual(Set(entries.map(\.id)), ["ethereum:" + reference, "celo:0x0000000000000000000000000000000000000001"])
    }

    func testLegacyPreparedCeloAliasIsRemovedFromSeedAndDiskCache() async throws {
        let reference = try XCTUnwrap(IndexedEVMChain.celo.nativeERC20)
        let token = "0xfecb3f7c54e2caae9dc6ac9060a822d47e053760"
        let prepared = Data("""
        {"format":1,"entries":[
          {"network":"celo","reference":"\(reference)","coinID":"celo","name":"Celo","symbol":"CELO"},
          {"network":"celo","reference":"\(token)","coinID":"brla-digital-brla","name":"BRLA Digital BRLA","symbol":"BRLA"}]}
        """.utf8)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        struct LegacyDisk: Encodable {
            let version = 1
            let fetchedAt = Date()
            let retryAt = Date.distantPast
            let data: Data
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(LegacyDisk(data: prepared)).write(to: folder.appendingPathComponent("catalog-v1.json"))
        for directory in [nil, folder] as [URL?] {
            let offline = DiscoveryTransport(Data(), status: 429)
            let catalog = TokenDiscoveryCatalog(transport: offline, directory: directory, seed: prepared)
            let results = await catalog.search("Celo", networks: ["celo"], excluding: ["celo:native"])
            XCTAssertEqual(results.map(\.reference), [token], "Only native portfolio CELO should appear alongside these tokens")
            let exact = await catalog.search(reference, networks: ["celo"])
            XCTAssertTrue(exact.isEmpty)
            let calls = await offline.calls
            XCTAssertEqual(calls, 0, "Existing installations must be fixed before a network refresh")
        }
    }

    func testBundledCeloSearchDoesNotDuplicateNativeCoin() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = TokenDiscoveryCatalog(transport: DiscoveryTransport(Data(), status: 429), directory: folder)
        let results = await catalog.search("Celo", networks: ["celo"])
        XCTAssertFalse(results.isEmpty, "Celo tokens remain searchable by network")
        XCTAssertFalse(results.contains { $0.reference == IndexedEVMChain.celo.nativeERC20 })
        let brla = await catalog.search("BRLA", networks: ["celo"])
        XCTAssertTrue(brla.contains { $0.coinID == "brla-digital-brla" })
    }

    func testFreshOlderCacheAddsMissingNetworkWithoutReplacingExistingListings() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reference = "0xfecb3f7c54e2caae9dc6ac9060a822d47e053760"
        let older = Data(#"[{"id":"brla-digital-brla","name":"Cached BRLA","symbol":"brla","platforms":{"xdai":"0xfecb3f7c54e2caae9dc6ac9060a822d47e053760"}}]"#.utf8)
        let newer = Data(#"[{"id":"brla-digital-brla","name":"BRLA Digital BRLA","symbol":"brla","platforms":{"xdai":"0xfecb3f7c54e2caae9dc6ac9060a822d47e053760","celo":"0xfecb3f7c54e2caae9dc6ac9060a822d47e053760"}},{"id":"seed-only","name":"Seed Only","symbol":"OLD","platforms":{"xdai":"0x0000000000000000000000000000000000000001"}}]"#.utf8)
        let original = TokenDiscoveryCatalog(transport: DiscoveryTransport(older), directory: folder, seed: older)
        let saved = await original.refreshIfNeeded()
        XCTAssertTrue(saved)
        let offline = DiscoveryTransport(Data(), status: 429)
        let upgraded = TokenDiscoveryCatalog(transport: offline, directory: folder,
            seed: try TokenDiscoveryCatalog.prepareSnapshot(newer))
        let results = await upgraded.search("BrLa", networks: all)
        XCTAssertEqual(Set(results.map(\.network)), ["celo", "gnosis"])
        XCTAssertEqual(results.first { $0.network == "celo" }?.reference, reference)
        XCTAssertEqual(results.first { $0.network == "gnosis" }?.name, "Cached BRLA")
        let resurrected = await upgraded.search("OLD", networks: all)
        XCTAssertTrue(resurrected.isEmpty, "Existing networks retain the last downloaded directory")
        let excluded = await upgraded.search("BRLA", networks: all, excluding: ["celo:" + reference])
        XCTAssertEqual(excluded.map(\.network), ["gnosis"], "Same address on another chain is a different token")
        let beforeRefresh = await offline.calls
        XCTAssertEqual(beforeRefresh, 0, "Upgrade must be searchable offline immediately")
        let refreshed = await upgraded.refreshIfNeeded()
        XCTAssertFalse(refreshed)
        let afterRefresh = await offline.calls
        XCTAssertEqual(afterRefresh, 1, "An incomplete old cache should request a normal refresh")
        let reopened = TokenDiscoveryCatalog(transport: offline, directory: folder, seed: older)
        let persisted = await reopened.search("BRLA", networks: ["celo"])
        XCTAssertEqual(persisted.map(\.reference), [reference])
        _ = await reopened.refreshIfNeeded()
        let afterReopen = await offline.calls
        XCTAssertEqual(afterReopen, 1, "Network upgrade must preserve failure cooldown")
    }

    func testBundledBRLADiscoveryIncludesCeloWithoutNetwork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let offline = DiscoveryTransport(Data(), status: 429)
        let catalog = TokenDiscoveryCatalog(transport: offline, directory: folder)
        for term in ["brla", "BRLA Digital", "0xfecb3f7c54e2caae9dc6ac9060a822d47e053760"] {
            let matches = await catalog.search(term, networks: ["celo"])
            let brla = try XCTUnwrap(matches.first { $0.coinID == "brla-digital-brla" })
            XCTAssertEqual(brla.reference, "0xfecb3f7c54e2caae9dc6ac9060a822d47e053760")
            XCTAssertEqual(brla.symbol, "BRLA")
            XCTAssertNil(brla.decimals, "Search must not guess token decimals")
        }
        let limited = await catalog.search("BRLA", networks: ["polygon", "gnosis"])
        XCTAssertEqual(Set(limited.map(\.network)), ["polygon", "gnosis"])
    }

    func testLocalMetadataCooldownIsDeferralNotAnotherProviderFailure() async throws {
        let transport = DiscoveryTransport(Data(), status: 429)
        let catalog = TokenDiscoveryCatalog(transport: transport, seed: seed)
        for index in 0..<2 {
            do {
                _ = try await catalog.resolve(network: "ethereum", reference: "0xdac17f958d2ee523a2206206994597c13d831ec7")
                XCTFail("Expected rate limit or local deferral")
            } catch {
                if index == 0 { XCTAssertEqual(error as? TokenDiscoveryError, .http(429)) }
                else { XCTAssertTrue(error is DiagnosticDeferral, "Local cooldown must not create a new app error") }
            }
        }
        let calls = await transport.calls; XCTAssertEqual(calls, 1)
    }

    func testLocalMetadataCapacityDefersWithoutStartingAFifthRequest() async throws {
        let coins = (1...5).map { index in
            ["id": "coin-\(index)", "name": "Fixture", "symbol": "TST",
             "platforms": ["ethereum": "0x" + String(format: "%040x", index)]] as [String: Any]
        }
        let transport = SaturatedDiscoveryTransport()
        let catalog = TokenDiscoveryCatalog(transport: transport, seed: try JSONSerialization.data(withJSONObject: coins))
        let flights = (1...4).map { index in Task {
            try await catalog.resolve(network: "ethereum", reference: "0x" + String(format: "%040x", index))
        } }
        for _ in 0..<100 {
            if await transport.calls == 4 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let admitted = await transport.calls; XCTAssertEqual(admitted, 4)
        do {
            _ = try await catalog.resolve(network: "ethereum", reference: "0x" + String(format: "%040x", 5))
            XCTFail("Capacity did not defer")
        } catch { XCTAssertEqual(error as? DiagnosticDeferral, .tokenMetadataCapacity) }
        let bounded = await transport.calls; XCTAssertEqual(bounded, 4)
        for flight in flights { _ = await flight.result }
    }

    func testNamesSymbolsNetworksAndSavedIdentity() async throws {
        let transport = DiscoveryTransport(seed)
        let catalog = TokenDiscoveryCatalog(transport: transport, seed: seed)
        let tokens = await catalog.search("  uSdT  ", networks: all)
        XCTAssertEqual(Set(tokens.map(\.network)), ["ethereum", "tron", "solana", "near", "ton", "aptos", "avalanche"])
        let names = await catalog.search("tether", networks: all)
        XCTAssertEqual(names.map(\.id), tokens.map(\.id))
        let excluded = await catalog.search("USD", networks: all, excluding: ["ethereum:0xdac17f958d2ee523a2206206994597c13d831ec7"])
        XCTAssertTrue(excluded.contains { $0.network == "ethereum" && $0.symbol == "USDC" })
        XCTAssertFalse(excluded.contains { $0.network == "ethereum" && $0.symbol == "USDT" })
        let exact = await catalog.search("0xDAC17F958D2EE523A2206206994597C13D831EC7", networks: all)
        XCTAssertEqual(exact.map(\.network), ["ethereum"])
        let calls = await transport.calls
        XCTAssertEqual(calls, 0, "Typing and filtering must never issue network requests")
    }

    func testPreparedSnapshotPreservesCanonicalResults() async throws {
        let expected = try TokenDiscoveryCatalog.decode(seed)
        let prepared = try TokenDiscoveryCatalog.prepareSnapshot(seed)
        let catalog = TokenDiscoveryCatalog(seed: prepared)
        let result = await catalog.search("usd", networks: all)
        XCTAssertEqual(Set(result.map(\.id)), Set(expected.map(\.id)))
        XCTAssertEqual(result.count, expected.count)
        for entry in result {
            XCTAssertEqual(try TokenDiscoveryNetworks.canonical(entry.reference, network: entry.network), entry.reference)
        }
    }

    func testRefreshCoalescesPersistsAndRespectsTTL() async throws {
        let transport = DiscoveryTransport(seed)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = TokenDiscoveryCatalog(transport: transport, directory: folder, seed: seed)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 { group.addTask { await catalog.refreshIfNeeded() } }
            for await _ in group { }
        }
        _ = await catalog.refreshIfNeeded()
        let reopened = TokenDiscoveryCatalog(transport: transport, directory: folder, seed: seed)
        _ = await reopened.refreshIfNeeded()
        let tokens = await reopened.search("USDT", networks: all)
        XCTAssertEqual(tokens.count, 7)
        let calls = await transport.calls
        XCTAssertEqual(calls, 1)
    }

    func testFailureRetainsResultsAndCooldownAcrossRestart() async throws {
        let transport = DiscoveryTransport(Data(), status: 429)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = TokenDiscoveryCatalog(transport: transport, directory: folder, seed: seed)
        _ = await first.refreshIfNeeded()
        let second = TokenDiscoveryCatalog(transport: transport, directory: folder, seed: seed)
        _ = await second.refreshIfNeeded()
        let tokens = await second.search("usdt", networks: all)
        XCTAssertEqual(tokens.count, 7)
        let calls = await transport.calls
        XCTAssertEqual(calls, 1)
    }

    func testBoundedResultsPreserveNetworksAndRejectAmbiguity() async throws {
        let catalog = TokenDiscoveryCatalog(seed: seed)
        let limited = await catalog.search("USD", networks: all, limit: 1)
        XCTAssertEqual(Set(limited.map(\.network)).count, 7, "A busy chain must not crowd out another chain")
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: seed) as? [[String: Any]])
        var duplicate = rows[0]; duplicate["id"] = "impostor"; rows.append(duplicate)
        let decoded = try TokenDiscoveryCatalog.decode(JSONSerialization.data(withJSONObject: rows))
        XCTAssertEqual(decoded.map(\.symbol), ["USDC"])
    }

    func testMetadataRequiresExactNetworkAndContractAndCoalesces() async throws {
        let data = Data(#"{"id":"tether","detail_platforms":{"ethereum":{"decimal_place":6,"contract_address":"0xdac17f958d2ee523a2206206994597c13d831ec7"},"tron":{"decimal_place":6,"contract_address":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"}}}"#.utf8)
        let transport = DiscoveryTransport(data)
        let catalog = TokenDiscoveryCatalog(transport: transport, seed: seed)
        async let eth = catalog.resolve(network: "ethereum", reference: "0xdac17f958d2ee523a2206206994597c13d831ec7")
        async let tron = catalog.resolve(network: "tron", reference: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t")
        let pair = try await (eth, tron)
        XCTAssertEqual(pair.0.decimals, 6); XCTAssertEqual(pair.1.decimals, 6)
        let calls = await transport.calls
        XCTAssertEqual(calls, 1)
        let bad = DiscoveryTransport(Data(#"{"id":"tether","detail_platforms":{"ethereum":{"decimal_place":6,"contract_address":"0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"}}}"#.utf8))
        let other = TokenDiscoveryCatalog(transport: bad, seed: seed)
        do { _ = try await other.resolve(network: "ethereum", reference: pair.0.reference); XCTFail("Mismatched contract was accepted") }
        catch { XCTAssertTrue(error is TokenDiscoveryError) }
    }

    func testRealBundledCatalogCoversAllTokenNetworksAndSearchIsFast() async throws {
        // Uses the shipping snapshot and production canonicalizers, not fixtures.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = TokenDiscoveryCatalog(directory: folder)
        let coldStart = ContinuousClock.now
        let first = await catalog.search("usdt", networks: all)
        XCTAssertFalse(first.isEmpty)
        print("DISCOVERY first local search including seed load: \(coldStart.duration(to: .now))")
        var covered: Set<String> = []
        for chain in all {
            let results = await catalog.search("us", networks: [chain])
            if !results.isEmpty { covered.insert(chain) }
        }
        for (chain, term) in [("story", "ip"), ("thorchain", "ruji")] {
            let results = await catalog.search(term, networks: [chain])
            if !results.isEmpty { covered.insert(chain) }
        }
        XCTAssertEqual(covered, all)
        let start = ContinuousClock.now
        for term in ["usdt", "usdc", "tether", "link", "wrapped", "ethereum", "pepe", "aave", "dai", "sol"] {
            let result = await catalog.search(term, networks: all)
            XCTAssertFalse(result.isEmpty)
        }
        let elapsed = start.duration(to: .now)
        print("DISCOVERY warm local searches (10): \(elapsed)")
        XCTAssertLessThan(elapsed, .seconds(2))
        let usdt = await catalog.search("usdt", networks: all)
        XCTAssertTrue(usdt.contains { $0.network == "tron" && $0.reference == "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t" && $0.decimals == 6 })
    }

    func testSelectedMetadataPersistsAndOptionalAbsenceIsNotRepeated() async throws {
        for decimals in ["6", "null"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let data = Data("{\"id\":\"tether\",\"detail_platforms\":{\"ethereum\":{\"decimal_place\":\(decimals),\"contract_address\":\"0xdac17f958d2ee523a2206206994597c13d831ec7\"}}}".utf8)
            let transport = DiscoveryTransport(data)
            for _ in 0..<2 {
                let catalog = TokenDiscoveryCatalog(transport: transport, directory: folder, seed: seed)
                do {
                    let value = try await catalog.resolve(network: "ethereum", reference: "0xdac17f958d2ee523a2206206994597c13d831ec7")
                    XCTAssertEqual(value.decimals, 6); XCTAssertEqual(decimals, "6")
                } catch { XCTAssertEqual(error as? TokenDiscoveryError, .metadataMissing); XCTAssertEqual(decimals, "null") }
            }
            let calls = await transport.calls
            XCTAssertEqual(calls, 1, "Metadata success and optional absence survive relaunch")
        }
    }

    func testLiveCatalogAndSelectedMetadata() async throws {
        guard ProcessInfo.processInfo.environment["OATH_DISCOVERY_LIVE"] == "1" else { throw XCTSkip("Explicit live read opt-in") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = TokenDiscoveryCatalog(directory: folder)
        let refreshed = await catalog.refreshIfNeeded()
        XCTAssertTrue(refreshed, "Must verify a real successful response, not count the seed as live")
        let tokens = await catalog.search("usdt", networks: all)
        for token in tokens where token.symbol == "USDT" {
            XCTAssertEqual(try TokenDiscoveryNetworks.canonical(token.reference, network: token.network), token.reference)
        }
        print("DISCOVERY live USDT networks: \(Set(tokens.map(\.network)).sorted())")
        XCTAssertTrue(tokens.contains { $0.network == "ethereum" && $0.reference == "0xdac17f958d2ee523a2206206994597c13d831ec7" })
    }

    func testLiveMetadataForEveryTokenNetwork() async throws {
        guard ProcessInfo.processInfo.environment["OATH_DISCOVERY_LIVE_ALL"] == "1" else { throw XCTSkip("Explicit live all-network metadata check") }
        let transport = AnkrHTTPTransport()
        let (data, status) = try await transport.send(URLRequest(url: URL(string: "https://api.coingecko.com/api/v3/coins/list?include_platform=true")!))
        XCTAssertEqual(status, 200)
        // No bundled metadata: every resolution below is backed by a live
        // exact-contract response (or a protocol-defined issued-asset scale).
        let catalog = TokenDiscoveryCatalog(transport: transport, seed: data)
        print("DISCOVERY live target networks: \(all.sorted())")
        for chain in all.sorted() {
            var choices = await catalog.search("USDC", networks: [chain])
            if choices.isEmpty { choices = await catalog.search("USDT", networks: [chain]) }
            if choices.isEmpty { choices = await catalog.search(chain == "thorchain" ? "ruji" : "ip", networks: [chain]) }
            let token = try XCTUnwrap(choices.first, chain)
            do {
                let resolved = try await catalog.resolve(network: chain, reference: token.reference)
                XCTAssertNotNil(resolved.decimals, chain)
                XCTAssertEqual(resolved.id, token.id)
                print("DISCOVERY_LIVE_METADATA \(chain) \(token.symbol) exact identity OK")
            } catch { XCTFail("Live metadata \(chain) \(token.coinID): \(error)") }
        }
    }
}

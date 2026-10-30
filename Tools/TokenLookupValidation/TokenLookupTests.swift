import XCTest
import OathDiagnostics
import OathAnkr
import OathDatabase
@testable import TokenLookup

private actor Capture: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

private struct AbsentOrFailedLookup: OathTokenLookingUp {
    func lookup(address: String, network: OathTokenNetwork) async throws -> OathTokenDefinition {
        if network.chain == .base { throw OathTokenLookupError.unavailable }
        throw OathTokenLookupError.notToken
    }
}

private struct EmptyDiscovery: OathTokenDiscovering {
    func search(_ query: String, networks: Set<String>, excluding: Set<String>, limit: Int) async -> [TokenDiscoveryEntry] { [] }
    func refreshIfNeeded() async -> Bool { false }
}

private struct UnavailableDirectory: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) { (Data(), 429) }
}

@MainActor final class TokenLookupTests: XCTestCase {
    private let publicToken = "0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    private let noToken = "0x0000000000000000000000000000000000000000"
    private func service(_ mode: String) -> OathTokenService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenRPCFixture.self]
        return OathTokenService(configuration: .init(ankrKey: mode), session: URLSession(configuration: configuration))
    }

    private func checkCatalogCooldownFallback(capture: Capture) async throws {
        // The production diagnostics outbox is configured once per process.
        // Reuse its capture and isolate this operation instead of attempting to
        // replace the transport in a second test.
        let operation = UUID()
        try await OathDiagnostics.$operationID.withValue(operation) {
        let bytes = Data(#"[{"id":"fixture","name":"Test Token","symbol":"tst","platforms":{"ethereum":"0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"}}]"#.utf8)
        let catalog = TokenDiscoveryCatalog(transport: UnavailableDirectory(), seed: bytes)
        let token = try XCTUnwrap(OathTokenDefinition.discovery(TokenDiscoveryCatalog.decode(bytes)[0]))
        // Rate limits are excluded by the shared availability policy; later admission is local.
        do { _ = try await catalog.resolve(network: "ethereum", reference: token.reference); XCTFail("Expected 429") }
        catch { XCTAssertEqual(error as? TokenDiscoveryError, .http(429)) }
        let resolved = try await service("valid").resolveForAdding(token, catalog: catalog)
        XCTAssertEqual(resolved.decimals, 6); XCTAssertEqual(resolved.id, token.id)
        try await Task.sleep(for: .milliseconds(100))
        let events = await capture.events.filter { $0.operationID == operation }
        XCTAssertFalse(events.contains { $0.context["http_status"] == "429" }, "Availability reports are excluded by shared policy")
        XCTAssertFalse(events.contains { $0.operation == "catalog_metadata_fallback" }, "Backpressure is not a new provider failure")
        XCTAssertFalse(String(describing: events).lowercased().contains(token.reference))
        }
    }

    func testBundledCeloBRLASearchUsesSharedModelDuringDirectoryOutage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = TokenDiscoveryCatalog(transport: UnavailableDirectory(), directory: folder)
        let model = OathTokenSearchModel(service: UnexpectedLookup(), catalog: catalog)
        await model.search("Brla", available: [.celo, .gnosis, .polygon])
        XCTAssertEqual(Set(model.results.map(\.network.chain)), [.celo, .gnosis, .polygon])
        let celo = try XCTUnwrap(model.results.first { $0.network.chain == .celo })
        XCTAssertEqual(celo.reference, "0xfecb3f7c54e2caae9dc6ac9060a822d47e053760")
        XCTAssertEqual(celo.symbol, "BRLA")
        XCTAssertNil(celo.decimals)
        XCTAssertTrue(model.failedNetworks.isEmpty)
        await model.search("Brla", available: [.polygon])
        XCTAssertEqual(model.results.map(\.network.chain), [.polygon])
    }

    private var newChains: [(OathImportChain, String, String, Int)] { [
        (.chiliz, "0x677f7e16c7dd57be1d4c8ad1244883214953dc47", "WCHZ", 18),
        (.polkadot, "assets:1984", "USDt", 6),
        (.filecoin, "0x60e1773636cf5e4a227d9ac24f20feca034ee25a", "WFIL", 18),
        (.sei, "0xe30fedd158a2e3b13e9badaeabafc5516e95e8c7", "WSEI", 18),
        (.zerog, "0x1cd0690ff9a693f5ef2dd976660a8dafc81a109c", "W0G", 18),
        (.iotex, "0xa00744882684c3e4747faefd68d283ea44099d03", "WIOTX", 18)
    ] }

    func testNewChainNamesSymbolsContractsAndExclusionsDuringDirectoryOutage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = TokenDiscoveryCatalog(transport: UnavailableDirectory(), directory: folder)
        let model = OathTokenSearchModel(service: UnexpectedLookup(), catalog: catalog)
        for (chain, reference, symbol, _) in newChains {
            let matches = await catalog.search(reference, networks: [chain.rawValue])
            let entry = try XCTUnwrap(matches.first, chain.rawValue)
            for query in [entry.name, symbol.lowercased(), reference] {
                await model.search(query, available: [chain])
                XCTAssertTrue(model.results.contains { $0.id == entry.id }, chain.rawValue + ": " + query)
                XCTAssertTrue(model.failedNetworks.isEmpty)
            }
            let excluded = await catalog.search(reference, networks: [chain.rawValue], excluding: [entry.id])
            XCTAssertTrue(excluded.isEmpty)
        }
    }

    func testNativeContractAliasesAreChainSpecificAndChecksumValidated() throws {
        let address = "0xa00744882684c3e4747faefd68d283ea44099d03"
        for (chain, alias) in [(OathImportChain.iotex, try IoTeXIdentity.native(address)),
                               (.filecoin, try FilecoinIdentity.delegated(address))] {
            let network = try XCTUnwrap(OathTokenNetwork.find(chain))
            XCTAssertEqual(OathTokenAddress.networks(for: alias).map(\.chain), [chain])
            XCTAssertEqual(try OathTokenAddress.canonical(alias, network: network).lowercased(), address)
            XCTAssertEqual(try OathTokenAddress.callAddress(alias, network: network).lowercased(), address)
            let damaged = String(alias.dropLast()) + (alias.last == "q" ? "p" : "q")
            XCTAssertTrue(OathTokenAddress.networks(for: damaged).isEmpty)
            XCTAssertThrowsError(try OathTokenAddress.canonical(alias, network: OathTokenNetwork.find(.ethereum)!))
        }
        XCTAssertTrue(OathTokenAddress.networks(for: try FilecoinIdentity.delegated(address, testnet: true)).isEmpty)
        for (chain, _, _, _) in newChains where chain.isEVM {
            let network = try XCTUnwrap(OathTokenNetwork.find(chain))
            XCTAssertEqual(OathTokenRPCConfiguration(ankrKey: "fixture").endpoints(for: network).count, 2)
            XCTAssertEqual(OathTokenRPCConfiguration(ankrKey: "").endpoints(for: network).count, 1)
        }
    }

    func testLiveNewChainCatalogAndRPCFallbacks() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TOKEN_SIX_CHAINS"] == "1",
              let key = ProcessInfo.processInfo.environment["OATH_TOKEN_LOOKUP_LIVE_KEY"] else {
            throw XCTSkip("Opt-in six-chain public metadata check")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = TokenDiscoveryCatalog(transport: UnavailableDirectory(), directory: folder)
        let primary = OathTokenService(configuration: .init(ankrKey: key))
        let fallback = OathTokenService(configuration: .init(ankrKey: ""))
        // Independent chains run concurrently; each metadata request keeps the
        // production endpoint ordering, chain checks, and response validation.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (chain, reference, symbol, decimals) in newChains {
                group.addTask {
                    let network = try XCTUnwrap(OathTokenNetwork.find(chain))
                    let entries = await catalog.search(reference, networks: [chain.rawValue])
                    let entry = try XCTUnwrap(entries.first)
                    let preview = try XCTUnwrap(OathTokenDefinition.discovery(entry))
                    let selected = try await primary.resolveForAdding(preview, catalog: catalog)
                    XCTAssertEqual(selected.id, entry.id)
                    for service in [primary, fallback] {
                        let token = try await service.lookup(address: reference, network: network)
                        XCTAssertEqual(token.symbol.uppercased(), symbol.uppercased(), chain.rawValue)
                        XCTAssertEqual(token.decimals, decimals, chain.rawValue)
                        if chain == .filecoin || chain == .iotex {
                            let alias = try chain == .filecoin ? FilecoinIdentity.delegated(reference) : IoTeXIdentity.native(reference)
                            let converted = try await service.lookup(address: alias, network: network)
                            XCTAssertEqual(converted.id, token.id)
                        }
                    }
                    print("OATH_SIX_CHAIN_LIVE: \(chain.rawValue) catalog, selected token, RPC fallback verified")
                }
            }
            try await group.waitForAll()
        }
    }

    func testLiveCeloBRLAResolutionFallsBackToChainMetadata() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_TOKEN_LOOKUP_LIVE_KEY"] else {
            throw XCTSkip("Opt-in public Celo token metadata check")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = TokenDiscoveryCatalog(transport: UnavailableDirectory(), directory: folder)
        let entries = await catalog.search("BRLA", networks: ["celo"])
        let entry = try XCTUnwrap(entries.first { $0.coinID == "brla-digital-brla" })
        let token = try XCTUnwrap(OathTokenDefinition.discovery(entry))
        let resolved = try await OathTokenService(configuration: .init(ankrKey: key))
            .resolveForAdding(token, catalog: catalog)
        XCTAssertEqual(resolved.id, entry.id)
        XCTAssertEqual(resolved.symbol, "BRLA")
        XCTAssertEqual(resolved.decimals, 18)
        print("OATH_CELO_BRLA_LIVE: shared discovery and live chain metadata fallback verified")
    }

    func testSearchArtworkIdentityDoesNotRequireTokenDecimals() throws {
        let data = Data(#"[{"id":"near-intents-bridged-usdt","name":"NEAR Intents Bridged USDT","symbol":"usdt","platforms":{"near-protocol":"eth-0xdac17f958d2ee523a2206206994597c13d831ec7.omft.near"}}]"#.utf8)
        let entry = try XCTUnwrap(TokenDiscoveryCatalog.decode(data).first)
        let token = try XCTUnwrap(OathTokenDefinition.discovery(entry))
        XCTAssertNil(token.decimals)
        XCTAssertNotNil(token.artworkIdentity, "Missing optional decimals must not bypass exact-identity artwork recovery")
    }

    func testAbsenceIsQuietButRealFailureHasChainAndCorrelation() async throws {
        let capture = Capture(), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        OathDiagnostics.configure(file: folder.appendingPathComponent("events.json"), transport: capture)
        let model = OathTokenSearchModel(service: AbsentOrFailedLookup(), catalog: EmptyDiscovery())
        await model.search(noToken, available: [.ethereum, .base])
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.failedNetworks.map(\.chain), [.base])
        XCTAssertFalse(model.isSearching)
        let nonToken = OathTokenSearchModel(service: service("revertmetadata"), catalog: EmptyDiscovery())
        await nonToken.search(publicToken, available: [.ethereum])
        XCTAssertTrue(nonToken.results.isEmpty)
        XCTAssertTrue(nonToken.failedNetworks.isEmpty)
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.error.message == "unavailable" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        let events = await capture.events
        XCTAssertFalse(events.contains { $0.error.message == "notToken" })
        XCTAssertEqual(events.count, 1, "Exact optional metadata reverts must not generate provider failures")
        let failed = try XCTUnwrap(events.first { $0.error.message == "unavailable" })
        XCTAssertEqual(failed.context["chain"], "base")
        XCTAssertNotNil(failed.operationID)
        XCTAssertFalse(String(describing: events).contains(noToken))
        let failure = OathTokenSearchModel(service: service("internalerror"), catalog: EmptyDiscovery())
        await failure.search(publicToken, available: [.ethereum])
        XCTAssertEqual(failure.failedNetworks.map(\.chain), [.ethereum])
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.error.domain == "Oath.Provider" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let genuine = await capture.events.filter { $0.error.domain == "Oath.Provider" && $0.component == "network" }
        XCTAssertFalse(genuine.isEmpty, "Original provider failure must survive domain conversion")
        for event in genuine {
            XCTAssertEqual(event.context["rpc_code"], "-32603")
            // HTTP context uses ANKR's provider chain name; the model boundary
            // above uses the app's canonical name. Both must remain scoped.
            XCTAssertEqual(event.context["chain"], "eth")
            XCTAssertNotNil(event.operationID)
        }
        XCTAssertFalse(String(describing: genuine).lowercased().contains(publicToken.lowercased()))
        try await checkCatalogCooldownFallback(capture: capture)
        try await checkProviderCausesSurviveLookupAndCache(capture: capture)
    }

    private func checkProviderCausesSurviveLookupAndCache(capture: Capture) async throws {
        let network = try XCTUnwrap(OathTokenNetwork.find(.ethereum))
        for (mode, domain, code, excluded) in [
            ("offline", NSURLErrorDomain, URLError.notConnectedToInternet.rawValue, true),
            ("http429", "Oath.HTTP", 429, true),
            ("http503", "Oath.HTTP", 503, true),
            ("http403", "Oath.HTTP", 403, false),
            ("rpclimit", "Oath.Provider", -32005, true),
            ("rpcinternal", "Oath.Provider", -32603, false)
        ] {
            let operation = UUID(), lookup = service(mode)
            let before = TokenRPCFixture.counter.count(mode)
            await OathDiagnostics.$operationID.withValue(operation) {
                for _ in 0..<2 {
                    do {
                        _ = try await lookup.lookup(address: publicToken, network: network)
                        XCTFail("Failed provider returned metadata")
                    } catch {
                        XCTAssertEqual((error as NSError).domain, domain, mode)
                        XCTAssertEqual((error as NSError).code, code, mode)
                    }
                }
                let model = OathTokenSearchModel(service: lookup, catalog: EmptyDiscovery())
                await model.search(publicToken, available: [.ethereum])
                XCTAssertTrue(model.results.isEmpty)
                XCTAssertEqual(model.failedNetworks.map(\.chain), [.ethereum])
            }
            XCTAssertEqual(TokenRPCFixture.counter.count(mode) - before, 1, "Preserve the 30-second failure cache")
            try await Task.sleep(for: .milliseconds(200))
            let events = await capture.events.filter { $0.operationID == operation }
            if excluded { XCTAssertTrue(events.isEmpty, "Availability must not reappear as a generic error: \(mode)") }
            else { XCTAssertTrue(events.contains { $0.error.domain == domain && $0.error.code == code }, "Access denial must remain reportable") }
            XCTAssertFalse(String(describing: events).lowercased().contains(publicToken.lowercased()))
        }
    }

    func testRevertDoesNotMeanAbsentTokenForNonMetadataRPC() async throws {
        let service = service("revert"), endpoint = URL(string: "https://fixture.invalid/revert")!
        for method in ["eth_chainId", "eth_getCode", "eth_estimateGas"] {
            do { _ = try await service.call(endpoint, method: method); XCTFail("Unexpected RPC success") }
            catch {
                let cause = try XCTUnwrap((error as? any DiagnosticCausalError)?.diagnosticCause)
                XCTAssertEqual((cause as NSError).domain, "Oath.Provider")
                XCTAssertEqual((cause as NSError).code, 3)
            }
        }
    }

    func testOnlyValidMetadataRevertMeansNotToken() async throws {
        let network = try XCTUnwrap(OathTokenNetwork.find(.ethereum))
        for mode in ["revertmetadata", "wrongerrorcode", "wrongreply", "resultanderror", "missingresult", "nullresult"] {
            do { _ = try await service(mode).lookup(address: publicToken, network: network); XCTFail("Invalid metadata accepted") }
            catch {
                if mode == "wrongerrorcode" {
                    XCTAssertEqual((error as NSError).domain, "Oath.Provider")
                    XCTAssertEqual((error as NSError).code, -32005)
                } else {
                    let expected: OathTokenLookupError = mode == "revertmetadata" ? .notToken : .malformedResponse
                    XCTAssertEqual(error as? OathTokenLookupError, expected, mode)
                }
            }
        }
    }

    func testProviderCausePreservationKeepsFallbackAndChainValidation() async throws {
        let network = try XCTUnwrap(OathTokenNetwork.find(.arc))
        for mode in ["arc-primary-outage", "arc-wrong-chain"] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [TokenRPCFixture.self]
            config.httpAdditionalHeaders = ["X-Oath-Fixture": mode]
            let lookup = OathTokenService(configuration: .init(ankrKey: "fixture"), session: URLSession(configuration: config))
            let fallbackBefore = TokenRPCFixture.counter.count("arcvalid")
            do {
                let token = try await lookup.lookup(address: publicToken, network: network)
                XCTAssertEqual(mode, "arc-primary-outage")
                XCTAssertEqual(token.network.chain, .arc)
                XCTAssertEqual(token.decimals, 6)
                XCTAssertEqual(TokenRPCFixture.counter.count("arcvalid") - fallbackBefore, 6)
            } catch {
                XCTAssertEqual(mode, "arc-wrong-chain")
                XCTAssertEqual(error as? OathTokenLookupError, .wrongNetwork)
                XCTAssertEqual(TokenRPCFixture.counter.count("arcvalid"), fallbackBefore, "Wrong identity must never trigger provider failover")
            }
        }
    }

    func testNoCodeAndValidTokenRemainDistinct() async throws {
        let network = try XCTUnwrap(OathTokenNetwork.find(.ethereum))
        do { _ = try await service("nocode").lookup(address: noToken, network: network); XCTFail("Empty code accepted") }
        catch { XCTAssertEqual(error as? OathTokenLookupError, .notToken) }
        let token = try await service("valid").lookup(address: publicToken, network: network)
        XCTAssertEqual(token.name, "Test Token")
        XCTAssertEqual(token.symbol, "TST")
        XCTAssertEqual(token.decimals, 6)
    }

    func testConcurrentLookupsAndVerifiedAbsenceDoNotRepeatRequests() async throws {
        let network = try XCTUnwrap(OathTokenNetwork.find(.ethereum))
        TokenRPCFixture.counter.reset()
        let client = service("valid"), address = publicToken
        try await withThrowingTaskGroup(of: OathTokenDefinition.self) { group in
            for _ in 0..<20 { group.addTask { try await client.lookup(address: address, network: network) } }
            for try await value in group { XCTAssertEqual(value.decimals, 6) }
        }
        XCTAssertEqual(TokenRPCFixture.counter.count("valid"), 6, "One chain check, code read and four metadata calls")
        let empty = service("nocode")
        for _ in 0..<3 {
            do { _ = try await empty.lookup(address: noToken, network: network); XCTFail("Empty contract accepted") }
            catch { XCTAssertEqual(error as? OathTokenLookupError, .notToken) }
        }
        XCTAssertEqual(TokenRPCFixture.counter.count("nocode"), 2)
    }

    func testAllAppChainsHaveDiscoveryOrNativeSearchAndPreserveRealIdentity() async throws {
        let supported = Set(OathImportChain.allCases.map(\.id))
        XCTAssertEqual(supported, Set(TokenDiscoveryNetworks.platforms.keys).union(TokenDiscoveryNetworks.nativeOnly))
        XCTAssertEqual(Set(OathTokenNetwork.all.map(\.id)), Set(TokenDiscoveryNetworks.platforms.keys))
        let entries = await TokenDiscoveryCatalog.shared.search("USDT", networks: supported)
        let mapped = entries.compactMap(OathTokenDefinition.discovery)
        XCTAssertEqual(entries.map(\.id), mapped.map(\.id))
        XCTAssertTrue(mapped.contains { $0.network.chain == .aptos })
        XCTAssertTrue(mapped.contains { $0.network.chain == .ton })
    }

    func testNameSearchDoesNotCallRPCAndResetCannotPublishStaleResults() async throws {
        let bytes = Data(#"[{"id":"tether","name":"Tether","symbol":"usdt","platforms":{"ethereum":"0xdac17f958d2ee523a2206206994597c13d831ec7","tron":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"}}]"#.utf8)
        let catalog = FixedDiscovery(entries: try TokenDiscoveryCatalog.decode(bytes))
        let model = OathTokenSearchModel(service: UnexpectedLookup(), catalog: catalog)
        await model.search("usdt", available: [.ethereum, .tron])
        XCTAssertEqual(Set(model.results.map(\.network.chain)), [.ethereum, .tron])
        XCTAssertFalse(model.isSearching)
        await model.search("tether", available: [.ethereum, .tron], savedIDs: ["ethereum:0xdac17f958d2ee523a2206206994597c13d831ec7"])
        XCTAssertEqual(model.results.map(\.network.chain), [.tron])
        let waiting = Task { await model.search("usdt", available: [.ethereum]) }
        try await Task.sleep(for: .milliseconds(10))
        model.reset()
        await waiting.value
        XCTAssertTrue(model.results.isEmpty)
    }

    func testOldRefreshCannotReplaceNewWalletNetworkResults() async throws {
        let data = Data(#"[{"id":"tether","name":"Tether","symbol":"usdt","platforms":{"ethereum":"0xdac17f958d2ee523a2206206994597c13d831ec7","tron":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"}}]"#.utf8)
        let model = OathTokenSearchModel(service: UnexpectedLookup(), catalog: DelayedRefreshDiscovery(entries: try TokenDiscoveryCatalog.decode(data)))
        let old = Task { await model.search("usdt", available: [.ethereum]) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.results.map(\.network.chain), [.ethereum])
        await model.search("usdt", available: [.tron])
        await old.value
        XCTAssertEqual(model.results.map(\.network.chain), [.tron])
        XCTAssertFalse(model.isSearching)
    }

    func testPickerRequestFindsMixedCaseUSDTBeforeWalletHasAnyTokensAndAfterTracking() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let chains: [OathImportChain] = [.ethereum, .tron, .solana]
        try await database.seed(networks: chains.enumerated().map { index, chain in
            .init(id: chain.id, name: chain.name, family: "fixture", symbol: "NATIVE", decimals: 18,
                  derivationPath: "fixture", logo: chain.logoAsset, sortOrder: index)
        }, assets: chains.map {
            .init(id: $0.id + ":native", networkID: $0.id, reference: "native", name: $0.name, symbol: "NATIVE", decimals: 18)
        })
        try await database.importWalletIfNeeded(.init(id: "fixture", name: "", kind: "hd", vaultReference: "fixture", createdAt: 1),
            accounts: chains.map { .init(id: $0.id, walletID: "fixture", networkID: $0.id, address: "public-fixture", derivationPath: "fixture") })
        let snapshot = try await database.snapshot(walletID: "fixture", currency: "USD")
        XCTAssertFalse(snapshot.holdings.contains { $0.symbol == "USDT" })
        // Real bundled directory, with refresh forced to fail. No provider or
        // wallet balance refresh is required for the initial name search.
        let catalog = TokenDiscoveryCatalog(transport: UnavailableDirectory(), directory: folder.appendingPathComponent("catalog"))
        let model = OathTokenSearchModel(service: UnexpectedLookup(), catalog: catalog)
        let request = OathTokenSearchRequest(query: "Usdt", walletID: "fixture", active: true, snapshot: snapshot)
        await model.search(request)
        let expected: Set<String> = [
            "ethereum:0xdac17f958d2ee523a2206206994597c13d831ec7",
            "tron:TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
            "solana:Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"
        ]
        XCTAssertTrue(expected.isSubset(of: Set(model.results.map(\.id))))
        let token = try XCTUnwrap(model.results.first { $0.id == "ethereum:0xdac17f958d2ee523a2206206994597c13d831ec7" })
        try await database.trackAsset(.init(id: token.id, networkID: token.network.id, reference: token.reference,
            name: token.name, symbol: token.symbol, decimals: 6), walletID: "fixture")
        let tracked = try await database.snapshot(walletID: "fixture", currency: "USD")
        let added = try XCTUnwrap(tracked.holdings.first { $0.reference == token.reference })
        XCTAssertEqual(added.accountID, "ethereum")
        XCTAssertNil(added.amountAtomic, "Discovery must not invent a spendable balance")
        let next = OathTokenSearchRequest(query: "Usdt", walletID: "fixture", active: true, snapshot: tracked)
        XCTAssertNotEqual(request, next, "Tracking must invalidate discovery exclusions")
        await model.search(next)
        XCTAssertFalse(model.results.contains { $0.id == token.id }, "The token now belongs in the saved-asset rows")
        XCTAssertTrue(expected.subtracting([token.id]).isSubset(of: Set(model.results.map(\.id))))

        // Switching wallets must not treat another wallet's selection as saved.
        try await database.importWalletIfNeeded(.init(id: "second", name: "", kind: "hd", vaultReference: "second", createdAt: 2),
            accounts: chains.map { .init(id: "second-" + $0.id, walletID: "second", networkID: $0.id,
                address: "public-fixture", derivationPath: "fixture") })
        let otherWallet = try await database.snapshot(walletID: "second", currency: "USD")
        XCTAssertFalse(otherWallet.holdings.contains { $0.assetID == token.id })
        await model.search(OathTokenSearchRequest(query: "Usdt", walletID: "second", active: true, snapshot: otherWallet))
        XCTAssertTrue(expected.isSubset(of: Set(model.results.map(\.id))))

        let converted = try await database.snapshot(walletID: "fixture", currency: "EUR")
        XCTAssertEqual(next, OathTokenSearchRequest(query: "Usdt", walletID: "fixture", active: true, snapshot: converted),
                       "Currency and valuation updates must not restart searches")
        let wrongWallet = OathTokenSearchRequest(query: "Usdt", walletID: "another-wallet", active: true, snapshot: tracked)
        XCTAssertFalse(wrongWallet.active)
        await model.search(wrongWallet)
        XCTAssertTrue(model.results.isEmpty)
        let waiting = OathTokenSearchRequest(query: "Usdt", walletID: "fixture", active: true, snapshot: nil)
        XCTAssertFalse(waiting.active)
        XCTAssertNotEqual(waiting, request, "A query typed before the account snapshot arrives must rerun when ready")
        let restricted = OathTokenSearchRequest(query: "Usdt", walletID: "fixture", active: true,
            snapshot: snapshot, permittedNetworks: [.tron])
        await model.search(restricted)
        XCTAssertEqual(Set(model.results.map(\.network.chain)), [.tron])
    }

    func testSelectionNavigatesSynchronouslyWhilePersistenceWaitsAndCoalesces() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (database, known) = try await selectionFixture(folder)
        try await database.importWalletIfNeeded(.init(id: "second", name: "", kind: "hd", vaultReference: "second", createdAt: 2),
            accounts: [.init(id: "second-ethereum", walletID: "second", networkID: "ethereum",
                address: "public-fixture", derivationPath: "fixture")])
        let token = OathTokenDefinition(network: known.network, address: known.address,
            name: known.name, symbol: known.symbol, decimals: nil, standard: known.standard, logoURL: nil)
        let snapshot = try await database.snapshot(walletID: "fixture", currency: "USD")
        let selection = OathTokenSelectionModel()
        var additions = 0
        var chosen: Holding?
        var resume: CheckedContinuation<Void, Never>?
        let add: @MainActor (OathTokenDefinition, String) async throws -> WalletSnapshot = { token, wallet in
            additions += 1
            await withCheckedContinuation { resume = $0 }
            try await database.trackAsset(.init(id: token.id, networkID: token.network.id, reference: token.reference,
                name: token.name, symbol: token.symbol, decimals: 6), walletID: wallet)
            return try await database.snapshot(walletID: wallet, currency: "USD")
        }
        selection.select(token, walletID: "fixture", snapshot: snapshot, add: add) { holding, value in
            XCTAssertEqual(value, snapshot, "Do not inject preview balances into the wallet snapshot")
            chosen = holding
        }
        XCTAssertNotNil(chosen, "Navigation must finish synchronously, before even starting the database task")
        XCTAssertEqual(additions, 0)
        XCTAssertTrue(try XCTUnwrap(chosen).isCatalogPreview)
        XCTAssertNil(chosen?.amountAtomic)
        XCTAssertNil(chosen?.price)
        XCTAssertEqual(chosen?.assetID, token.id)
        selection.select(token, walletID: "fixture", snapshot: snapshot, add: add) { _, _ in }
        for _ in 0..<100 where resume == nil { await Task.yield() }
        XCTAssertEqual(additions, 1, "The session coalesces repeated selections, even from separate screens")
        XCTAssertEqual(selection.pendingCount, 1)
        resume?.resume()
        for _ in 0..<200 where selection.pendingCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(selection.pendingCount, 0)
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let persisted = try await reopened.snapshot(walletID: "fixture", currency: "USD")
        let saved = try XCTUnwrap(persisted.holdings.first { $0.assetID == token.id })
        XCTAssertFalse(saved.isCatalogPreview)
        XCTAssertEqual(saved.decimals, 6, "Only resolved metadata reaches persistence")
        XCTAssertNil(saved.amountAtomic)
        let otherWallet = try await reopened.snapshot(walletID: "second", currency: "USD")
        XCTAssertFalse(otherWallet.holdings.contains { $0.assetID == token.id },
                       "Silent persistence must add only to the wallet that selected the result")
        var selectedSaved = false
        selection.select(token, walletID: "fixture", snapshot: persisted, add: { _, _ in
            XCTFail("Saved token was added again"); return persisted
        }) { holding, _ in selectedSaved = !holding.isCatalogPreview }
        XCTAssertTrue(selectedSaved)
    }

    func testCancelledBackgroundSelectionNeverNavigatesAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (database, token) = try await selectionFixture(folder)
        let snapshot = try await database.snapshot(walletID: "fixture", currency: "USD")
        let selection = OathTokenSelectionModel()
        var pending: CheckedContinuation<WalletSnapshot, Never>?
        var navigations = 0
        selection.select(token, walletID: "fixture", snapshot: snapshot, add: { _, _ in
            await withCheckedContinuation { pending = $0 }
        }) { _, _ in navigations += 1 }
        XCTAssertEqual(navigations, 1)
        for _ in 0..<100 where pending == nil { await Task.yield() }
        XCTAssertNotNil(pending)
        selection.cancel()
        pending?.resume(returning: snapshot)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(selection.pendingCount, 0)
        XCTAssertEqual(navigations, 1, "Late completion after lock/reset must never navigate")
    }

    func testSelectionRejectsWrongWalletAndRetriesBackgroundFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (database, token) = try await selectionFixture(folder)
        let snapshot = try await database.snapshot(walletID: "fixture", currency: "USD")
        let selection = OathTokenSelectionModel()
        selection.select(token, walletID: "other-wallet", snapshot: snapshot, add: { _, _ in
            XCTFail("Wrong wallet reached persistence"); return snapshot
        }) { _, _ in XCTFail("Wrong wallet navigated") }
        XCTAssertEqual(selection.pendingCount, 0)
        var navigations = 0
        selection.select(token, walletID: "fixture", snapshot: snapshot, add: { _, _ in
            throw OathTokenLookupError.unavailable
        }) { _, _ in navigations += 1 }
        XCTAssertEqual(navigations, 1, "Even an offline metadata provider cannot block navigation")
        for _ in 0..<100 where selection.pendingCount > 0 { await Task.yield() }
        XCTAssertEqual(selection.pendingCount, 0)
        selection.select(token, walletID: "fixture", snapshot: snapshot, add: { token, wallet in
            try await database.trackAsset(.init(id: token.id, networkID: token.network.id, reference: token.reference,
                name: token.name, symbol: token.symbol, decimals: 6), walletID: wallet)
            return try await database.snapshot(walletID: wallet, currency: "USD")
        }) { _, _ in navigations += 1 }
        for _ in 0..<200 where selection.pendingCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(navigations, 2, "Only taps navigate; background completion is silent")
        let saved = try await database.snapshot(walletID: "fixture", currency: "USD")
        XCTAssertTrue(saved.holdings.contains { $0.assetID == token.id })
    }

    func testBackgroundSelectionsBoundConcurrencyAndCancelQueuedWork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (database, base) = try await selectionFixture(folder)
        let snapshot = try await database.snapshot(walletID: "fixture", currency: "USD")
        let selection = OathTokenSelectionModel()
        var pending: [CheckedContinuation<WalletSnapshot, Never>] = []
        var navigations = 0
        for index in 1...6 {
            let token = OathTokenDefinition(network: base.network,
                address: "0x" + String(repeating: String(index), count: 40), name: "Fixture", symbol: "TEST",
                decimals: nil, standard: "ERC20", logoURL: nil)
            selection.select(token, walletID: "fixture", snapshot: snapshot, add: { _, _ in
                await withCheckedContinuation { pending.append($0) }
            }) { _, _ in navigations += 1 }
        }
        XCTAssertEqual(navigations, 6, "Queue limits must not delay navigation")
        for _ in 0..<100 where pending.count < 4 { await Task.yield() }
        XCTAssertEqual(pending.count, 4)
        XCTAssertEqual(selection.pendingCount, 6)
        selection.cancel()
        for continuation in pending { continuation.resume(returning: snapshot) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(pending.count, 4, "Lock/reset must prevent queued work starting")
        XCTAssertEqual(selection.pendingCount, 0)
        XCTAssertEqual(navigations, 6)
    }

    private func selectionFixture(_ folder: URL) async throws -> (OathDatabase, OathTokenDefinition) {
        let database = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await database.seed(networks: [.init(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH",
            decimals: 18, derivationPath: "fixture", logo: "network-ethereum", sortOrder: 0)],
            assets: [.init(id: "ethereum:native", networkID: "ethereum", reference: "native", name: "Ethereum", symbol: "ETH", decimals: 18)])
        try await database.importWalletIfNeeded(.init(id: "fixture", name: "", kind: "hd", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "ethereum", walletID: "fixture", networkID: "ethereum", address: "public-fixture", derivationPath: "fixture")])
        let network = try XCTUnwrap(OathTokenNetwork.find(.ethereum))
        return (database, .init(network: network, address: publicToken, name: "USD Coin", symbol: "USDC", decimals: 6,
            standard: "ERC20", logoURL: nil))
    }

    func testDiscoveryPreservesScannedTokenAndNativePaymentConstraints() async throws {
        let bytes = Data(#"[{"id":"tether","name":"Tether","symbol":"usdt","platforms":{"ethereum":"0xdac17f958d2ee523a2206206994597c13d831ec7","tron":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"}}]"#.utf8)
        let model = OathTokenSearchModel(service: UnexpectedLookup(), catalog: FixedDiscovery(entries: try TokenDiscoveryCatalog.decode(bytes)))
        await model.search("Usdt", available: [.ethereum, .tron], requiredReference: "0xDAC17F958D2EE523A2206206994597C13D831EC7")
        XCTAssertEqual(model.results.map(\.network.chain), [.ethereum])
        await model.search("Usdt", available: [.ethereum, .tron], requiredReference: "native")
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.isSearching)
    }

    func testLiveMetadataAbsenceAndNonTokenContract() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_TOKEN_LOOKUP_LIVE_KEY"] else {
            throw XCTSkip("Opt-in public token RPC check")
        }
        let service = OathTokenService(configuration: .init(ankrKey: key))
        for (chain, address, name, symbol, decimals) in [
            (OathImportChain.ethereum, publicToken, "USD Coin", "USDC", 6),
            (.base, "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", "USD Coin", "USDC", 6),
            (.bnb, "0x55d398326f99059fF775485246999027B3197955", "Tether USD", "USDT", 18),
            (.optimism, "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85", "USD Coin", "USDC", 6)
        ] {
            let network = try XCTUnwrap(OathTokenNetwork.find(chain))
            let token = try await service.lookup(address: address, network: network)
            XCTAssertEqual(token.name, name); XCTAssertEqual(token.symbol, symbol); XCTAssertEqual(token.decimals, decimals)
            for absent in [noToken, "0x000000000022D473030F116dDEE9F6B43aC78BA3"] {
                do { _ = try await service.lookup(address: absent, network: network); XCTFail("Non-token accepted") }
                catch { XCTAssertEqual(error as? OathTokenLookupError, .notToken) }
            }
            print("OATH_TOKEN_LOOKUP_LIVE: \(network.id) exact token metadata, empty account and Permit2 non-token contract verified")
        }
    }

    func testLiveCatalogAddResolutionAllNetworks() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TOKEN_DISCOVERY_ADD_LIVE"] == "1",
              let key = ProcessInfo.processInfo.environment["OATH_TOKEN_LOOKUP_LIVE_KEY"] else { throw XCTSkip("Explicit all-network live lookup") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_TOKEN_DISCOVERY_SEED"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        // The shipped public snapshot remains searchable during a directory
        // outage. Force that outage, then exercise actual chain reads below.
        let catalog = TokenDiscoveryCatalog(transport: UnavailableDirectory(), seed: data)
        let service = OathTokenService(configuration: .init(ankrKey: key))
        var passed: Set<String> = []
        for chain in TokenDiscoveryNetworks.platforms.keys.sorted() {
            var choices = await catalog.search("USDC", networks: [chain])
            if choices.isEmpty { choices = await catalog.search("USDT", networks: [chain]) }
            if choices.isEmpty { choices = await catalog.search(chain == "thorchain" ? "ruji" : "ip", networks: [chain]) }
            let entry = try XCTUnwrap(choices.first, chain)
            let token = try XCTUnwrap(OathTokenDefinition.discovery(entry))
            do {
                let resolved = try await OathDiagnostics.$chain.withValue(chain) {
                    try await service.resolveForAdding(token,
                        owner: chain == "stellar" ? "GBEBCRCJ5VX7GERSGJ5XGJX7K2CHNVQB67K2KGCX7RFGMCBIIZQ5E4GY" : nil,
                        catalog: catalog)
                }
                XCTAssertNotNil(resolved.decimals)
                XCTAssertEqual(resolved.id, entry.id)
                passed.insert(chain)
                print("OATH_DISCOVERY_ADD_LIVE \(chain): \(entry.decimals == nil ? "live chain metadata fallback" : "protocol-defined scale") verified")
            } catch { XCTFail("Selected-token metadata failed for \(chain): \(type(of: error))") }
        }
        XCTAssertEqual(passed, Set(TokenDiscoveryNetworks.platforms.keys))
    }
}

private struct UnexpectedLookup: OathTokenLookingUp {
    func lookup(address: String, network: OathTokenNetwork) async throws -> OathTokenDefinition {
        XCTFail("Name search must not probe RPCs")
        throw OathTokenLookupError.unavailable
    }
}

private struct FixedDiscovery: OathTokenDiscovering {
    let entries: [TokenDiscoveryEntry]
    func search(_ query: String, networks: Set<String>, excluding: Set<String>, limit: Int) async -> [TokenDiscoveryEntry] {
        entries.filter { networks.contains($0.network) && !excluding.contains($0.id) }
    }
    func refreshIfNeeded() async -> Bool { false }
}

private struct DelayedRefreshDiscovery: OathTokenDiscovering {
    let entries: [TokenDiscoveryEntry]
    func search(_ query: String, networks: Set<String>, excluding: Set<String>, limit: Int) async -> [TokenDiscoveryEntry] {
        entries.filter { networks.contains($0.network) && !excluding.contains($0.id) }
    }
    func refreshIfNeeded() async -> Bool {
        try? await Task.sleep(for: .milliseconds(200))
        return true
    }
}

private final class TokenRPCFixture: URLProtocol, @unchecked Sendable {
    static let counter = RPCRequestCounter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), bytes = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; data.append(bytes, count: count)
            }
            body = data
        }
        let input = try! JSONSerialization.jsonObject(with: body!) as! [String: Any]
        let method = input["method"] as! String
        var mode = request.url!.lastPathComponent
        if let scenario = request.value(forHTTPHeaderField: "X-Oath-Fixture"), scenario.hasPrefix("arc-") {
            mode = request.url?.host == "rpc.blockdaemon.mainnet.arc.io"
                ? (scenario == "arc-primary-outage" ? "http503" : "valid") : "arcvalid"
        }
        Self.counter.increment(mode)
        if mode == "offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        if mode.hasPrefix("http"), let status = Int(mode.dropFirst(4)) {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("provider unavailable".utf8))
            client?.urlProtocolDidFinishLoading(self); return
        }
        var result: Any = mode == "arcvalid" ? "0x13b2" : "0x1"
        if method == "eth_getCode" { result = mode == "nocode" ? "0x" : "0x6000" }
        if method == "eth_call" {
            let selector = ((input["params"] as? [Any])?.first as? [String: Any])?["data"] as? String
            if selector == "0x313ce567" { result = "0x" + String(repeating: "0", count: 63) + "6" }
            else if selector == "0x18160ddd" { result = "0x" + String(repeating: "0", count: 63) + "1" }
            else {
                let text = selector == "0x06fdde03" ? "Test Token" : "TST"
                result = "0x" + Data(text.utf8).map { String(format: "%02x", $0) }.joined() + String(repeating: "00", count: 32 - text.utf8.count)
            }
        }
        var output: [String: Any] = ["jsonrpc": "2.0", "id": input["id"]!, "result": result]
        if mode == "revert" || (method == "eth_call" && ["revertmetadata", "wrongerrorcode", "internalerror", "wrongreply", "resultanderror"].contains(mode)) {
            output["error"] = ["code": mode == "wrongerrorcode" ? -32005 : mode == "internalerror" ? -32603 : 3, "message": "execution reverted"]
            if mode != "resultanderror" { output.removeValue(forKey: "result") }
            if mode == "wrongreply" { output["id"] = "different-reply" }
        }
        if method == "eth_call", mode == "missingresult" { output.removeValue(forKey: "result") }
        if method == "eth_call", mode == "nullresult" { output["result"] = NSNull() }
        if mode == "rpclimit" || mode == "rpcinternal" {
            output.removeValue(forKey: "result")
            output["error"] = ["code": mode == "rpclimit" ? -32005 : -32603,
                               "message": mode == "rpclimit" ? "limit reached" : "provider internal error"]
        }
        let data = try! JSONSerialization.data(withJSONObject: output)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private final class RPCRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func increment(_ key: String) { lock.withLock { values[key, default: 0] += 1 } }
    func count(_ key: String) -> Int { lock.withLock { values[key, default: 0] } }
    func reset() { lock.withLock { values = [:] } }
}

import XCTest
@testable import OathAnkr

final class FilecoinTests: XCTestCase, @unchecked Sendable {
    func testGLIFDelegatedVectorsAndNetworkSeparation() throws {
        let vectors = [
            ("0x9858effd232b4033e47d90003d41ec34ecaeda94", "f410ftbmo77jdfnadhzd5saad2qpmgtwk5wuuuo4qucq"),
            ("0x27ef5cdbe01777d62438affeb695e33fc2335979", "f410fe7xvzw7ac535mjbyv77lnfpdh7bdgwlzqbe3qsy")
        ]
        for (ethereum, delegated) in vectors {
            XCTAssertEqual(try FilecoinIdentity.delegated(ethereum), delegated)
            XCTAssertEqual(try FilecoinIdentity.ethereum(delegated), ethereum)
            XCTAssertEqual(try TokenDiscoveryNetworks.canonical(delegated, network: "filecoin"), ethereum)
            for invalid in ["t" + delegated.dropFirst(), delegated.uppercased(), String(delegated.dropLast()) + "a",
                            delegated.replacingOccurrences(of: "410", with: "411"), delegated + "a"] {
                XCTAssertThrowsError(try FilecoinIdentity.ethereum(invalid))
            }
        }
        XCTAssertThrowsError(try FilecoinIdentity.delegated("0xff00000000000000000000000000000000000064"))
        XCTAssertThrowsError(try FilecoinIdentity.ethereum("f0100"))
        XCTAssertEqual(IndexedEVMChain.filecoin.chainID, 314)
        XCTAssertEqual(IndexedEVMChain.filecoin.nativeCoinID, "filecoin")
        XCTAssertEqual(IndexedEVMChain.filecoin.historyStreams, IndexedEVMHistoryStream.allCases)
    }

    func testDelegatedRejectsEverySingleCharacterMutation() throws {
        let original = "f410fe7xvzw7ac535mjbyv77lnfpdh7bdgwlzqbe3qsy"
        for index in original.indices {
            var mutated = original
            mutated.replaceSubrange(index...index, with: original[index] == "a" ? "b" : "a")
            XCTAssertThrowsError(try FilecoinIdentity.ethereum(mutated))
            XCTAssertThrowsError(try FilecoinHistoryArchive.address(.string(mutated), id: .string("f0100")))
        }
    }

    func testArchivedContractCreationUsesStrictEAMReturn() throws {
        let returned = "0x831a001fd65c55027f4f0bb40363af86038d4d7632a6bd17fe421f8c5460e1773636cf5e4a227d9ac24f20feca034ee25a"
        let contract = IndexedEVMChain.filecoin.wrappedNative
        XCTAssertEqual(try FilecoinHistoryArchive.createdAddress(.string(returned)), contract)
        for invalid in [returned + "00", String(returned.dropLast(2)), returned.replacingOccurrences(of: "0x83", with: "0x82"),
                        returned.replacingOccurrences(of: "5502", with: "5501")] {
            XCTAssertThrowsError(try FilecoinHistoryArchive.createdAddress(.string(invalid)))
        }
        let (row, message) = try filecoinArchiveFixture()
        guard case .object(var indexed) = row, case .object(var proof) = message else { return XCTFail() }
        indexed["to"] = .null; indexed["created_contract"] = .object(["hash": .string(contract)])
        proof["to"] = .string("f010"); proof["method"] = .string("CreateExternal")
        proof["receipt"] = .object(["exitCode": .number("0"), "return": .string(returned)])
        XCTAssertEqual(try FilecoinHistoryArchive.corroborate(rows: [.object(indexed)], messages: [filecoinHash: .object(proof)], stream: .transactions).count, 1)
        proof["to"] = .string("f011")
        XCTAssertThrowsError(try FilecoinHistoryArchive.corroborate(rows: [.object(indexed)], messages: [filecoinHash: .object(proof)], stream: .transactions))
    }

    func testFilecoinDEXRequiresCorrectContractNetworkAndLiquidity() throws {
        let ref = IndexedEVMChain.filecoin.wrappedNative
        func payload(network: String = "filecoin", price: Any = "0.87", reserve: String = "100000") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["data": [["type": "token", "id": network + "_" + ref,
                "attributes": ["address": ref, "price_usd": price, "total_reserve_in_usd": reserve]]]])
        }
        XCTAssertEqual(try IndexedEVMMarkets.decodeTerminalDEX(payload(), chain: .filecoin, references: [ref]).first?.usd, "0.87")
        XCTAssertTrue(try IndexedEVMMarkets.decodeTerminalDEX(payload(price: NSNull()), chain: .filecoin, references: [ref]).isEmpty)
        XCTAssertTrue(try IndexedEVMMarkets.decodeTerminalDEX(payload(reserve: "9999"), chain: .filecoin, references: [ref]).isEmpty)
        XCTAssertThrowsError(try IndexedEVMMarkets.decodeTerminalDEX(payload(network: "eth"), chain: .filecoin, references: [ref]))
        XCTAssertThrowsError(try IndexedEVMMarkets.decodeTerminalDEX(payload(), chain: .filecoin, references: ["0x1111111111111111111111111111111111111111"]))
    }

    func testCatalogDoesNotUseTickerOrOtherNetworkToPriceFILTokens() throws {
        let ref = IndexedEVMChain.filecoin.wrappedNative
        let data = try JSONSerialization.data(withJSONObject: [
            ["id": "wrapped-fil", "symbol": "wfil", "platforms": ["filecoin": ref]],
            ["id": "impostor", "symbol": "wfil", "platforms": ["ethereum": ref]]
        ])
        let catalog = try IndexedEVMMarkets.decodeCatalog(data, chain: .filecoin)
        XCTAssertEqual(catalog.ids, [ref: "wrapped-fil"])
    }
}

private let filecoinOwner = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
private let filecoinOther = "0x27ef5cdbe01777d62438affeb695e33fc2335979"
private let filecoinHash = "0x" + String(repeating: "a", count: 64)
private let filecoinTime = 1_790_000_000.0

private func filecoinArchiveFixture() throws -> (SolanaJSON, SolanaJSON) {
    let row: [String: Any] = ["hash": filecoinHash, "block_number": 100,
        "timestamp": Date(timeIntervalSince1970: filecoinTime).ISO8601Format(),
        "from": ["hash": filecoinOwner], "to": ["hash": filecoinOther], "value": "9007199254740993", "status": "ok"]
    let message: [String: Any] = ["ethTransactionHash": filecoinHash, "height": 100, "timestamp": filecoinTime,
        "from": try FilecoinIdentity.delegated(filecoinOwner), "to": try FilecoinIdentity.delegated(filecoinOther),
        "value": "9007199254740993", "receipt": ["exitCode": 0],
        "fee": ["baseFeeBurn": "100", "overEstimationBurn": "30", "minerTip": "1000"]]
    let decoder = JSONDecoder()
    return try (decoder.decode(SolanaJSON.self, from: JSONSerialization.data(withJSONObject: row)),
                decoder.decode(SolanaJSON.self, from: JSONSerialization.data(withJSONObject: message)))
}

private actor FilecoinArchiveTransport: AnkrTransport {
    enum Mode { case missing, wrongChain, malformed, providerError, unavailable }
    let mode: Mode
    var hosts: [String] = []
    init(_ mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        hosts.append(request.url?.host ?? "")
        let (row, message) = try filecoinArchiveFixture()
        if request.url?.host == "filecoin.blockscout.com" {
            return (try JSONEncoder().encode(SolanaJSON.object(["items": .array([row]), "next_page_params": .null])), 200)
        }
        if request.url?.host == "filfox.info" { return (try JSONEncoder().encode(message), 200) }
        if mode == .unavailable { throw AnkrError.transport }
        if mode == .malformed { return (Data("{}".utf8), 200) }
        let calls = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody)).array)
        let replies = calls.map { call -> SolanaJSON in
            if call["method"].string == "eth_chainId" {
                return .object(["id": call["id"], "jsonrpc": .string("2.0"), "result": .string(mode == .wrongChain ? "0x1" : "0x13a")])
            }
            if mode == .providerError { return .object(["id": call["id"], "jsonrpc": .string("2.0"), "error": .object(["code": .number("-32601")])]) }
            return .object(["id": call["id"], "jsonrpc": .string("2.0"), "result": .null])
        }
        return (try JSONEncoder().encode(SolanaJSON.array(replies)), 200)
    }
}

extension FilecoinTests {
    func testMissingRPCRecordUsesIndependentArchiveWithoutTrustingMalformedRPC() async throws {
        let transport = FilecoinArchiveTransport(.missing)
        let page = try await IndexedEVMClient(chain: .filecoin, apiKey: "fixture", transport: transport)
            .history(owner: filecoinOwner, stream: .transactions)
        XCTAssertEqual(page.events.count, 1)
        XCTAssertEqual(page.events.first?.amount, "9007199254740993")
        XCTAssertEqual(page.events.first?.fee, "1130")
        let event = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(page.events.first?.raw))
        XCTAssertEqual(event["verification_source"].string, "blockscout_filfox_archive")
        for mode in [FilecoinArchiveTransport.Mode.wrongChain, .malformed, .providerError] {
            let bad = FilecoinArchiveTransport(mode)
            do {
                _ = try await IndexedEVMClient(chain: .filecoin, apiKey: "fixture", transport: bad).history(owner: filecoinOwner, stream: .transactions)
                XCTFail("Invalid RPC evidence must not select an archive")
            } catch { XCTAssertNotNil(error as? AnkrError) }
            let hosts = await bad.hosts
            XCTAssertFalse(hosts.contains("filfox.info"))
        }
    }

    func testArchiveRejectsMismatchedHashAmountParticipantHeightAndTime() throws {
        let (row, message) = try filecoinArchiveFixture()
        let changes: [(String, SolanaJSON)] = [("ethTransactionHash", .string("0x" + String(repeating: "b", count: 64))),
            ("value", .string("1")), ("from", .string(try FilecoinIdentity.delegated(filecoinOther))),
            ("height", .number("101")), ("timestamp", .number(String(filecoinTime + 30)))]
        for (key, value) in changes {
            guard case .object(var changed) = message else { return XCTFail() }
            changed[key] = value
            XCTAssertThrowsError(try FilecoinHistoryArchive.corroborate(rows: [row], messages: [filecoinHash: .object(changed)], stream: .transactions))
        }
    }

    func testCatalogRateLimitUsesBundledExactFilecoinIdentities() async throws {
        struct Unavailable: AnkrTransport {
            func send(_ request: URLRequest) async throws -> (Data, Int) { (Data(), 429) }
        }
        let catalog = try await IndexedEVMMarkets(chain: .filecoin, transport: Unavailable()).catalog()
        XCTAssertGreaterThanOrEqual(catalog.ids.count, 6)
        XCTAssertEqual(catalog.ids[IndexedEVMChain.filecoin.wrappedNative], "wrapped-fil")
        XCTAssertEqual(catalog.ids["0x80b98d3aa09ffff255c3ba4a241111ff1262f045"], "usdfc")
    }
}

extension FilecoinTests {
    func testLegacyWrappedFILRequiresRawEventAndMatchingNativeMovement() throws {
        let wrapper = "0x1111111111111111111111111111111111111111", zero = "0x" + String(repeating: "0", count: 40)
        let row: [String: Any] = ["transaction_hash": filecoinHash, "block_number": 100, "log_index": 7,
            "timestamp": Date(timeIntervalSince1970: filecoinTime).ISO8601Format(),
            "from": ["hash": filecoinOther], "to": ["hash": zero],
            "token": ["type": "ERC-20", "address_hash": wrapper, "decimals": "18", "name": "Wrapped FIL", "symbol": "WFIL"],
            "total": ["value": "25", "decimals": "18"]]
        let transfer: [String: Any] = ["type": "transfer", "from": try FilecoinIdentity.delegated(wrapper),
            "to": try FilecoinIdentity.delegated(filecoinOther), "value": "25"]
        let log: [String: Any] = ["address": try FilecoinIdentity.delegated(wrapper), "removed": false, "data": "0x19", "logIndex": 0,
            "topics": ["0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65", "0x" + String(repeating: "0", count: 24) + filecoinOther.dropFirst(2)]]
        var message: [String: Any] = ["ethTransactionHash": filecoinHash, "height": 100, "timestamp": filecoinTime,
            "receipt": ["exitCode": 0], "tokenTransfers": [Any](), "transfers": [transfer], "archive_event_logs": [log]]
        func decode(_ value: Any) throws -> SolanaJSON { try JSONDecoder().decode(SolanaJSON.self, from: JSONSerialization.data(withJSONObject: value)) }
        let indexed = try decode(row), proof = try decode(message)
        XCTAssertEqual(try FilecoinHistoryArchive.corroborate(rows: [indexed], messages: [filecoinHash: proof], stream: .transfers).count, 1)
        XCTAssertThrowsError(try FilecoinHistoryArchive.corroborate(rows: [indexed, indexed], messages: [filecoinHash: proof], stream: .transfers))
        message["transfers"] = [Any]()
        XCTAssertThrowsError(try FilecoinHistoryArchive.corroborate(rows: [indexed], messages: [filecoinHash: decode(message)], stream: .transfers))
        message["transfers"] = [transfer]
        var wrongLog = log; wrongLog["removed"] = true; message["archive_event_logs"] = [wrongLog]
        XCTAssertThrowsError(try FilecoinHistoryArchive.corroborate(rows: [indexed], messages: [filecoinHash: decode(message)], stream: .transfers))
    }
}

extension FilecoinTests {
    func testArchiveCoalescesConcurrentMessageReads() async throws {
        let transport = FilecoinArchiveTransport(.missing), archive = FilecoinHistoryArchive(transport: transport)
        async let first = archive.messages(hashes: [filecoinHash])
        async let second = archive.messages(hashes: [filecoinHash])
        let results = try await (first, second)
        XCTAssertEqual(results.0[filecoinHash], results.1[filecoinHash])
        let hosts = await transport.hosts
        XCTAssertEqual(hosts.filter { $0 == "filfox.info" }.count, 1)
    }

    func testArchivedZeroValueSubcallUsesVerifiedActorIdentityAndExecutionStatus() throws {
        let row: [String: Any] = ["transaction_hash": filecoinHash, "block_number": 100, "index": 9,
            "timestamp": Date(timeIntervalSince1970: filecoinTime).ISO8601Format(),
            "from": ["hash": filecoinOwner], "to": ["hash": filecoinOther], "value": "0", "success": true]
        var call: [String: Any] = ["from": "f0100", "fromId": "f0100", "to": "f0200", "toId": "f0200", "value": "0", "receipt": ["exitCode": 0]]
        var message: [String: Any] = ["ethTransactionHash": filecoinHash, "height": 100, "timestamp": filecoinTime,
            "receipt": ["exitCode": 0], "transfers": [Any](), "archive_actor_ids": [filecoinOwner: "f0100", filecoinOther: "f0200"], "archive_subcalls": [call]]
        func decode(_ value: Any) throws -> SolanaJSON { try JSONDecoder().decode(SolanaJSON.self, from: JSONSerialization.data(withJSONObject: value)) }
        let indexed = try decode(row)
        XCTAssertEqual(try FilecoinHistoryArchive.corroborate(rows: [indexed], messages: [filecoinHash: decode(message)], stream: .internalTransactions).count, 1)
        call["receipt"] = ["exitCode": 1]; message["archive_subcalls"] = [call]
        XCTAssertThrowsError(try FilecoinHistoryArchive.corroborate(rows: [indexed], messages: [filecoinHash: decode(message)], stream: .internalTransactions))
        call["receipt"] = ["exitCode": 0]; message["archive_subcalls"] = [call]
        message["archive_actor_ids"] = [filecoinOwner: "f0999", filecoinOther: "f0200"]
        XCTAssertThrowsError(try FilecoinHistoryArchive.corroborate(rows: [indexed], messages: [filecoinHash: decode(message)], stream: .internalTransactions))
    }
}

extension FilecoinTests {
    func testPriceFallbackRejectsStaleQuoteWithoutDroppingFreshToken() async throws {
        struct Prices: AnkrTransport {
            func send(_ request: URLRequest) async throws -> (Data, Int) {
                if request.url?.host == "api.coingecko.com" { return (Data(), 429) }
                let now = Date().timeIntervalSince1970
                return (try JSONSerialization.data(withJSONObject: ["coins": [
                    "coingecko:wrapped-fil": ["price": "0.87", "confidence": 0.99, "timestamp": now],
                    "coingecko:usdfc": ["price": "1", "confidence": 0.99, "timestamp": now - 10000]]]), 200)
            }
        }
        let wfil = IndexedEVMChain.filecoin.wrappedNative, usdfc = "0x80b98d3aa09ffff255c3ba4a241111ff1262f045"
        let prices = try await IndexedEVMMarkets(chain: .filecoin, transport: Prices()).prices(references: [wfil, usdfc],
            catalog: .init(chain: .filecoin, ids: [wfil: "wrapped-fil", usdfc: "usdfc"]))
        XCTAssertEqual(prices.count, 1)
        XCTAssertEqual(prices.first?.reference, wfil)
        XCTAssertEqual(prices.first?.source, "DefiLlama")
        XCTAssertEqual(prices.first?.usd, "0.87")
    }
}

extension FilecoinTests {
    func testShiftedTraceLinkRequiresIndependentMovementEvidence() async throws {
        struct ShiftedTrace: AnkrTransport {
            let mismatch: Bool
            func send(_ request: URLRequest) async throws -> (Data, Int) {
                let oldHash = "0x" + String(repeating: "b", count: 64)
                let path = request.url!.path
                let (transaction, baseMessage) = try filecoinArchiveFixture()
                guard case .object(var row) = transaction, case .object(var message) = baseMessage else { throw AnkrError.invalidResponse }
                row["hash"] = nil; row["transaction_hash"] = .string(oldHash)
                row["index"] = .number("3"); row["transaction_index"] = .number("1"); row["success"] = .bool(true)
                let value: SolanaJSON
                if path.contains("/blocks/") {
                    guard case .object(var candidate) = transaction else { throw AnkrError.invalidResponse }
                    candidate["position"] = .number("0")
                    value = .object(["items": .array([.object(candidate)]), "next_page_params": .null])
                } else if path.contains("/internal-transactions") {
                    value = .object(["items": .array([.object(row)]), "next_page_params": .null])
                } else if path.contains("/address/") {
                    let address = request.url!.lastPathComponent
                    value = .object(["ethAddress": .string(address), "id": .string(address == filecoinOwner ? "f0100" : "f0200")])
                } else if path.hasSuffix("/subcalls") { value = .array([]) }
                else {
                    let hash = request.url!.lastPathComponent
                    message["ethTransactionHash"] = .string(hash)
                    message["from"] = .string("f0999")
                    message["cid"] = .string("bafy" + String(repeating: "a", count: 55))
                    message["transfers"] = hash == oldHash ? .array([]) : .array([.object([
                        "type": .string("transfer"), "from": .string(filecoinOwner), "to": .string(filecoinOther),
                        "value": mismatch ? .string("1") : row["value"]!
                    ])])
                    value = .object(message)
                }
                return (try JSONEncoder().encode(value), 200)
            }
        }
        let page = try await IndexedEVMClient(chain: .filecoin, apiKey: "fixture", transport: ShiftedTrace(mismatch: false))
            .history(owner: filecoinOwner, stream: .internalTransactions)
        XCTAssertEqual(page.events.first?.hash, filecoinHash)
        XCTAssertEqual(page.events.first?.amount, "9007199254740993")
        do {
            _ = try await IndexedEVMClient(chain: .filecoin, apiKey: "fixture", transport: ShiftedTrace(mismatch: true))
                .history(owner: filecoinOwner, stream: .internalTransactions)
            XCTFail("An adjacent hash without a matching transfer must fail")
        } catch { XCTAssertEqual(error as? AnkrError, .invalidResponse) }
    }

    func testFilecoinRootTraceIsNotCountedTwiceAndMissingHashRequiresUniqueExactTransfer() throws {
        let (row, message) = try filecoinArchiveFixture()
        guard case .object(var fields) = row else { return XCTFail() }
        fields["hash"] = nil; fields["transaction_hash"] = .null
        fields["success"] = .bool(true); fields["index"] = .number("10")
        let trace = SolanaJSON.object(fields)
        let recovered = try IndexedEVMClient.recoverFilecoinTraceHash(trace, candidates: [row])
        XCTAssertEqual(recovered["transaction_hash"].string, filecoinHash)
        XCTAssertThrowsError(try IndexedEVMClient.recoverFilecoinTraceHash(trace, candidates: [row, row]))
        fields["value"] = .string("1")
        XCTAssertThrowsError(try IndexedEVMClient.recoverFilecoinTraceHash(.object(fields), candidates: [row]))
        XCTAssertTrue(try FilecoinHistoryArchive.corroborate(rows: [recovered], messages: [filecoinHash: message], stream: .internalTransactions).isEmpty)
    }

    func testFailedAncestorRevertsSuccessfulChildrenWithoutAffectingSiblings() throws {
        func call(_ status: Int, children: [SolanaJSON] = []) -> SolanaJSON {
            .object(["receipt": .object(["exitCode": .number(String(status))]), "subcalls": .array(children)])
        }
        let calls = try FilecoinHistoryArchive.flatten(.array([call(1, children: [call(0)]), call(0)]))
        XCTAssertEqual(calls.filter { $0["archive_reverted"] == .bool(true) }.count, 2)
        XCTAssertEqual(calls.filter { $0["archive_reverted"] == .bool(false) }.count, 1)
    }

    func testBothRPCProvidersUnavailableRecoverFromCorroboratedArchive() async throws {
        let transport = FilecoinArchiveTransport(.unavailable)
        let page = try await IndexedEVMClient(chain: .filecoin, apiKey: "fixture", transport: transport).history(owner: filecoinOwner, stream: .transactions)
        XCTAssertEqual(page.events.first?.amount, "9007199254740993")
        let hosts = await transport.hosts
        XCTAssertTrue(hosts.contains("rpc.ankr.com"))
        XCTAssertTrue(hosts.contains("api.node.glif.io"))
        XCTAssertTrue(hosts.contains("filfox.info"))
    }
}

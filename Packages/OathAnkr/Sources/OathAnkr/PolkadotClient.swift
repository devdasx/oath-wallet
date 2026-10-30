import Foundation
import OathDiagnostics

/// Asset Hub owns user DOT balances. The Relay Chain RPC is a separate network.
public actor PolkadotClient {
    private let endpoints: [URL], explorer: URL, graph: URL
    private let relayEndpoints: [URL]
    private let transport: any AnkrTransport
    private let permits = AnkrPermits(count: 4)
    private var verified: Set<URL> = []
    private var tokens: [String: PolkadotToken] = [:]
    private var marketIDs: [String: String] = [:]
    private var ethereumIDs: [String: String] = [:]
    private var marketCatalogAt = Date.distantPast
    public init(ankrAPIKey: String? = nil, endpoints: [URL] = [URL(string: "https://polkadot-asset-hub-rpc.polkadot.io")!, URL(string: "https://asset-hub.selvagelabs.io")!],
                explorer: URL = URL(string: "https://ahp-api.statescan.io")!, graph: URL = URL(string: "https://ahp-gh-api.statescan.io/graphql")!,
                transport: any AnkrTransport = AnkrHTTPTransport()) throws {
        guard !endpoints.isEmpty, endpoints.count <= 4, (endpoints + [explorer, graph]).allSatisfy({ $0.scheme == "https" }) else { throw PolkadotError.configuration }
        self.endpoints = endpoints; self.explorer = explorer; self.graph = graph; self.transport = transport
        if let key = ankrAPIKey, !key.isEmpty {
            guard key.count <= 256, key.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw PolkadotError.configuration }
            relayEndpoints = [URL(string: "https://rpc.ankr.com/polkadot")!.appendingPathComponent(key), URL(string: "https://rpc.polkadot.io")!]
        } else { relayEndpoints = [URL(string: "https://rpc.polkadot.io")!] }
    }
    private func read(_ url: URL, body: SolanaJSON? = nil) async throws -> SolanaJSON {
        var request = URLRequest(url: url); request.timeoutInterval = 25
        request.setValue("OathWallet/4.1", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for attempt in 0..<3 {
            try Task.checkCancellation(); try await permits.acquire()
            var ownsPermit = true
            do {
                let (data, status) = try await transport.send(request)
                await permits.release(); ownsPermit = false; try Task.checkCancellation()
                guard status == 200 else { throw PolkadotError.http(status) }
                guard data.count <= 16_000_000 else { throw PolkadotError.malformed }
                return try JSONDecoder().decode(SolanaJSON.self, from: data)
            } catch {
                if ownsPermit { await permits.release() }
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                var context = DiagnosticHTTP.context(request); context["chain"] = "polkadot"; context["attempt"] = String(attempt + 1)
                OathDiagnostics.record(error, component: "polkadot", operation: "read", context: context)
                let retry: Bool
                if case PolkadotError.http(let code) = error { retry = code == 429 || code >= 500 }
                else { retry = error is URLError || (error as? AnkrError) == .transport }
                guard retry, attempt < 2 else { throw error }
                try await Task.sleep(for: .milliseconds(400 * (1 << attempt)))
            }
        }
        throw PolkadotError.unavailable
    }
    private func call(_ endpoint: URL, _ method: String, _ params: [SolanaJSON]) async throws -> SolanaJSON {
        let reply = try await read(endpoint, body: .object(["jsonrpc": .string("2.0"), "id": .number("1"), "method": .string(method), "params": .array(params)]))
        if !reply["error"].isNull {
            let error = PolkadotError.rpc(Int(reply["error"]["code"].text ?? "") ?? -1)
            OathDiagnostics.record(error, component: "polkadot", operation: "rpc", context: ["chain": "polkadot", "rpc_method": method])
            throw error
        }
        guard reply["id"].text == "1", case .object(let fields) = reply, fields["result"] != nil else { throw PolkadotError.malformed }
        return reply["result"]
    }
    func rpc(_ method: String, _ params: [SolanaJSON]) async throws -> SolanaJSON {
        var failure: any Error = PolkadotError.unavailable
        for endpoint in endpoints {
            do {
                if !verified.contains(endpoint) {
                    guard try await call(endpoint, "chain_getBlockHash", [.number("0")]).string == PolkadotIdentity.genesis else { throw PolkadotError.wrongNetwork }
                    verified.insert(endpoint)
                }
                return try await call(endpoint, method, params)
            } catch {
                try Task.checkCancellation(); if error is CancellationError { throw error }
                OathDiagnostics.record(error, component: "polkadot", operation: "rpc_fallback", context: ["chain": "polkadot", "rpc_method": method]); failure = error
            }
        }
        throw failure
    }
    public func finalizedBlock() async throws -> (hash: String, height: Int64) {
        guard let hash = try await rpc("chain_getFinalizedHead", []).string, try PolkadotIdentity.bytes(hash).count == 32 else { throw PolkadotError.malformed }
        let header = try await rpc("chain_getHeader", [.string(hash)])
        guard let n = header["number"].string, n.hasPrefix("0x"), let height = Int64(n.dropFirst(2), radix: 16), height > 0 else { throw PolkadotError.malformed }
        return (hash, height)
    }
    public func relayFinalizedHeight() async throws -> Int64 {
        var failure: any Error = PolkadotError.unavailable
        for endpoint in relayEndpoints {
            do {
                if !verified.contains(endpoint) {
                    guard try await call(endpoint, "chain_getBlockHash", [.number("0")]).string == PolkadotIdentity.relayGenesis else { throw PolkadotError.wrongNetwork }
                    verified.insert(endpoint)
                }
                guard let hash = try await call(endpoint, "chain_getFinalizedHead", []).string else { throw PolkadotError.malformed }
                let header = try await call(endpoint, "chain_getHeader", [.string(hash)])
                guard let n = header["number"].string, n.hasPrefix("0x"), let height = Int64(n.dropFirst(2), radix: 16), height > 0 else { throw PolkadotError.malformed }
                return height
            } catch {
                try Task.checkCancellation(); if error is CancellationError { throw error }
                OathDiagnostics.record(error, component: "polkadot", operation: "relay_history_fallback", context: ["chain": "polkadot"]); failure = error
            }
        }
        throw failure
    }
    /// QueryStorageAt batches keys and binds every result to the requested block.
    func storage(_ keys: [String], at hash: String) async throws -> [String: SolanaJSON] {
        guard Set(keys).count == keys.count, keys.count <= 10_000 else { throw PolkadotError.malformed }
        return try await withThrowingTaskGroup(of: [String: SolanaJSON].self) { group in
            var next = 0, result: [String: SolanaJSON] = [:]
            func enqueue() {
                guard next < keys.count else { return }
                let chunk = Array(keys[next..<min(keys.count, next + 100)]); next += chunk.count
                group.addTask {
                    let value = try await self.rpc("state_queryStorageAt", [.array(chunk.map(SolanaJSON.string)), .string(hash)])
                    guard let rows = value.array, rows.count == 1, rows[0]["block"].string == hash, let changes = rows[0]["changes"].array else { throw PolkadotError.malformed }
                    var values: [String: SolanaJSON] = [:]
                    for change in changes {
                        guard let pair = change.array, pair.count == 2, let key = pair[0].string, chunk.contains(key), values[key] == nil,
                              pair[1].isNull || pair[1].string != nil else { throw PolkadotError.malformed }
                        values[key] = pair[1]
                    }
                    guard values.count == chunk.count else { throw PolkadotError.incompleteInventory }; return values
                }
            }
            for _ in 0..<min(4, (keys.count + 99) / 100) { enqueue() }
            for try await values in group { result.merge(values) { old, _ in old }; enqueue() }
            return result
        }
    }
    private func catalog(pallet: String, hash: String) async throws -> [PolkadotToken] {
        guard let palletPrefix = PolkadotStorage.pallets[pallet] else { throw PolkadotError.malformed }
        let prefix = "0x" + palletPrefix + PolkadotStorage.asset
        var keys: [String] = [], cursor: String? = nil
        repeat {
            let value = try await rpc("state_getKeysPaged", [.string(prefix), .number("500"), cursor.map(SolanaJSON.string) ?? .null, .string(hash)])
            guard let rows = value.array else { throw PolkadotError.malformed }
            var last = cursor
            for row in rows {
                guard let key = row.string, key.hasPrefix(prefix), last == nil || key > last! else { throw PolkadotError.paginationLoop }
                keys.append(key); last = key
            }
            guard keys.count <= 10_000 else { throw PolkadotError.incompleteInventory }
            cursor = rows.count == 500 ? last : nil
        } while cursor != nil
        let metadataKeys = keys.map { "0x" + palletPrefix + PolkadotStorage.metadata + $0.dropFirst(66) }
        let values = try await storage(metadataKeys, at: hash)
        return try metadataKeys.map { key in
            guard let value = values[key] else { throw PolkadotError.incompleteInventory }
            // An existing pallet asset may have no metadata. SCALE's declared
            // default is an empty name/symbol, zero decimals and no freeze.
            return try PolkadotStorage.token(key: key, value: value.isNull ? .string("0x" + String(repeating: "00", count: 20)) : value, pallet: pallet)
        }
    }
    public func inventory(owner: String) async throws -> PolkadotInventory {
        let owner = try PolkadotIdentity.address(owner), block = try await finalizedBlock()
        async let local = catalog(pallet: "Assets", hash: block.hash)
        async let foreign = catalog(pallet: "ForeignAssets", hash: block.hash)
        async let pools = catalog(pallet: "PoolAssets", hash: block.hash)
        let catalog = try await local + foreign + pools
        guard Set(catalog.map(\.reference)).count == catalog.count else { throw PolkadotError.malformed }
        let nativeKey = try PolkadotStorage.nativeKey(owner)
        let pairs = try catalog.map { (try PolkadotStorage.accountKey($0, owner: owner), $0) }
        let values = try await storage([nativeKey] + pairs.map(\.0), at: block.hash)
        guard let native = values[nativeKey] else { throw PolkadotError.incompleteInventory }
        var holdings = [PolkadotHolding(token: .native, amount: try PolkadotStorage.native(native))]
        for (key, token) in pairs {
            guard let value = values[key] else { throw PolkadotError.incompleteInventory }
            if let holding = try PolkadotStorage.holding(value, token: token) { holdings.append(holding) }
        }
        tokens = Dictionary(uniqueKeysWithValues: catalog.map { ($0.reference, $0) })
        return .init(owner: owner, blockHash: block.hash, height: block.height, holdings: holdings)
    }
    func graphql(_ query: String, variables: [String: SolanaJSON] = [:]) async throws -> SolanaJSON {
        let reply = try await read(graph, body: .object(["query": .string(query), "variables": .object(variables)]))
        guard reply["errors"].isNull, !reply["data"].isNull else { throw PolkadotError.unavailable }; return reply["data"]
    }
    public func metadata(reference: String) async throws -> PolkadotToken {
        if reference == "native" { return .native }
        if let token = tokens[reference] { return token }
        let foreign = reference.hasPrefix("foreign:"), id = String(reference.split(separator: ":", maxSplits: 1).last ?? "")
        guard foreign || reference.hasPrefix("assets:"), foreign ? ((try? PolkadotIdentity.bytes(id).count) == 32) : UInt32(id) != nil else { throw PolkadotError.malformed }
        let field = foreign ? "foreignAsset" : "asset"
        let value = try await graphql("query($id:\(foreign ? "String" : "Int")!){\(field)(id:$id){metadata{name symbol decimals}}}", variables: ["id": foreign ? .string(id) : .number(id)])[field]["metadata"]
        guard let name = value["name"].string, let symbol = value["symbol"].string, let decimals = Int(value["decimals"].text ?? ""), (0...255).contains(decimals) else { throw PolkadotError.malformed }
        let token = PolkadotToken(reference: reference, name: name, symbol: symbol, decimals: decimals, pallet: foreign ? "ForeignAssets" : "Assets", key: Data())
        if tokens.count < 10_000 { tokens[reference] = token }
        return token
    }
    public func currentMetadata(reference: String) async throws -> PolkadotToken {
        try await OathDiagnostics.withChain("polkadot") {
            let ref = try PolkadotIdentity.reference(reference)
            let pallet = ref.hasPrefix("assets:") ? "Assets" : ref.hasPrefix("foreign:") ? "ForeignAssets" : "PoolAssets"
            let block = try await finalizedBlock(), values = try await catalog(pallet: pallet, hash: block.hash)
            guard let token = values.first(where: { $0.reference == ref }) else { throw PolkadotError.unavailable }
            return token
        }
    }
    public func history(owner: String, stream: String, page: Int, finalizedHeight: Int64) async throws -> PolkadotHistoryPage {
        let owner = try PolkadotIdentity.address(owner)
        let relay = stream.hasPrefix("relay-"), stream = stream.replacingOccurrences(of: "relay-", with: "")
        guard ["native", "assets", "foreign", "extrinsics"].contains(stream), !relay || stream == "native" || stream == "extrinsics", (0...100_000).contains(page) else { throw PolkadotError.malformed }
        let rows: [SolanaJSON]
        if stream == "native" || stream == "extrinsics" {
            let path = "accounts/" + owner + (stream == "native" ? "/transfers" : "/extrinsics")
            let base = relay ? URL(string: "https://polkadot-api.statescan.io")! : explorer
            var url = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            url.queryItems = [.init(name: "page", value: String(page)), .init(name: "page_size", value: "100")]
            let reply = try await read(url.url!)
            guard let items = reply["items"].array else { throw PolkadotError.malformed }; rows = items
        } else {
            let field = stream == "foreign" ? "foreignAssetTransfers" : "assetTransfers"
            let reply = try await graphql("query($owner:String!,$offset:Int!){\(field)(address:$owner,offset:$offset,limit:100){transfers{assetId balance from to indexer{blockHeight blockTime blockHash eventIndex extrinsicIndex}}}}", variables: ["owner": .string(owner), "offset": .number(String(page * 100))])
            guard let items = reply[field]["transfers"].array else { throw PolkadotError.malformed }; rows = items
        }
        guard rows.count <= 100 else { throw PolkadotError.malformed }
        var events: [PolkadotEvent] = []
        for row in rows {
            let i = row["indexer"], height = try PolkadotIdentity.number(i["blockHeight"])
            guard height <= finalizedHeight else { continue }
            let isExtrinsic = stream == "extrinsics"
            let from = try PolkadotIdentity.address((isExtrinsic ? row["signer"] : row["from"]).string ?? "")
            let to = isExtrinsic ? owner : try PolkadotIdentity.address(row["to"].string ?? "")
            guard from == owner || to == owner else { throw PolkadotError.malformed }
            let index = try PolkadotIdentity.number(isExtrinsic ? i["extrinsicIndex"] : i["eventIndex"])
            let transaction = (relay ? "relay:" : "") + (i["extrinsicIndex"].text.map { "\(height)-\($0)" } ?? "event:\(height)-\(index)")
            let reference = stream == "assets" ? "assets:" + (row["assetId"].text ?? "") : stream == "foreign" ? "foreign:" + (row["assetId"].text ?? "") : "native"
            let token = try await metadata(reference: reference)
            // Signed extrinsics with no transfer still belong in account history.
            // Transfer rows take precedence when this extrinsic also moved funds.
            guard !isExtrinsic || row["isSuccess"] == .bool(true) || row["isSuccess"] == .bool(false) else { throw PolkadotError.malformed }
            events.append(.init(id: "\(isExtrinsic ? "extrinsic" : "event"):\(relay ? "relay:" : "")\(height)-\(index)", transaction: transaction, reference: reference,
                amount: isExtrinsic ? "0" : try PolkadotIdentity.amount(row["balance"]), from: from, to: to,
                height: height, timestamp: Double(try PolkadotIdentity.number(i["blockTime"])) / 1000,
                successful: isExtrinsic ? row["isSuccess"] == .bool(true) : true, token: token))
        }
        guard Set(events.map(\.id)).count == events.count else { throw PolkadotError.malformed }
        return .init(events: events, next: rows.count == 100 ? page + 1 : nil, oldestHeight: try rows.map { try PolkadotIdentity.number($0["indexer"]["blockHeight"]) }.min())
    }
    public func prices(for tokens: [PolkadotToken]) async throws -> [PolkadotPrice] {
        if Date().timeIntervalSince(marketCatalogAt) > 86_400 {
            do {
                let list = try await read(URL(string: "https://api.coingecko.com/api/v3/coins/list?include_platform=true")!)
                guard let rows = list.array, !rows.isEmpty else { throw PolkadotError.malformed }
                var local: [String: String] = [:], ethereum: [String: String] = [:]
                for row in rows {
                    guard let id = row["id"].string, id.utf8.count <= 150, id.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) || (97...122).contains($0) }) else { continue }
                    if let asset = row["platforms"]["polkadot"].string, let number = UInt32(asset), String(number) == asset { local["assets:" + asset] = id }
                    if let contract = row["platforms"]["ethereum"].string, contract.count == 42 { ethereum[contract.lowercased()] = id }
                }
                marketIDs = local; ethereumIDs = ethereum; marketCatalogAt = .now
            } catch {
                try Task.checkCancellation(); if error is CancellationError { throw error }
                OathDiagnostics.record(error, component: "prices", operation: "polkadot_catalog_fallback", context: ["chain": "polkadot"])
            }
        }
        func id(_ token: PolkadotToken) -> String? {
            if let fixed = token.coinGeckoID { return fixed }
            if let mapped = marketIDs[token.reference] { return mapped }
            // XCM v5: parents=2, GlobalConsensus(Ethereum(1)), AccountKey20(None).
            // Match the canonical bridge location, never the display symbol.
            if token.pallet == "ForeignAssets", token.key.count == 27, token.key.prefix(7) == Data([2, 2, 9, 7, 4, 3, 0]) {
                return ethereumIDs[PolkadotIdentity.hex(token.key.suffix(20))]
            }
            if token.pallet == "ForeignAssets", token.key == Data([2, 1, 9, 7, 4]) { return "ethereum" }
            return nil
        }
        guard tokens.count <= 10_000, Set(tokens.map(\.reference)).count == tokens.count else { throw PolkadotError.malformed }
        let mapping = Dictionary(uniqueKeysWithValues: tokens.compactMap { token in id(token).map { (token.reference, $0) } })
        let known = tokens.filter { mapping[$0.reference] != nil }, ids = Set(mapping.values).sorted()
        guard !ids.isEmpty else { return [] }
        let quotes = try await withThrowingTaskGroup(of: Result<[String: (usd: String, source: String)], Error>.self) { group in
            var next = 0, result: [String: (usd: String, source: String)] = [:]
            var failure: (any Error)?
            func enqueue() {
                guard next < ids.count else { return }
                let chunk = Array(ids[next..<min(ids.count, next + 80)]); next += chunk.count
                group.addTask {
                    do { return .success(try await self.priceBatch(chunk)) }
                    catch {
                        OathDiagnostics.record(error, component: "prices", operation: "polkadot_price_batch", context: ["chain": "polkadot"])
                        return .failure(error)
                    }
                }
            }
            for _ in 0..<min(4, (ids.count + 79) / 80) { enqueue() }
            for try await batch in group {
                try Task.checkCancellation()
                switch batch {
                case .success(let values): result.merge(values) { _, new in new }
                case .failure(let error):
                    if error is CancellationError { throw error }
                    failure = error
                }
                enqueue()
            }
            if result.isEmpty, let failure { throw failure }
            return result
        }
        return known.compactMap { token in
            quotes[mapping[token.reference]!].map { .init(reference: token.reference, usd: $0.usd, source: $0.source, observedAt: .now) }
        }
    }
    private func priceBatch(_ ids: [String]) async throws -> [String: (usd: String, source: String)] {
        var values: [String: String] = [:], source = "CoinGecko"
        do {
            var url = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
            url.queryItems = [.init(name: "ids", value: ids.joined(separator: ",")), .init(name: "vs_currencies", value: "usd")]
            let data = try await read(url.url!)
            for id in ids { if let price = TonMarkets.positive(data[id]["usd"]) { values[id] = price } }
        } catch {
            try Task.checkCancellation(); if error is CancellationError { throw error }
            OathDiagnostics.record(error, component: "prices", operation: "polkadot_price_fallback", context: ["chain": "polkadot"])
        }
        let missing = ids.filter { values[$0] == nil }
        if !missing.isEmpty {
            do {
                let keys = missing.map { "coingecko:" + $0 }.joined(separator: ",")
                let data = try await read(URL(string: "https://coins.llama.fi/prices/current/" + keys)!)
                for id in missing { if let price = TonMarkets.positive(data["coins"]["coingecko:" + id]["price"]) { values[id] = price } }
                source = "CoinGecko / DefiLlama"
            } catch {
                try Task.checkCancellation(); if error is CancellationError { throw error }
                OathDiagnostics.record(error, component: "prices", operation: "polkadot_partial_prices", context: ["chain": "polkadot"])
                if values.isEmpty { throw error }
            }
        }
        return values.mapValues { (usd: $0, source: source) }
    }
}

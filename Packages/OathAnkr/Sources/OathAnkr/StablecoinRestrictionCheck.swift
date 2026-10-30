import Foundation
import OathDiagnostics

/// Read-only probes. The durable scheduler owns once-only semantics; this actor
/// owns decoding/network work, away from MainActor. No balance or signing path.
public actor StablecoinRestrictionCheck {
    private let endpoints: [String: URL]
    private let transport: any AnkrTransport
    public init(endpoints: [String: URL], transport: any AnkrTransport = AnkrHTTPTransport()) {
        self.endpoints = endpoints; self.transport = transport
    }
    enum Failure: Error { case configuration, malformed, wrongNetwork, http(Int), rpc(Int), provider }
    typealias JSON = SolanaJSON

    public func check(_ account: StablecoinRestrictionAccount,
                      tokens: [StablecoinRestrictionToken]) async -> [StablecoinRestrictionResult] {
        await OathDiagnostics.$operationID.withValue(UUID()) {
            await OathDiagnostics.$chain.withValue(account.network) {
                do {
                    guard tokens.allSatisfy({ $0.network == account.network && StablecoinRestrictionRegistry.tokens.contains($0) }),
                          let endpoint = endpoints[account.network], endpoint.scheme == "https" else { throw Failure.configuration }
                    try await verify(account, endpoint)
                    return await withTaskGroup(of: StablecoinRestrictionResult.self) { group in
                        for token in tokens {
                            group.addTask {
                                do {
                                    let blocked = try await self.probeWithRecovery(account, token, endpoint)
                                    return .init(token: token, outcome: blocked ? .restricted : .notDetected)
                                } catch {
                                    OathDiagnostics.record(error, component: "stablecoin_security", operation: "restriction_probe",
                                                           context: ["chain": account.network, "stage": "token_policy"])
                                    return .init(token: token, outcome: .unavailable)
                                }
                            }
                        }
                        var results: [StablecoinRestrictionResult] = []
                        for await result in group { results.append(result) }
                        return results.sorted { $0.token.id < $1.token.id }
                    }
                } catch {
                    OathDiagnostics.record(error, component: "stablecoin_security", operation: "network_identity",
                                           context: ["chain": account.network, "stage": "network_check"])
                    return tokens.map { .init(token: $0, outcome: .unavailable) }
                }
            }
        }
    }

    private func probeWithRecovery(_ account: StablecoinRestrictionAccount,
                                   _ token: StablecoinRestrictionToken, _ endpoint: URL) async throws -> Bool {
        try Task.checkCancellation()
        do {
            let result = try await probe(account, token, endpoint)
            try Task.checkCancellation()
            return result
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            // Only a transient Solana read failure can switch providers. Never
            // recover wrong-network, malformed or mismatched-account evidence.
            guard account.network == "solana", Self.isTransientPolicyRead(error),
                  let fallback = Self.publicMainnetEndpoints["solana"], fallback != endpoint else { throw error }
            OathDiagnostics.record(error, component: "stablecoin_security", operation: "restriction_fallback",
                                   context: ["chain": "solana", "stage": "token_policy"])
            try await verify(account, fallback)
            try Task.checkCancellation()
            let result = try await probe(account, token, fallback)
            try Task.checkCancellation()
            return result
        }
    }

    private static func isTransientPolicyRead(_ error: Error) -> Bool {
        if error as? AnkrError == .transport { return true }
        if let error = error as? URLError {
            return [.timedOut, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
                    .networkConnectionLost, .notConnectedToInternet].contains(error.code)
        }
        switch error {
        case Failure.http(429), Failure.http(500...599): return true
        case Failure.rpc(let code): return [429, -32005, -32016, -32429].contains(code)
        default: return false
        }
    }

    func request(_ url: URL, _ body: JSON? = nil) async throws -> JSON {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, status) = try await DiagnosticHTTP.$publicAccountPolicyProbe.withValue(true) {
            try await transport.send(request)
        }
        guard data.count <= 4 * 1024 * 1024 else { throw Failure.malformed }
        if DiagnosticHTTP.expectedClioHolderAbsence(data, status: status, request: request) { return .null }
        if !(200..<300).contains(status) {
            // Alternative decoding only recognizes the documented absent Stellar
            // account. Other error bodies need not be JSON; preserve HTTP failure.
            if status == 404, let json = try? JSONDecoder().decode(JSON.self, from: data),
               json["status"].integer == 404,
               json["type"].string == "https://stellar.org/horizon-errors/not_found" { return .null }
            throw Failure.http(status)
        }
        return try JSONDecoder().decode(JSON.self, from: data)
    }
    func rpc(_ url: URL, _ method: String, _ params: JSON = .array([])) async throws -> JSON {
        let json = try await request(url, .object(["jsonrpc": .string("2.0"), "id": .number("1"),
                                                 "method": .string(method), "params": params]))
        // TON Center v2 returns its documented {ok,result} envelope even on
        // /jsonRPC. Accept this only for that provider; chain/result validation
        // remains identical to the existing Ankr TON adapter.
        if url.host == "toncenter.com", url.path == "/api/v2/jsonRPC" {
            guard json["ok"] == .bool(true), !json["result"].isNull else { throw Failure.provider }
            return json["result"]
        }
        guard json["id"].text == "1", json["jsonrpc"].string == "2.0" else { throw Failure.malformed }
        if !json["error"].isNull {
            throw Failure.rpc(json["error"]["code"].text.flatMap(Int.init) ?? -1)
        }
        guard !json["result"].isNull else { throw Failure.malformed }
        return json["result"]
    }
    func xrpl(_ url: URL, _ method: String, _ params: [String: JSON]) async throws -> JSON {
        let json = try await request(url, .object(["method": .string(method), "params": .array([.object(params)])]))
        let result = json["result"]
        guard result["status"].string == "success", result["error"].isNull else { throw Failure.provider }
        return result
    }
    func verify(_ account: StablecoinRestrictionAccount, _ url: URL) async throws {
        let address = account.address
        if let chainID = StablecoinRestrictionRegistry.evmIDs[account.network] {
            guard address.count == 42, address.hasPrefix("0x"), address.dropFirst(2).allSatisfy(\.isHexDigit) else { throw Failure.malformed }
            let result = try await rpc(url, "eth_chainId")
            guard let raw = result.string, raw.hasPrefix("0x"), UInt64(raw.dropFirst(2), radix: 16) == chainID else { throw Failure.wrongNetwork }
            return
        }
        switch account.network {
        case "solana":
            guard SolanaIdentity.isAddress(address) else { throw Failure.malformed }
            guard try await rpc(url, "getGenesisHash").string == SolanaIdentity.genesis else { throw Failure.wrongNetwork }
        case "near":
            _ = try NearIdentity.address(address)
            // Ankr disables status, but serves the same genesis configuration
            // used by Oath's NEAR client. Both paths verify mainnet explicitly.
            let paid = url.host == "rpc.ankr.com"
            guard try await rpc(url, paid ? "EXPERIMENTAL_genesis_config" : "status",
                                paid ? .object([:]) : .array([]))["chain_id"].string == "mainnet" else {
                throw Failure.wrongNetwork
            }
        case "aptos":
            _ = try AptosIdentity.address(address)
            guard try await request(url)["chain_id"].integer == 1 else { throw Failure.wrongNetwork }
        case "tron":
            guard TronIdentity.isAddress(address) else { throw Failure.malformed }
            let genesis = try await request(url.appendingPathComponent("wallet/getblockbynum"), .object(["num": .number("0")]))
            guard genesis["blockID"].string == TronSendNetwork.mainnet.genesisID else { throw Failure.wrongNetwork }
        case "stellar":
            _ = try StellarIdentity.address(address)
            guard try await request(url)["network_passphrase"].string == "Public Global Stellar Network ; September 2015" else { throw Failure.wrongNetwork }
        case "xrpl":
            _ = try XrplIdentity.address(address)
            let info = try await xrpl(url, "server_info", [:])["info"]
            guard info["network_id"].isNull || info["network_id"].integer == 0 else { throw Failure.wrongNetwork }
        case "ton":
            _ = try TonIdentity.raw(address)
            guard try await rpc(url, "getMasterchainInfo", .object([:]))["init"]["root_hash"].string == TonIdentity.genesis else { throw Failure.wrongNetwork }
        case "sui":
            _ = try SuiIdentity.address(address)
            _ = try await suiQuery(url, "{chainIdentifier}", [:])
        default: throw Failure.configuration
        }
    }
    func probe(_ account: StablecoinRestrictionAccount, _ token: StablecoinRestrictionToken, _ url: URL) async throws -> Bool {
        if StablecoinRestrictionRegistry.evmIDs[account.network] != nil {
            let data = "0x" + TronSendCrypto.hex(Data(TronSendCrypto.keccak(Data(token.method.utf8)).prefix(4)))
                + String(repeating: "0", count: 24) + account.address.dropFirst(2)
            let result = try await rpc(url, "eth_call", .array([
                .object(["to": .string(token.reference), "data": .string(data)]), .string("latest")]))
            return try Self.abiBool(result)
        }
        switch account.network {
        case "solana":
            let result = try await rpc(url, "getTokenAccountsByOwner", .array([.string(account.address),
                .object(["mint": .string(token.reference)]), .object(["encoding": .string("jsonParsed"), "commitment": .string("finalized")])]))
            return try Self.solanaFrozen(result, owner: account.address, mint: token.reference)
        case "near":
            let args = try JSONEncoder().encode(JSON.object(["account_id": .string(account.address)]))
            let result = try await rpc(url, "query", .object(["request_type": .string("call_function"), "finality": .string("final"),
                "account_id": .string(token.reference), "method_name": .string(token.method), "args_base64": .string(args.base64EncodedString())]))
            guard let bytes = result["result"].array, bytes.count <= 128,
                  bytes.allSatisfy({ $0.integer.map { $0 <= 255 } == true }) else { throw Failure.malformed }
            let decoded = try JSONDecoder().decode(JSON.self, from: Data(bytes.map { UInt8($0.integer!) }))
            if token.symbol == "USDC" { return try Self.boolean(decoded) }
            guard let status = decoded.string, ["Allowable", "Banned"].contains(status) else { throw Failure.malformed }
            return status == "Banned"
        case "aptos":
            let result = try await request(url.appendingPathComponent("view"), .object(["function": .string(token.method),
                "type_arguments": .array([]), "arguments": .array([.string(account.address)])]))
            return try Self.aptosRestricted(result, symbol: token.symbol)
        case "tron":
            let parameter = String(repeating: "0", count: 24) + TronSendCrypto.hex(try TronIdentity.bytes(account.address).dropFirst())
            let result = try await request(url.appendingPathComponent("walletsolidity/triggerconstantcontract"), .object([
                "owner_address": .string(account.address), "contract_address": .string(token.reference),
                "function_selector": .string(token.method), "parameter": .string(parameter), "visible": .bool(true)]))
            guard result["result"]["result"] == .bool(true), let values = result["constant_result"].array, values.count == 1,
                  let raw = values[0].string else { throw Failure.provider }
            return try Self.abiBool(.string("0x" + raw))
        case "stellar":
            let result = try await request(url.appendingPathComponent("accounts").appendingPathComponent(account.address))
            if result.isNull { return false }
            return try Self.stellarRestricted(result, owner: account.address, token: token)
        case "xrpl": return try await xrplRestricted(account, token, url)
        case "ton": return try await tonRestricted(account, token, url)
        case "sui": return try await suiRestricted(account, token, url)
        default: throw Failure.configuration
        }
    }
    static func boolean(_ json: JSON) throws -> Bool {
        guard case .bool(let value) = json else { throw Failure.malformed }; return value
    }
    static func aptosRestricted(_ json: JSON, symbol: String) throws -> Bool {
        // Tether's deployed view returns (freeze_sending, freeze_receiving).
        // Circle returns a single account blocklist boolean.
        guard let values = json.array, values.count == (symbol == "USDT" ? 2 : 1) else { throw Failure.malformed }
        let flags = try values.map(boolean)
        return flags.contains(true)
    }
    static func abiBool(_ json: JSON) throws -> Bool {
        guard let raw = json.string, raw.count == 66, raw.hasPrefix("0x"),
              raw.dropFirst(2).dropLast().allSatisfy({ $0 == "0" }), let last = raw.last, last == "0" || last == "1" else { throw Failure.malformed }
        return raw.last == "1"
    }
    static func solanaFrozen(_ json: JSON, owner: String, mint: String) throws -> Bool {
        guard json["context"]["slot"].integer != nil, let rows = json["value"].array, rows.count <= 4096 else { throw Failure.malformed }
        var frozen = false, seen = Set<String>()
        for row in rows {
            let account = row["account"], parsed = account["data"]["parsed"], info = parsed["info"]
            guard let id = row["pubkey"].string, SolanaIdentity.isAddress(id), seen.insert(id).inserted,
                  account["owner"].string == SolanaIdentity.tokenProgram,
                  parsed["type"].string == "account", info["owner"].string == owner, info["mint"].string == mint,
                  let state = info["state"].string, ["initialized", "frozen"].contains(state) else { throw Failure.malformed }
            // Include zero-balance accounts; receiving may still be restricted.
            frozen = frozen || state == "frozen"
        }
        return frozen
    }
    static func stellarRestricted(_ json: JSON, owner: String, token: StablecoinRestrictionToken) throws -> Bool {
        guard json["account_id"].string == owner, let balances = json["balances"].array else { throw Failure.malformed }
        var restricted = false
        for balance in balances where balance["asset_issuer"].string == token.reference && balance["asset_code"].string == token.method {
            restricted = try !boolean(balance["is_authorized"]) || restricted
        }
        return restricted
    }
}

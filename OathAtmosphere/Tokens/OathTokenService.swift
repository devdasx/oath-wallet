import OathDiagnostics
import Foundation
import OathAnkr

/// A Sendable JSON tree keeps provider data out of untyped actor boundaries.
indirect enum OathTokenJSON: Codable, Sendable, Equatable {
    case object([String: Self]), array([Self]), string(String), number(Double), bool(Bool), null
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> Self { if case .object(let v) = self { v[key] ?? .null } else { .null } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var array: [Self]? { if case .array(let v) = self { v } else { nil } }
    var int: Int? {
        guard case .number(let v) = self, v.isFinite, v.rounded() == v, v >= 0, v < Double(Int.max) else { return nil }
        return Int(v)
    }
}

protocol OathTokenLookingUp: Sendable {
    func lookup(address: String, network: OathTokenNetwork) async throws -> OathTokenDefinition
}

private final class OathTokenNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // RPC credentials are in the URL. Never forward them to a redirect.
        completionHandler(nil)
    }
}

actor OathTokenService: OathTokenLookingUp {
    // Internal routing marker only. Callers and the failure cache receive the
    // original error, so availability filtering cannot lose its domain/code.
    private struct ProviderFailure: DiagnosticCausalError {
        let cause: any Error
        var diagnosticCause: (any Error)? { cause }
    }
    static let shared = OathTokenService(configuration: .bundled())
    private let configuration: OathTokenRPCConfiguration
    private let session: URLSession
    private var verified: [String: Date] = [:]
    private var cache: [String: (Date, OathTokenDefinition)] = [:]
    private var lookupFlights: [String: Task<OathTokenDefinition, Error>] = [:]
    private var absent: [String: Date] = [:]
    private var failures: [String: (Date, any Error)] = [:]

    init(configuration: OathTokenRPCConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 18
            config.httpMaximumConnectionsPerHost = 6
            config.httpCookieStorage = nil
            config.urlCache = nil
            self.session = URLSession(configuration: config, delegate: OathTokenNoRedirect(), delegateQueue: nil)
        }
    }

    func lookup(address: String, network: OathTokenNetwork) async throws -> OathTokenDefinition {
        try Task.checkCancellation()
        let address = try OathTokenAddress.canonical(address, network: network)
        let key = network.id + ":" + (network.chain.isEVM ? address.lowercased() : address)
        if let (date, value) = cache[key], Date().timeIntervalSince(date) < 300 { return value }
        if let date = absent[key], Date().timeIntervalSince(date) < 300 { throw OathTokenLookupError.notToken }
        if let (date, error) = failures[key], Date().timeIntervalSince(date) < 30 { throw error }
        let task: Task<OathTokenDefinition, Error>
        if let flight = lookupFlights[key] { task = flight }
        else {
            guard lookupFlights.count < 16 else { throw OathTokenLookupError.unavailable }
            task = Task { try await self.loadAndCacheToken(address: address, network: network, key: key) }
            lookupFlights[key] = task
        }
        let token = try await task.value
        try Task.checkCancellation()
        return token
    }

    private func loadAndCacheToken(address: String, network: OathTokenNetwork, key: String) async throws -> OathTokenDefinition {
        do { return try await loadToken(address: address, network: network, key: key) }
        catch {
            // Report once for the shared request before caching the failure.
            // A verified absent token remains an expected search result.
            if error as? OathTokenLookupError != .notToken {
                OathDiagnostics.record(error, component: "token_lookup", operation: "lookup", context: ["chain": network.id])
            }
            if let failure = error as? OathTokenLookupError, failure != .notToken {
                cacheFailure(failure, key: key)
            }
            throw error
        }
    }

    private func cacheFailure(_ error: any Error, key: String) {
        if failures.count >= 128 { failures.removeAll(keepingCapacity: true) }
        failures[key] = (.now, error)
    }

    private func loadToken(address: String, network: OathTokenNetwork, key: String) async throws -> OathTokenDefinition {
        defer { lookupFlights[key] = nil }
        if network.chain == .polkadot {
            let metadata = try await PolkadotClient().currentMetadata(reference: address)
            let token = OathTokenDefinition(network: network, address: metadata.reference, name: metadata.name, symbol: metadata.symbol, decimals: metadata.decimals, standard: "Asset Hub", logoURL: nil)
            try Task.checkCancellation()
            if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
            cache[key] = (.now, token); return token
        }
        let endpoints = configuration.endpoints(for: network)
        guard !endpoints.isEmpty else { throw OathTokenLookupError.configurationMissing }
        for (index, endpoint) in endpoints.enumerated() {
            do {
                try await verify(network, endpoint: endpoint)
                let token: OathTokenDefinition
                if network.chain == .solana { token = try await solana(address, network: network, endpoint: endpoint) }
                else { token = try await evm(address, network: network, endpoint: endpoint) }
                try Task.checkCancellation()
                if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
                cache[key] = (Date(), token)
                return token
            } catch OathTokenLookupError.notToken {
                // diagnostics: token-search-absence. Cache a verified absence
                // so revisiting the same query does not probe every chain again.
                if absent.count >= 128 { absent.removeAll(keepingCapacity: true) }
                absent[key] = .now
                throw OathTokenLookupError.notToken
            } catch let failure as ProviderFailure {
                OathDiagnostics.record(failure.cause, component: "token_lookup", operation: "provider_request",
                    context: ["chain": network.id])
                guard index + 1 < endpoints.count else {
                    // These failures previously cached `.unavailable`. Keep
                    // that cooldown, while retaining its actual provider cause.
                    if !Task.isCancelled { cacheFailure(failure.cause, key: key) }
                    throw failure.cause
                }
            } catch OathTokenLookupError.unavailable where index + 1 < endpoints.count { continue }
        }
        throw OathTokenLookupError.unavailable
    }

    /// All entry points for adding catalog results share this exact metadata
    /// resolution path. Known scales never trigger another directory request.
    func resolveForAdding(_ token: OathTokenDefinition, owner: String? = nil,
                          catalog: TokenDiscoveryCatalog = .shared) async throws -> OathTokenDefinition {
        if token.decimals != nil { return token }
        if let (date, saved) = cache[token.id], Date().timeIntervalSince(date) < 300 { return saved }
        let decimals: Int
        do {
            let entry = try await catalog.resolve(network: token.network.id, reference: token.reference)
            guard let value = entry.decimals else { throw OathTokenLookupError.metadataUnavailable }
            decimals = value
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if case TokenDiscoveryError.metadataMissing = error {
                // Missing optional catalog decimals use the normal chain read.
            } else { OathDiagnostics.record(error, component: "token_lookup", operation: "catalog_metadata_fallback") }
            if token.network.chain.isEVM || [.solana, .tron].contains(token.network.chain) {
                return try await lookup(address: token.address, network: token.network)
            }
            do { decimals = try await configuration.discoveryDecimals(network: token.network, reference: token.reference, owner: owner) }
            catch {
                OathDiagnostics.record(error, component: "token_lookup", operation: "chain_metadata", context: ["chain": token.network.id])
                throw error
            }
        }
        try Task.checkCancellation()
        let result = OathTokenDefinition(network: token.network, address: token.address, name: token.name,
            symbol: token.symbol, decimals: decimals, standard: token.standard, logoURL: token.logoURL)
        if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
        cache[token.id] = (.now, result)
        return result
    }

    private func verify(_ network: OathTokenNetwork, endpoint: URL) async throws {
        let verificationKey = network.id + "|" + endpoint.absoluteString
        if let date = verified[verificationKey], Date().timeIntervalSince(date) < 60 { return }
        if let expected = network.chainID {
            let result = try await call(endpoint, method: "eth_chainId")
            guard let raw = result.string, raw.hasPrefix("0x"), UInt64(raw.dropFirst(2), radix: 16) == expected else {
                throw OathTokenLookupError.wrongNetwork
            }
        } else {
            let result = try await call(endpoint, method: "getGenesisHash")
            guard result.string == "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d" else {
                throw OathTokenLookupError.wrongNetwork
            }
        }
        // Include endpoint identity: a fallback must independently prove its chain.
        verified[verificationKey] = Date()
    }

    private func evm(_ address: String, network: OathTokenNetwork, endpoint: URL) async throws -> OathTokenDefinition {
        let to = try OathTokenAddress.callAddress(address, network: network)
        let code = try await call(endpoint, method: "eth_getCode", params: [.string(to), .string("latest")])
        guard let rawCode = code.string, let bytes = OathTokenAddress.hex(rawCode) else { throw OathTokenLookupError.malformedResponse }
        guard !bytes.isEmpty || (network.chain == .arc && to.lowercased() == "0x3600000000000000000000000000000000000000") else {
            throw OathTokenLookupError.notToken
        }
        async let name = contract(endpoint, to: to, data: "0x06fdde03")
        async let symbol = contract(endpoint, to: to, data: "0x95d89b41")
        async let decimals = contract(endpoint, to: to, data: "0x313ce567")
        async let supply = contract(endpoint, to: to, data: "0x18160ddd")
        let values = try await (name, symbol, decimals, supply)
        _ = try OathTokenABI.word(values.3)
        return OathTokenDefinition(network: network, address: address,
            name: try OathTokenABI.string(values.0), symbol: try OathTokenABI.string(values.1),
            decimals: try OathTokenABI.decimals(values.2), standard: network.chain == .tron ? "TRC-20" : "ERC-20",
            logoURL: artwork(address, network: network))
    }

    private func solana(_ address: String, network: OathTokenNetwork, endpoint: URL) async throws -> OathTokenDefinition {
        let account = try await call(endpoint, method: "getAccountInfo", params: [.string(address),
            .object(["encoding": .string("jsonParsed"), "commitment": .string("confirmed")])])["value"]
        guard account != .null else { throw OathTokenLookupError.notToken }
        let owner = account["owner"].string
        guard [OathSolanaMetadata.tokenProgram, OathSolanaMetadata.token2022Program].contains(owner),
              account["executable"] == .bool(false), account["data"]["parsed"]["type"].string == "mint" else {
            throw OathTokenLookupError.notToken
        }
        let info = account["data"]["parsed"]["info"]
        guard info["isInitialized"] == .bool(true), let decimals = info["decimals"].int,
              (0...255).contains(decimals), let supply = info["supply"].string,
              !supply.isEmpty, supply.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw OathTokenLookupError.malformedResponse
        }
        var metadata: (name: String, symbol: String)?
        if owner == OathSolanaMetadata.token2022Program {
            for item in info["extensions"].array ?? [] where item["extension"].string == "tokenMetadata" {
                let state = item["state"]
                guard state["mint"].string == address, let name = state["name"].string, let symbol = state["symbol"].string else {
                    throw OathTokenLookupError.malformedResponse
                }
                metadata = try (OathTokenABI.clean(name), OathTokenABI.clean(symbol))
            }
        }
        if metadata == nil {
            let candidates = try OathSolanaMetadata.candidates(mint: address)
            // Most mints resolve in the first batch. Bounded batches exhaust
            // all possible bumps for absent metadata without an indexer scan.
            var offset = 0
            while offset < candidates.count && metadata == nil {
                try Task.checkCancellation()
                let count = offset == 0 ? 8 : min(96, candidates.count - offset)
                let batch = Array(candidates[offset..<(offset + count)])
                let result = try await call(endpoint, method: "getMultipleAccounts", params: [.array(batch.map { .string($0) }),
                    .object(["encoding": .string("base64"), "commitment": .string("confirmed")])])
                guard let accounts = result["value"].array, accounts.count == batch.count else { throw OathTokenLookupError.malformedResponse }
                for account in accounts where account["owner"].string == OathSolanaMetadata.program {
                    guard account["executable"] == .bool(false), let encoded = account["data"].array?.first?.string,
                          let data = Data(base64Encoded: encoded) else { throw OathTokenLookupError.malformedResponse }
                    metadata = try OathSolanaMetadata.decode(data, mint: address)
                    break
                }
                offset += count
            }
        }
        guard let metadata else { throw OathTokenLookupError.metadataUnavailable }
        return OathTokenDefinition(network: network, address: address, name: metadata.name, symbol: metadata.symbol,
            decimals: decimals, standard: owner == OathSolanaMetadata.token2022Program ? "Token-2022" : "SPL Token",
            logoURL: artwork(address, network: network))
    }

    private func artwork(_ address: String, network: OathTokenNetwork) -> URL? {
        URL(string: "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/\(network.artworkDirectory)/assets/\(address)/logo.png")
    }

    private func contract(_ endpoint: URL, to: String, data: String) async throws -> String {
        let result = try await DiagnosticHTTP.$optionalEVMMetadataProbe.withValue(true) {
            try await call(endpoint, method: "eth_call", params: [.object(["to": .string(to), "data": .string(data)]), .string("latest")])
        }
        guard let value = result.string else { throw OathTokenLookupError.malformedResponse }
        guard value != "0x" else { throw OathTokenLookupError.notToken }
        return value
    }

    func call(_ endpoint: URL, method: String, params: [OathTokenJSON] = []) async throws -> OathTokenJSON {
        try Task.checkCancellation()
        let id = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OathTokenJSON.object([
            "jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .array(params)]))
        let data: Data, response: URLResponse
        do { (data, response) = try await DiagnosticHTTP.data(for: request, session: session) }
        catch {
            OathDiagnostics.record(error)
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw ProviderFailure(cause: error)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw ProviderFailure(cause: URLError(.badServerResponse))
        }
        guard http.statusCode == 200 else {
            throw ProviderFailure(cause: NSError(domain: "Oath.HTTP", code: http.statusCode))
        }
        guard data.count <= 1_048_576, let json = try? JSONDecoder().decode(OathTokenJSON.self, from: data),
              case .object(let fields) = json, json["jsonrpc"].string == "2.0", json["id"].string == id else {
            throw OathTokenLookupError.malformedResponse
        }
        if let error = fields["error"] {
            guard fields["result"] == nil, case .object = error,
                  case .number(let code) = error["code"], code.isFinite, code.rounded() == code,
                  code >= Double(Int.min), code < Double(Int.max),
                  error["message"].string != nil else { throw OathTokenLookupError.malformedResponse }
            // Only an explicit, correlated revert from an exact metadata read
            // proves absence. Outages, wrong IDs and other RPC methods do not.
            if DiagnosticHTTP.optionalEVMMetadataProbe,
               DiagnosticHTTP.expectedEVMMetadataAbsence(data, status: http.statusCode, request: request) {
                throw OathTokenLookupError.notToken
            }
            // Preserve the original RPC code as well as HTTP/transport causes.
            // Shared filtering owns the untrusted provider message.
            throw ProviderFailure(cause: NSError(domain: "Oath.Provider", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(error["message"].string!.prefix(1024))]))
        }
        guard let result = fields["result"] else { throw OathTokenLookupError.malformedResponse }
        return result
    }
}

import Foundation
import OathDiagnostics

/// Shared paid routes for Vault's public account checks. The caller supplies
/// its existing local key; no credential value is checked into source or logged.
public enum PublicCheckProviders {
    public enum Failure: Error { case missingAPIKey }
    public static func endpoints(ankrAPIKey key: String) throws -> [String: URL] {
        guard !key.isEmpty, key.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }) else { throw Failure.missingAPIKey }
        var result = StablecoinRestrictionCheck.publicMainnetEndpoints
        let paths = [
            "ethereum": "eth", "bnb": "bsc", "arbitrum": "arbitrum", "avalanche": "avalanche",
            "base": "base", "optimism": "optimism", "polygon": "polygon", "gnosis": "gnosis",
            "linea": "linea", "scroll": "scroll", "taiko": "taiko", "telos": "telos",
            "xlayer": "xlayer", "fantom": "fantom", "flare": "flare", "somnia": "somnia_mainnet",
            "story": "story_mainnet", "monad": "monad_mainnet", "unichain": "unichain_mainnet", "chiliz": "chiliz", "celo": "celo",
            "hyperevm": "hyperevm", "robinhood": "robinhood_mainnet",
            "solana": "solana", "near": "near", "xrpl": "xrp_mainnet", "ton": "ton_api_v2",
            "tron": "premium-http/tron", "aptos": "premium-http/aptos", "sui": "premium-http/sui_graphql"
        ]
        for (chain, path) in paths {
            result[chain] = URL(string: "https://rpc.ankr.com/" + path)!.appendingPathComponent(key)
        }
        result["aptos"] = result["aptos"]!.appendingPathComponent("v1")
        // Horizon account/threshold APIs are separate from Soroban JSON-RPC.
        // Arc and THORChain keep their existing, chain-verified public adapters.
        return result
    }
}

/// One shared connection pool and request budget for both check queues.
/// Wallets/chains can overlap without creating thousands of sockets. Failures
/// propagate to the checker; this transport never repeats an account probe.
public actor PublicCheckTransport: AnkrTransport {
    private let base: any AnkrTransport
    private let total: AnkrPermits
    private var hosts: [String: AnkrPermits] = [:]
    private struct Cached {
        let value: Data
        let expires: ContinuousClock.Instant
    }
    private var metadata: [String: Cached] = [:]

    public init(maximumRequests: Int = 128, transport: (any AnkrTransport)? = nil) {
        total = AnkrPermits(count: min(128, max(1, maximumRequests)))
        base = transport ?? AnkrHTTPTransport(maximumConnectionsPerHost: 64)
    }

    public func send(_ input: URLRequest) async throws -> (Data, Int) {
        try Task.checkCancellation()
        var request = input
        request.setValue("OathVault/1.0", forHTTPHeaderField: "User-Agent")
        let key = metadataKey(request)
        if let key, let cached = metadata[key], cached.expires > .now { return (cached.value, 200) }
        let host = request.url?.host ?? ""
        let gate = hosts[host] ?? AnkrPermits(count: host == "rpc.ankr.com" ? 128 : 4)
        hosts[host] = gate
        try await gate.acquire()
        do {
            try await total.acquire()
        } catch {
            await gate.release()
            OathDiagnostics.record(error, component: "multisig", operation: "public_check_capacity")
            throw error
        }
        do {
            try Task.checkCancellation()
            // A preceding request may have populated metadata while this one
            // waited for capacity. Account requests never enter this branch.
            if let key, let cached = metadata[key], cached.expires > .now {
                await total.release(); await gate.release()
                return (cached.value, 200)
            }
            let result = try await base.send(request)
            try Task.checkCancellation()
            await total.release(); await gate.release()
            // Only tiny, successful network metadata; never cache account or
            // token results, errors or provider response bodies in diagnostics.
            if let key, result.1 == 200, result.0.count < 4096,
               let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
               json["error"] == nil, json["result"] != nil {
                metadata = metadata.filter { $0.value.expires > .now }
                if metadata.count < 128 {
                    metadata[key] = .init(value: result.0, expires: .now.advanced(by: .seconds(5)))
                }
            }
            return result
        } catch {
            await total.release(); await gate.release()
            OathDiagnostics.record(error, component: "multisig", operation: "public_check_transport")
            throw error
        }
    }

    private func metadataKey(_ request: URLRequest) -> String? {
        guard let url = request.url, let body = request.httpBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String,
              ["eth_chainId", "eth_blockNumber", "getGenesisHash", "getMasterchainInfo", "status",
               "EXPERIMENTAL_genesis_config"].contains(method),
              json["id"] != nil,
              let canonical = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return nil }
        // Object key order is immaterial. Preserve exact id/params while
        // coalescing equivalent requests from independently encoded clients.
        return url.absoluteString + ":" + canonical.base64EncodedString()
    }
}

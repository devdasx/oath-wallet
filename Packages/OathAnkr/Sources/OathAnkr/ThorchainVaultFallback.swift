import Foundation
import OathDiagnostics

extension ThorchainClient {
    func recoverVaultMarkets() async throws -> [SolanaJSON] {
        do { return try await vaultMarkets() }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            switch error {
            case DiagnosticDeferral.publicMarketCooldown: break // Independent node reads can still proceed.
            case ThorchainError.rateLimited, ThorchainError.transport,
                 ThorchainError.http(429), ThorchainError.http(500), ThorchainError.http(502),
                 ThorchainError.http(503), ThorchainError.http(504): break
            default: throw error
            }
            OathDiagnostics.record(error, component: "ThorchainClient", operation: "vault_node_fallback",
                context: ["chain": "thorchain", "source": "Rujira"])
            return try await nodeVaultMarkets()
        }
    }

    // Official chain registry and CosmWasm queries, independent of the Rujira
    // indexer's rate bucket. No wallet address, signing or broadcast is involved.
    // RujiraNetwork/rujira_ex: deployments.ex and ghost/vault/{status,config}.
    func nodeVaultMarkets() async throws -> [SolanaJSON] {
        let registry = try await read(Self.node, path: "thorchain/contracts")
        guard let infos = registry["infos"].array, infos.count <= 10_000 else { throw ThorchainError.malformed }
        let addresses = try infos.filter { $0["contract"].string == "rujira-ghost-vault" }.map { row in
            guard let address = row["address"].string else { throw ThorchainError.malformed }
            return try ThorchainIdentity.address(address)
        }
        guard addresses.count <= 100, Set(addresses).count == addresses.count else { throw ThorchainError.incomplete }
        var rows: [SolanaJSON] = []
        // At most four reads in flight. A broken vault cannot erase prices for
        // other vaults; each failure is recorded at its own recovery boundary.
        for start in stride(from: 0, to: addresses.count, by: 2) {
            let batch = Array(addresses[start..<min(start + 2, addresses.count)])
            let values = await withTaskGroup(of: SolanaJSON?.self, returning: [SolanaJSON].self) { group in
                for address in batch {
                    group.addTask {
                        await OathDiagnostics.attempt("thorchain_vault_node_read") {
                            async let config = read(Self.node, path: Self.vaultQueryPath(address, kind: "config"))
                            async let status = read(Self.node, path: Self.vaultQueryPath(address, kind: "status"))
                            return try await Self.decodeNodeVault(config: config["data"], status: status["data"])
                        }
                    }
                }
                var result: [SolanaJSON] = []
                for await value in group { if let value { result.append(value) } }
                return result
            }
            try Task.checkCancellation()
            rows += values
        }
        return rows
    }

    static func vaultQueryPath(_ address: String, kind: String) -> String {
        let payload = Data("{\"\(kind)\":{}}".utf8).base64EncodedString()
        return "cosmwasm/wasm/v1/contract/" + address + "/smart/" + payload
    }

    static func decodeNodeVault(config: SolanaJSON, status: SolanaJSON, now: Date = .now) throws -> SolanaJSON {
        // An empty pool has no receipt valuation. It is optional coverage,
        // not a provider failure and must not generate diagnostics.
        if status["deposit_pool"]["shares"].text == "0" { return .null }
        guard let denom = config["denom"].string,
              let ratioText = TonMarkets.positive(status["deposit_pool"]["ratio"]),
              let ratio = Decimal(string: ratioText),
              let shares = TonMarkets.positive(status["deposit_pool"]["shares"]),
              let nanos = status["last_updated"].text.flatMap(Double.init), nanos.isFinite else { throw ThorchainError.malformed }
        _ = try ThorchainIdentity.reference(denom)
        let time = Date(timeIntervalSince1970: nanos / 1_000_000_000)
        guard now.timeIntervalSince(time) >= -60, now.timeIntervalSince(time) < 3600 else { throw ThorchainError.malformed }
        let scaled = ratio * 1_000_000_000_000
        guard !scaled.isNaN, NSDecimalNumber(decimal: scaled).doubleValue.isFinite else { throw ThorchainError.malformed }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // REST Decimal is unscaled; GraphQL Bigint is scaled 1e12. Convert once
        // so both paths use the same identity/precision checks at publication.
        return .object([
            "asset": .object(["variants": .object(["native": .object(["denom": .string(denom)])])]),
            "status": .object(["depositPool": .object(["ratio": .string(NSDecimalNumber(decimal: scaled).stringValue),
                "shares": .string(shares)]), "lastUpdated": .string(formatter.string(from: time))])
        ])
    }
}

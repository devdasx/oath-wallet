import Foundation
import OathDiagnostics

/// Last resort only. Each attempt has a dedicated TLS connection, a verified
/// genesis/BCH checkpoint and short timeouts. Never leases the history/recovery
/// pool or silently falls back to HTTP again, which could create retry loops.
enum UTXOServerFallback {
    private static func peers(_ network: UTXONetwork) -> [ElectrumServer] {
        // This peer quotes beyond the DOGE safety ceiling; use the other two.
        network == .dogecoin ? Array(network.servers.dropFirst()) : network.servers
    }
    private static func perform<Value: Sendable>(_ network: UTXONetwork, server: ElectrumServer,
        operation: @Sendable (ElectrumPool) async throws -> Value) async throws -> Value {
        let pool = ElectrumPool(servers: [server], maximumConnections: 1, network: network,
            transactionFallback: nil, requestTimeout: 2, makeTransport: { ElectrumWire(server: $0) })
        do {
            let result = try await operation(pool)
            await pool.close(); return result
        } catch {
            await pool.close()
            OathDiagnostics.record(error, component: "send", operation: "last_resort_server",
                context: ["chain": network.rawValue, "host": server.host])
            throw error
        }
    }
    static func fees(_ network: UTXONetwork) -> [UTXOFeeProvider.Source] {
        peers(network).enumerated().map { index, peer in
            .init(name: peer.host, delay: .milliseconds(index * 100)) {
                try await perform(network, server: peer) { try await $0.bitcoinFeeRate() }
            }
        }
    }
    static func broadcasts(_ network: UTXONetwork) -> [UTXOBroadcastProvider.Source] {
        peers(network).enumerated().map { index, peer in
            .init(name: peer.host, delay: .milliseconds(index * 100), submit: { hex in
                guard let raw = Data(hex: hex) else { throw BitcoinError.invalidResponse }
                return try await perform(network, server: peer) {
                    // An already-known error must go through exact-byte lookup.
                    try await $0.broadcastBitcoin(raw, acceptAlreadyKnown: false)
                }
            }, lookup: { txid in
                try await perform(network, server: peer) { try await $0.transactions(txids: [txid])[txid] }
            })
        }
    }
}

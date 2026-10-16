import Foundation
import GRDB
import OathAnkr

extension OathDatabase {
    /// Public metadata cache. No owner, wallet, balances or approval decisions.
    /// Catalog lookup intentionally includes sold, hidden and zero-balance assets.
    public func contractIdentities(network: String, addresses: [String]) async throws -> [ContractIdentity] {
        guard addresses.count <= 1_000 else { throw StoreError.invalidValue("identity count") }
        let refs = try Set(addresses.map { try ContractIdentity.canonical($0, network: network) })
        return try await pool.read { db in
            try refs.compactMap { address in
                let cached: ContractIdentity?
                if let data = try Data.fetchOne(db, sql: "SELECT identity FROM contractIdentities WHERE network=? AND address=?", arguments: [network, address]) {
                    cached = try JSONDecoder().decode(ContractIdentity.self, from: data)
                } else { cached = nil }
                if cached?.source == .onChain { return cached }
                let insensitive = EVMSendNetwork(rawValue: network) != nil || network == "arc"
                let clause = insensitive ? "reference=? COLLATE NOCASE" : "reference=?"
                guard let asset = try AssetRecord.fetchOne(db, sql: "SELECT * FROM assets WHERE networkID=? AND \(clause)", arguments: [network, address]),
                      let name = ContractIdentity.clean(asset.name), name != address,
                      !["unknown", "unknown token", "unknown contract"].contains(name.lowercased()) else { return cached }
                return try ContractIdentity(network: network, address: address, name: name, symbol: asset.symbol,
                                            decimals: asset.decimals, source: .catalog)
            }
        }
    }
    public func saveContractIdentities(_ identities: [ContractIdentity]) async throws {
        guard identities.count <= 1_000 else { throw StoreError.invalidValue("identity count") }
        try await pool.write { db in
            for identity in identities {
                // Revalidate decoded values too; Codable must not bypass bounds.
                let value = try ContractIdentity(network: identity.network, address: identity.address, name: identity.name,
                    symbol: identity.symbol, decimals: identity.decimals, source: identity.source, checkedAt: identity.checkedAt)
                try db.execute(sql: """
                    INSERT INTO contractIdentities(network,address,identity,checkedAt) VALUES(?,?,?,?)
                    ON CONFLICT(network,address) DO UPDATE SET identity=excluded.identity,checkedAt=excluded.checkedAt
                    WHERE excluded.checkedAt>=contractIdentities.checkedAt
                    """, arguments: [value.network, value.address, try JSONEncoder().encode(value), value.checkedAt.timeIntervalSince1970])
            }
            try db.execute(sql: "DELETE FROM contractIdentities WHERE rowid IN (SELECT rowid FROM contractIdentities ORDER BY checkedAt DESC LIMIT -1 OFFSET 4000)")
        }
    }
}

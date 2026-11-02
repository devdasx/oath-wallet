import OathDiagnostics
import Foundation
import OathDatabase

/// Shared, lazy bootstrap: no database opening, migration, or preferences I/O
/// occurs in a SwiftUI initializer. A failed open is retryable, never a reset.
actor OathDataEnvironment {
    static let shared = OathDataEnvironment()
    private var opening: Task<OathDatabase, Error>?

    func database() async throws -> OathDatabase {
        if let opening { return try await opening.value }
        let task = Task<OathDatabase, Error> {
            var namespace = OathInstallationSecurity.appNamespace
            #if DEBUG && targetEnvironment(simulator)
            if let scope = UserDefaults.standard.string(forKey: "oath.walletTestScope"), UUID(uuidString: scope) != nil {
                namespace = "org.oathwallet.tests." + scope
            }
            #endif
            let url = URL.applicationSupportDirectory.appendingPathComponent(namespace, isDirectory: true)
                .appendingPathComponent("Database", isDirectory: true).appendingPathComponent("oath.sqlite")
            let db = try await OathDatabase.open(at: url)
            // A pending reset fences wallet writes, including contact search
            // updates from network metadata triggers. Seed after its cleanup.
            if try await db.pendingWalletReset() == nil { try await Self.seed(db) }
            var legacy: [String: String] = [:]
            if let language = UserDefaults.standard.string(forKey: OathLanguagePreference.storageKey) {
                legacy["language"] = language
            }
            try await db.migrateLegacySettings(legacy)
            UserDefaults.standard.removeObject(forKey: OathLanguagePreference.storageKey)
            return db
        }
        opening = task
        do { return try await task.value }
        catch { OathDiagnostics.record(error); opening = nil; throw error }
    }

    static func seed(_ db: OathDatabase) async throws {
        let featured: [OathImportChain] = [.bitcoin, .ethereum, .solana, .bnb, .tron, .ton]
        let ordered = featured + OathImportChain.allCases.filter { !featured.contains($0) }.sorted { $0.name < $1.name }
        try await db.seed(networks: ordered.enumerated().map { index, chain in
            NetworkRecord(id: chain.id, name: chain.name, family: chain.isEVM ? "evm" : chain.isUTXO ? "utxo" : "account",
                          symbol: chain.ticker, decimals: chain.nativeDecimals, derivationPath: chain.walletPath,
                          logo: chain.logoAsset, sortOrder: index)
        }, assets: ordered.map { chain in
            AssetRecord(id: chain.id + ":native", networkID: chain.id, reference: "native", name: chain.name,
                        symbol: chain.ticker, decimals: chain.nativeDecimals, logo: chain.logoAsset)
        })
    }
}

extension OathImportChain {
    var isUTXO: Bool { [.bitcoin, .bitcoincash, .dogecoin, .litecoin].contains(self) }
    var nativeDecimals: Int {
        if isEVM { return 18 }
        switch self {
        case .bitcoin, .bitcoincash, .dogecoin, .litecoin, .aptos, .thorchain: return 8
        case .solana, .sui, .ton: return 9
        case .polkadot: return 10
        case .stellar: return 7
        case .tron, .xrpl: return 6
        case .near: return 24
        default: return 18
        }
    }
}

extension OathWalletProfile {
    static func stored(_ snapshot: WalletSnapshot) throws -> Self {
        guard let id = UUID(uuidString: snapshot.wallet.id) else {
            throw OathDiagnostics.failure(OathWalletError.corruptVault, reason: "invalid_stored_wallet_identity")
        }
        let addresses = snapshot.accounts.compactMap { account -> OathWalletAddress? in
            // A newer build can enroll chains this binary does not implement.
            // This is a display/capability projection, not vault validation:
            // retain every account in SQL and the full snapshot, and expose
            // only addresses whose chain this binary can operate safely.
            // Expected forward-compatible metadata is not a diagnostic error.
            OathWalletAddress.stored(account, network: snapshot.networks.first { $0.id == account.networkID })
        }
        return Self(id: id, addresses: addresses, createdAt: Date(timeIntervalSince1970: snapshot.wallet.createdAt),
                    backedUp: snapshot.wallet.backedUp)
    }
}

extension OathWalletAddress {
    static func stored(_ account: AccountRecord, network: NetworkRecord?) -> Self? {
        guard let chain = OathImportChain(rawValue: account.networkID) else { return nil }
        // Display labels are recoverable from the bundled catalogue. They do
        // not validate keys or addresses and must never make a vault unusable.
        if network == nil {
            OathDiagnostics.record(DiagnosticFailure("Missing stored network display metadata"),
                component: "wallet", operation: "stored_address", severity: "warning",
                context: ["chain": chain.rawValue, "stage": "display_metadata", "reason": "network_metadata_fallback"])
        }
        return Self(chain: chain, address: account.address, path: account.derivationPath,
                    accountIndex: account.accountIndex, accountID: account.id,
                    assetID: account.networkID + ":native", storedNetworkName: network?.name ?? chain.name,
                    storedTicker: network?.symbol ?? chain.ticker, storedLogo: network?.logo ?? chain.logoAsset)
    }
}

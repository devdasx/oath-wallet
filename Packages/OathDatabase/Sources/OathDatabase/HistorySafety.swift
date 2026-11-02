import OathDiagnostics
import Foundation
import GRDB
import OathAnkr

/// One read boundary for every activity surface. Raw ledger records and sync
/// cursors are preserved; filtering happens BEFORE search, counts and pagination.
/// Unlisted is not proof of fraud: explicit user tracking can reveal a token,
/// but cannot override phishing metadata or zero-value transfer protection.
enum HistorySafety {
    static let metadataFunction = DatabaseFunction("oath_phishing_metadata", argumentCount: 2, pure: true) { values in
        suspiciousMetadata(name: String.fromDatabaseValue(values[0]) ?? "",
                           symbol: String.fromDatabaseValue(values[1]) ?? "")
    }

    static func suspiciousMetadata(name: String, symbol: String) -> Bool {
        let original = name + " " + symbol
        // Remove invisible controls before examining URL/claim bait, including
        // bidi overrides and zero-width characters used to disguise links.
        let text = String(original.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) &&
            !CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0) })
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if text.contains("http://") || text.contains("https://") || text.contains("www.") || text.contains("t.me/") { return true }
        // Domain names alone (e.g. yearn.finance) are valid project names.
        let domain = text.range(of: #"[a-z0-9][a-z0-9-]*\.[a-z]{2,}(?:[/\s]|$)"#, options: .regularExpression) != nil
        let bait = text.range(of: #"\b(claim|visit|redeem|airdrop|reward|voucher|bonus|gift)\b"#, options: .regularExpression) != nil
        return domain && bait
    }

    static func migrate(_ db: Database) throws {
        // Public, contract-keyed evidence survives a token reaching zero balance.
        // It cannot be confused with another chain or a same-symbol impostor.
        try db.execute(sql: """
            CREATE TABLE tokenHistoryTrust (
                networkID TEXT NOT NULL, reference TEXT NOT NULL, source TEXT NOT NULL,
                decimals INTEGER, observedAt DOUBLE NOT NULL,
                PRIMARY KEY(networkID,reference,source)
            );
            CREATE INDEX token_history_trust_source ON tokenHistoryTrust(source);
            CREATE TABLE tokenHistoryBlocks (
                networkID TEXT NOT NULL, reference TEXT NOT NULL, source TEXT NOT NULL,
                PRIMARY KEY(networkID,reference,source)
            );
            """)
        for table in ["ankrAssets", "solanaHoldings", "tronHoldings", "tonHoldings", "aptosHoldings", "suiHoldings",
                      "nearHoldings", "xrplHoldings", "stellarHoldings", "arcHoldings", "robinhoodHoldings"] {
            let flag = table == "ankrAssets" ? "onlyWhitelisted" : "verified"
            let time = table == "ankrAssets" ? "fetchedAt" : "observedAt"
            let source = "verified." + table
            try db.execute(sql: """
                INSERT OR IGNORE INTO tokenHistoryTrust(networkID,reference,source,decimals,observedAt)
                SELECT s.networkID,s.reference,?,s.decimals,h.\(time) FROM \(table) h JOIN assets s ON s.id=h.assetID
                WHERE h.\(flag)=1 AND s.reference<>'native';
                """, arguments: [source])
            for operation in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER trust_\(table)_\(operation) AFTER \(operation) ON \(table) WHEN NEW.\(flag)=1
                    BEGIN
                        INSERT INTO tokenHistoryTrust(networkID,reference,source,decimals,observedAt)
                        SELECT networkID,reference,'\(source)',decimals,NEW.\(time) FROM assets
                        WHERE id=NEW.assetID AND reference<>'native'
                        ON CONFLICT(networkID,reference,source) DO UPDATE SET
                            decimals=excluded.decimals,observedAt=excluded.observedAt
                        WHERE excluded.observedAt>=tokenHistoryTrust.observedAt;
                    END;
                    """)
            }
        }
        for entry in try MarketCacheEntry.fetchAll(db, sql: """
            SELECT * FROM publicMarketCache WHERE key IN ('tron.coingecko.catalog.v1','solana.coingecko.catalog.v1',
                'aptos.catalog','sui.catalog','near.catalog','xrpl.catalog','stellar.catalog','arc.catalog','robinhood.catalog','hyperevm.catalog','monad.catalog','unichain.catalog','celo.catalog','chiliz.catalog','filecoin.catalog','sei.catalog','zerog.catalog','iotex.catalog')
                OR key LIKE 'ton.token.%' OR key LIKE 'evm.verified.%'
            """) { try ingestCatalog(entry, db: db) }
        try createVisibilityView(db)
    }

    static func createVisibilityView(_ db: Database, indexedMetadata: Bool = false) throws {
        // v28 is also used when upgrading older stores. v58 backfills the
        // metadata flag before replacing the view with the indexed form.
        let safeMetadata = indexedMetadata ? "s.historyMetadataSafe=1" : "NOT oath_phishing_metadata(s.name,s.symbol)"
        let walletOptIn = indexedMetadata
            ? "OR EXISTS(SELECT 1 FROM walletPortfolioFilters f WHERE f.walletID=a.walletID AND f.hidesUnverifiedTokens=0)" : ""
        try db.execute(sql: """
            CREATE VIEW visibleActivity AS
            SELECT a.* FROM activity a JOIN assets s ON s.id=a.assetID
            WHERE \(safeMetadata)
            AND NOT EXISTS(SELECT 1 FROM tokenHistoryBlocks b WHERE b.networkID=s.networkID AND b.reference=s.reference)
            AND (s.reference='native'
                \(walletOptIn)
                OR EXISTS(SELECT 1 FROM trackedAssets tr WHERE tr.accountID=a.accountID AND tr.assetID=a.assetID)
                OR EXISTS(SELECT 1 FROM tokenHistoryTrust v WHERE v.networkID=s.networkID AND v.reference=s.reference
                    AND (v.decimals IS NULL OR v.decimals=s.decimals)))
            AND (a.amountAtomic<>'0' OR
                (s.reference='native' AND a.direction IN ('outgoing','self')) OR
                (a.direction IN ('outgoing','self') AND EXISTS(SELECT 1 FROM transactions t
                    LEFT JOIN transactionEvidence e ON e.transactionID=t.id AND e.accountID=a.accountID
                    WHERE t.id=a.transactionID AND COALESCE(e.outcome,t.state) IN ('failed','canceled','replaced','reorged'))));
            """)
    }

    static func trust(networkID: String, reference: String, decimals: Int?, source: String,
                      observedAt: Double, db: Database) throws {
        guard reference != "native" else { return }
        try db.execute(sql: """
            INSERT INTO tokenHistoryTrust(networkID,reference,source,decimals,observedAt) VALUES(?,?,?,?,?)
            ON CONFLICT(networkID,reference,source) DO UPDATE SET decimals=excluded.decimals,observedAt=excluded.observedAt
            WHERE excluded.observedAt>=tokenHistoryTrust.observedAt
            """, arguments: [networkID,reference,source,decimals,observedAt])
    }

    /// Index the existing verified directories once at write time, not by
    /// decoding large JSON for every history row. Also handles pre-update caches.
    static func ingestCatalog(_ entry: MarketCacheEntry, db: Database) throws {
        let decoder = JSONDecoder()
        var network: String
        var tokens: [(String, Int?)]
        switch entry.key {
        case "tron.coingecko.catalog.v1":
            guard let list = OathDiagnostics.attempt("index_cached_tron_catalog", body: { try TronMarkets.decodeCatalog(entry.payload) }) else { return }
            network = "tron"; tokens = list.values.map { ($0.address,$0.decimals) }
        case "solana.coingecko.catalog.v1":
            guard let list = OathDiagnostics.attempt("index_cached_solana_catalog", body: { try SolanaMarkets.decodeCatalog(entry.payload) }) else { return }
            network = "solana"; tokens = list.values.map { ($0.address,$0.decimals) }
        case "aptos.catalog":
            guard let list = OathDiagnostics.attempt("index_cached_metadata", body: { try decoder.decode(AptosCatalog.self, from: entry.payload) }) else { return }
            network = "aptos"; tokens = list.tokens.values.filter(\.verified).map { ($0.reference,$0.decimals) }
            tokens += list.aliases.compactMap { alias, canonical in
                list.tokens[canonical].flatMap { $0.verified ? (alias,$0.decimals) : nil }
            }
        case "sui.catalog", "near.catalog", "xrpl.catalog", "stellar.catalog", "arc.catalog", "robinhood.catalog", "hyperevm.catalog", "monad.catalog", "unichain.catalog", "celo.catalog", "chiliz.catalog", "filecoin.catalog", "sei.catalog", "zerog.catalog", "iotex.catalog":
            struct IDs: Decodable { let ids: [String: String] }
            guard let list = OathDiagnostics.attempt("index_cached_metadata", body: { try decoder.decode(IDs.self, from: entry.payload) }) else { return }
            network = String(entry.key.prefix(while: { $0 != "." })); tokens = list.ids.keys.map { ($0,nil) }
        default:
            if entry.key.hasPrefix("evm.verified.") {
                guard let list = OathDiagnostics.attempt("index_cached_metadata", body: { try decoder.decode(VerifiedEVMTokenCatalog.self, from: entry.payload) }),
                      entry.key == "evm.verified." + list.networkID,
                      AnkrChain(networkID: list.networkID) != nil else { return }
                network = list.networkID; tokens = list.decimalsByReference.map { ($0.key,$0.value) }
                // A directory fallback has identity but no precision. Preserve
                // precision already verified by this same source and network;
                // missing metadata is not evidence to relax the history guard.
                let identityOnly = list.referencesWithoutDecimals ?? []
                var knownDecimals: [String: Int] = [:]
                if !identityOnly.isEmpty {
                    for row in try Row.fetchAll(db, sql: "SELECT reference,decimals FROM tokenHistoryTrust WHERE source=? AND networkID=? AND decimals IS NOT NULL",
                                                arguments: [entry.key, network]) {
                        knownDecimals[row["reference"]] = row["decimals"]
                    }
                }
                tokens += identityOnly.map { ($0,knownDecimals[$0]) }
            } else if entry.key.hasPrefix("ton.token.") {
                guard let token = OathDiagnostics.attempt("index_cached_metadata", body: { try decoder.decode(TonToken.self, from: entry.payload) }),
                      entry.key == "ton.token." + token.reference else { return }
                network = "ton"; tokens = token.verified && token.isBlacklisted != true ? [(token.reference,token.decimals)] : []
                // Explicit provider blacklist wins over an older listing or user tracking.
                if let blocked = token.isBlacklisted {
                    try db.execute(sql: "DELETE FROM tokenHistoryBlocks WHERE networkID='ton' AND reference=? AND source='tonapi'", arguments: [token.reference])
                    if blocked {
                        try db.execute(sql: "INSERT INTO tokenHistoryBlocks(networkID,reference,source) VALUES('ton',?,'tonapi')", arguments: [token.reference])
                    }
                }
            } else { return }
        }
        // This source is replaced only after a successfully decoded response.
        // A failed network request never clears cached verification.
        try db.execute(sql: "DELETE FROM tokenHistoryTrust WHERE source=?", arguments: [entry.key])
        for (reference, decimals) in tokens {
            try trust(networkID: network, reference: reference, decimals: decimals, source: entry.key,
                      observedAt: entry.fetchedAt, db: db)
        }
    }
}

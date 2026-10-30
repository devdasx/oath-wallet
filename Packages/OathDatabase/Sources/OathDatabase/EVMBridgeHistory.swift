import GRDB

extension OathDatabase {
    static func installBridgeHistory(_ db: Database) throws {
        guard let swapView = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name='validHistorySwaps'") else {
            throw StoreError.invalidValue("missing swap history view")
        }
        try db.execute(sql: "DROP VIEW projectedHistoryActivity; DROP VIEW validHistorySwaps;")
        try db.execute(sql: swapView.replacingOccurrences(of: "c.version=1", with: "c.version=2"))
        try db.execute(sql: """
        ALTER TABLE evmHistorySwaps ADD COLUMN bridgeKey TEXT;
        ALTER TABLE evmHistorySwaps ADD COLUMN bridgeDirection TEXT;
        ALTER TABLE evmHistorySwaps ADD COLUMN bridgeAssetID TEXT REFERENCES assets(id);
        ALTER TABLE evmHistorySwaps ADD COLUMN bridgeAmount TEXT;
        ALTER TABLE evmHistorySwaps ADD COLUMN bridgeProtocol TEXT;
        CREATE INDEX evm_bridge_key ON evmHistorySwaps(bridgeKey);
        CREATE VIEW validHistoryBridges AS
        SELECT c.*,owner.walletID,owner.networkID,lower(owner.address) AS address,t.hash,t.timestamp,
            (SELECT MAX(a.sortTimestamp) FROM visibleActivity a WHERE a.accountID=c.accountID AND a.transactionID=c.transactionID) AS sortTimestamp
        FROM evmHistorySwaps c
        JOIN accounts owner ON owner.id=c.accountID AND owner.syncGeneration=c.generation
        JOIN transactions t ON t.id=c.transactionID
        LEFT JOIN transactionEvidence e ON e.accountID=c.accountID AND e.transactionID=c.transactionID
        WHERE c.version=2 AND c.bridgeKey IS NOT NULL AND c.bridgeAssetID IS NOT NULL
        AND COALESCE(e.outcome,t.state)='confirmed' AND lower(t.blockHash)=c.blockHash
        AND EXISTS(SELECT 1 FROM visibleActivity a WHERE a.accountID=c.accountID AND a.transactionID=c.transactionID AND a.assetID=c.bridgeAssetID)
        AND NOT EXISTS(SELECT 1 FROM visibleActivity a WHERE a.accountID=c.accountID AND a.transactionID=c.transactionID
            AND a.assetID<>c.bridgeAssetID AND a.amountAtomic<>'0');
        CREATE VIEW pairedHistoryBridges AS
        SELECT s.*,d.accountID AS outputAccountID,d.transactionID AS outputTransactionID,d.networkID AS outputNetworkID,
            d.bridgeAssetID AS destinationAssetID,d.bridgeAmount AS destinationAmount
        FROM validHistoryBridges s JOIN validHistoryBridges d ON s.bridgeKey=d.bridgeKey
            AND s.walletID=d.walletID AND s.address=d.address AND s.networkID<>d.networkID
            AND s.bridgeDirection='outgoing' AND d.bridgeDirection='incoming'
        WHERE (SELECT COUNT(*) FROM validHistoryBridges b WHERE b.walletID=s.walletID AND b.address=s.address AND b.bridgeKey=s.bridgeKey)=2;
        CREATE VIEW projectedHistoryActivity AS
        SELECT a.id,a.walletID,a.accountID,a.networkID,a.transactionID,a.assetID,a.direction,a.amountAtomic,
            a.counterparty,a.timestamp,a.sortTimestamp,NULL AS outputAssetID,NULL AS received,
            NULL AS outputAccountID,NULL AS outputTransactionID,NULL AS outputNetworkID,NULL AS bridgeProtocol
        FROM visibleActivity a WHERE NOT EXISTS(SELECT 1 FROM validHistorySwaps c WHERE c.accountID=a.accountID AND c.transactionID=a.transactionID)
            AND NOT EXISTS(SELECT 1 FROM validHistoryBridges c WHERE c.accountID=a.accountID AND c.transactionID=a.transactionID)
        UNION ALL
        SELECT 'swap:'||c.accountID||':'||c.networkID||':'||lower(c.hash),c.walletID,c.accountID,c.networkID,
            c.transactionID,c.inputAssetID,'swap',c.spent,'',c.timestamp,
            (SELECT MAX(a.sortTimestamp) FROM visibleActivity a WHERE a.accountID=c.accountID AND a.transactionID=c.transactionID),
            c.outputAssetID,c.received,c.accountID,c.transactionID,c.networkID,NULL
        FROM validHistorySwaps c
        UNION ALL
        SELECT 'bridge:'||c.accountID||':'||c.networkID||':'||lower(c.hash),c.walletID,c.accountID,c.networkID,
            c.transactionID,c.bridgeAssetID,'bridge',c.bridgeAmount,c.bridgeProtocol,c.timestamp,c.sortTimestamp,
            c.destinationAssetID,c.destinationAmount,c.outputAccountID,c.outputTransactionID,c.outputNetworkID,c.bridgeProtocol
        FROM pairedHistoryBridges c
        UNION ALL
        SELECT 'bridge:'||c.accountID||':'||c.networkID||':'||lower(c.hash),c.walletID,c.accountID,c.networkID,
            c.transactionID,c.bridgeAssetID,CASE c.bridgeDirection WHEN 'outgoing' THEN 'bridgeOutgoing' ELSE 'bridgeIncoming' END,
            c.bridgeAmount,c.bridgeProtocol,c.timestamp,c.sortTimestamp,NULL,NULL,NULL,NULL,NULL,c.bridgeProtocol
        FROM validHistoryBridges c WHERE NOT EXISTS(SELECT 1 FROM pairedHistoryBridges p
            WHERE (p.accountID=c.accountID AND p.transactionID=c.transactionID)
                OR (p.outputAccountID=c.accountID AND p.outputTransactionID=c.transactionID));
        """)
    }
}

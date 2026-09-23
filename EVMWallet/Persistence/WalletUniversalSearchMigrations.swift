import GRDB

extension WalletDatabase {
    static func registerUniversalSearchMigrations(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v27_universal_transaction_search"
        ) { database in
            try database.execute(
                sql: """
                CREATE VIRTUAL TABLE transactionSearchIndex USING fts5(
                    transactionID UNINDEXED,
                    accountID UNINDEXED,
                    title,
                    body,
                    tokenize = 'unicode61 remove_diacritics 2',
                    prefix = '2 3 4 6 8 12'
                );

                INSERT INTO transactionSearchIndex(
                    transactionID,
                    accountID,
                    title,
                    body
                )
                SELECT
                    transactionRecord.id,
                    transactionRecord.accountID,
                    transactionRecord.assetSymbol,
                    trim(
                        transactionRecord.kind || ' '
                        || transactionRecord.status || ' '
                        || transactionRecord.direction || ' '
                        || transactionRecord.networkID || ' '
                        || transactionRecord.transactionHash || ' '
                        || COALESCE(
                            transactionRecord.fromAddress,
                            ''
                        ) || ' '
                        || COALESCE(
                            transactionRecord.toAddress,
                            ''
                        ) || ' '
                        || COALESCE(
                            transactionRecord.counterpartyAddress,
                            ''
                        ) || ' '
                        || COALESCE(
                            transactionRecord.methodName,
                            ''
                        ) || ' '
                        || transactionRecord.displayDetail || ' '
                        || transactionRecord.displayTime || ' '
                        || COALESCE(assetRecord.name, '') || ' '
                        || COALESCE(assetRecord.symbol, '') || ' '
                        || COALESCE(
                            assetRecord.contractAddress,
                            ''
                        ) || ' '
                        || COALESCE(networkRecord.nativeSymbol, '') || ' '
                        || COALESCE(
                            networkRecord.trustWalletBlockchain,
                            ''
                        ) || ' '
                        || COALESCE(noteRecord.note, '')
                    )
                FROM transactions AS transactionRecord
                LEFT JOIN assets AS assetRecord
                    ON assetRecord.id = transactionRecord.assetID
                LEFT JOIN networks AS networkRecord
                    ON networkRecord.id = transactionRecord.networkID
                LEFT JOIN transactionNotes AS noteRecord
                    ON noteRecord.transactionID = transactionRecord.id;

                CREATE TRIGGER transactionSearch_insert
                AFTER INSERT ON transactions
                BEGIN
                    INSERT INTO transactionSearchIndex(
                        transactionID,
                        accountID,
                        title,
                        body
                    )
                    SELECT
                        new.id,
                        new.accountID,
                        new.assetSymbol,
                        trim(
                            new.kind || ' '
                            || new.status || ' '
                            || new.direction || ' '
                            || new.networkID || ' '
                            || new.transactionHash || ' '
                            || COALESCE(new.fromAddress, '') || ' '
                            || COALESCE(new.toAddress, '') || ' '
                            || COALESCE(
                                new.counterpartyAddress,
                                ''
                            ) || ' '
                            || COALESCE(new.methodName, '') || ' '
                            || new.displayDetail || ' '
                            || new.displayTime || ' '
                            || COALESCE(assetRecord.name, '') || ' '
                            || COALESCE(assetRecord.symbol, '') || ' '
                            || COALESCE(
                                assetRecord.contractAddress,
                                ''
                            ) || ' '
                            || COALESCE(networkRecord.nativeSymbol, '') || ' '
                            || COALESCE(
                                networkRecord.trustWalletBlockchain,
                                ''
                            )
                        )
                    FROM (SELECT 1)
                    LEFT JOIN assets AS assetRecord
                        ON assetRecord.id = new.assetID
                    LEFT JOIN networks AS networkRecord
                        ON networkRecord.id = new.networkID;
                END;

                CREATE TRIGGER transactionSearch_update
                AFTER UPDATE ON transactions
                BEGIN
                    DELETE FROM transactionSearchIndex
                    WHERE transactionID = old.id;

                    INSERT INTO transactionSearchIndex(
                        transactionID,
                        accountID,
                        title,
                        body
                    )
                    SELECT
                        new.id,
                        new.accountID,
                        new.assetSymbol,
                        trim(
                            new.kind || ' '
                            || new.status || ' '
                            || new.direction || ' '
                            || new.networkID || ' '
                            || new.transactionHash || ' '
                            || COALESCE(new.fromAddress, '') || ' '
                            || COALESCE(new.toAddress, '') || ' '
                            || COALESCE(
                                new.counterpartyAddress,
                                ''
                            ) || ' '
                            || COALESCE(new.methodName, '') || ' '
                            || new.displayDetail || ' '
                            || new.displayTime || ' '
                            || COALESCE(assetRecord.name, '') || ' '
                            || COALESCE(assetRecord.symbol, '') || ' '
                            || COALESCE(
                                assetRecord.contractAddress,
                                ''
                            ) || ' '
                            || COALESCE(networkRecord.nativeSymbol, '') || ' '
                            || COALESCE(
                                networkRecord.trustWalletBlockchain,
                                ''
                            ) || ' '
                            || COALESCE(noteRecord.note, '')
                        )
                    FROM (SELECT 1)
                    LEFT JOIN assets AS assetRecord
                        ON assetRecord.id = new.assetID
                    LEFT JOIN networks AS networkRecord
                        ON networkRecord.id = new.networkID
                    LEFT JOIN transactionNotes AS noteRecord
                        ON noteRecord.transactionID = new.id;
                END;

                CREATE TRIGGER transactionSearch_delete
                AFTER DELETE ON transactions
                BEGIN
                    DELETE FROM transactionSearchIndex
                    WHERE transactionID = old.id;
                END;

                CREATE TRIGGER transactionSearch_asset_update
                AFTER UPDATE OF name, symbol, contractAddress ON assets
                BEGIN
                    UPDATE transactions
                    SET updatedAt = updatedAt
                    WHERE assetID = new.id;
                END;

                CREATE TRIGGER transactionSearch_network_update
                AFTER UPDATE OF nativeSymbol, trustWalletBlockchain
                    ON networks
                BEGIN
                    UPDATE transactions
                    SET updatedAt = updatedAt
                    WHERE networkID = new.id;
                END;

                CREATE TRIGGER transactionSearch_note_insert
                AFTER INSERT ON transactionNotes
                BEGIN
                    UPDATE transactionSearchIndex
                    SET body = body || ' ' || new.note
                    WHERE transactionID = new.transactionID;
                END;

                CREATE TRIGGER transactionSearch_note_update
                AFTER UPDATE ON transactionNotes
                BEGIN
                    DELETE FROM transactionSearchIndex
                    WHERE transactionID = new.transactionID;

                    INSERT INTO transactionSearchIndex(
                        transactionID,
                        accountID,
                        title,
                        body
                    )
                    SELECT
                        transactionRecord.id,
                        transactionRecord.accountID,
                        transactionRecord.assetSymbol,
                        trim(
                            transactionRecord.kind || ' '
                            || transactionRecord.status || ' '
                            || transactionRecord.direction || ' '
                            || transactionRecord.networkID || ' '
                            || transactionRecord.transactionHash || ' '
                            || COALESCE(
                                transactionRecord.fromAddress,
                                ''
                            ) || ' '
                            || COALESCE(
                                transactionRecord.toAddress,
                                ''
                            ) || ' '
                            || COALESCE(
                                transactionRecord.counterpartyAddress,
                                ''
                            ) || ' '
                            || COALESCE(
                                transactionRecord.methodName,
                                ''
                            ) || ' '
                            || transactionRecord.displayDetail || ' '
                            || transactionRecord.displayTime || ' '
                            || COALESCE(assetRecord.name, '') || ' '
                            || COALESCE(assetRecord.symbol, '') || ' '
                            || COALESCE(
                                assetRecord.contractAddress,
                                ''
                            ) || ' '
                            || COALESCE(networkRecord.nativeSymbol, '') || ' '
                            || COALESCE(
                                networkRecord.trustWalletBlockchain,
                                ''
                            ) || ' '
                            || new.note
                        )
                    FROM transactions AS transactionRecord
                    LEFT JOIN assets AS assetRecord
                        ON assetRecord.id = transactionRecord.assetID
                    LEFT JOIN networks AS networkRecord
                        ON networkRecord.id = transactionRecord.networkID
                    WHERE transactionRecord.id = new.transactionID;
                END;

                CREATE TRIGGER transactionSearch_note_delete
                AFTER DELETE ON transactionNotes
                BEGIN
                    DELETE FROM transactionSearchIndex
                    WHERE transactionID = old.transactionID;

                    INSERT INTO transactionSearchIndex(
                        transactionID,
                        accountID,
                        title,
                        body
                    )
                    SELECT
                        transactionRecord.id,
                        transactionRecord.accountID,
                        transactionRecord.assetSymbol,
                        trim(
                            transactionRecord.kind || ' '
                            || transactionRecord.status || ' '
                            || transactionRecord.direction || ' '
                            || transactionRecord.networkID || ' '
                            || transactionRecord.transactionHash || ' '
                            || COALESCE(
                                transactionRecord.fromAddress,
                                ''
                            ) || ' '
                            || COALESCE(
                                transactionRecord.toAddress,
                                ''
                            ) || ' '
                            || COALESCE(
                                transactionRecord.counterpartyAddress,
                                ''
                            ) || ' '
                            || COALESCE(
                                transactionRecord.methodName,
                                ''
                            ) || ' '
                            || transactionRecord.displayDetail || ' '
                            || transactionRecord.displayTime || ' '
                            || COALESCE(assetRecord.name, '') || ' '
                            || COALESCE(assetRecord.symbol, '') || ' '
                            || COALESCE(
                                assetRecord.contractAddress,
                                ''
                            ) || ' '
                            || COALESCE(networkRecord.nativeSymbol, '') || ' '
                            || COALESCE(
                                networkRecord.trustWalletBlockchain,
                                ''
                            )
                        )
                    FROM transactions AS transactionRecord
                    LEFT JOIN assets AS assetRecord
                        ON assetRecord.id = transactionRecord.assetID
                    LEFT JOIN networks AS networkRecord
                        ON networkRecord.id = transactionRecord.networkID
                    WHERE transactionRecord.id = old.transactionID;
                END;
                """
            )
        }
    }
}

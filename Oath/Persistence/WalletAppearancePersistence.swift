import GRDB

extension WalletDatabase {
    static func registerWalletAppearanceMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v40_wallet_appearance_colors"
        ) { database in
            let allowedValues = WalletAppearanceColor.allCases
                .map { "'\($0.rawValue)'" }
                .joined(separator: ", ")
            try database.execute(
                sql: """
                ALTER TABLE wallets ADD COLUMN appearanceColorID TEXT
                    NOT NULL DEFAULT 'blue'
                    CHECK (appearanceColorID IN (\(allowedValues)));
                """
            )

            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, profileID
                FROM wallets
                ORDER BY profileID, sortOrder, createdAt, id
                """
            )
            var nextIndexByProfileID: [String: Int] = [:]
            var randomizedColorsByProfileID:
                [String: [WalletAppearanceColor]] = [:]
            for row in rows {
                let walletID: String = row["id"]
                let profileID: String = row["profileID"]
                let index = nextIndexByProfileID[profileID, default: 0]
                if randomizedColorsByProfileID[profileID] == nil
                    || index % WalletAppearanceColor.allCases.count == 0
                {
                    randomizedColorsByProfileID[profileID] =
                        WalletAppearanceColor.allCases.shuffled()
                }
                let palette = randomizedColorsByProfileID[profileID]
                    ?? WalletAppearanceColor.allCases
                let color = palette[index % palette.count]
                nextIndexByProfileID[profileID] = index + 1
                try database.execute(
                    sql: """
                    UPDATE wallets
                    SET appearanceColorID = ?
                    WHERE id = ?
                    """,
                    arguments: [color.rawValue, walletID]
                )
            }
        }
    }

    static func nextWalletAppearanceColor(
        profileID: String,
        database: Database
    ) throws -> WalletAppearanceColor {
        let existingIDs = try String.fetchAll(
            database,
            sql: """
            SELECT appearanceColorID
            FROM wallets
            WHERE profileID = ? AND archivedAt IS NULL
            """,
            arguments: [profileID]
        )
        return WalletAppearanceColor.nextAvailable(
            existingIDs: existingIDs
        )
    }
}

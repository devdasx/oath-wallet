import Foundation
import GRDB

/// Verify public derivation/progress rows as well as the primary account when a
/// collection moves between devices. A forged row cannot become an owned input.
enum DeviceMigrationBitcoinImportedVerifier {
    static func validate(source: any DatabaseReader, walletID: String,
                         material: BitcoinImportedWalletMaterial) throws {
        try source.read { database in
            let cursor = try Row.fetchCursor(database, sql: "SELECT * FROM bitcoinImportedAddresses WHERE walletID=?",
                                             arguments: [walletID])
            while let row = try cursor.next() {
                try Task.checkCancellation()
                let sourceID: Int = row["sourceIndex"]
                let branch: Int = row["branch"]
                let index: Int = row["addressIndex"]
                guard material.sources.indices.contains(sourceID), index >= material.sources[sourceID].rangeStart else {
                    throw DeviceMigrationError.invalidWalletSecret
                }
                let recorded = try JSONDecoder().decode(BitcoinHDDerivedAddress.self, from: row["publicAddress"] as Data)
                let derived = try material.sources[sourceID].descriptor.address(branch: branch, index: index, sourceID: String(sourceID))
                guard recorded == derived, row["scriptHash"] as String == derived.scriptHash else {
                    throw DeviceMigrationError.invalidWalletSecret
                }
            }
        }
    }
}

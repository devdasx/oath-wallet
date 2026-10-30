import Foundation
import GRDB

public struct MultisigNoticeState: Equatable, Sendable {
    public let acknowledged: Bool
}

extension OathDatabase {
    // A local UI preference scoped to the wallet record, not an address or a
    // signing policy. New imports/restores get their own acknowledgement.
    static func multisigNoticeKey(_ walletID: String) -> String {
        "multisigNoticeAcknowledged." + walletID
    }

    // Retained only to clean up the removed card preference on permanent wallet deletion.
    static func multisigWarningKey(_ walletID: String) -> String {
        "multisigWarningDismissed." + walletID
    }

    private static func multisigNoticeState(_ db: Database, walletID: String) throws -> MultisigNoticeState {
        guard let wallet = try WalletRecord.fetchOne(db, key: walletID), wallet.deletedAt == nil else {
            throw StoreError.missingRecord
        }
        return try MultisigNoticeState(
            acknowledged: SettingRecord.fetchOne(db, key: multisigNoticeKey(walletID))?.value == "true")
    }

    public func multisigNoticeState(walletID: String) async throws -> MultisigNoticeState {
        try await pool.read { try Self.multisigNoticeState($0, walletID: walletID) }
    }

    public func hasAcknowledgedMultisigNotice(walletID: String) async throws -> Bool {
        try await multisigNoticeState(walletID: walletID).acknowledged
    }

    @discardableResult
    public func acknowledgeMultisigNotice(walletID: String) async throws -> MultisigNoticeState {
        try await pool.write { db in
            _ = try Self.multisigNoticeState(db, walletID: walletID)
            try SettingRecord(key: Self.multisigNoticeKey(walletID), value: "true",
                              updatedAt: Date.now.timeIntervalSince1970).upsert(db)
            return try Self.multisigNoticeState(db, walletID: walletID)
        }
    }

}

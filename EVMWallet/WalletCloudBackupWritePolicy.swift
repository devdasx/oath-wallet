import Foundation

/// A user-triggered create cannot overwrite a backup without explicit consent.
enum WalletCloudBackupWritePolicy: Sendable {
    case createOnly
    case replaceExisting

    func validate(existingBackup: Bool) throws {
        if existingBackup, self == .createOnly {
            throw WalletCloudBackupReplacementRequired()
        }
    }
}

struct WalletCloudBackupReplacementRequired: Error, Sendable {}

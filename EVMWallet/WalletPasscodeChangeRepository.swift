import Foundation
import GRDB

enum WalletPasscodeLockoutPolicy {
    static let firstLockedAttempt = 5

    private static let durations: [TimeInterval] = [
        5,
        30,
        5 * 60,
        30 * 60,
        60 * 60,
        6 * 60 * 60
    ]

    static func duration(
        afterFailedAttemptCount failedAttemptCount: Int
    ) -> TimeInterval? {
        guard failedAttemptCount >= firstLockedAttempt else {
            return nil
        }
        let index = min(
            failedAttemptCount - firstLockedAttempt,
            durations.count - 1
        )
        return durations[index]
    }
}

extension WalletDatabase {
    func activePasscodeLockoutDeadline(
        at date: Date = Date()
    ) async throws -> Date? {
        let timestamp = try await pool.read { database in
            try DBProfileSecurityRecord.fetchOne(
                database,
                key: Self.defaultProfileID
            )?.lockedUntil
        }
        guard let timestamp else { return nil }
        let deadline = Date(timeIntervalSince1970: timestamp)
        return deadline > date ? deadline : nil
    }

    func changePasscode(
        currentPasscode: String,
        newPasscode: String,
        vault: WalletSecretVault = .shared
    ) async throws {
        guard try await authenticatePasscode(
            currentPasscode,
            vault: vault
        ) == .success else {
            throw WalletCreationPersistenceError.invalidPasscode
        }

        let oldReference = try await pool.read { database in
            try DBProfileSecurityRecord.fetchOne(
                database,
                key: Self.defaultProfileID
            )?.passcodeKeychainReference
        }
        guard let oldReference else {
            throw WalletCreationPersistenceError.missingSecret
        }

        let credential = try WalletPasscodeCredential.make(
            passcode: newPasscode
        )
        let newReference = try vault.storePasscodeCredential(
            JSONEncoder().encode(credential)
        )

        do {
            try await pool.write { database in
                guard var security = try DBProfileSecurityRecord.fetchOne(
                    database,
                    key: Self.defaultProfileID
                ), security.passcodeKeychainReference == oldReference else {
                    throw WalletCreationPersistenceError.missingSecret
                }
                security.passcodeKeychainReference = newReference
                security.failedAttemptCount = 0
                security.lockedUntil = nil
                security.updatedAt = Date().timeIntervalSince1970
                try security.update(database)
            }
        } catch {
            try? vault.deletePasscodeCredential(reference: newReference)
            throw error
        }

        try? vault.deletePasscodeCredential(reference: oldReference)
    }
}

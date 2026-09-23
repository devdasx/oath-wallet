import Foundation

struct WalletSecureCleanupRecoveryResult: Equatable, Sendable {
    let completedSecretJobs: Int
    let pendingSecretJobs: Int
    let completedPushJobs: Int
    let pendingPushJobs: Int
    let pendingMaintenanceOperations: Int
    let lastErrorCode: String?

    var hasPendingPushCleanup: Bool {
        pendingPushJobs > 0
    }
}

actor WalletSecureCleanupRecoveryService {
    static let shared = WalletSecureCleanupRecoveryService()

    private let secretVault: any WalletSecureCleanupVault
    private let pushCleaner: PushInstallationResetCleaner

    init(
        secretVault: any WalletSecureCleanupVault =
            WalletSecretVault.shared,
        pushCleaner: PushInstallationResetCleaner = .shared
    ) {
        self.secretVault = secretVault
        self.pushCleaner = pushCleaner
    }

    func prepareAppResetCleanupPlan() throws
        -> WalletAppResetCleanupPlan
    {
        let references = try secretVault.allReferences()
        let requiresPushCleanup =
            try pushCleaner.preflightRequiresCleanup()
        return WalletAppResetCleanupPlan(
            secretReferences: references,
            requiresPushCleanup: requiresPushCleanup
        )
    }

    func retryPendingCleanup(
        database: WalletDatabase
    ) async -> WalletSecureCleanupRecoveryResult {
        var lastErrorCode: String?

        // Security cleanup always precedes optional database maintenance.
        // A slow checkpoint or VACUUM must never delay Keychain erasure or
        // server-side notification deactivation.
        let secretResult = await database.retryPendingSecretCleanup(
            vault: secretVault
        )
        if let code = secretResult.lastErrorCode {
            lastErrorCode = code
        }

        var pendingMaintenanceCount = 0
        let pushJobs: [DBSecureCleanupJobRecord]
        do {
            pushJobs = try await database.pendingPushCleanupJobs()
        } catch {
            let code = WalletSecureCleanupErrorCode.errorCode(for: error)
            return WalletSecureCleanupRecoveryResult(
                completedSecretJobs: secretResult.completedCount,
                pendingSecretJobs: secretResult.pendingCount,
                completedPushJobs: 0,
                pendingPushJobs: 1,
                pendingMaintenanceOperations: pendingMaintenanceCount,
                lastErrorCode: code
            )
        }

        var completedPushJobs = 0
        var pendingPushJobs = pushJobs.count
        if !pushJobs.isEmpty {
            let pushResult = await pushCleaner.cleanup()
            if pushResult.pendingCount == 0 {
                await database.completePushCleanupJobs(pushJobs)
                completedPushJobs = pushJobs.count
                pendingPushJobs = 0
            } else {
                let code =
                    pushResult.lastErrorCode ?? "push_cleanup_pending"
                await database.failPushCleanupJobs(
                    pushJobs,
                    errorCode: code
                )
                lastErrorCode = code
            }
        }

        let maintenanceOperations =
            await database.appResetOperationsRequiringMaintenance()
        for operation in maintenanceOperations {
            guard let operationID = UUID(uuidString: operation.id) else {
                pendingMaintenanceCount += 1
                lastErrorCode = "invalid_maintenance_operation_id"
                continue
            }
            let completed = await database.performPostResetMaintenance(
                operationID: operationID
            )
            if !completed {
                pendingMaintenanceCount += 1
                lastErrorCode =
                    operation.maintenanceErrorCode
                    ?? "maintenance_pending"
            }
        }

        return WalletSecureCleanupRecoveryResult(
            completedSecretJobs: secretResult.completedCount,
            pendingSecretJobs: secretResult.pendingCount,
            completedPushJobs: completedPushJobs,
            pendingPushJobs: pendingPushJobs,
            pendingMaintenanceOperations: pendingMaintenanceCount,
            lastErrorCode: lastErrorCode
        )
    }
}

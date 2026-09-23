import Foundation

protocol PushInstallationResetVault: Sendable {
    func resetCleanupReadiness() throws -> Bool
    func prepareCurrentIdentityForReset() throws
    func deactivationTombstones() throws
        -> [PushDeactivationTombstone]
    func removeTombstone(installationID: String) throws
    func deleteAllResetState() throws
}

protocol PushInstallationDeactivating: Sendable {
    func deactivate(
        installationID: String,
        credential: Data
    ) async throws
}

extension PushInstallationVault: PushInstallationResetVault {}
extension PushNotificationAPIClient: PushInstallationDeactivating {}

struct PushInstallationResetCleanupResult: Equatable, Sendable {
    let completedCount: Int
    let pendingCount: Int
    let lastErrorCode: String?
}

final class PushInstallationResetCleaner: @unchecked Sendable {
    static let shared = PushInstallationResetCleaner()

    typealias ClientFactory =
        @Sendable () throws -> any PushInstallationDeactivating

    private let vault: any PushInstallationResetVault
    private let clientFactory: ClientFactory

    init(
        vault: any PushInstallationResetVault =
            PushInstallationVault.shared,
        clientFactory: @escaping ClientFactory = {
            try PushNotificationAPIClient.configured()
        }
    ) {
        self.vault = vault
        self.clientFactory = clientFactory
    }

    func preflightRequiresCleanup() throws -> Bool {
        do {
            let required = try vault.resetCleanupReadiness()
            return required
        } catch {
            throw error
        }
    }

    func cleanup() async -> PushInstallationResetCleanupResult {
        do {
            try vault.prepareCurrentIdentityForReset()
        } catch {
            return failedResult(
                stage: "prepare_tombstone",
                pendingCount: 1,
                error: error
            )
        }

        let tombstones: [PushDeactivationTombstone]
        do {
            tombstones = try vault.deactivationTombstones()
        } catch {
            return failedResult(
                stage: "read_tombstones",
                pendingCount: 1,
                error: error
            )
        }

        guard !tombstones.isEmpty else {
            do {
                try vault.deleteAllResetState()
                return PushInstallationResetCleanupResult(
                    completedCount: 0,
                    pendingCount: 0,
                    lastErrorCode: nil
                )
            } catch {
                return failedResult(
                    stage: "verify_empty_vault",
                    pendingCount: 1,
                    error: error
                )
            }
        }

        let client: any PushInstallationDeactivating
        do {
            client = try clientFactory()
        } catch {
            return failedResult(
                stage: "configure_client",
                pendingCount: tombstones.count,
                error: error
            )
        }

        var completedCount = 0
        var lastErrorCode: String?
        for tombstone in tombstones {
            do {
                try await client.deactivate(
                    installationID: tombstone.installationID,
                    credential: tombstone.credential
                )
                try vault.removeTombstone(
                    installationID: tombstone.installationID
                )
                completedCount += 1
            } catch
                where PushNotificationDeactivationError
                    .isAlreadyComplete(error)
            {
                do {
                    try vault.removeTombstone(
                        installationID: tombstone.installationID
                    )
                    completedCount += 1
                } catch {
                    lastErrorCode =
                        PushNotificationDeactivationError.code(error)
                }
            } catch {
                lastErrorCode =
                    PushNotificationDeactivationError.code(error)
            }
        }

        let remaining: [PushDeactivationTombstone]
        do {
            remaining = try vault.deactivationTombstones()
        } catch {
            return failedResult(
                stage: "verify_tombstones",
                pendingCount: max(1, tombstones.count - completedCount),
                error: error,
                completedCount: completedCount
            )
        }

        if remaining.isEmpty {
            do {
                // This explicitly removes both the current identity and the
                // tombstone account, then verifies neither remains.
                try vault.deleteAllResetState()
            } catch {
                return failedResult(
                    stage: "delete_push_vault",
                    pendingCount: 1,
                    error: error,
                    completedCount: completedCount
                )
            }
        }

        return PushInstallationResetCleanupResult(
            completedCount: completedCount,
            pendingCount: remaining.count,
            lastErrorCode: lastErrorCode
        )
    }

    private func failedResult(
        stage: String,
        pendingCount: Int,
        error: Error,
        completedCount: Int = 0
    ) -> PushInstallationResetCleanupResult {
        let code = PushNotificationDeactivationError.code(error)
        return PushInstallationResetCleanupResult(
            completedCount: completedCount,
            pendingCount: pendingCount,
            lastErrorCode: code
        )
    }
}

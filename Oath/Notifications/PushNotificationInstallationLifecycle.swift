import Foundation
import UIKit

struct PushDeactivationRetryResult: Equatable, Sendable {
    let pendingCount: Int
    let lastErrorCode: String?
}

enum PushNotificationDeactivationError {
    static func isAlreadyComplete(_ error: Error) -> Bool {
        guard let error = error as? PushNotificationAPIError else {
            return false
        }
        return switch error {
        case let .server(status, code):
            status == 404 && code == "installation_not_found"
        default:
            false
        }
    }

    static func code(_ error: Error) -> String {
        if let error = error as? PushNotificationAPIError {
            return error.diagnosticCode
        }
        if let error = error as? PushInstallationVaultError {
            return error.diagnosticCode
        }
        let raw = String(describing: type(of: error))
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_.-")
        )
        return String(
            raw.unicodeScalars
                .filter { allowed.contains($0) }
                .prefix(80)
                .map(Character.init)
        )
    }
}

@MainActor
final class PushNotificationInstallationLifecycle {
    private(set) var registrationAllowed = false

    private let vault: PushInstallationVault
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var isRetrying = false

    init(vault: PushInstallationVault = .shared) {
        self.vault = vault
    }

    func enableRegistration(
        topic: String,
        environment: String
    ) throws {
        registrationAllowed = true
        _ = try vault.prepareAPNSContext(
            topic: topic,
            environment: environment
        )
        UIApplication.shared.registerForRemoteNotifications()
    }

    func acceptAPNSToken(
        _ token: Data,
        topic: String,
        environment: String
    ) throws -> Bool {
        guard registrationAllowed else {
            UIApplication.shared.unregisterForRemoteNotifications()
            return false
        }
        _ = try vault.storeAPNSToken(
            token,
            topic: topic,
            environment: environment
        )
        return true
    }

    func requestAPNSTokenIfEnabled() {
        guard registrationAllowed else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func disableAndDeactivate() async -> PushDeactivationRetryResult {
        registrationAllowed = false
        UIApplication.shared.unregisterForRemoteNotifications()

        do {
            if try vault.currentIdentity() != nil {
                try vault.replaceCurrentWithTombstone()
            }
        } catch {
            let code = PushNotificationDeactivationError.code(error)
            scheduleRetry()
            return PushDeactivationRetryResult(
                pendingCount: 1,
                lastErrorCode: code
            )
        }
        return await retryPendingDeactivations()
    }

    func retryPendingDeactivations() async
        -> PushDeactivationRetryResult {
        guard !isRetrying else {
            let count = (try? vault.deactivationTombstones().count) ?? 1
            return PushDeactivationRetryResult(
                pendingCount: count,
                lastErrorCode: nil
            )
        }
        isRetrying = true
        defer { isRetrying = false }

        let tombstones: [PushDeactivationTombstone]
        do {
            tombstones = try vault.deactivationTombstones()
        } catch {
            let code = PushNotificationDeactivationError.code(error)
            scheduleRetry()
            return PushDeactivationRetryResult(
                pendingCount: 1,
                lastErrorCode: code
            )
        }
        guard !tombstones.isEmpty else {
            retryAttempt = 0
            retryTask?.cancel()
            retryTask = nil
            return PushDeactivationRetryResult(
                pendingCount: 0,
                lastErrorCode: nil
            )
        }

        let client: PushNotificationAPIClient
        do {
            client = try PushNotificationAPIClient.configured()
        } catch {
            let code = PushNotificationDeactivationError.code(error)
            scheduleRetry()
            return PushDeactivationRetryResult(
                pendingCount: tombstones.count,
                lastErrorCode: code
            )
        }

        var pendingCount = 0
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
            } catch
                where PushNotificationDeactivationError
                    .isAlreadyComplete(error) {
                do {
                    try vault.removeTombstone(
                        installationID: tombstone.installationID
                    )
                } catch {
                    pendingCount += 1
                    lastErrorCode =
                        PushNotificationDeactivationError.code(error)
                }
            } catch {
                pendingCount += 1
                lastErrorCode =
                    PushNotificationDeactivationError.code(error)
            }
        }

        if pendingCount > 0 {
            scheduleRetry()
        } else {
            retryAttempt = 0
            retryTask?.cancel()
            retryTask = nil
        }
        return PushDeactivationRetryResult(
            pendingCount: pendingCount,
            lastErrorCode: lastErrorCode
        )
    }

    func suspend() {
        registrationAllowed = false
        retryTask?.cancel()
        retryTask = nil
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryAttempt = min(retryAttempt + 1, 8)
        let exponent = min(retryAttempt - 1, 6)
        let delay = min(300, 5 * (1 << exponent))
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self else {
                return
            }
            retryTask = nil
            if !registrationAllowed {
                _ = await disableAndDeactivate()
            } else {
                _ = await retryPendingDeactivations()
            }
        }
    }
}

import Foundation
import Security
import UIKit

/// Resolves passcode readiness only after iOS can safely expose
/// `WhenUnlockedThisDeviceOnly` Keychain items.
///
/// The database intentionally becomes available earlier than the passcode
/// verifier. A cold launch can therefore restore a wallet while the
/// application is still inactive or protected data is unavailable. This
/// resolver bridges that lifecycle gap without ever interpreting a failed
/// Keychain read as disabled protection.
@MainActor
struct WalletLaunchPasscodeCredentialResolver {
    struct ProtectionState: Equatable, Sendable {
        let isApplicationActive: Bool
        let isProtectedDataAvailable: Bool

        var permitsCredentialRead: Bool {
            isApplicationActive && isProtectedDataAvailable
        }
    }

    struct Policy: Equatable, Sendable {
        let protectionCheckLimit: Int?
        let readinessAttemptLimit: Int?
        let protectionCheckDelayNanoseconds: UInt64
        let readinessRetryDelayNanoseconds: UInt64

        static let coldLaunch = Policy(
            // A locked device can keep protected Keychain data unavailable
            // for an arbitrary amount of time. Production launch therefore
            // waits until iOS exposes it instead of converting a timeout into
            // a false missing-credential recovery.
            protectionCheckLimit: nil,
            readinessAttemptLimit: nil,
            protectionCheckDelayNanoseconds: 100_000_000,
            readinessRetryDelayNanoseconds: 100_000_000
        )
    }

    typealias ProtectionStateProvider =
        @MainActor () -> ProtectionState
    typealias ReadinessProvider =
        @MainActor () async throws -> WalletPasscodeCredentialReadiness
    typealias Pause =
        @MainActor (_ nanoseconds: UInt64) async -> Void

    private let policy: Policy
    private let protectionState: ProtectionStateProvider
    private let readiness: ReadinessProvider
    private let pause: Pause

    init(
        database: WalletDatabase,
        policy: Policy = .coldLaunch
    ) {
        self.init(
            policy: policy,
            protectionState: {
                ProtectionState(
                    isApplicationActive:
                        UIApplication.shared.applicationState == .active,
                    isProtectedDataAvailable:
                        UIApplication.shared.isProtectedDataAvailable
                )
            },
            readiness: {
                try await database.passcodeCredentialReadiness()
            },
            pause: { nanoseconds in
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        )
    }

    init(
        policy: Policy,
        protectionState: @escaping ProtectionStateProvider,
        readiness: @escaping ReadinessProvider,
        pause: @escaping Pause
    ) {
        self.policy = policy
        self.protectionState = protectionState
        self.readiness = readiness
        self.pause = pause
    }

    func resolve() async throws -> WalletPasscodeCredentialReadiness {
        guard try await waitForProtectedApplicationState() else {
            return .unavailable(
                .keychainTemporarilyUnavailable(
                    errSecInteractionNotAllowed
                )
            )
        }

        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            let result = try await readiness()
            guard case let .unavailable(issue) = result,
                  issue.isColdLaunchRetryable else {
                return result
            }
            if let attemptLimit = policy.readinessAttemptLimit,
               attempt >= max(1, attemptLimit) {
                return result
            }

            await pause(policy.readinessRetryDelayNanoseconds)
        }
    }

    private func waitForProtectedApplicationState() async throws -> Bool {
        var check = 0
        while true {
            try Task.checkCancellation()
            check += 1
            if protectionState().permitsCredentialRead {
                return true
            }
            if let checkLimit = policy.protectionCheckLimit,
               check >= max(1, checkLimit) {
                return false
            }
            await pause(policy.protectionCheckDelayNanoseconds)
        }
    }
}

private extension WalletPasscodeCredentialIssue {
    var isColdLaunchRetryable: Bool {
        switch self {
        case .keychainTemporarilyUnavailable:
            true
        case .missingSecurityRecord, .credentialNotFound,
             .invalidCredentialData, .keychainAccessFailed,
             .persistenceVerificationFailed,
             .databaseUnavailable, .unexpected:
            false
        }
    }
}

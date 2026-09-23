import Foundation
import BiometricBridge
import GRDB
import Security
import SwiftUI
import UIKit
import WalletCore

struct WalletSecuritySettings: Equatable, Sendable {
    var appLockEnabled: Bool
    var biometricEnabled: Bool
    var autoLockDuration: WalletAutoLockDuration
    var privacyShieldEnabled: Bool

    var requiresAuthentication: Bool {
        appLockEnabled
    }

    var allowsBiometricAuthentication: Bool {
        requiresAuthentication && biometricEnabled
    }

    static let secureDefault = WalletSecuritySettings(
        appLockEnabled: true,
        biometricEnabled: false,
        autoLockDuration: .minute1,
        privacyShieldEnabled: false
    )
}

enum WalletAuthenticationRequirement: Equatable, Sendable {
    case none
    case biometrics
    case passcode
}

enum WalletAuthenticationRequirementPolicy {
    static func requirement(
        settings: WalletSecuritySettings,
        availability: WalletBiometricAvailability
    ) -> WalletAuthenticationRequirement {
        guard settings.requiresAuthentication else { return .none }
        return settings.allowsBiometricAuthentication
            && availability.isAvailable
            ? .biometrics
            : .passcode
    }
}

enum WalletAuthenticationEntryPresentation: Equatable, Sendable {
    case biometricPrompt
    case passcode
}

enum WalletAutoLockDuration: String, CaseIterable, Identifiable, Sendable {
    case immediately
    case minute1
    case minutes5
    case minutes15
    case hour1
    case hours4

    var id: String { rawValue }

    var seconds: Int? {
        switch self {
        case .immediately:
            0
        case .minute1:
            60
        case .minutes5:
            300
        case .minutes15:
            900
        case .hour1:
            3_600
        case .hours4:
            14_400
        }
    }

    var titleKey: String {
        switch self {
        case .immediately:
            "settings.security.auto_lock.immediately"
        case .minute1:
            "settings.security.auto_lock.minute_1"
        case .minutes5:
            "settings.security.auto_lock.minutes_5"
        case .minutes15:
            "settings.security.auto_lock.minutes_15"
        case .hour1:
            "settings.security.auto_lock.hour_1"
        case .hours4:
            "settings.security.auto_lock.hours_4"
        }
    }

    init(seconds: Int?) {
        switch seconds {
        case 0:
            self = .immediately
        case 30, 60:
            self = .minute1
        case 300:
            self = .minutes5
        case 900:
            self = .minutes15
        case 3_600:
            self = .hour1
        case 14_400, nil:
            self = .hours4
        default:
            self = .minute1
        }
    }
}

struct WalletSecretExportAuthorization: Hashable, Sendable {
    private let walletID: String
    private let expiresAt: Date

    private init(walletID: String, expiresAt: Date) {
        self.walletID = walletID
        self.expiresAt = expiresAt
    }

    static func whenProtectionIsDisabled(
        walletID: String,
        database: WalletDatabase
    ) async throws -> WalletSecretExportAuthorization {
        let protectionIsDisabled = try await database.pool.read {
            database in
            guard let settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: WalletDatabase.defaultProfileID
            ) else {
                throw WalletSecurityPersistenceError.missingSettings
            }
            return !settings.appLockEnabled
        }
        guard protectionIsDisabled else {
            throw WalletSecretExportAuthorizationError
                .authenticationRequired
        }
        return Self(
            walletID: walletID,
            expiresAt: Date().addingTimeInterval(30)
        )
    }

    static func afterAuthentication(
        walletID: String,
        grant: WalletAuthenticationGrant,
        database: WalletDatabase
    ) async throws -> WalletSecretExportAuthorization {
        let settings = try await database.walletSecuritySettings()
        guard grant.permits(settings: settings) else {
            throw WalletSecretExportAuthorizationError
                .authenticationRequired
        }
        return Self(
            walletID: walletID,
            expiresAt: Date().addingTimeInterval(30)
        )
    }

    func permits(walletID: String) -> Bool {
        self.walletID == walletID && Date() <= expiresAt
    }
}

enum WalletSecretExportAuthorizationError: Error {
    case authenticationRequired
}

struct WalletPasscodeCredential: Codable, Sendable {
    let algorithm: String
    let iterations: UInt32
    let salt: Data
    let verifier: Data

    static func make(passcode: String) throws -> Self {
        guard passcode.count == 6,
              passcode.allSatisfy({ $0 >= "0" && $0 <= "9" })
        else {
            throw WalletCreationPersistenceError.invalidPasscode
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        )
        guard status == errSecSuccess else {
            throw WalletCreationPersistenceError.randomGenerationFailed(status)
        }

        let salt = Data(bytes)
        let iterations: UInt32 = 210_000
        guard let verifier = PBKDF2.hmacSha256(
            password: Data(passcode.utf8),
            salt: salt,
            iterations: iterations,
            dkLen: 32
        ) else {
            throw WalletCreationPersistenceError.passcodeDerivationFailed
        }

        return Self(
            algorithm: "pbkdf2-hmac-sha256",
            iterations: iterations,
            salt: salt,
            verifier: verifier
        )
    }

    static func decodeStoredData(_ data: Data) throws -> Self {
        let credential = try JSONDecoder().decode(Self.self, from: data)
        guard credential.algorithm == "pbkdf2-hmac-sha256",
              credential.iterations == 210_000,
              credential.salt.count == 32,
              credential.verifier.count == 32
        else {
            throw WalletSecretVaultError.invalidStoredData
        }
        return credential
    }

    func matches(passcode: String) -> Bool {
        guard algorithm == "pbkdf2-hmac-sha256",
              let candidate = PBKDF2.hmacSha256(
                password: Data(passcode.utf8),
                salt: salt,
                iterations: iterations,
                dkLen: UInt32(verifier.count)
              )
        else {
            return false
        }
        return candidate.constantTimeEquals(verifier)
    }
}

private extension Data {
    func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        return zip(self, other).reduce(UInt8(0)) { partial, pair in
            partial | (pair.0 ^ pair.1)
        } == 0
    }
}

enum WalletBiometryKind: String, Sendable {
    case faceID
    case touchID
    case opticID
    case generic

    var titleKey: String {
        switch self {
        case .faceID:
            "settings.security.face_id"
        case .touchID:
            "settings.security.touch_id"
        case .opticID:
            "settings.security.optic_id"
        case .generic:
            "settings.security.biometrics.title"
        }
    }

    var unlockActionKey: String {
        switch self {
        case .faceID:
            "security.authentication.use_face_id"
        case .touchID:
            "security.authentication.use_touch_id"
        case .opticID:
            "security.authentication.use_optic_id"
        case .generic:
            "security.authentication.use_biometrics"
        }
    }

    var systemImageName: String {
        switch self {
        case .faceID:
            "faceid"
        case .touchID:
            "touchid"
        case .opticID:
            "opticid"
        case .generic:
            "person.badge.key"
        }
    }
}

struct WalletBiometricAvailability: Equatable, Sendable {
    let isAvailable: Bool
    let kind: WalletBiometryKind
}

enum WalletBiometricAuthenticationError: Error, Equatable {
    case unavailable
    case cancelled
    case fallbackRequested
    case interrupted
    case busy
    case unsuccessful
}

struct WalletLaunchSecurityRecoveryProof: Sendable {
    private let expiresAt: Date

    fileprivate init() {
        expiresAt = Date().addingTimeInterval(30)
    }

    func permitsPasscodeCredentialRecovery() -> Bool {
        Date() <= expiresAt
    }
}

enum WalletSecurityPersistenceError: Error {
    case missingSettings
    case appLockAlreadyEnabled
}

enum WalletLaunchSecurityRecoveryError: Error {
    case invalidRecoveryAuthorization
    case passcodeCredentialAvailable
    case passcodeCredentialRecoveryUnavailable
    case securityStateChanged
}

@MainActor
final class WalletBiometricAuthenticator:
    NSObject,
    @preconcurrency EVMBiometricAuthenticationBridgeDelegate
{
    static let shared = WalletBiometricAuthenticator()

    private var activeBridge: EVMBiometricAuthenticationBridge?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var activeRequestID: UUID?
    private var activeSource = "none"

    private override init() {
        super.init()
    }

    func availability() -> WalletBiometricAvailability {
        let bridgeKind =
            EVMBiometricAuthenticationBridge.availableBiometryKind()
        return WalletBiometricAvailability(
            isAvailable: bridgeKind != .unavailable,
            kind: Self.kind(for: bridgeKind)
        )
    }

    func authenticate(
        reason: String,
        source: String = "unspecified"
    ) async throws {
        guard continuation == nil else {
            throw WalletBiometricAuthenticationError.busy
        }

        try await waitUntilApplicationIsActive()
        await Task.yield()

        let bridgeKind =
            EVMBiometricAuthenticationBridge.availableBiometryKind()
        guard bridgeKind != .unavailable else {
            throw WalletBiometricAuthenticationError.unavailable
        }

        try Task.checkCancellation()
        // Another caller may have resumed during the foreground preflight.
        guard continuation == nil else {
            throw WalletBiometricAuthenticationError.busy
        }
        let requestID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                activeRequestID = requestID
                activeSource = source
                let bridge = EVMBiometricAuthenticationBridge()
                bridge.delegate = self
                activeBridge = bridge
                bridge.startAuthentication(
                    withReason: reason,
                    fallbackTitle: WalletLocalization.string(
                        "security.authentication.use_passcode"
                    ),
                    cancelTitle: WalletLocalization.string("common.cancel")
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelActiveAuthentication(requestID: requestID)
            }
        }
        try validateCompletedAuthentication()
    }

    func authenticateForLaunchSecurityRecovery(
        reason: String
    ) async throws -> WalletLaunchSecurityRecoveryProof {
        guard continuation == nil else {
            throw WalletBiometricAuthenticationError.busy
        }
        try await waitUntilApplicationIsActive()
        await Task.yield()
        guard EVMBiometricAuthenticationBridge
            .isDeviceOwnerAuthenticationAvailable() else {
            throw WalletBiometricAuthenticationError.unavailable
        }

        try Task.checkCancellation()
        guard continuation == nil else {
            throw WalletBiometricAuthenticationError.busy
        }
        let requestID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                activeRequestID = requestID
                let bridge = EVMBiometricAuthenticationBridge()
                bridge.delegate = self
                activeBridge = bridge
                bridge.startDeviceOwnerAuthentication(
                    withReason: reason,
                    cancelTitle: WalletLocalization.string("common.cancel")
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelActiveAuthentication(requestID: requestID)
            }
        }
        try validateCompletedAuthentication()
        return WalletLaunchSecurityRecoveryProof()
    }

    func biometricAuthenticationBridge(
        _ bridge: EVMBiometricAuthenticationBridge,
        didCompleteWith result: EVMBiometricAuthenticationResult
    ) {
        guard bridge === activeBridge, let continuation else {
            return
        }
        self.continuation = nil
        activeRequestID = nil
        activeBridge = nil
        activeSource = "none"

        switch result {
        case .succeeded:
            continuation.resume()
        case .cancelled:
            continuation.resume(
                throwing: WalletBiometricAuthenticationError.cancelled
            )
        case .fallbackRequested:
            continuation.resume(
                throwing:
                    WalletBiometricAuthenticationError.fallbackRequested
            )
        case .interrupted:
            continuation.resume(
                throwing: WalletBiometricAuthenticationError.interrupted
            )
        case .unavailable:
            continuation.resume(
                throwing: WalletBiometricAuthenticationError.unavailable
            )
        default:
            continuation.resume(
                throwing: WalletBiometricAuthenticationError.unsuccessful
            )
        }
    }

    private func cancelActiveAuthentication(requestID: UUID) {
        guard activeRequestID == requestID, let continuation else { return }
        self.continuation = nil
        activeRequestID = nil
        let bridge = activeBridge
        activeBridge = nil
        activeSource = "none"
        bridge?.cancelAuthentication()
        continuation.resume(throwing: CancellationError())
    }

    private func waitUntilApplicationIsActive() async throws {
        guard UIApplication.shared.applicationState != .active else {
            return
        }

        let notifications = NotificationCenter.default.notifications(
            named: UIApplication.didBecomeActiveNotification
        )
        guard UIApplication.shared.applicationState != .active else {
            return
        }
        for await _ in notifications {
            try Task.checkCancellation()
            if UIApplication.shared.applicationState == .active {
                return
            }
        }
        try Task.checkCancellation()
    }

    private func validateCompletedAuthentication() throws {
        try Task.checkCancellation()
        // LocalAuthentication succeeds before its system UI finishes dismissing.
        // Foreground inactivity is not failed authentication, so return the
        // verified result immediately. Presentation authorization accepts that
        // transient inactive state and only rejects a real background trip.
        guard UIApplication.shared.applicationState != .background else {
            throw WalletBiometricAuthenticationError.interrupted
        }
    }

    private static func resultCode(
        _ result: EVMBiometricAuthenticationResult
    ) -> String {
        switch result {
        case .succeeded: "succeeded"
        case .cancelled: "cancelled"
        case .fallbackRequested: "fallback_requested"
        case .interrupted: "interrupted"
        case .unavailable: "unavailable"
        default: "unsuccessful"
        }
    }

    private static func kind(
        for type: EVMBiometryKind
    ) -> WalletBiometryKind {
        switch type {
        case .faceID:
            .faceID
        case .touchID:
            .touchID
        case .opticID:
            .opticID
        default:
            .generic
        }
    }
}

extension Notification.Name {
    static let walletSecuritySettingsDidChange = Notification.Name(
        "WalletSecuritySettingsDidChange"
    )
}

extension WalletDatabase {
    func walletSecuritySettings() async throws -> WalletSecuritySettings {
        try await pool.read { database in
            guard let record = try DBUserSettingsRecord.fetchOne(
                database,
                key: Self.defaultProfileID
            ) else {
                return .secureDefault
            }
            return WalletSecuritySettings(
                appLockEnabled: record.appLockEnabled,
                biometricEnabled:
                    record.appLockEnabled && record.biometricEnabled,
                autoLockDuration: WalletAutoLockDuration(
                    seconds: record.autoLockSeconds
                ),
                privacyShieldEnabled: record.privacyShieldEnabled
            )
        }
    }

    func disableAppLock() async throws {
        try await updateSecuritySettings { record in
            record.appLockEnabled = false
            record.biometricEnabled = false
        }
    }

    func enableAppLock(
        passcode: String,
        vault: WalletSecretVault = .shared
    ) async throws {
        let credential = try WalletPasscodeCredential.make(
            passcode: passcode
        )
        let newReference = try vault.storePasscodeCredential(
            JSONEncoder().encode(credential)
        )
        let oldReference: String?

        do {
            oldReference = try await pool.write { database in
                guard var settings = try DBUserSettingsRecord.fetchOne(
                    database,
                    key: Self.defaultProfileID
                ) else {
                    throw WalletSecurityPersistenceError.missingSettings
                }
                guard !settings.appLockEnabled else {
                    throw WalletSecurityPersistenceError
                        .appLockAlreadyEnabled
                }

                let now = Date().timeIntervalSince1970
                let existingSecurity =
                    try DBProfileSecurityRecord.fetchOne(
                        database,
                        key: Self.defaultProfileID
                    )

                if var security = existingSecurity {
                    security.passcodeKeychainReference = newReference
                    security.failedAttemptCount = 0
                    security.lockedUntil = nil
                    security.updatedAt = now
                    try security.update(database)
                } else {
                    try DBProfileSecurityRecord(
                        profileID: Self.defaultProfileID,
                        passcodeKeychainReference: newReference,
                        failedAttemptCount: 0,
                        lockedUntil: nil,
                        updatedAt: now
                    ).insert(database)
                }

                settings.appLockEnabled = true
                settings.biometricEnabled = false
                settings.updatedAt = now
                try settings.update(database)

                return existingSecurity?.passcodeKeychainReference
            }
        } catch {
            try? vault.deletePasscodeCredential(reference: newReference)
            throw error
        }

        if let oldReference, oldReference != newReference {
            try? vault.deletePasscodeCredential(reference: oldReference)
        }
        await postSecuritySettingsDidChange()
    }

    func recoverPasscodeCredential(
        passcode: String,
        authorization: WalletLaunchSecurityRecoveryProof,
        vault: WalletSecretVault = .shared
    ) async throws {
        guard authorization.permitsPasscodeCredentialRecovery() else {
            throw WalletLaunchSecurityRecoveryError
                .invalidRecoveryAuthorization
        }

        let expectedReference = try await pool.read { database in
            guard let settings = try DBUserSettingsRecord.fetchOne(
                database,
                key: Self.defaultProfileID
            ), settings.appLockEnabled else {
                throw WalletLaunchSecurityRecoveryError
                    .passcodeCredentialRecoveryUnavailable
            }
            return try DBProfileSecurityRecord.fetchOne(
                database,
                key: Self.defaultProfileID
            )?.passcodeKeychainReference
        }

        if let expectedReference {
            do {
                let _: WalletPasscodeCredential =
                    try vault.validatedPasscodeCredential(
                        reference: expectedReference,
                        decode: WalletPasscodeCredential.decodeStoredData
                    )
                throw WalletLaunchSecurityRecoveryError
                    .passcodeCredentialAvailable
            } catch let error as WalletLaunchSecurityRecoveryError {
                throw error
            } catch {
                switch WalletPasscodeCredentialIssue.classify(error) {
                case .credentialNotFound, .invalidCredentialData:
                    break
                case .missingSecurityRecord,
                     .keychainTemporarilyUnavailable,
                     .keychainAccessFailed,
                     .persistenceVerificationFailed,
                     .databaseUnavailable,
                     .unexpected:
                    throw WalletLaunchSecurityRecoveryError
                        .passcodeCredentialRecoveryUnavailable
                }
            }
        }

        let credential = try WalletPasscodeCredential.make(
            passcode: passcode
        )
        let newReference = try vault.storePasscodeCredential(
            JSONEncoder().encode(credential)
        )

        do {
            try await pool.write { database in
                guard var settings = try DBUserSettingsRecord.fetchOne(
                    database,
                    key: Self.defaultProfileID
                ), settings.appLockEnabled else {
                    throw WalletLaunchSecurityRecoveryError
                        .securityStateChanged
                }
                let currentSecurity =
                    try DBProfileSecurityRecord.fetchOne(
                        database,
                        key: Self.defaultProfileID
                    )
                guard currentSecurity?.passcodeKeychainReference
                        == expectedReference else {
                    throw WalletLaunchSecurityRecoveryError
                        .securityStateChanged
                }

                let now = Date().timeIntervalSince1970
                if var security = currentSecurity {
                    security.passcodeKeychainReference = newReference
                    security.failedAttemptCount = 0
                    security.lockedUntil = nil
                    security.updatedAt = now
                    try security.update(database)
                } else {
                    try DBProfileSecurityRecord(
                        profileID: Self.defaultProfileID,
                        passcodeKeychainReference: newReference,
                        failedAttemptCount: 0,
                        lockedUntil: nil,
                        updatedAt: now
                    ).insert(database)
                }
                settings.biometricEnabled = false
                settings.updatedAt = now
                try settings.update(database)
            }
        } catch {
            try? vault.deletePasscodeCredential(reference: newReference)
            throw error
        }

        if let expectedReference, expectedReference != newReference {
            try? vault.deletePasscodeCredential(
                reference: expectedReference
            )
        }
        await postSecuritySettingsDidChange()
    }

    func setBiometricEnabled(
        _ isEnabled: Bool,
        vault: WalletSecretVault = .shared
    ) async throws {
        if isEnabled {
            try await preparePasscodeCredentialPersistence(vault: vault)
        }
        try await updateSecuritySettings { record in
            record.biometricEnabled = record.appLockEnabled && isEnabled
        }
    }

    func setAutoLockDuration(
        _ duration: WalletAutoLockDuration
    ) async throws {
        try await updateSecuritySettings { record in
            record.autoLockSeconds = duration.seconds
        }
    }

    func setPrivacyShieldEnabled(_ isEnabled: Bool) async throws {
        try await updateSecuritySettings { record in
            record.privacyShieldEnabled = isEnabled
        }
    }

    private func updateSecuritySettings(
        _ update: @Sendable (inout DBUserSettingsRecord) -> Void
    ) async throws {
        try await pool.write { database in
            guard var record = try DBUserSettingsRecord.fetchOne(
                database,
                key: Self.defaultProfileID
            ) else {
                throw WalletSecurityPersistenceError.missingSettings
            }
            update(&record)
            record.updatedAt = Date().timeIntervalSince1970
            try record.update(database)
        }
        await postSecuritySettingsDidChange()
    }

    private func postSecuritySettingsDidChange() async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .walletSecuritySettingsDidChange,
                object: nil
            )
        }
    }
}

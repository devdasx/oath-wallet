import OathDiagnostics
import Foundation
import LocalAuthentication
import Security

enum OathBiometricCredentialError: Error, Equatable, Sendable {
    case missing, invalid, cancelled, unavailable
    case keychain(OSStatus)

    var isExpectedAuthenticationOutcome: Bool {
        switch self {
        case .missing, .cancelled, .unavailable, .keychain(errSecAuthFailed): return true
        case .invalid, .keychain: return false
        }
    }
}

/// Configuration is immutable once dispatched. Only invalidate() can run
/// concurrently, as supported by LocalAuthentication to cancel an active read.
private final class OathBiometricKeychainRead: @unchecked Sendable {
    private let context: LAContext
    private let query: CFDictionary

    init(identity: [String: Any], reason: String, passcodeTitle: String) {
        let context = LAContext()
        context.localizedReason = reason
        context.localizedFallbackTitle = passcodeTitle
        context.localizedCancelTitle = passcodeTitle
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var query = identity
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        self.context = context
        self.query = query as CFDictionary
    }

    func invalidate() { context.invalidate() }

    func read() throws -> Data {
        var result: CFTypeRef?
        // The protected item's actual key is required; a policy match alone
        // never grants access. Do not substitute the device PIN for the app PIN.
        let status = SecItemCopyMatching(query, &result)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: throw OathBiometricCredentialError.missing
        case errSecUserCanceled: throw OathBiometricCredentialError.cancelled
        case errSecNotAvailable, errSecInteractionNotAllowed: throw OathBiometricCredentialError.unavailable
        default: throw OathBiometricCredentialError.keychain(status)
        }
        guard let data = result as? Data else { throw OathBiometricCredentialError.invalid }
        return data
    }
}

/// One-shot bridge for a synchronous OS read. A task-group race would still
/// wait for an unresponsive Keychain call; this resumes the caller independently
/// and ignores late replies. The lock protects all completion state.
final class OathBiometricRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let invalidate: @Sendable () -> Void
    private var continuation: CheckedContinuation<Data, any Error>?
    private var completed = false
    private var earlyResult: Result<Data, any Error>?

    init(invalidate: @escaping @Sendable () -> Void) { self.invalidate = invalidate }

    func read(timeout: TimeInterval = 20, operation: @escaping @Sendable () throws -> Data) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let early = lock.withLock {
                    if completed { return earlyResult }
                    self.continuation = continuation
                    return nil as Result<Data, any Error>?
                }
                if let early { continuation.resume(with: early); return }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(OathBiometricCredentialError.unavailable))
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    guard !self.lock.withLock({ self.completed }) else { return }
                    self.finish(Result { try operation() })
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        let delivery = lock.withLock { () -> (Bool, CheckedContinuation<Data, any Error>?) in
            guard !completed else { return (false, nil) }
            completed = true
            let target = continuation
            continuation = nil
            if target == nil { earlyResult = result }
            return (true, target)
        }
        guard delivery.0 else { return }
        // Close the OS prompt before making the app passcode screen usable.
        invalidate()
        delivery.1?.resume(with: result)
    }
}

protocol OathBiometricCredentialStoring: Sendable {
    func hasEnrollment() async throws -> Bool
    func disable() async throws
    func read(reason: String) async throws -> Data
    func enableIfAvailable(strings: OathLocalizer,
                           credentialProvider: (@Sendable () async throws -> Data)?) async -> OathBiometricSetupResult
}

/// The protected Keychain read owns authentication. A face match alone is not
/// permission to open a wallet: the device must release its actual saved key.
/// Interactive reads run off the actor so a stalled OS prompt cannot block
/// passcode fallback. Cancellation and a deadline invalidate that exact context.
actor OathBiometricCredentialStore: OathBiometricCredentialStoring {
    let service: String
    private let installation: OathInstallationSecurity?

    // Production is bound by default. Only isolated native credential tests
    // explicitly opt out with nil to exercise raw Keychain behavior.
    init(service: String, installation: OathInstallationSecurity? = .shared) {
        self.service = service
        self.installation = installation
    }

    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "biometric-enrollment-v1",
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }

    func hasEnrollment() throws -> Bool {
        try installation?.prepare()
        let context = LAContext()
        context.interactionNotAllowed = true
        defer { context.invalidate() }
        var query = identity
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var attributes: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &attributes)
        if status == errSecItemNotFound { return false }
        if status == errSecSuccess || status == errSecInteractionNotAllowed { return true }
        throw OathBiometricCredentialError.keychain(status)
    }

    func disable() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OathBiometricCredentialError.keychain(status)
        }
    }

    func read(reason: String) async throws -> Data {
        try Task.checkCancellation()
        try installation?.prepare()
        let query = OathBiometricKeychainRead(identity: identity, reason: reason,
            passcodeTitle: OathLocalizer.current.text(.unlockPasscodeTitle))
        let request = OathBiometricRequest(invalidate: { query.invalidate() })
        var data = try await request.read { try query.read() }
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        try Task.checkCancellation()
        do { return try installation?.open(data, context: "biometric:\(service)") ?? data }
        catch { OathDiagnostics.record(error); throw OathBiometricCredentialError.invalid }
    }

    func enableIfAvailable(strings: OathLocalizer,
                           credentialProvider: (@Sendable () async throws -> Data)?) async -> OathBiometricSetupResult {
        let context = LAContext()
        defer { context.invalidate() }
        context.localizedFallbackTitle = ""
        context.localizedCancelTitle = strings.text(.notNow)
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var capabilityError: NSError?
        let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                   error: &capabilityError)
        let kind: OathBiometricKind?
        switch context.biometryType {
        case .faceID: kind = .faceID
        case .touchID: kind = .touchID
        default: kind = nil
        }
        guard available, let kind else {
            if let error = capabilityError as? LAError, error.code == .biometryLockout {
                return .failed(kind: kind, reason: .lockedOut)
            }
            return .unavailable
        }
        do {
            let authenticated = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: strings.format(.enableBiometrics, strings.invariant(kind.name)))
            guard authenticated else { return .failed(kind: kind, reason: .notRecognized) }
            try Task.checkCancellation()
            var credential: Data
            if let credentialProvider { credential = try await credentialProvider() }
            else {
                // Only the reusable verifier-only setup component uses a token.
                // The wallet always supplies its wallet-bound encryption key.
                credential = Data(count: 32)
                guard credential.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else {
                    throw OathBiometricSetupError.storage
                }
            }
            defer { credential.resetBytes(in: credential.startIndex..<credential.endIndex) }
            try save(credential, context: context)
            return .enabled(kind)
        } catch is CancellationError {
            return .failed(kind: kind, reason: .interrupted)
        } catch let error as LAError { OathDiagnostics.record(error);
            return .failed(kind: kind, reason: Self.map(error.code))
        } catch { OathDiagnostics.record(error); return .failed(kind: kind, reason: .storage) }
    }

    private static func map(_ error: LAError.Code) -> OathBiometricSetupError {
        switch error {
        case .userCancel, .userFallback: .cancelled
        case .systemCancel, .appCancel, .notInteractive, .invalidContext: .interrupted
        case .biometryLockout: .lockedOut
        case .authenticationFailed: .notRecognized
        default: .unavailable
        }
    }

    private func save(_ credential: Data, context: LAContext) throws {
        try Task.checkCancellation()
        let stored = try installation?.seal(credential, context: "biometric:\(service)") ?? credential
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error
        ) else {
            _ = error?.takeRetainedValue()
            throw OathBiometricSetupError.storage
        }
        var query = identity
        query[kSecUseAuthenticationContext as String] = context
        let attributes: [String: Any] = [
            kSecAttrAccessControl as String: access,
            kSecValueData as String: stored
        ]
        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess else {
                throw OathBiometricSetupError.storage
            }
        } else if status != errSecSuccess {
            throw OathBiometricSetupError.storage
        }
    }
}

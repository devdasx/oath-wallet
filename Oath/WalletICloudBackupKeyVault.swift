import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

typealias WalletPasskeyPresentationAnchor = ASPresentationAnchor

struct WalletBackupPasskeyRegistration: Sendable {
    let credentialID: Data
    let wrappingKey: SymmetricKey
}

protocol WalletBackupPasskeyAuthorizing: Sendable {
    @MainActor
    func register(
        walletID: String,
        walletName: String,
        prfSalt: Data,
        presentationAnchor: WalletPasskeyPresentationAnchor?
    ) async throws -> WalletBackupPasskeyRegistration

    @MainActor
    func deriveWrappingKey(
        walletID: String,
        credentialID: Data,
        prfSalt: Data,
        presentationAnchor: WalletPasskeyPresentationAnchor?
    ) async throws -> SymmetricKey
}

enum WalletBackupPasskeyIdentity {
    static let relyingPartyIdentifier = "aperturex.io"
    static let prfSaltByteCount = 32

    static func userHandle(walletID: String) -> Data {
        Data(
            SHA256.hash(
                data: Data(
                    "com.aperture.wallet.cloud-backup.user.\(walletID)"
                        .utf8
                )
            )
        )
    }

    static func secureRandomData(count: Int) throws -> Data {
        guard count > 0 else {
            throw WalletCloudBackupError.randomGenerationFailed(
                errSecParam
            )
        }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        )
        guard status == errSecSuccess else {
            throw WalletCloudBackupError.randomGenerationFailed(status)
        }
        return Data(bytes)
    }
}

@MainActor
enum WalletPasskeyPresentationCoordinator {
    private static let diagnosticDomain =
        "com.aperture.wallet.passkey.presentation"

    static func activeAnchor(
        _ anchor: WalletPasskeyPresentationAnchor?
    ) async throws -> WalletPasskeyPresentationAnchor {
        guard let anchor else {
            throw presentationFailure(
                code: 1,
                description: "presentation_anchor_unavailable"
            )
        }

        while true {
            try Task.checkCancellation()

            guard let scene = anchor.windowScene else {
                throw presentationFailure(
                    code: 2,
                    description: "presentation_anchor_detached"
                )
            }
            guard !anchor.isHidden, anchor.alpha > 0 else {
                throw presentationFailure(
                    code: 3,
                    description: "presentation_anchor_hidden"
                )
            }

            if scene.activationState == .foregroundActive,
               UIApplication.shared.applicationState == .active
            {
                await Task.yield()
                guard anchor.windowScene === scene,
                      !anchor.isHidden,
                      anchor.alpha > 0
                else {
                    continue
                }
                return anchor
            }

            if scene.activationState != .foregroundActive {
                await waitForSceneActivation(scene)
            } else {
                await waitForApplicationActivation()
            }
        }
    }

    private static func waitForSceneActivation(
        _ scene: UIWindowScene
    ) async {
        let notifications = NotificationCenter.default.notifications(
            named: UIScene.didActivateNotification
        )
        guard scene.activationState != .foregroundActive else {
            return
        }
        for await notification in notifications {
            if Task.isCancelled {
                return
            }
            if let activatedScene = notification.object as? UIScene,
               activatedScene === scene
            {
                return
            }
            if scene.activationState == .foregroundActive {
                return
            }
        }
    }

    private static func waitForApplicationActivation() async {
        let notifications = NotificationCenter.default.notifications(
            named: UIApplication.didBecomeActiveNotification
        )
        guard UIApplication.shared.applicationState != .active else {
            return
        }
        for await _ in notifications {
            return
        }
    }

    private static func presentationFailure(
        code: Int,
        description: String
    ) -> WalletCloudBackupFailure {
        WalletCloudBackupFailure(
            category: .passkeyPresentationUnavailable,
            diagnostic: WalletCloudBackupDiagnostic(
                domain: diagnosticDomain,
                code: code,
                description: description
            )
        )
    }
}

protocol WalletBackupDataKeyStoring: Sendable {
    func dataKey(
        walletID: String,
        credentialID: Data
    ) async throws -> SymmetricKey?

    func storeDataKey(
        _ key: SymmetricKey,
        walletID: String,
        credentialID: Data
    ) async throws

    func deleteDataKey(walletID: String) async throws
    func removeAllDataKeys() async throws
}

actor WalletBackupDataKeyStore: WalletBackupDataKeyStoring {
    static let shared = WalletBackupDataKeyStore()

    private struct CachedDataKey: Codable {
        let credentialDigest: Data
        let keyData: Data
    }

    private static let referencePrefix =
        "icloud-passkey-backup-data-key."

    private let vault: WalletSecretVault

    init(vault: WalletSecretVault = .shared) {
        self.vault = vault
    }

    nonisolated static func reference(walletID: String) -> String {
        let digest = SHA256.hash(
            data: Data(
                "com.aperture.wallet.cloud-backup.data-key.\(walletID)"
                    .utf8
            )
        )
        return referencePrefix
            + digest.map { String(format: "%02x", $0) }.joined()
    }

    func dataKey(
        walletID: String,
        credentialID: Data
    ) async throws -> SymmetricKey? {
        let encoded: Data
        do {
            encoded = try vault.data(
                reference: Self.reference(walletID: walletID)
            )
        } catch WalletSecretVaultError.itemNotFound {
            return nil
        } catch {
            throw Self.mapVaultError(error)
        }

        guard let cached = try? JSONDecoder().decode(
            CachedDataKey.self,
            from: encoded
        ), cached.credentialDigest == Self.credentialDigest(credentialID),
           cached.keyData.count == 32
        else {
            return nil
        }
        return SymmetricKey(data: cached.keyData)
    }

    func storeDataKey(
        _ key: SymmetricKey,
        walletID: String,
        credentialID: Data
    ) async throws {
        let keyData = key.withUnsafeBytes { Data($0) }
        guard !walletID.isEmpty,
              !credentialID.isEmpty,
              keyData.count == 32,
              let encoded = try? JSONEncoder().encode(
                CachedDataKey(
                    credentialDigest: Self.credentialDigest(
                        credentialID
                    ),
                    keyData: keyData
                )
              )
        else {
            throw WalletCloudBackupError.backupKeyUnavailable
        }
        do {
            try vault.replace(
                encoded,
                kind: .cloudBackupDataKey,
                reference: Self.reference(walletID: walletID)
            )
        } catch {
            throw Self.mapVaultError(error)
        }
    }

    func deleteDataKey(walletID: String) async throws {
        do {
            try vault.deleteIfPresent(
                reference: Self.reference(walletID: walletID)
            )
        } catch {
            throw Self.mapVaultError(error)
        }
    }

    func removeAllDataKeys() async throws {
        do {
            for reference in try vault.allReferences()
            where reference.hasPrefix(Self.referencePrefix) {
                try vault.deleteIfPresent(reference: reference)
            }
        } catch {
            throw Self.mapVaultError(error)
        }
    }

    private nonisolated static func credentialDigest(
        _ credentialID: Data
    ) -> Data {
        Data(SHA256.hash(data: credentialID))
    }

    private nonisolated static func mapVaultError(
        _ error: Error
    ) -> WalletCloudBackupError {
        switch error as? WalletSecretVaultError {
        case let .temporarilyUnavailable(status),
             let .unexpectedStatus(status):
            return .keychainFailure(status)
        case .itemNotFound:
            return .backupKeyUnavailable
        case .invalidReference, .invalidStoredData,
             .persistenceVerificationFailed, .referenceConflict, .none:
            return .backupKeyUnavailable
        }
    }
}

final class WalletBackupPasskeyAuthorizer:
    WalletBackupPasskeyAuthorizing,
    @unchecked Sendable
{
    static let shared = WalletBackupPasskeyAuthorizer()

    private let relyingPartyIdentifier: String

    init(
        relyingPartyIdentifier: String =
            WalletBackupPasskeyIdentity.relyingPartyIdentifier
    ) {
        self.relyingPartyIdentifier = relyingPartyIdentifier
    }

    @MainActor
    func register(
        walletID: String,
        walletName: String,
        prfSalt: Data,
        presentationAnchor: WalletPasskeyPresentationAnchor?
    ) async throws -> WalletBackupPasskeyRegistration {
        try validateInputs(
            walletID: walletID,
            credentialID: nil,
            prfSalt: prfSalt
        )
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: relyingPartyIdentifier
        )
        let request = provider.createCredentialRegistrationRequest(
            challenge: try WalletBackupPasskeyIdentity.secureRandomData(
                count: 32
            ),
            name: walletName,
            userID: WalletBackupPasskeyIdentity.userHandle(
                walletID: walletID
            ),
            requestStyle: .standard
        )
        request.displayName = walletName
        request.userVerificationPreference = .required
        request.prf = .inputValues(
            .init(saltInput1: prfSalt)
        )

        let authorization = try await authorize(
            request,
            presentationAnchor: presentationAnchor
        )
        guard let credential = authorization.credential as?
                ASAuthorizationPlatformPublicKeyCredentialRegistration,
              !credential.credentialID.isEmpty
        else {
            throw WalletCloudBackupError.invalidPasskeyCredential
        }
        guard let prf = credential.prf,
              prf.isSupported,
              let wrappingKey = prf.first
        else {
            throw WalletCloudBackupError.passkeyPRFUnavailable
        }
        return WalletBackupPasskeyRegistration(
            credentialID: credential.credentialID,
            wrappingKey: wrappingKey
        )
    }

    @MainActor
    func deriveWrappingKey(
        walletID: String,
        credentialID: Data,
        prfSalt: Data,
        presentationAnchor: WalletPasskeyPresentationAnchor?
    ) async throws -> SymmetricKey {
        try validateInputs(
            walletID: walletID,
            credentialID: credentialID,
            prfSalt: prfSalt
        )
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: relyingPartyIdentifier
        )
        let request = provider.createCredentialAssertionRequest(
            challenge: try WalletBackupPasskeyIdentity.secureRandomData(
                count: 32
            )
        )
        request.allowedCredentials = [
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(
                credentialID: credentialID
            )
        ]
        request.userVerificationPreference = .required
        request.prf = .perCredentialInputValues([
            credentialID: .init(saltInput1: prfSalt)
        ])

        let authorization = try await authorize(
            request,
            presentationAnchor: presentationAnchor
        )
        guard let credential = authorization.credential as?
                ASAuthorizationPlatformPublicKeyCredentialAssertion
        else {
            throw WalletCloudBackupError.invalidPasskeyCredential
        }
        guard credential.credentialID == credentialID,
              credential.userID == WalletBackupPasskeyIdentity.userHandle(
                walletID: walletID
              )
        else {
            throw WalletCloudBackupError.passkeyCredentialMismatch
        }
        guard let wrappingKey = credential.prf?.first else {
            throw WalletCloudBackupError.passkeyPRFUnavailable
        }
        return wrappingKey
    }

    @MainActor
    private func authorize(
        _ request: ASAuthorizationRequest,
        presentationAnchor: WalletPasskeyPresentationAnchor?
    ) async throws -> ASAuthorization {
        let presentationAnchor = try await
            WalletPasskeyPresentationCoordinator.activeAnchor(
                presentationAnchor
            )
        do {
            return try await WalletBackupPasskeyAuthorizationSession(
                anchor: presentationAnchor
            ).perform(request)
        } catch is CancellationError {
            throw WalletCloudBackupError.passkeyCanceled
        } catch {
            throw Self.mapAuthorizationError(error)
        }
    }

    private func validateInputs(
        walletID: String,
        credentialID: Data?,
        prfSalt: Data
    ) throws {
        guard !walletID.isEmpty,
              prfSalt.count
                == WalletBackupPasskeyIdentity.prfSaltByteCount,
              credentialID == nil
                || (credentialID?.isEmpty == false
                    && credentialID?.count ?? 0 <= 1_024)
        else {
            throw WalletCloudBackupError.invalidPasskeyCredential
        }
    }

    private static func mapAuthorizationError(
        _ error: Error
    ) -> any Error {
        let nsError = error as NSError
        let category: WalletCloudBackupError
        guard nsError.domain == ASAuthorizationError.errorDomain,
              let code = ASAuthorizationError.Code(rawValue: nsError.code)
        else {
            return WalletCloudBackupFailure(
                category: .passkeyAuthorizationFailed,
                diagnostic: WalletCloudBackupDiagnostic(error: error)
            )
        }

        switch code {
        case .canceled:
            return WalletCloudBackupError.passkeyCanceled
        case .deviceNotConfiguredForPasskeyCreation:
            category = .passkeyDeviceNotConfigured
        case .notHandled:
            category = .passkeyConfigurationUnavailable
        case .notInteractive:
            category = .passkeyPresentationUnavailable
        case .invalidResponse:
            category = .invalidPasskeyCredential
        case .unknown, .failed, .matchedExcludedCredential,
             .credentialImport, .credentialExport,
             .preferSignInWithApple:
            category = .passkeyAuthorizationFailed
        @unknown default:
            category = .passkeyAuthorizationFailed
        }
        return WalletCloudBackupFailure(
            category: category,
            diagnostic: WalletCloudBackupDiagnostic(error: error)
        )
    }
}

@MainActor
private final class WalletBackupPasskeyAuthorizationSession:
    NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    private let anchor: ASPresentationAnchor
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<
        ASAuthorization,
        Error
    >?

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func perform(
        _ request: ASAuthorizationRequest
    ) async throws -> ASAuthorization {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let controller = ASAuthorizationController(
                    authorizationRequests: [request]
                )
                self.controller = controller
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func authorizationController(
        controller _: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        finish(.success(authorization))
    }

    func authorizationController(
        controller _: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        finish(.failure(error))
    }

    func presentationAnchor(
        for _: ASAuthorizationController
    ) -> ASPresentationAnchor {
        anchor
    }

    private func cancel() {
        controller?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(
        _ result: Result<ASAuthorization, Error>
    ) {
        guard let continuation else { return }
        self.continuation = nil
        controller = nil
        continuation.resume(with: result)
    }
}

import Foundation

/// Authentication and Keychain persistence are owned by the credential store.
/// Interactive reads are cancellable and never block the UI thread.
@MainActor
final class OathDeviceBiometrics: OathBiometricsEnabling {
    private let credentialStore: any OathBiometricCredentialStoring
    private let credentialProvider: (@Sendable () async throws -> Data)?

    init(service: String = (Bundle.main.bundleIdentifier ?? "org.oathwallet.atmosphere.studio") + ".biometrics",
         credentialProvider: (@Sendable () async throws -> Data)? = nil) {
        self.credentialStore = OathBiometricCredentialStore(service: service, installation: .shared)
        self.credentialProvider = credentialProvider
    }

    init(credentialStore: any OathBiometricCredentialStoring,
         credentialProvider: @escaping @Sendable () async throws -> Data) {
        self.credentialStore = credentialStore
        self.credentialProvider = credentialProvider
    }

    func enableIfAvailable() async -> OathBiometricSetupResult {
        await credentialStore.enableIfAvailable(strings: .current, credentialProvider: credentialProvider)
    }
}

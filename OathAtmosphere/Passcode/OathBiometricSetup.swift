import Foundation

enum OathBiometricKind: String, Equatable, Sendable {
    case faceID, touchID

    var name: String { self == .faceID ? "Face ID" : "Touch ID" }
}

enum OathBiometricSetupError: Error, Equatable, Sendable {
    case cancelled, interrupted, lockedOut, notRecognized, unavailable, storage
}

enum OathBiometricSetupResult: Equatable, Sendable {
    case unavailable
    case enabled(OathBiometricKind)
    case failed(kind: OathBiometricKind?, reason: OathBiometricSetupError)
}

protocol OathBiometricsEnabling: Sendable {
    /// Attempts enrollment automatically when biometrics are available. Success
    /// means both authentication and protected credential persistence succeeded.
    func enableIfAvailable() async -> OathBiometricSetupResult
}

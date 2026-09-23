import Foundation

enum WalletSensitiveAction: String, Identifiable, Hashable, Sendable {
    case viewRecoveryPhrase
    case privateKeyExport
    case manualBackup
    case disableICloudBackup

    var id: String { rawValue }
}

@MainActor
enum WalletSensitiveActionAuthorizer {
    static func prepare(
        database: WalletDatabase
    ) async throws -> WalletAuthenticationActionPreparation {
        let settings = try await database.walletSecuritySettings()
        return await WalletAuthenticationAction.prepare(
            settings: settings,
            purpose: .walletSensitiveData
        )
    }
}

struct WalletSensitiveMaterialPresentation: Identifiable, Sendable {
    let id = UUID()
    let action: WalletSensitiveAction
    let material: WalletSensitiveMaterial
}

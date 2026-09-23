import Foundation

enum AppLaunchSecurityRoute: Equatable, Sendable {
    case authentication
    case wallet
    case unavailable(WalletPasscodeCredentialIssue)
}

enum AppLaunchSecurityRoutingPolicy {
    static func route(
        settings: WalletSecuritySettings,
        credentialReadiness: WalletPasscodeCredentialReadiness
    ) -> AppLaunchSecurityRoute {
        guard settings.requiresAuthentication else {
            return .wallet
        }

        switch credentialReadiness {
        case .available:
            return .authentication
        case .protectionDisabled:
            return .wallet
        case let .unavailable(issue):
            return .unavailable(issue)
        }
    }
}

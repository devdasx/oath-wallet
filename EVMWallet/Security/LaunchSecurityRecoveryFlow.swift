import SwiftUI

struct LaunchSecurityRecoveryFlow: View {
    enum Route: Hashable {
        case setPasscode
        case confirmPasscode(PasscodeDraft)
    }

    let database: WalletDatabase
    let issue: WalletPasscodeCredentialIssue
    let onRecovered: () -> Void

    @State private var path: [Route] = []
    @State private var authorization:
        WalletLaunchSecurityRecoveryProof?

    var body: some View {
        NavigationStack(path: ($path)) {
            LaunchSecurityRecoveryAuthenticationScreen(
                issue: issue
            ) { proof in
                authorization = proof
                path.append(.setPasscode)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .setPasscode:
                    LaunchSecurityRecoveryPasscodeScreen { passcode in
                        guard let draft = PasscodeDraft(passcode) else {
                            return
                        }
                        path.append(.confirmPasscode(draft))
                    }
                case let .confirmPasscode(draft):
                    LaunchSecurityRecoveryPasscodeConfirmationScreen(
                        database: database,
                        expectedPasscode: draft.value,
                        authorization: authorization,
                        onRecovered: onRecovered
                    )
                }
            }
        }
    }
}

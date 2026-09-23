import GRDB
import Observation
import SwiftUI

enum WalletAppDeepLinkDestination: Hashable, Sendable {
    case physicalEntropy
    case universalSearch
    case receive
    case currencyConverter
    case securitySettings
    case walletManagement

    var universalURL: URL {
        switch self {
        case .physicalEntropy:
            WalletAppDeepLinkParser.entropyWalletCreationURL
        case .universalSearch:
            WalletAppDeepLinkParser.universalSearchURL
        case .receive:
            WalletAppDeepLinkParser.receiveURL
        case .currencyConverter:
            WalletAppDeepLinkParser.currencyConverterURL
        case .securitySettings:
            WalletAppDeepLinkParser.securitySettingsURL
        case .walletManagement:
            WalletAppDeepLinkParser.walletManagementURL
        }
    }
}

struct WalletAppDeepLinkRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let destination: WalletAppDeepLinkDestination
}

enum WalletAppDeepLinkParser {
    static let entropyWalletCreationURL = URL(
        string: "https://aperturex.io/app/create-wallet/entropy"
    )!
    static let entropyWalletCreationCustomURL = URL(
        string: "aperturewallet://create-wallet/entropy"
    )!
    static let universalSearchURL = URL(
        string: "https://aperturex.io/app/search"
    )!
    static let receiveURL = URL(
        string: "https://aperturex.io/app/receive"
    )!
    static let currencyConverterURL = URL(
        string: "https://aperturex.io/app/tools/currency-converter"
    )!
    static let securitySettingsURL = URL(
        string: "https://aperturex.io/app/settings/security"
    )!
    static let walletManagementURL = URL(
        string: "https://aperturex.io/app/settings/wallets"
    )!

    private static let universalDestinations:
        [String: WalletAppDeepLinkDestination] = [
            "/app/create-wallet/entropy": .physicalEntropy,
            "/app/search": .universalSearch,
            "/app/receive": .receive,
            "/app/tools/currency-converter": .currencyConverter,
            "/app/settings/security": .securitySettings,
            "/app/settings/wallets": .walletManagement
        ]

    private static let customDestinations:
        [String: WalletAppDeepLinkDestination] = [
            "/create-wallet/entropy": .physicalEntropy,
            "/search": .universalSearch,
            "/receive": .receive,
            "/tools/currency-converter": .currencyConverter,
            "/settings/security": .securitySettings,
            "/settings/wallets": .walletManagement
        ]

    static func destination(
        for url: URL
    ) -> WalletAppDeepLinkDestination? {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ), components.user == nil, components.password == nil,
              components.port == nil else {
            return nil
        }

        let normalizedPath: String
        if components.path.count > 1, components.path.hasSuffix("/") {
            normalizedPath = String(components.path.dropLast())
        } else {
            normalizedPath = components.path
        }

        if components.scheme?.lowercased() == "https",
           components.host?.lowercased() == "aperturex.io" {
            return universalDestinations[normalizedPath]
        }

        if components.scheme?.lowercased() == "aperturewallet",
           let host = components.host?.lowercased(), !host.isEmpty {
            return customDestinations["/\(host)\(normalizedPath)"]
        }

        return nil
    }
}

@MainActor
@Observable
final class WalletAppDeepLinkCoordinator {
    private(set) var pendingRequest: WalletAppDeepLinkRequest?
    private var deferredWalletAddress: String?

    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let destination = WalletAppDeepLinkParser.destination(
            for: url
        ) else {
            return false
        }
        enqueue(destination)
        return true
    }

    func enqueue(_ destination: WalletAppDeepLinkDestination) {
        pendingRequest = WalletAppDeepLinkRequest(
            id: UUID(),
            destination: destination
        )
    }

    func consumeRequest(id: UUID) {
        guard pendingRequest?.id == id else { return }
        pendingRequest = nil
    }

    func deferWalletOpening(address: String) {
        deferredWalletAddress = address
    }

    func takeDeferredWalletAddress() -> String? {
        defer { deferredWalletAddress = nil }
        return deferredWalletAddress
    }

}

extension WalletDatabase {
    func entropyEventCreationSecurityMode(
        vault: WalletSecretVault = .shared
    ) async throws -> SettingsWalletCreationSecurityMode {
        try await pool.read { database in
            guard let security = try DBProfileSecurityRecord.fetchOne(
                database,
                key: Self.defaultProfileID
            ) else {
                return .requirePasscodeSetup
            }

            let _: WalletPasscodeCredential =
                try vault.validatedPasscodeCredential(
                    reference: security.passcodeKeychainReference,
                    decode: WalletPasscodeCredential.decodeStoredData
                )
            return .reuseExistingProfile
        }
    }
}

private struct WalletEntropyEventPresentation: Identifiable {
    let id: UUID
    let securityMode: SettingsWalletCreationSecurityMode
}

@MainActor
private struct WalletEntropyEventDeepLinkModifier: ViewModifier {
    let database: WalletDatabase
    let onWalletCreated: (String) -> Void

    @Environment(WalletAppDeepLinkCoordinator.self)
    private var coordinator
    @Environment(\.openURL) private var openURL
    @State private var presentation: WalletEntropyEventPresentation?
    @State private var failure: WalletPersistenceFailure?
    @State private var failedDestination:
        WalletAppDeepLinkDestination?

    func body(content: Content) -> some View {
        content
            .task(id: coordinator.pendingRequest?.id) {
                guard let request = coordinator.pendingRequest else {
                    return
                }
                await prepare(request)
            }
            .sheet(item: $presentation) { presentation in
                OnboardingView(
                    database: database,
                    startAction: .physicalEntropy,
                    usesExistingProfileSecurity:
                        presentation.securityMode == .reuseExistingProfile,
                    onOpenWallet: completeCreationFlow
                )
                .walletSheetPresentation(nativeGlass: false)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .alert(
                "wallet.creation.error.title",
                isPresented: failurePresentationBinding
            ) {
                Button("import.saving.retry", action: UniHaptic.action(retry))

                if let supportURL = failure?.supportURL {
                    Button("wallet.persistence.contact_support", action: UniHaptic.action(nil) {
                        openURL(supportURL)
                    })
                }

                Button("common.cancel", role: .cancel, action: UniHaptic.action {
                    clearFailure()
                })
            } message: {
                if let failure {
                    Text(verbatim: failureMessage(failure))
                }
            }
    }

    private var failurePresentationBinding: Binding<Bool> {
        Binding(
            get: { failure != nil },
            set: { isPresented in
                if !isPresented {
                    clearFailure()
                }
            }
        )
    }

    private func prepare(_ request: WalletAppDeepLinkRequest) async {
        guard request.destination == .physicalEntropy else {
            return
        }

        do {
            let securityMode = try await database
                .entropyEventCreationSecurityMode()
            guard coordinator.pendingRequest?.id == request.id else {
                return
            }
            presentation = WalletEntropyEventPresentation(
                id: request.id,
                securityMode: securityMode
            )
            coordinator.consumeRequest(id: request.id)
        } catch {
            guard coordinator.pendingRequest?.id == request.id else {
                return
            }
            failure = WalletPersistenceFailure(error: error)
            failedDestination = request.destination
            coordinator.consumeRequest(id: request.id)
            UniHaptic.play(.error)
        }
    }

    private func retry() {
        guard let failedDestination else { return }
        clearFailure()
        coordinator.enqueue(failedDestination)
    }

    private func clearFailure() {
        failure = nil
        failedDestination = nil
    }

    private func completeCreationFlow(_ address: String) {
        presentation = nil
        onWalletCreated(address)
    }

    private func failureMessage(
        _ failure: WalletPersistenceFailure
    ) -> String {
        [
            WalletLocalization.string(failure.messageKey),
            EnglishNumbers.localized(
                "wallet.persistence.support.hint",
                WalletSupport.emailAddress
            ),
            EnglishNumbers.localized(
                "wallet.persistence.error.reference",
                failure.diagnosticCode
            )
        ]
        .joined(separator: "\n\n")
    }
}

extension View {
    func walletEntropyEventDeepLink(
        database: WalletDatabase,
        onWalletCreated: @escaping (String) -> Void
    ) -> some View {
        modifier(
            WalletEntropyEventDeepLinkModifier(
                database: database,
                onWalletCreated: onWalletCreated
            )
        )
    }
}

extension AppRootView {
    @MainActor
    func handleEntropyEventWalletCreated(
        _ address: String,
        coordinator: WalletAppDeepLinkCoordinator
    ) {
        switch phase {
        case .onboarding, .wallet:
            openWallet(address: address)
        case .startup, .launchAuthentication,
             .launchSecurityUnavailable,
             .launchRestorationUnavailable:
            coordinator.deferWalletOpening(address: address)
        }
    }

    @MainActor
    func openDeferredEntropyEventWalletIfPossible(
        coordinator: WalletAppDeepLinkCoordinator
    ) {
        switch phase {
        case .onboarding, .wallet:
            guard let address = coordinator
                .takeDeferredWalletAddress() else {
                return
            }
            openWallet(address: address)
        case .startup, .launchAuthentication,
             .launchSecurityUnavailable,
             .launchRestorationUnavailable:
            return
        }
    }

}

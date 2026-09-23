import SwiftUI

struct DeviceMigrationExportAuthenticationScreen: View {
    private enum Phase {
        case loading
        case authenticating(WalletSecuritySettings)
        case failed
    }

    let database: WalletDatabase
    let beginsWithPasscode: Bool
    let initialErrorKey: String?
    let onAuthorized: (WalletDeviceMigrationAuthorization) -> Void

    @State private var phase: Phase
    @State private var didStart: Bool
    @State private var isIssuingAuthorization = false
    @State private var authenticationIdentity = UUID()

    init(
        database: WalletDatabase,
        settings: WalletSecuritySettings? = nil,
        beginsWithPasscode: Bool = false,
        initialErrorKey: String? = nil,
        onAuthorized: @escaping (
            WalletDeviceMigrationAuthorization
        ) -> Void
    ) {
        self.database = database
        self.beginsWithPasscode = beginsWithPasscode
        self.initialErrorKey = initialErrorKey
        self.onAuthorized = onAuthorized
        if let settings {
            _phase = State(initialValue: .authenticating(settings))
            _didStart = State(initialValue: true)
        } else {
            _phase = State(initialValue: .loading)
            _didStart = State(initialValue: false)
        }
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                Text("device_migration.authentication.loading")
                    .foregroundStyle(.secondary)
            case let .authenticating(settings):
                WalletSecurityAuthenticationView(
                    database: database,
                    settings: settings,
                    purpose: .deviceMigrationExport,
                    beginsWithPasscode: beginsWithPasscode,
                    initialErrorKey: initialErrorKey,
                    onAuthenticationGranted: completeAuthentication
                )
                .id(authenticationIdentity)
            case .failed:
                failureContent
            }
        }
        .background(WalletTheme.groupedBackground)
        .task {
            guard !didStart else { return }
            didStart = true
            await prepareAccess()
        }
    }

    private var failureContent: some View {
        List {
            Group {
                Section {
                    Text("device_migration.authentication.unavailable")
                        .foregroundStyle(.secondary)

                    Button("common.retry", action: UniHaptic.action {
                        retry()
                    })
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
    }

    @MainActor
    private func prepareAccess() async {
        do {
            phase = .authenticating(
                try await database.walletSecuritySettings()
            )
        } catch {
            phase = .failed
        }
    }

    private func completeAuthentication(
        _ grant: WalletAuthenticationGrant
    ) {
        guard !isIssuingAuthorization else { return }
        isIssuingAuthorization = true
        Task { @MainActor in
            do {
                let authorization = try await database
                    .authorizeDeviceMigration(
                        authenticationGrant: grant
                    )
                onAuthorized(authorization)
            } catch {
                isIssuingAuthorization = false
                phase = .failed
            }
        }
    }

    private func retry() {
        isIssuingAuthorization = false
        authenticationIdentity = UUID()
        if case .authenticating = phase {
            return
        }
        phase = .loading
        Task {
            await prepareAccess()
        }
    }
}

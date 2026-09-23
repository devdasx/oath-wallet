import Foundation
import GRDB
import Testing
@testable import Aperture

struct WalletNotificationScopeTests {
    @MainActor
    @Test
    func activeWalletIsAlwaysMonitoredAndInactiveWalletRequiresOptIn()
        async throws {
        let database = try WalletDatabase.temporary()
        try await seedWallets(database)
        let repository = PushNotificationRegistrationRepository(
            database: database
        )
        let identity = PushInstallationIdentity(
            installationID:
                "10000000-0000-4000-8000-000000000001",
            credential: Data(repeating: 0x44, count: 32),
            apnsToken: Data(repeating: 0x55, count: 32),
            remoteUserID:
                "10000000-0000-4000-8000-000000000002"
        )

        let initial = try await repository.snapshot(
            identity: identity,
            apnsEnvironment: "sandbox"
        )
        #expect(scope(in: initial) == [
            "active-wallet": true,
            "inactive-wallet": false
        ])

        let optedIn = try await database
            .setNotificationsEnabledWhenInactive(
                walletID: "inactive-wallet",
                enabled: true
            )
        #expect(optedIn.notificationsEnabledWhenInactive)
        let afterOptIn = try await repository.snapshot(
            identity: identity,
            apnsEnvironment: "sandbox"
        )
        #expect(scope(in: afterOptIn) == [
            "active-wallet": true,
            "inactive-wallet": true
        ])

        _ = try await database.setNotificationsEnabledWhenInactive(
            walletID: "inactive-wallet",
            enabled: false
        )
        _ = try await database.selectWallet(
            walletID: "inactive-wallet"
        )
        let afterSelection = try await repository.snapshot(
            identity: identity,
            apnsEnvironment: "sandbox"
        )
        #expect(scope(in: afterSelection) == [
            "active-wallet": false,
            "inactive-wallet": true
        ])
    }

    @Test
    func inactiveNotificationPreferenceDefaultsOffAndPersists()
        async throws {
        let database = try WalletDatabase.temporary()
        try await seedWallets(database)

        let initial = try await database.managedWallet(
            walletID: "inactive-wallet"
        )
        #expect(!initial.notificationsEnabledWhenInactive)

        _ = try await database.setNotificationsEnabledWhenInactive(
            walletID: "inactive-wallet",
            enabled: true
        )
        let restored = try await database.managedWallet(
            walletID: "inactive-wallet"
        )
        #expect(restored.notificationsEnabledWhenInactive)
    }

    private func scope(
        in snapshot: PushInstallationSnapshotRequest
    ) -> [String: Bool] {
        Dictionary(
            uniqueKeysWithValues: snapshot.wallets.map {
                ($0.walletID, $0.notificationMonitoringEnabled)
            }
        )
    }

    private func seedWallets(_ database: WalletDatabase) async throws {
        let now = Date().timeIntervalSince1970
        try await database.pool.write { db in
            for fixture in [
                (
                    walletID: "active-wallet",
                    accountID: "active-account",
                    address:
                        "0x1111111111111111111111111111111111111111",
                    selected: true
                ),
                (
                    walletID: "inactive-wallet",
                    accountID: "inactive-account",
                    address:
                        "0x2222222222222222222222222222222222222222",
                    selected: false
                )
            ] {
                try DBWalletRecord(
                    id: fixture.walletID,
                    profileID: WalletDatabase.defaultProfileID,
                    name: fixture.walletID,
                    kind: DatabaseWalletKind.created.rawValue,
                    secretKeyReference:
                        "opaque-\(fixture.walletID)",
                    isSelected: fixture.selected,
                    sortOrder: fixture.selected ? 0 : 1,
                    createdAt: now,
                    updatedAt: now,
                    lastOpenedAt: fixture.selected ? now : nil,
                    archivedAt: nil
                ).insert(db)
                try DBWalletAccountRecord(
                    id: fixture.accountID,
                    walletID: fixture.walletID,
                    networkID: "eth",
                    address: fixture.address,
                    normalizedAddress: fixture.address,
                    label: nil,
                    derivationPath: nil,
                    accountIndex: 0,
                    publicKey: "public",
                    isWatchOnly: false,
                    isEnabled: true,
                    createdAt: now,
                    updatedAt: now,
                    lastSyncedAt: nil
                ).insert(db)
            }
        }
    }
}

@MainActor
struct AppRootWalletSynchronizationTests {
    private let evmAddressA =
        "0x1111111111111111111111111111111111111111"
    private let evmAddressB =
        "0x2222222222222222222222222222222222222222"

    @Test
    func selectingAnotherWalletImmediatelyClearsThePriorContext() {
        let contextA = context(
            walletID: "wallet-a",
            address: evmAddressA,
            name: "Wallet A",
            capabilities: .fullWallet
        )
        let snapshotA = snapshot(totalBalance: "125.50")
        var presentation = AppRootWalletPresentation.resolved(
            context: contextA,
            state: .content(snapshotA)
        )

        let requestB = UUID()
        presentation = .pending(
            requestID: requestB,
            address: evmAddressB,
            suggestedName: "Wallet B"
        )

        #expect(!presentation.isReadyForWalletActions)
        #expect(presentation.resolvedContext == nil)
        #expect(presentation.contentSnapshot == nil)
        #expect(presentation.address == evmAddressB)
        #expect(presentation.name == "Wallet B")
        #expect(presentation.capabilities == .fullWallet)
        guard case .loading = presentation.state else {
            Issue.record("A new wallet selection must expose only loading state")
            return
        }
    }

    @Test
    func lateResolutionFromThePreviousWalletIsRejected() {
        let contextA = context(
            walletID: "wallet-a",
            address: evmAddressA,
            name: "Wallet A",
            capabilities: WalletCapabilities(
                scope: .privateKey(.evm)
            )
        )
        let requestB = UUID()
        var presentation = AppRootWalletPresentation.pending(
            requestID: contextA.requestID,
            address: evmAddressA,
            suggestedName: contextA.name
        )

        presentation = .pending(
            requestID: requestB,
            address: evmAddressB,
            suggestedName: "Wallet B"
        )

        #expect(!presentation.accepts(contextA))
        #expect(
            presentation.replacingState(
                .content(snapshot(totalBalance: "999.00")),
                for: contextA
            ) == nil
        )
        #expect(
            !presentation.acceptsPending(
                requestID: contextA.requestID,
                address: contextA.identity.address
            )
        )
        #expect(presentation.address == evmAddressB)
        #expect(presentation.contentSnapshot == nil)
    }

    @Test
    func lateCachePublicationCannotOverwriteTheNewWallet() {
        let contextA = context(
            walletID: "wallet-a",
            address: evmAddressA,
            name: "Wallet A",
            capabilities: .fullWallet
        )
        let contextB = context(
            walletID: "wallet-b",
            address: evmAddressB,
            name: "Wallet B",
            capabilities: WalletCapabilities(
                scope: .privateKey(.solana)
            )
        )
        let snapshotB = snapshot(totalBalance: "42.25")
        var presentation = AppRootWalletPresentation.resolved(
            context: contextB,
            state: .content(snapshotB)
        )

        let staleCommit = presentation.replacingState(
            .content(snapshot(totalBalance: "999.00")),
            for: contextA
        )
        #expect(staleCommit == nil)

        if let staleCommit {
            presentation = staleCommit
        }
        #expect(presentation.accepts(contextB))
        #expect(presentation.resolvedContext == contextB)
        #expect(presentation.contentSnapshot?.totalBalance == decimal("42.25"))
        #expect(presentation.name == "Wallet B")
        #expect(
            presentation.capabilities
                == WalletCapabilities(scope: .privateKey(.solana))
        )
    }

    @Test
    func olderRequestForTheSameWalletIsRejectedAfterReloadRebind() {
        let firstContext = context(
            walletID: "wallet-a",
            address: evmAddressA,
            name: "Wallet A",
            capabilities: .fullWallet
        )
        var presentation = AppRootWalletPresentation.resolved(
            context: firstContext,
            state: .content(snapshot(totalBalance: "8.00"))
        )
        let currentContext = firstContext.replacingRequestID(UUID())

        guard let rebound = presentation.rebinding(to: currentContext) else {
            Issue.record("A matching wallet must allow a request rebind")
            return
        }
        presentation = rebound

        #expect(!presentation.accepts(firstContext))
        #expect(presentation.accepts(currentContext))
        #expect(
            presentation.replacingState(
                .content(snapshot(totalBalance: "999.00")),
                for: firstContext
            ) == nil
        )
        #expect(presentation.contentSnapshot?.totalBalance == decimal("8.00"))
    }

    @Test
    func validSnapshotCommitDoesNotRevertAConcurrentWalletRename() {
        let loadContext = context(
            walletID: "wallet-a",
            address: evmAddressA,
            name: "Wallet A",
            capabilities: .fullWallet
        )
        var presentation = AppRootWalletPresentation.resolved(
            context: loadContext,
            state: .loading
        )

        guard let renamed = presentation.replacingName(
            "Renamed Wallet",
            matchingAddress: evmAddressA
        ) else {
            Issue.record("The selected wallet rename should be accepted")
            return
        }
        presentation = renamed

        guard let committed = presentation.replacingState(
            .content(snapshot(totalBalance: "17.25")),
            for: loadContext
        ) else {
            Issue.record("The in-flight snapshot should remain wallet-scoped")
            return
        }
        presentation = committed

        #expect(presentation.name == "Renamed Wallet")
        #expect(presentation.contentSnapshot?.totalBalance == decimal("17.25"))
    }

    @Test
    func resolvedCommitPublishesOneCoherentSendContext() {
        let capabilities = WalletCapabilities(
            scope: .privateKey(.bitcoin)
        )
        let resolved = context(
            walletID: "wallet-btc",
            address: "bc1qexample",
            name: "Bitcoin Wallet",
            capabilities: capabilities
        )
        let presentation = AppRootWalletPresentation.resolved(
            context: resolved,
            state: .content(snapshot(totalBalance: "3.75"))
        )

        #expect(presentation.isReadyForWalletActions)
        #expect(presentation.resolvedContext == resolved)
        #expect(presentation.name == resolved.name)
        #expect(presentation.address == resolved.identity.address)
        #expect(presentation.capabilities == resolved.capabilities)
        #expect(presentation.contentSnapshot?.totalBalance == decimal("3.75"))
    }

    @Test
    func addressMatchingUsesChainAppropriateCaseRules() {
        #expect(
            AppRootWalletAddressMatcher.matches(
                evmAddressA.uppercased(),
                evmAddressA
            )
        )
        #expect(
            !AppRootWalletAddressMatcher.matches(
                "SolanaAddressCaseSensitive",
                "solanaaddresscasesensitive"
            )
        )
        #expect(
            AppRootWalletAddressMatcher.matches(
                "  bc1qexample  ",
                "bc1qexample"
            )
        )
    }

    private func context(
        walletID: String,
        address: String,
        name: String,
        capabilities: WalletCapabilities
    ) -> AppRootResolvedWalletContext {
        AppRootResolvedWalletContext(
            requestID: UUID(),
            identity: PersistedWalletIdentity(
                walletID: walletID,
                address: address
            ),
            name: name,
            capabilities: capabilities
        )
    }

    private func snapshot(totalBalance: String) -> WalletHomeSnapshot {
        WalletHomeSnapshot(
            totalBalance: decimal(totalBalance),
            assets: [],
            transactions: []
        )
    }

    private func decimal(_ value: String) -> Decimal {
        Decimal(
            string: value,
            locale: Locale(identifier: "en_US_POSIX")
        ) ?? 0
    }
}

import Foundation
import Observation

/// Authorization and transient export state owned by the Backup & Keys flow.
@MainActor
@Observable
final class SettingsBackupPrivateKeyAccess {
    enum Route: String, Identifiable {
        case chains
        var id: String { rawValue }
    }

    private(set) var isBusy = false
    private(set) var authenticationContext: WalletAuthenticationPasscodeContext?
    var isAuthenticationPresented = false
    var route: Route?
    private(set) var items: [WalletPrivateKeyExportItem] = []
    var failure: WalletOperationFailurePresentation?

    @ObservationIgnored private let prepare:
        @MainActor () async throws -> WalletAuthenticationActionPreparation
    @ObservationIgnored private let load:
        @MainActor (WalletAuthenticationGrant) async throws -> [WalletPrivateKeyExportItem]
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var pendingGrant: WalletAuthenticationGrant?
    @ObservationIgnored private var pendingItems: [WalletPrivateKeyExportItem] = []
    @ObservationIgnored private var isSceneActive = true

    init(
        prepare: @escaping @MainActor () async throws -> WalletAuthenticationActionPreparation,
        load: @escaping @MainActor (WalletAuthenticationGrant) async throws -> [WalletPrivateKeyExportItem]
    ) {
        self.prepare = prepare
        self.load = load
    }

    convenience init(database: WalletDatabase, walletID: String) {
        self.init(
            prepare: {
                try await WalletSensitiveActionAuthorizer.prepare(
                    database: database
                )
            },
            load: { grant in
                let authorization = try await database.authorizeSecretExport(
                    walletID: walletID,
                    authenticationGrant: grant
                )
                try Task.checkCancellation()
                return try await database.privateKeyExportItems(
                    walletID: walletID,
                    authorization: authorization
                )
            }
        )
    }

    func request() async {
        guard requestID == nil, route == nil else { return }
        let id = UUID()
        requestID = id
        isBusy = true
        failure = nil
        defer { if requestID == id { isBusy = false } }
        do {
            let preparation = try await prepare()
            try Task.checkCancellation()
            guard requestID == id else { return }
            switch preparation {
            case let .authorized(grant):
                try await export(grant, requestID: id)
            case let .requiresPasscode(context):
                authenticationContext = context
                isAuthenticationPresented = isSceneActive
            case .cancelled:
                cancelPendingRequest()
            }
        } catch {
            handle(error, requestID: id)
        }
    }

    func completePasscode(_ grant: WalletAuthenticationGrant) {
        guard requestID != nil, authenticationContext != nil else { return }
        pendingGrant = grant
        isAuthenticationPresented = false
    }

    /// Export only after the passcode cover has actually finished dismissing.
    func authenticationDidDismiss() async {
        guard let id = requestID, let grant = pendingGrant else {
            cancelPendingRequest()
            return
        }
        pendingGrant = nil
        authenticationContext = nil
        isBusy = true
        defer { if requestID == id { isBusy = false } }
        do {
            try await export(grant, requestID: id)
        } catch {
            handle(error, requestID: id)
        }
    }

    func sceneBecameInactive() { isSceneActive = false }

    func sceneBecameActive() {
        isSceneActive = true
        publishWhenActive()
    }

    func cancelPendingRequest() {
        requestID = nil
        pendingGrant = nil
        pendingItems.removeAll()
        authenticationContext = nil
        isAuthenticationPresented = false
        isBusy = false
    }

    func clearExport() {
        items.removeAll()
        cancelPendingRequest()
    }

    private func export(_ grant: WalletAuthenticationGrant, requestID id: UUID) async throws {
        let loadedItems = try await load(grant)
        try Task.checkCancellation()
        guard requestID == id else { return }
        guard !loadedItems.isEmpty else { throw WalletManagementError.secretUnavailable }
        pendingItems = loadedItems
        publishWhenActive()
    }

    private func publishWhenActive() {
        guard isSceneActive, requestID != nil else { return }
        if authenticationContext != nil, pendingGrant == nil {
            isAuthenticationPresented = true
            return
        }
        guard !pendingItems.isEmpty else { return }
        items = pendingItems
        pendingItems.removeAll()
        route = .chains
        requestID = nil
        isBusy = false
    }

    private func handle(_ error: Error, requestID id: UUID) {
        guard requestID == id else { return }
        cancelPendingRequest()
        guard !(error is CancellationError) else { return }
        failure = WalletOperationFailurePresentation(
            messageKey: "settings.wallets.private_key.export.load.error",
            error: error
        )
        UniHaptic.play(.error)
    }
}

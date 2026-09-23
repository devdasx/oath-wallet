import SwiftUI

struct DeviceMigrationExportFlow: View {
    let database: WalletDatabase
    let authorization: WalletDeviceMigrationAuthorization

    var body: some View {
        DeviceMigrationExportInvitationScreen(
            database: database,
            authorization: authorization
        )
    }
}

typealias DeviceMigrationExportPasscodeContext =
    WalletAuthenticationPasscodeContext

enum DeviceMigrationExportDestinationPreparation: Sendable {
    case authorized(WalletDeviceMigrationAuthorization)
    case requiresPasscode(DeviceMigrationExportPasscodeContext)
    case cancelled
}

enum DeviceMigrationExportNavigationPresentation: Equatable, Sendable {
    case export
    case passcode
}

struct DeviceMigrationExportAccessUnavailableView: View {
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                "device_migration.export.title",
                systemImage: "circle.dashed"
            )
        } description: {
            Text("device_migration.authentication.unavailable")
        } actions: {
            Button("common.retry", action: UniHaptic.action(retry))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .navigationTitle("device_migration.export.title")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DeviceMigrationExportNavigationState {
    private(set) var isAuthorizing = false
    private(set) var isPasscodePresentationActive = false
    private(set) var activeRequestID: UUID?
    private(set) var authorization:
        WalletDeviceMigrationAuthorization?
    private(set) var passcodeContext:
        DeviceMigrationExportPasscodeContext?

    private var deferredPreparation:
        DeviceMigrationExportDestinationPreparation?
    private var pendingPresentation:
        DeviceMigrationExportNavigationPresentation?

    mutating func beginAuthorization() -> UUID? {
        guard !isAuthorizing, passcodeContext == nil,
              !isPasscodePresentationActive, deferredPreparation == nil,
              pendingPresentation == nil else { return nil }
        let requestID = UUID()
        activeRequestID = requestID
        isAuthorizing = true
        authorization = nil
        passcodeContext = nil
        deferredPreparation = nil
        pendingPresentation = nil
        return requestID
    }

    mutating func receive(
        _ preparation: DeviceMigrationExportDestinationPreparation,
        requestID: UUID,
        sceneIsActive: Bool,
        sceneIsBackground: Bool = false
    ) {
        guard activeRequestID == requestID else { return }
        guard !sceneIsBackground else {
            invalidateForBackground()
            return
        }
        activeRequestID = nil
        isAuthorizing = false
        if sceneIsActive {
            apply(preparation)
        } else {
            deferredPreparation = preparation
        }
    }

    mutating func fail(requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
        isAuthorizing = false
    }

    mutating func resumeAfterInactive() {
        guard let deferredPreparation else { return }
        self.deferredPreparation = nil
        apply(deferredPreparation)
    }

    mutating func invalidateForBackground() {
        if !isPasscodePresentationActive { passcodeContext = nil }
        activeRequestID = nil
        isAuthorizing = false
        deferredPreparation = nil
        pendingPresentation = nil
    }

    mutating func acceptAfterPasscode(
        _ authorization: WalletDeviceMigrationAuthorization,
        sceneIsBackground: Bool = false
    ) {
        guard !sceneIsBackground else {
            invalidateForBackground()
            return
        }
        let preparation = DeviceMigrationExportDestinationPreparation
            .authorized(authorization)
        passcodeContext = nil
        apply(preparation)
    }

    mutating func passcodeAuthenticationDidDismiss() {
        isPasscodePresentationActive = false
        if passcodeContext != nil { cancelPasscodeAuthentication() }
    }

    mutating func cancelPasscodeAuthentication() {
        isPasscodePresentationActive = false
        passcodeContext = nil
        deferredPreparation = nil
        pendingPresentation = nil
    }

    mutating func takePendingPresentation(sceneIsActive: Bool = true)
        -> DeviceMigrationExportNavigationPresentation? {
        guard sceneIsActive, !isPasscodePresentationActive else { return nil }
        if pendingPresentation == .passcode { isPasscodePresentationActive = true }
        defer { pendingPresentation = nil }
        return pendingPresentation
    }

    mutating func clear() {
        isPasscodePresentationActive = false
        isAuthorizing = false
        activeRequestID = nil
        authorization = nil
        passcodeContext = nil
        deferredPreparation = nil
        pendingPresentation = nil
    }

    private mutating func apply(
        _ preparation: DeviceMigrationExportDestinationPreparation
    ) {
        switch preparation {
        case let .authorized(authorization):
            self.authorization = authorization
            passcodeContext = nil
            pendingPresentation = .export
        case let .requiresPasscode(context):
            authorization = nil
            passcodeContext = context
            pendingPresentation = .passcode
        case .cancelled:
            authorization = nil
            passcodeContext = nil
            pendingPresentation = nil
        }
    }
}

@MainActor
enum DeviceMigrationExportDestinationAuthorizer {
    static func prepare(
        database: WalletDatabase
    ) async throws -> DeviceMigrationExportDestinationPreparation {
        let settings = try await database.walletSecuritySettings()
        switch await WalletAuthenticationAction.prepare(
            settings: settings,
            purpose: .deviceMigrationExport
        ) {
        case let .authorized(grant):
            return .authorized(
                try await database.authorizeDeviceMigration(
                    authenticationGrant: grant
                )
            )
        case let .requiresPasscode(context):
            return .requiresPasscode(context)
        case .cancelled:
            return .cancelled
        }
    }
}

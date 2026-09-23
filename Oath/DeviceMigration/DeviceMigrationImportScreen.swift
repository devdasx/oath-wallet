import SwiftUI

struct DeviceMigrationImportScreen: View {
    let database: WalletDatabase
    let onImported: (PersistedWalletIdentity) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WalletSettingsStore.self) private var applicationSettings

    @State private var transferSession:
        DeviceMigrationReceiverSession
    @State private var didStart = false
    @State private var isImporting = false
    @State private var importResult: DeviceMigrationImportResult?
    @State private var importError: DeviceMigrationError?

    init(
        invitation: DeviceMigrationInvitation,
        database: WalletDatabase,
        onImported: @escaping (PersistedWalletIdentity) -> Void
    ) {
        self.database = database
        self.onImported = onImported
        _transferSession = State(
            initialValue: DeviceMigrationReceiverSession(
                invitation: invitation
            )
        )
    }

    var body: some View {
        List {
            Group {
                Section {
                    statusContent
                        .id(statusIdentity)
                } header: {
                    Text("device_migration.status.section")
                }

                Section {
                    Text("device_migration.import.keep_nearby")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("device_migration.import.security")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("device_migration.import.instructions.section")
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .navigationTitle("device_migration.import.title")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isImporting)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if importResult != nil || displayedError != nil {
                footerAction
            }
        }
        .interactiveDismissDisabled(isImporting)
        .task {
            guard !didStart else { return }
            didStart = true
            await applicationSettings.flush()
            transferSession.start()
        }
        .onChange(
            of: transferSession.incomingPackage?.id,
            initial: true
        ) { _, packageID in
            guard packageID != nil else { return }
            beginImportIfReady()
        }
        .onDisappear {
            transferSession.stop()
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: statusIdentity
        )
    }

    @ViewBuilder
    private var statusContent: some View {
        if isImporting {
            VStack(alignment: .leading, spacing: 10) {
                statusText(
                    title: "device_migration.import.importing.title",
                    detail: "device_migration.import.importing.detail"
                )
            }
        } else if let importResult {
            VStack(alignment: .leading, spacing: 5) {
                Text("device_migration.import.complete.title")
                    .font(.headline)
                Text(
                    verbatim: EnglishNumbers.localized(
                        "device_migration.import.complete.detail",
                        importResult.walletCount
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            }
        } else if let displayedError {
            VStack(alignment: .leading, spacing: 5) {
                Text("device_migration.import.failed.title")
                    .font(.headline)
                    .foregroundStyle(WalletTheme.danger)
                Text(
                    LocalizedStringKey(displayedError.userMessageKey)
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            switch transferSession.state {
            case .searching:
                VStack(alignment: .leading, spacing: 10) {
                    statusText(
                        title: "device_migration.status.searching.title",
                        detail: "device_migration.status.searching.detail"
                    )
                }
            case .connecting:
                VStack(alignment: .leading, spacing: 10) {
                    statusText(
                        title: "device_migration.status.connecting.title",
                        detail: "device_migration.status.connecting.detail"
                    )
                }
            case let .receiving(progress):
                VStack(alignment: .leading, spacing: 12) {
                    statusText(
                        title: "device_migration.import.receiving.title",
                        detail: "device_migration.import.receiving.detail"
                    )
                    DeviceMigrationProgressBar(progress: progress)
                }
            case .verifying, .readyToImport:
                VStack(alignment: .leading, spacing: 10) {
                    statusText(
                        title: "device_migration.import.verifying.title",
                        detail: "device_migration.import.verifying.detail"
                    )
                }
            case let .completed(walletCount):
                Text(
                    verbatim: EnglishNumbers.localized(
                        "device_migration.import.complete.detail",
                        walletCount
                    )
                )
            case .failed:
                EmptyView()
            }
        }
    }

    private func statusText(
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var footerAction: some View {
        Group {
            if let importResult {
                PrimaryWalletButton(
                    title: "device_migration.import.continue"
                ) {
                    applicationSettings.applyDeviceMigrationSettings(
                        importResult.applicationSettings
                    )
                    onImported(importResult.selectedWallet)
                }
            } else {
                SecondaryWalletButton(
                    title: "device_migration.import.scan_again"
                ) {
                    dismiss()
                }
            }
        }
        .walletActionScreenMargins()
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(WalletTheme.groupedBackground)
    }

    private var displayedError: DeviceMigrationError? {
        if let importError {
            return importError
        }
        if case let .failed(error) = transferSession.state {
            return error
        }
        return nil
    }

    private var statusIdentity: String {
        if isImporting {
            return "importing"
        }
        if importResult != nil {
            return "completed"
        }
        if let displayedError {
            return "failed_\(displayedError.diagnosticCode)"
        }
        return switch transferSession.state {
        case .searching:
            "searching"
        case .connecting:
            "connecting"
        case .receiving:
            "receiving"
        case .verifying:
            "verifying"
        case .readyToImport:
            "ready"
        case .completed:
            "completed"
        case let .failed(error):
            "failed_\(error.diagnosticCode)"
        }
    }

    private func beginImportIfReady() {
        guard !isImporting,
              importResult == nil,
              importError == nil,
              let package = transferSession.incomingPackage else {
            return
        }
        isImporting = true
        Task {
            do {
                let result = try await database.importDeviceMigration(
                    package
                )
                isImporting = false
                importResult = result
                transferSession.completeImport(
                    result: .success(result)
                )
                UniHaptic.play(.success)
            } catch {
                let migrationError = error as? DeviceMigrationError
                    ?? .importFailed
                isImporting = false
                importError = migrationError
                transferSession.completeImport(
                    result: .failure(migrationError)
                )
                UniHaptic.play(.error)
            }
        }
    }
}

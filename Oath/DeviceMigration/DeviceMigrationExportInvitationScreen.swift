import SwiftUI

struct DeviceMigrationExportInvitationScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WalletSettingsStore.self) private var applicationSettings

    @State private var transferSession: DeviceMigrationSourceSession
    @State private var secondsRemaining = 0
    @State private var didStart = false

    init(
        database: WalletDatabase,
        authorization: WalletDeviceMigrationAuthorization
    ) {
        _transferSession = State(
            initialValue: DeviceMigrationSourceSession(
                database: database,
                authorization: authorization
            )
        )
    }

    var body: some View {
        List {
            Group {
                if showsInvitation {
                    Section {
                        invitationContent
                    } header: {
                        Text("device_migration.export.qr.section")
                    } footer: {
                        Text("device_migration.export.qr.footer")
                    }
                }

                Section {
                    statusContent
                        .id(statusIdentity)
                } header: {
                    Text("device_migration.status.section")
                }

                Section {
                    migrationCoverageRow(
                        title: "device_migration.includes.wallets",
                        detail: "device_migration.includes.wallets.detail"
                    )
                    migrationCoverageRow(
                        title: "device_migration.includes.activity",
                        detail: "device_migration.includes.activity.detail"
                    )
                    migrationCoverageRow(
                        title: "device_migration.includes.settings",
                        detail: "device_migration.includes.settings.detail"
                    )
                } header: {
                    Text("device_migration.includes.section")
                } footer: {
                    Text("device_migration.export.source_retained")
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .navigationTitle("device_migration.export.title")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .task {
            guard !didStart else { return }
            didStart = true
            await applicationSettings.flush()
            transferSession.start()
            await updateCountdown()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                transferSession.stop()
                didStart = false
                secondsRemaining = 0
            case .active:
                restartAfterBackgroundIfNeeded()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onDisappear {
            transferSession.stop()
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: statusIdentity
        )
    }

    private var invitationContent: some View {
        VStack(spacing: 18) {
            if let invitation = transferSession.invitation {
                ReceiveQRCodeImage(
                    payload: invitation.qrPayload,
                    accessibilityLabel:
                        "device_migration.export.qr.accessibility",
                    cachesRenderedImage: false
                )
                .frame(maxWidth: 420)
                .walletSensitiveGraphic(cornerRadius: 24)
                .frame(maxWidth: .infinity)

                if secondsRemaining > 0 {
                    Text(
                        verbatim: EnglishNumbers.localized(
                            "device_migration.export.expires",
                            secondsRemaining
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("device_migration.export.preparing")
                    .foregroundStyle(.secondary)
                    .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch transferSession.state {
        case .preparingInvitation:
            Text("device_migration.export.preparing")
                .foregroundStyle(.secondary)
        case .waitingForReceiver:
            statusText(
                title: "device_migration.status.waiting.title",
                detail: "device_migration.status.waiting.detail"
            )
        case .connecting:
            statusText(
                title: "device_migration.status.connecting.title",
                detail: "device_migration.status.connecting.detail"
            )
        case .preparingData:
            VStack(alignment: .leading, spacing: 10) {
                statusText(
                    title: "device_migration.status.preparing.title",
                    detail: "device_migration.status.preparing.detail"
                )
            }
        case let .transferring(progress):
            VStack(alignment: .leading, spacing: 12) {
                statusText(
                    title: "device_migration.status.transferring.title",
                    detail: "device_migration.status.transferring.detail"
                )
                DeviceMigrationProgressBar(progress: progress)
            }
        case .verifyingImport:
            statusText(
                title: "device_migration.status.verifying.title",
                detail: "device_migration.status.verifying.detail"
            )
        case let .completed(walletCount):
            VStack(alignment: .leading, spacing: 5) {
                Text("device_migration.export.complete.title")
                    .font(.headline)
                Text(
                    verbatim: EnglishNumbers.localized(
                        "device_migration.export.complete.detail",
                        walletCount
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        case .expired:
            statusText(
                title: "device_migration.export.expired.title",
                detail: "device_migration.export.expired.detail"
            )
        case let .failed(error):
            VStack(alignment: .leading, spacing: 5) {
                Text("device_migration.export.failed.title")
                    .font(.headline)
                    .foregroundStyle(WalletTheme.danger)
                Text(LocalizedStringKey(error.userMessageKey))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    private func migrationCoverageRow(
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var showsInvitation: Bool {
        switch transferSession.state {
        case .preparingInvitation, .waitingForReceiver, .connecting:
            true
        default:
            false
        }
    }

    private var statusIdentity: String {
        switch transferSession.state {
        case .preparingInvitation:
            "preparing_invitation"
        case .waitingForReceiver:
            "waiting"
        case .connecting:
            "connecting"
        case .preparingData:
            "preparing_data"
        case .transferring:
            "transferring"
        case .verifyingImport:
            "verifying"
        case .completed:
            "completed"
        case .expired:
            "expired"
        case let .failed(error):
            "failed_\(error.diagnosticCode)"
        }
    }

    @MainActor
    private func updateCountdown() async {
        while !Task.isCancelled,
              let invitation = transferSession.invitation {
            secondsRemaining = max(
                Int(ceil(invitation.expiresAt.timeIntervalSinceNow)),
                0
            )
            guard secondsRemaining > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    @MainActor
    private func restartAfterBackgroundIfNeeded() {
        guard !didStart else { return }
        didStart = true
        transferSession.start()
        Task { @MainActor in
            await updateCountdown()
        }
    }
}

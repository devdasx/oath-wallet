import SwiftUI

struct ResetAppProgressSheet: View {
    let database: WalletDatabase
    let applicationSettings: WalletSettingsStore
    let onResetComplete: () -> Void
    let onCancel: () -> Void

    @State private var stage: WalletAppResetProgressStage = .preparing
    @State private var status: WalletDestructiveProgressStatus = .running
    @State private var didStart = false
#if DEBUG
    @Environment(\.appResetTestActions) private var testActions
#endif

    var body: some View {
        WalletDestructiveProgressContent(
            status: status,
            transitionIdentity:
                "\(status.rawValue)-\(stage.rawValue)",
            titleKey: titleKey,
            detailKey: detailKey,
            stableCopies: WalletAppResetProgressStage.allCases.map(
                \.progressCopy
            ),
            progressAccessibilityKey:
                "settings.reset.progress.animation.accessibility",
            stepLocalizationKey: "settings.reset.progress.step",
            step: status == .running ? stage.ordinal : nil,
            totalSteps: status == .running ? stage.total : nil
        )
        .frame(maxWidth: 520)
        .padding(.horizontal, 28)
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .walletSafeAreaBar(edge: .bottom, spacing: 0) {
            action
                .walletActionScreenMargins()
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .walletDestructiveProgressSheetPresentation()
#if DEBUG
        .onChange(of: status, initial: true) { _, status in
            testActions?.complete = status == .completed ? onResetComplete : nil
        }
#endif
        .task {
            guard !didStart else { return }
            didStart = true
            await beginReset()
        }
    }

    @ViewBuilder
    private var action: some View {
        WalletDestructiveProgressActionHost(status: status) {
            PrimaryWalletButton(
                title: "common.done"
            ) {
                onResetComplete()
            }
            .accessibilityIdentifier("resetAppDone")
        } failure: {
            VStack(spacing: 10) {
                PrimaryWalletButton(
                    title: "settings.reset.progress.failed.retry"
                ) {
                    status = .running
                    stage = .preparing
                    Task {
                        await beginReset()
                    }
                }

                SecondaryWalletButton(
                    title: "settings.reset.progress.failed.cancel"
                ) {
                    onCancel()
                }
            }
        }
    }

    private var titleKey: LocalizedStringKey {
        switch status {
        case .failed:
            "settings.reset.progress.failed.title"
        case .completed:
            "settings.reset.progress.complete.title"
        case .running:
            stage.titleKey
        }
    }

    private var detailKey: LocalizedStringKey {
        switch status {
        case .failed:
            "settings.reset.progress.failed.detail"
        case .completed:
            "settings.reset.progress.complete.detail"
        case .running:
            stage.detailKey
        }
    }

    @MainActor
    private func beginReset() async {
        status = .running
        stage = .preparing
        var completionTracker =
            WalletDestructiveProgressCompletionTracker<
                WalletAppResetProgressStage
            >()
        let progress = AsyncStream.makeStream(
            of: WalletAppResetProgressStage.self,
            bufferingPolicy: .unbounded
        )
        let resetTask = Task { @MainActor in
            defer {
                progress.continuation.finish()
            }
            do {
                try await WalletAppResetService.shared.eraseAllData(
                    database: database,
                    applicationSettings: applicationSettings
                ) { nextStage in
                    progress.continuation.yield(nextStage)
                }
                return true
            } catch {
                return false
            }
        }

        do {
            for await nextStage in progress.stream {
                try Task.checkCancellation()
                let didCompletePreviousStage =
                    completionTracker.transition(to: nextStage)
                stage = nextStage
                if didCompletePreviousStage {
                    UniHaptic.play(.successQuiet)
                }
                try await Task.sleep(
                    nanoseconds:
                        nextStage.minimumPresentationDurationNanoseconds
                )
            }

            try Task.checkCancellation()
            if await resetTask.value {
                status = .completed
                if completionTracker.finish() {
                    UniHaptic.play(.successQuiet)
                }
            } else {
                status = .failed
            }
        } catch is CancellationError {
            resetTask.cancel()
        } catch {
            resetTask.cancel()
            status = .failed
        }
    }

}

private extension WalletAppResetProgressStage {
    var titleKey: LocalizedStringKey {
        switch self {
        case .preparing:
            "settings.reset.progress.preparing.title"
        case .securingCredentials:
            "settings.reset.progress.credentials.title"
        case .removingWalletData:
            "settings.reset.progress.wallet_data.title"
        case .clearingLocalData:
            "settings.reset.progress.local_data.title"
        case .finishing:
            "settings.reset.progress.finishing.title"
        case .complete:
            "settings.reset.progress.complete.title"
        }
    }

    var detailKey: LocalizedStringKey {
        switch self {
        case .preparing:
            "settings.reset.progress.preparing.detail"
        case .securingCredentials:
            "settings.reset.progress.credentials.detail"
        case .removingWalletData:
            "settings.reset.progress.wallet_data.detail"
        case .clearingLocalData:
            "settings.reset.progress.local_data.detail"
        case .finishing:
            "settings.reset.progress.finishing.detail"
        case .complete:
            "settings.reset.progress.complete.detail"
        }
    }

    var progressCopy: WalletDestructiveProgressCopy {
        WalletDestructiveProgressCopy(
            id: String(rawValue),
            titleKey: titleKey,
            detailKey: detailKey
        )
    }
}

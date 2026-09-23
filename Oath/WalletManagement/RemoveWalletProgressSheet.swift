import SwiftUI

struct RemoveWalletProgressSheet: View {
    let database: WalletDatabase
    let removalPlan: WalletRemovalPlan
    let onRemoved: (WalletRemovalResult) -> Void
    let onCancel: () -> Void

    @State private var stage: WalletRemovalProgressStage = .preparing
    @State private var status: WalletDestructiveProgressStatus = .running
    @State private var result: WalletRemovalResult?
    @State private var didStart = false

    var body: some View {
        WalletDestructiveProgressContent(
            status: status,
            transitionIdentity:
                "\(status.rawValue)-\(stage.rawValue)",
            titleKey: titleKey,
            detailKey: detailKey,
            stableCopies: WalletRemovalProgressStage.allCases.map(
                \.progressCopy
            ),
            progressAccessibilityKey:
                "settings.wallets.remove.progress.accessibility",
            stepLocalizationKey:
                "settings.wallets.remove.progress.step",
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
        .task {
            guard !didStart else { return }
            didStart = true
            await beginRemoval()
        }
    }

    @ViewBuilder
    private var action: some View {
        WalletDestructiveProgressActionHost(status: status) {
            PrimaryWalletButton(
                title: "settings.wallets.remove.progress.complete.action"
            ) {
                guard let result else { return }
                onRemoved(result)
            }
        } failure: {
            VStack(spacing: 10) {
                PrimaryWalletButton(
                    title: "settings.wallets.remove.progress.failed.retry"
                ) {
                    Task {
                        await beginRemoval()
                    }
                }

                SecondaryWalletButton(
                    title: "settings.wallets.remove.progress.failed.cancel"
                ) {
                    onCancel()
                }
            }
        }
    }

    private var titleKey: LocalizedStringKey {
        switch status {
        case .failed:
            "settings.wallets.remove.progress.failed.title"
        case .completed:
            "settings.wallets.remove.progress.complete.title"
        case .running:
            stage.titleKey
        }
    }

    private var detailKey: LocalizedStringKey {
        switch status {
        case .failed:
            "settings.wallets.remove.progress.failed.detail"
        case .completed:
            "settings.wallets.remove.progress.complete.detail"
        case .running:
            stage.detailKey
        }
    }

    @MainActor
    private func beginRemoval() async {
        status = .running
        stage = .preparing
        result = nil
        var completionTracker =
            WalletDestructiveProgressCompletionTracker<
                WalletRemovalProgressStage
            >()

        let progress = AsyncStream.makeStream(
            of: WalletRemovalProgressStage.self,
            bufferingPolicy: .unbounded
        )
        let removalTask = Task { @MainActor () -> WalletRemovalResult? in
            defer {
                progress.continuation.finish()
            }
            do {
                return try await database.executeWalletRemoval(
                    removalPlan
                ) { nextStage in
                    progress.continuation.yield(nextStage)
                }
            } catch {
                return nil
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
            if let removalResult = await removalTask.value {
                result = removalResult
                status = .completed
                if completionTracker.finish() {
                    UniHaptic.play(.successQuiet)
                }
            } else {
                status = .failed
                UniHaptic.play(.error)
            }
        } catch is CancellationError {
            removalTask.cancel()
        } catch {
            removalTask.cancel()
            status = .failed
            UniHaptic.play(.error)
        }
    }

}

private extension WalletRemovalProgressStage {
    var titleKey: LocalizedStringKey {
        switch self {
        case .preparing:
            "settings.wallets.remove.progress.preparing.title"
        case .removingWalletData:
            "settings.wallets.remove.progress.wallet_data.title"
        case .removingCredentials:
            "settings.wallets.remove.progress.credentials.title"
        case .updatingServices:
            "settings.wallets.remove.progress.services.title"
        case .complete:
            "settings.wallets.remove.progress.complete.title"
        }
    }

    var detailKey: LocalizedStringKey {
        switch self {
        case .preparing:
            "settings.wallets.remove.progress.preparing.detail"
        case .removingWalletData:
            "settings.wallets.remove.progress.wallet_data.detail"
        case .removingCredentials:
            "settings.wallets.remove.progress.credentials.detail"
        case .updatingServices:
            "settings.wallets.remove.progress.services.detail"
        case .complete:
            "settings.wallets.remove.progress.complete.detail"
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

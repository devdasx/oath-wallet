import SwiftUI

struct BitcoinSilentPaymentSettingsScreen: View {
    let walletID: String
    let database: WalletDatabase

    @State private var snapshot: BitcoinSilentPaymentSettingsSnapshot?
    @State private var errorMessage: String?
    @State private var durableScanProgress:
        BitcoinSilentPaymentScanProgress?
    @State private var liveScanProgress: WalletPrivateScanLiveProgress?

    var body: some View {
        List {
            Group {
                if let snapshot, let account = snapshot.account {
                    Section {
                        Text("bitcoin.silent.known_outputs_only")
                            .foregroundStyle(WalletTheme.secondaryLabel)
                    }

                    if let progress = scanProgressPresentation {
                        Section {
                            BitcoinSilentPaymentScanProgressView(
                                lastScannedHeight: progress.currentHeight,
                                targetHeight: progress.targetHeight,
                                completionFraction:
                                    progress.completionFraction,
                                isCurrentHeightEstimated:
                                    progress.isCurrentHeightEstimated
                            )
                        }
                    }

                    Section("bitcoin.settings.statistics.section") {
                        LabeledContent(
                            "bitcoin.settings.balance",
                            value: snapshot.balanceAtomic
                                .bitcoinSettingsDisplay
                        )
                        LabeledContent(
                            "bitcoin.settings.silent.outputs",
                            value: String(snapshot.outputs.count)
                        )
                        LabeledContent(
                            "bitcoin.settings.silent.unspent_outputs",
                            value: String(snapshot.unspentCount)
                        )
                        LabeledContent(
                            "bitcoin.settings.silent.spent_outputs",
                            value: String(
                                snapshot.outputs.count - snapshot.unspentCount
                            )
                        )
                        LabeledContent(
                            "bitcoin.settings.silent.birth_height",
                            value: String(account.birthHeight)
                        )
                        LabeledContent(
                            "bitcoin.settings.silent.last_scan_height",
                            value: String(account.lastScanHeight)
                        )
                    }

                    Section {
                        ForEach(
                            snapshot.outputs,
                            id: \.settingsIdentifier
                        ) { output in
                            NavigationLink(
                                value: BitcoinWalletSettingsRoute.silentOutput(
                                    output.transactionHash,
                                    output.outputIndex
                                )
                            ) {
                                BitcoinSilentPaymentOutputRow(output: output)
                            }
                        }
                    } header: {
                        Text("bitcoin.settings.silent.outputs")
                    } footer: {
                        if snapshot.outputs.isEmpty {
                            Text("bitcoin.settings.silent.outputs.empty")
                        } else {
                            Text("bitcoin.settings.silent.outputs.footer")
                        }
                    }
                } else if let errorMessage {
                    Section {
                        Text(verbatim: errorMessage)
                            .foregroundStyle(WalletTheme.danger)
                    }
                } else {
                    Section {
                        Text("receive.details.loading")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle(
            "receive.bitcoin.address_type.silent_payments"
        )
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await load() }
        }
        .task(id: walletID + ":durable-scan-progress") {
            await observeDurableScanProgress()
        }
        .task(id: walletID + ":live-scan-progress") {
            await observeLiveScanProgress()
        }
    }

    private var scanProgressPresentation:
        BitcoinSilentPaymentScanPresentation? {
        guard BitcoinSilentPaymentScanClient.isAvailable else { return nil }
        if let liveScanProgress {
            return BitcoinSilentPaymentScanPresentation(liveScanProgress)
        }
        guard let durableScanProgress,
              durableScanProgress.isScanning else { return nil }
        return BitcoinSilentPaymentScanPresentation(
            currentHeight: Int64(durableScanProgress.lastScanHeight),
            targetHeight: Int64(durableScanProgress.targetHeight),
            completionFraction: durableScanProgress.completionFraction,
            isCurrentHeightEstimated: false
        )
    }

    @MainActor
    private func load() async {
        do {
            let account = try await database.bitcoinSilentPaymentAccount(
                walletID: walletID
            )
            let outputs = try await database.bitcoinSilentPaymentOutputs(
                walletID: walletID
            )
            snapshot = BitcoinSilentPaymentSettingsSnapshot(
                account: account,
                outputs: outputs
            )
            errorMessage = account == nil
                ? WalletLocalization.string("bitcoin.settings.load.error")
                : nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = WalletLocalization.string(
                "bitcoin.settings.load.error"
            )
        }
    }

    @MainActor
    private func observeDurableScanProgress() async {
        do {
            for try await progress in database
                .bitcoinSilentPaymentScanProgressObservation(
                    walletID: walletID
                ) {
                try Task.checkCancellation()
                durableScanProgress = progress

                if let progress,
                   !progress.isScanning,
                   snapshot?.account?.lastScanHeight
                    != progress.lastScanHeight {
                    await load()
                }
            }
        } catch is CancellationError {
            return
        } catch {
            durableScanProgress = nil
        }
    }

    @MainActor
    private func observeLiveScanProgress() async {
        let updates = WalletPrivateScanLiveProgressCenter.shared.observation(
            walletID: walletID,
            kind: .bitcoinSilentPayments
        )
        for await progress in updates {
            guard !Task.isCancelled else { return }
            liveScanProgress = progress
        }
    }
}

private struct BitcoinSilentPaymentScanPresentation {
    let currentHeight: Int64
    let targetHeight: Int64
    let completionFraction: Double?
    let isCurrentHeightEstimated: Bool

    init(
        currentHeight: Int64,
        targetHeight: Int64,
        completionFraction: Double?,
        isCurrentHeightEstimated: Bool
    ) {
        self.currentHeight = currentHeight
        self.targetHeight = targetHeight
        self.completionFraction = completionFraction
        self.isCurrentHeightEstimated = isCurrentHeightEstimated
    }

    init(_ progress: WalletPrivateScanLiveProgress) {
        currentHeight = progress.currentHeight
        targetHeight = progress.targetHeight
        completionFraction = progress.completionFraction
        isCurrentHeightEstimated = progress.isCurrentHeightEstimated
    }
}

private struct BitcoinSilentPaymentScanProgressView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let lastScannedHeight: Int64
    let targetHeight: Int64
    let completionFraction: Double?
    let isCurrentHeightEstimated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(WalletTheme.success)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)

                Text("wallet.home.loading")
                    .font(.headline)
            }

            if targetHeight > 0 {
                if let completionFraction {
                    ProgressView(value: completionFraction)
                        .tint(WalletTheme.accent)
                        .animation(
                            reduceMotion
                                ? nil : .linear(duration: 0.25),
                            value: completionFraction
                        )
                        .accessibilityValue(
                            Text(
                                EnglishNumbers.percentage(
                                    Decimal(completionFraction * 100)
                                )
                            )
                        )
                }

                LabeledContent(
                    "bitcoin.settings.silent.last_scan_height",
                    value: heightText(
                        lastScannedHeight,
                        isEstimated: isCurrentHeightEstimated
                    )
                )
                LabeledContent(
                    "bitcoin.settings.silent.block_height",
                    value: heightText(targetHeight, isEstimated: false)
                )
                LabeledContent(
                    "wallet.scan.blocks_remaining",
                    value: heightText(
                        max(0, targetHeight - lastScannedHeight),
                        isEstimated: isCurrentHeightEstimated
                    )
                )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bitcoinSilentPaymentScanProgress")
    }

    private func heightText(
        _ height: Int64,
        isEstimated: Bool
    ) -> String {
        let value = EnglishNumbers.integer(height)
        return isEstimated ? "~\(value)" : value
    }
}

private struct BitcoinSilentPaymentOutputRow: View {
    let output: BitcoinSilentPaymentOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: output.valueAtomic.bitcoinSettingsDisplay)
                Spacer(minLength: 12)
                Text(LocalizedStringKey(
                    output.isSpent
                        ? "bitcoin.settings.address.status.spent"
                        : "bitcoin.settings.address.status.unspent"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(verbatim: output.settingsOutpoint)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

extension BitcoinSilentPaymentOutput {
    var settingsIdentifier: String {
        "\(transactionHash):\(outputIndex)"
    }

    var settingsOutpoint: String {
        "\(transactionHash):\(outputIndex)"
    }
}

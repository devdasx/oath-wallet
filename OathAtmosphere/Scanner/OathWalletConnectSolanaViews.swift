import SwiftUI
import OathAnkr
import OathDatabase
import OathDiagnostics

struct OathWCSolanaReview: View {
    let request: WalletConnectSolanaRequest
    let reviews: [WalletConnectSolanaReview]
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    @State private var identities: [String: ContractIdentity] = [:]
    var body: some View {
        VStack(spacing: 0) {
            OathSettingsRow(title: request.network.walletConnectName, accessory: .none, networkLogo: "network-solana")
            if request.network != .mainnet { OathSettingsFooter { Text(strings.text(.wcSolanaTestnet)) } }
            if let message = request.message {
                OathWCMessageReview(message: String(decoding: message, as: UTF8.self), signIn: nil, account: request.account, network: request.network.walletConnectName, close: close)
            } else {
                OathWCValue(title: strings.text(.scannerWCAccount), value: request.account, leftToRight: true)
                OathSettingsFooter { Text(strings.text(request.broadcasts ? .wcSolanaSimulation : .wcSolanaSignOnly)) }
                ForEach(Array(reviews.enumerated()), id: \.offset) { index, review in
                    if reviews.count > 1 { OathSettingsFooter { Text(strings.format(.wcSolanaBatch, strings.number(index + 1), strings.number(reviews.count))) } }
                    if let nonce = try? request.transactions[index].durableNonce() {
                        OathSettingsFooter { Text(strings.text(.wcSolanaDurableNonce)) }
                        OathWCValue(title: strings.text(.wcSolanaNonceAccount), value: nonce.address, leftToRight: true)
                    }
                    ForEach(Array(review.changes.enumerated()), id: \.offset) { _, change in
                        let token = identities[change.reference]
                        let symbol = change.reference == "native" ? "SOL" : token?.symbol ?? ""
                        let units = change.decimals.flatMap { OathSendAmount.units(String(change.amount), decimals: $0) }
                        let amount = units.map { $0 + " " + symbol } ?? (String(change.amount) + " · " + strings.text(.wcRawAmount))
                        OathSettingsRow(title: (change.increase ? "+" : "−") + amount,
                            accessory: .none, subtitle: change.reference == "native" ? request.network.walletConnectName : token?.name ?? change.reference,
                            networkLogo: change.reference == "native" ? "network-solana" : nil)
                        if change.reference != "native" {
                            OathWCValue(title: strings.text(.wcContractAddress), value: change.reference, leftToRight: true)
                        }
                    }
                    OathWCValue(title: strings.text(.transactionNetworkFee), value: (OathSendAmount.units(String(review.fee), decimals: 9) ?? String(review.fee)) + " SOL", leftToRight: true)
                    OathWCValue(title: strings.text(.wcSolanaFeePayer), value: request.transactions[index].feePayer, leftToRight: true)
                    if review.incomplete { OathSettingsFooter { Text(strings.text(.wcSolanaPartial)) } }
                    NavigationLink {
                        OathWCContent {
                            OathSettingsRow(title: request.network.walletConnectName, accessory: .none, networkLogo: "network-solana")
                            ForEach(review.programs, id: \.self) { program in
                                OathWCValue(title: strings.text(.wcContractAddress), value: program, leftToRight: true)
                            }
                            OathSettingsFooter { Text(strings.text(.wcCallWarning)) }
                            ForEach(Array(request.transactions[index].instructions.enumerated()), id: \.offset) { _, instruction in
                                OathWCValue(title: strings.text(.wcContractAddress), value: request.transactions[index].keys[instruction.program], leftToRight: true)
                                Text(instruction.data.map { String(format: "%02x", $0) }.joined()).oathFont(.footnote).textSelection(.enabled)
                                    .environment(\.layoutDirection, .leftToRight).padding(.horizontal, 20)
                            }
                        }.navigationTitle(strings.text(.wcSolanaPrograms)).navigationBarTitleDisplayMode(.inline)
                    } label: { OathSettingsRow(title: strings.text(.wcSolanaPrograms), icon: "text.alignleft") }
                        .buttonStyle(OathSettingsRowButtonStyle())
                    OathSettingsSectionRule()
                }
                if !request.broadcasts { OathSettingsFooter { Text(strings.text(.wcSolanaSimulation)) } }
            }
        }.task(id: request.fingerprint) {
            identities = [:]
            // Mainnet metadata must never label a different test-cluster mint.
            guard request.network == .mainnet else { return }
            await OathDiagnostics.$chain.withValue("solana") {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    for reference in Set(reviews.flatMap(\.changes).map(\.reference)).sorted().prefix(16) where reference != "native" {
                        if let identity = await OathDiagnostics.attemptOptional("walletconnect_solana_metadata", body: {
                            try await OathPermissionService.shared.identity(network: "solana", address: reference, asset: true)
                        }), !Task.isCancelled, identity.network == "solana" { identities[reference] = identity }
                    }
                }
            }
        }
    }
}
struct OathWCSolanaCompletion: View {
    let submission: WalletConnectSolanaSubmission
    let identity: OathWCIdentity
    let close: @MainActor () -> Void
    @Environment(\.oathLocalizer) private var strings
    private var confirmed: Bool { submission.state == "confirmed" }
    private var failed: Bool { ["failed", "expired"].contains(submission.state) }
    var body: some View {
        OathWCResultContent(identity: identity) {
            VStack(spacing: 0) {
                VStack(spacing: 18) {
                    Image(systemName: confirmed ? "checkmark.circle" : failed ? "exclamationmark.circle" : "clock")
                        .font(.system(size: 52)).foregroundStyle(failed ? Color.red : OathOnboardingColors.blue)
                    Text(strings.text(confirmed ? .wcTransactionConfirmed : failed ? .wcTransactionFailed : .wcTransactionPending)).oathFont(.title2, weight: .semibold)
                    Text(strings.text(confirmed ? .wcTransactionConfirmedDetail : failed ? .wcTransactionFailedDetail : .wcTransactionPendingDetail))
                        .oathFont(.body).foregroundStyle(.secondary)
                }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.bottom, 24)
                OathWCValue(title: strings.text(.tokenNetwork), value: SolanaSendNetwork(walletConnectChain: submission.chain)?.walletConnectName ?? submission.chain)
                OathWCValue(title: strings.text(.assetTransactionID), value: submission.signature, leftToRight: true)
            }
        }.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OathDoneButton(action: close).accessibilityIdentifier("walletconnect.solana.done")
            }
        }
        .toolbar(.hidden, for: .bottomBar)
    }
}

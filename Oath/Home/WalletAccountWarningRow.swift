import SwiftUI

/// One warning for the currently displayed wallet; unrelated wallets never merge.
struct WalletAccountWarningRow: View {
    let hasTronMultisig: Bool
    let findings: [StablecoinBlacklistRecord]

    var body: some View {
        if findings.isEmpty {
            if hasTronMultisig { TronMultisignatureWarningRow() }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("wallet.restrictions.warning.title").font(.headline)
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill")
                        .symbolRenderingMode(.monochrome).accessibilityHidden(true)
                }
                .accessibilityAddTraits(.isHeader)
                if hasTronMultisig {
                    Text("tron.permissions.warning.title").font(.headline)
                    Text("tron.permissions.warning.body").font(.subheadline)
                }
                Text("wallet.blacklist.warning.body").font(.subheadline)
                ForEach(findings) { finding in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: finding.symbol + " · " + (
                            ReceiveNetworkCatalog.network(for: finding.networkID)?.localizedName ?? finding.networkID
                        )).font(.subheadline.weight(.semibold))
                        Text(verbatim: finding.address).font(.caption).textSelection(.enabled)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
            .foregroundStyle(WalletTheme.onDangerLabel)
            .listRowBackground(WalletTheme.danger)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.account.restrictions.warning")
        }
    }
}

private struct StablecoinBlacklistFindingsKey: EnvironmentKey {
    static let defaultValue: [StablecoinBlacklistRecord] = []
}

extension EnvironmentValues {
    var stablecoinBlacklistFindings: [StablecoinBlacklistRecord] {
        get { self[StablecoinBlacklistFindingsKey.self] }
        set { self[StablecoinBlacklistFindingsKey.self] = newValue }
    }
}

extension AppRootView {
    @MainActor
    func observeStablecoinFindings() async {
        do {
            for try await findings in database.confirmedStablecoinChecks() {
                guard !Task.isCancelled else { return }
                stablecoinFindings = findings
            }
        } catch {
            // Retain confirmed findings if observation is interrupted.
        }
    }
}

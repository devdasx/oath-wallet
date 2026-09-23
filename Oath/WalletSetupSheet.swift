import SwiftUI

struct WalletSetupSheet: View {
    let route: WalletRoute

    @Environment(\.dismiss) private var dismiss
    @State private var selectedImportMethod: ImportMethod = .recoveryPhrase
    @State private var showPrototypeBoundary = false

    var body: some View {
        NavigationStack {
            Group {
                List {
                    Group {
                        Section {
                            header
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }

                        switch route {
                        case .create:
                            Section {
                                createContent
                            }
                        case .existing:
                            existingContent
                        }
                    }
                    .walletListRowSurface()
                }
                .walletListAppearance()
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .walletSafeAreaBar(edge: .bottom, spacing: 0) {
                    PrimaryWalletButton(
                        title: route == .create ? "setup.action.start" : "common.continue"
                    ) {
                        showPrototypeBoundary = true
                    }
                    .walletActionScreenMargins()
                    .padding(.vertical, 10)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        WalletCloseButton {
                            dismiss()
                        }
                    }
                }
                .alert("prototype.alert.title", isPresented: $showPrototypeBoundary) {
                    Button(role: .cancel, action: UniHaptic.action {}) {
                        Text("common.done")
                    }
                } message: {
                    Text("prototype.alert.message")
                }
            }

        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: headerSymbol)
                .font(.system(size: 24, weight: WalletSFSymbol.weight))
                .foregroundStyle(WalletTheme.accent)
                .frame(width: 52, height: 52)
                .background(WalletTheme.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            Text(headerTitle)
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)

            Text(headerMessage)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var createContent: some View {
        Group {
            InfoRow(
                symbol: "iphone.gen3.radiowaves.left.and.right",
                title: "setup.private.title",
                detail: "setup.private.detail"
            )
            InfoRow(
                symbol: "key.horizontal.fill",
                title: "setup.recovery.title",
                detail: "setup.recovery.detail"
            )
            InfoRow(
                symbol: "checkmark.seal.fill",
                title: "setup.review.title",
                detail: "setup.review.detail"
            )
        }
    }

    private var existingContent: some View {
        Section {
            Picker("setup.choose_method", selection: $selectedImportMethod) {
                ForEach(ImportMethod.allCases) { method in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(method.title)
                            .font(.headline)
                            .foregroundStyle(WalletTheme.primaryLabel)
                        Text(method.detail)
                            .font(.subheadline)
                            .foregroundStyle(WalletTheme.secondaryLabel)
                    }
                    .multilineTextAlignment(.leading)
                    .tag(method)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("setup.choose_method")
        }
    }

    private var headerSymbol: String {
        switch route {
        case .create: "shield.checkered"
        case .existing: "arrow.down.to.line"
        }
    }

    private var headerTitle: LocalizedStringKey {
        switch route {
        case .create: "setup.create.title"
        case .existing: "setup.import.title"
        }
    }

    private var headerMessage: LocalizedStringKey {
        switch route {
        case .create:
            "setup.create.message"
        case .existing:
            "setup.import.message"
        }
    }
}

private struct InfoRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.body)
                .fontWeight(WalletSFSymbol.weight)
                .foregroundStyle(WalletTheme.accent)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum ImportMethod: String, CaseIterable, Identifiable {
    case recoveryPhrase
    case hardwareWallet

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .recoveryPhrase: "import.recovery.title"
        case .hardwareWallet: "setup.hardware.title"
        }
    }

    var detail: String {
        switch self {
        case .recoveryPhrase:
            EnglishNumbers.localized("import.recovery.detail", 12, 24)
        case .hardwareWallet:
            WalletLocalization.string("setup.hardware.detail")
        }
    }

}

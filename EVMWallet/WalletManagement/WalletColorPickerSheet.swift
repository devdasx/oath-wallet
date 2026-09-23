import SwiftUI

struct WalletColorPickerSheet: View {
    let database: WalletDatabase
    let wallet: ManagedWallet
    let onColorChanged: (WalletAppearanceColor) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedColor: WalletAppearanceColor
    @State private var saveTask: Task<Void, Never>?
    @State private var showsSaveError = false

    init(
        database: WalletDatabase,
        wallet: ManagedWallet,
        onColorChanged:
            @escaping (WalletAppearanceColor) -> Void = { _ in }
    ) {
        self.database = database
        self.wallet = wallet
        self.onColorChanged = onColorChanged
        _selectedColor = State(initialValue: wallet.appearanceColor)
    }

    var body: some View {
        NavigationStack {
            Group {
                List {
                    Group {
                        Section {
                            ForEach(WalletAppearanceColor.allCases) { color in
                                Button(action: UniHaptic.action {
                                    select(color)
                                }) {
                                    HStack(spacing: 12) {
                                        WalletIdentityIcon(
                                            color: color,
                                            isSelected: selectedColor == color
                                        )

                                        Text(color.nameKey)
                                            .foregroundStyle(
                                                WalletTheme.primaryLabel
                                            )
                                            .fontWeight(
                                                selectedColor == color
                                                ? .semibold : .regular
                                            )

                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .disabled(saveTask != nil)
                                .listRowBackground(
                                    WalletTheme.groupedSurface.opacity(0.86)
                                )
                                .accessibilityValue(
                                    Text(
                                        selectedColor == color
                                        ? "selection.selected"
                                        : "selection.not_selected"
                                    )
                                )
                            }
                        } header: {
                            Text("settings.wallets.color.section")
                        } footer: {
                            Text("settings.wallets.color.footer")
                        }
                    }
                    .walletListRowSurface()
                }
                .walletListAppearance()
                .scrollContentBackground(.hidden)
                .navigationTitle("settings.wallets.color.title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        WalletCloseButton {
                            dismiss()
                        }
                        .disabled(saveTask != nil)
                    }
                }
            }

        }
        .walletSheetPresentation()
        .interactiveDismissDisabled(saveTask != nil)
        .alert(
            "settings.wallets.operation.error.title",
            isPresented: $showsSaveError
        ) {
            Button("common.ok", role: .cancel, action: UniHaptic.action {})
        } message: {
            Text("settings.wallets.color.error")
        }
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
        }
    }

    private func select(_ color: WalletAppearanceColor) {
        guard color != selectedColor, saveTask == nil else { return }
        saveTask = Task { @MainActor in
            defer { saveTask = nil }
            do {
                _ = try await database.setWalletAppearanceColor(
                    walletID: wallet.id,
                    color: color
                )
                try Task.checkCancellation()
                selectedColor = color
                onColorChanged(color)
                UniHaptic.play(.selection)
            } catch is CancellationError {
                return
            } catch {
                UniHaptic.play(.error)
                showsSaveError = true
            }
        }
    }
}

import SwiftUI

struct AutoLockSettingsView: View {
    let database: WalletDatabase
    let onSelectionChanged: (WalletAutoLockDuration) -> Void

    @State private var selection: WalletAutoLockDuration
    @State private var previousSelection: WalletAutoLockDuration
    @State private var isSaving = false
    @State private var isErrorPresented = false

    init(
        database: WalletDatabase,
        initialSelection: WalletAutoLockDuration,
        onSelectionChanged: @escaping (WalletAutoLockDuration) -> Void
    ) {
        self.database = database
        self.onSelectionChanged = onSelectionChanged
        _selection = State(initialValue: initialSelection)
        _previousSelection = State(initialValue: initialSelection)
    }

    var body: some View {
        List {
            Group {
                Section {
                    Picker("settings.security.auto_lock", selection: $selection) {
                        ForEach(WalletAutoLockDuration.allCases) { option in
                            Text(LocalizedStringKey(option.titleKey))
                                .tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(isSaving)
                } footer: {
                    Text("settings.security.auto_lock.footer")
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("settings.security.auto_lock")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selection) { oldValue, newValue in
            guard oldValue != newValue, !isSaving else { return }
            UniHaptic.play(.selection)
            previousSelection = oldValue
            isSaving = true
            Task {
                do {
                    try await database.setAutoLockDuration(newValue)
                    previousSelection = newValue
                    isSaving = false
                    onSelectionChanged(newValue)
                } catch {
                    selection = previousSelection
                    isSaving = false
                    isErrorPresented = true
                }
            }
        }
        .alert(
            "settings.security.update.error.title",
            isPresented: $isErrorPresented
        ) {
            Button("common.ok", action: UniHaptic.action {})
        } message: {
            Text("settings.security.update.error.message")
        }
    }
}

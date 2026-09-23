import SwiftUI

struct WalletSwitcherTrustWalletFolderScreen: View {
    let onBackupsFound: ([TrustWalletBackupDescriptor]) -> Void

    @State private var isChoosingBackupSource = false
    @State private var isReading = false
    @State private var errorKey: String?
    @State private var discoveryTask: Task<Void, Never>?

    var body: some View {
        List {
            Group {
                Section {
                    Button(
                        LocalizedStringKey(
                            TrustWalletBackupDocumentPickerPolicy
                                .selectionActionLocalizationKey
                        )
                    , action: UniHaptic.action(nil) {
                        errorKey = nil
                        isChoosingBackupSource = true
                    })
                    .disabled(isReading)
                } footer: {
                    Text(
                        LocalizedStringKey(
                            TrustWalletBackupDocumentPickerPolicy
                                .selectionDetailLocalizationKey
                        )
                    )
                }

                if isReading {
                    Section {
                        Text("import.icloud.loading")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let errorKey {
                    Section {
                        Text(LocalizedStringKey(errorKey))
                            .foregroundStyle(WalletTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("trust_wallet.restore.menu")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isChoosingBackupSource,
            allowedContentTypes:
                TrustWalletBackupDocumentPickerPolicy
                .allowedContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleSelection
        )
        .onDisappear {
            discoveryTask?.cancel()
            discoveryTask = nil
            isReading = false
        }
    }

    private func handleSelection(
        _ result: Result<[URL], Error>
    ) {
        switch result {
        case let .success(urls):
            guard urls.count == 1, let selectedURL = urls.first else {
                errorKey = "import.icloud.load.error"
                return
            }
            discoverBackups(at: selectedURL)
        case let .failure(error):
            let cocoaError = error as NSError
            guard cocoaError.code != NSUserCancelledError else { return }
            errorKey = "import.icloud.load.error"
        }
    }

    private func discoverBackups(at selectedURL: URL) {
        discoveryTask?.cancel()
        errorKey = nil
        isReading = true
        discoveryTask = Task { @MainActor in
            defer { isReading = false }
            do {
                let backups = try await TrustWalletBackupSelectionReader
                    .discover(at: selectedURL)
                try Task.checkCancellation()
                onBackupsFound(backups)
            } catch is CancellationError {
                return
            } catch {
                errorKey = TrustWalletBackupImportPresentation
                    .folderErrorKey(for: error)
            }
        }
    }
}

import SwiftUI

struct OnboardingTrustWalletBackupSelectionScreen: View {
    let backups: [TrustWalletBackupDescriptor]
    let onSelect: (TrustWalletBackupDescriptor) -> Void

    var body: some View {
        List {
            Group {
                Section("import.icloud.section") {
                    ForEach(backups) { backup in
                        Button(action: UniHaptic.action(nil) {
                            onSelect(backup)
                        }) {
                            VStack(alignment: .leading, spacing: 4) {
                                if let displayName = backup.displayName {
                                    Text(verbatim: displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                } else {
                                    Text("import.icloud.backup.title")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                }

                                Text(verbatim: backup.fileName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)

                                if let modifiedAt = backup.modifiedAt {
                                    Text(
                                        verbatim: EnglishNumbers.dateTime(
                                            modifiedAt
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }

                                Text(LocalizedStringKey(backup.kind.titleKey))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("trust_wallet.restore.menu")
        .navigationBarTitleDisplayMode(.inline)
    }
}

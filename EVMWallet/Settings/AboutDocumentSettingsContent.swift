import SwiftUI

struct AboutDocumentSettingsContent: View {
    let message: LocalizedStringKey

    var body: some View {
        List {
            Group {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
    }
}

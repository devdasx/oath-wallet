import SwiftUI

struct LicensesSettingsView: View {
    var body: some View {
        AboutDocumentSettingsContent(
            message: "settings.about.licenses.message"
        )
        .navigationTitle("settings.about.licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

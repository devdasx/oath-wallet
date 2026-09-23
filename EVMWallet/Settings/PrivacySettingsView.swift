import SwiftUI

struct PrivacySettingsView: View {
    var body: some View {
        AboutDocumentSettingsContent(
            message: "settings.about.privacy.message"
        )
        .navigationTitle("settings.about.privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

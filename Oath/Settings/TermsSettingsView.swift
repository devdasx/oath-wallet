import SwiftUI

struct TermsSettingsView: View {
    var body: some View {
        AboutDocumentSettingsContent(
            message: "settings.about.terms.message"
        )
        .navigationTitle("settings.about.terms")
        .navigationBarTitleDisplayMode(.inline)
    }
}

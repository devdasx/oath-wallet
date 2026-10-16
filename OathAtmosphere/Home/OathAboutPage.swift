import SwiftUI

struct OathSupportLinkRow: View {
    let title: OathStringKey
    let icon: String
    let url: URL
    let identifier: String
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        Link(destination: url) { OathSettingsRow(title: strings.text(title), icon: icon) }
            .buttonStyle(OathSettingsRowButtonStyle())
            .accessibilityIdentifier(identifier)
    }
}

struct OathAboutPage: View {
    var body: some View {
        VStack(spacing: 0) {
            OathSupportLinkRow(title: .articles, icon: "newspaper", url: OathSupportLinks.articles, identifier: "settings.about.articles")
            OathSupportLinkRow(title: .privacyPolicy, icon: "hand.raised", url: OathSupportLinks.privacy, identifier: "settings.about.privacy")
            OathSupportLinkRow(title: .termsOfService, icon: "doc.text", url: OathSupportLinks.terms, identifier: "settings.about.terms")
        }
    }
}

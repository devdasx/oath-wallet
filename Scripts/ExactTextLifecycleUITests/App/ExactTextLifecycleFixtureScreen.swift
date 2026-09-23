import SwiftUI
import UIKit

struct ExactTextLifecycleFixtureScreen: View {
    @Environment(\.scenePhase) private var phase
    @State private var showsDetail = false
    @State private var isAuthorizing = false
    @State private var report = ""
    @State private var requestsPrivacy = false
    private let value = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    var body: some View {
        NavigationStack {
            List {
                Section("Identifier") {
                    WalletExactText(value)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Button("Detail") { showsDetail = true }
                    Button("Confirm") { isAuthorizing = true }
                    Button("System privacy request") { requestsPrivacy.toggle() }
                    Button("Check rendering") { checkRendering() }
                    Text(verbatim: report).accessibilityIdentifier("renderReport")
                }
            }
            .navigationTitle("Text Lifecycle Fixture")
            .disabled(isAuthorizing)
            .sheet(isPresented: $showsDetail) { ExactTextDetailFixtureScreen(value: value) }
            .fullScreenCover(isPresented: $isAuthorizing) {
                Button("Cancel authorization") { isAuthorizing = false }
            }
        }
        .redacted(reason: requestsPrivacy ? .privacy : [])
        .environment(\.walletPrivacyShieldEnabled, false)
        .onChange(of: phase) { _, _ in checkRendering() }
    }

    private func checkRendering() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first?.keyWindow else { return }
        report = ExactTextRenderingProbe.report(in: window)
    }
}

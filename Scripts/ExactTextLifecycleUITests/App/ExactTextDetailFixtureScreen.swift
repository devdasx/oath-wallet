import SwiftUI
import UIKit

struct ExactTextDetailFixtureScreen: View {
    let value: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var report = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    WalletExactText(value).fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Button("Check detail rendering") { checkRendering() }
                    Text(verbatim: report).accessibilityIdentifier("detailRenderReport")
                }
            }
            .navigationTitle("Transaction ID")
            .toolbar { Button(role: .close) { dismiss() } }
        }
        .onChange(of: phase) { _, _ in checkRendering() }
    }

    private func checkRendering() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first?.keyWindow else { return }
        report = ExactTextRenderingProbe.report(in: window)
    }
}

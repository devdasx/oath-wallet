import SwiftUI

@main
struct HomeAssetPinFixtureApp: App {
    var body: some Scene {
        WindowGroup { PinFixtureScreen() }
    }
}

struct PinFixtureScreen: View {
    @State private var pinned: Set<Int> = [1]
    @State private var recorder = PinFrameRecorder()
    private var reduceMotion: Bool { ProcessInfo.processInfo.arguments.contains("--reduce-motion") }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(verbatim: "Balance").font(.largeTitle)
                    Text(verbatim: "Send / Receive")
                }
                if !pinned.isEmpty {
                    Section {
                        ForEach((0..<4).filter { pinned.contains($0) }, id: \.self) { row($0) }
                    } header: { Text(verbatim: "Pinned") }
                }
                if pinned.count < 4 {
                    Section {
                        ForEach((0..<4).filter { !pinned.contains($0) }, id: \.self) { row($0) }
                    } header: { Text(verbatim: "Assets") }
                }
            }
            .listStyle(.insetGrouped)
            .animation(reduceMotion ? nil : .default, value: pinned)
            .navigationTitle("Pin fixture")
            .toolbar {
                Button("Record") { recorder.begin() }
                Button("Report") { recorder.report() }
            }
            .safeAreaInset(edge: .bottom) {
                Text(verbatim: recorder.result).font(.caption).lineLimit(1).accessibilityIdentifier("report")
            }
        }
    }

    private func row(_ id: Int) -> some View {
        PinFixtureRow(id: id, pinned: pinned.contains(id))
            .background(PinFrameProbe(id: id, recorder: recorder))
            .walletHomeAssetPinAction(isPinned: pinned.contains(id)) {
                recorder.committing(id)
                if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
            }
    }
}

struct PinFixtureRow: View {
    let id: Int
    let pinned: Bool
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(verbatim: "Asset \(id)").font(.headline)
                Text(verbatim: "0 COIN").font(.subheadline)
            }
            Spacer()
            Text(verbatim: "$0.00")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Asset \(id)")
        .accessibilityIdentifier("asset-\(id)")
        .accessibilityValue(String(pinned))
    }
}

// Only the production pin-action primitive is linked into this isolated fixture.
// These stand-ins avoid wallet services, persistence, credentials, and network I/O.
enum WalletTheme { static let accent = Color.accentColor }
enum UniHaptic {
    case selection
    static func play(_ value: Self) {}
}

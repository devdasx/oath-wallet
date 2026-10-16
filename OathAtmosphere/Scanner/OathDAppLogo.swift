import SwiftUI
import OathTokenImages
import OathDiagnostics

/// A single logo presentation for proposals, requests and connected dApps.
/// Missing metadata is normal. Fetch/decode failures use ArtworkLoader's shared
/// diagnostics, cache, redirect validation, byte limit and concurrency budget.
struct OathDAppLogo: View {
    let icons: [String]
    var size: CGFloat = 44
    @Environment(\.scenePhase) private var scenePhase
    @State private var artwork: ArtworkImage?
    @State private var loadedSources: [String] = []
    private var sources: [String] { OathWalletConnectPolicy.iconSources(icons) }
    private struct LoadID: Hashable { let sources: [String]; let active: Bool }

    var body: some View {
        Group {
            if loadedSources == sources, let artwork { ArtworkImageView(artwork) }
            else {
                Image(systemName: "link")
                    .font(.system(size: size * 0.42)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size, height: size)
        .background(artwork == nil ? Color(uiColor: OathSurfaceColors.field) : .white)
        .clipShape(.rect(cornerRadius: size * 0.24))
        .accessibilityHidden(true)
        .task(id: LoadID(sources: sources, active: scenePhase == .active)) {
            guard scenePhase == .active, !sources.isEmpty else { return }
            let requested = sources
            await OathDiagnostics.$operationID.withValue(UUID()) {
                if let cached = await ArtworkLoader.shared.cached(for: requested), !Task.isCancelled {
                    artwork = cached; loadedSources = requested
                }
                let image = await ArtworkLoader.shared.image(for: requested)
                guard !Task.isCancelled else { return }
                artwork = image; loadedSources = requested
            }
        }
    }
}

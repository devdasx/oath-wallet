import SwiftUI
import Testing
import UIKit
@testable import Aperture

@Suite("Native action screen margins", .serialized)
@MainActor
struct WalletActionButtonLayoutTests {
    @Test(arguments: SuccessLayout.allCases)
    func screenMarginsAreNativeAndAppliedOnce(layout: SuccessLayout) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let measurements = ActionMarginMeasurements()
        let controller = UIHostingController(rootView: ActionMarginTestContent(measurements: measurements)
            .environment(\.dynamicTypeSize, layout.textSize)
            .environment(\.layoutDirection, layout.direction)
            .environment(\.colorScheme, layout.colorScheme)
            .ignoresSafeArea())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: layout.size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        // Resize the same hosting controller to exercise margin updates.
        for size in [layout.size, CGSize(width: 320, height: 700), layout.size] {
            window.frame = CGRect(origin: .zero, size: size)
            controller.view.frame = window.bounds
            for _ in 0..<5 {
                controller.view.setNeedsLayout()
                window.layoutIfNeeded()
                controller.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            let native = controller.systemMinimumLayoutMargins
            let available = controller.view.bounds.width
            let expectedWidth = min(560, available - native.leading - native.trailing)
            let automatic = try #require(measurements.frames["automatic"])
            let grouped = try #require(measurements.frames["grouped"])
            let existingContainer = try #require(measurements.frames["container"])
            #expect(native.leading > 0 && native.trailing > 0)
            #expect(abs(automatic.width - expectedWidth) < 1)
            #expect(abs(automatic.minX - (available - expectedWidth) / 2) < 1)
            #expect(abs(grouped.width - automatic.width) < 1)
            #expect(abs(grouped.minX - automatic.minX) < 1)
            // A native inset container must not receive another screen inset.
            #expect(abs(existingContainer.width - available) < 1)
        }
    }
}

@MainActor
private final class ActionMarginMeasurements {
    var frames: [String: CGRect] = [:]
}

private struct ActionMarginFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ActionMarginTestContent: View {
    let measurements: ActionMarginMeasurements

    var body: some View {
        VStack(spacing: 12) {
            probe("automatic").walletAutomaticActionMargins()
            VStack {
                probe("grouped").walletAutomaticActionMargins()
            }
            .walletActionScreenMargins()
            probe("container")
                .walletAutomaticActionMargins()
                .walletActionUsesContainerMargins()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "actions")
        .onPreferenceChange(ActionMarginFrameKey.self) { measurements.frames = $0 }
    }

    private func probe(_ key: String) -> some View {
        Color.clear.frame(height: 52)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ActionMarginFrameKey.self,
                        value: [key: proxy.frame(in: .named("actions"))])
                }
            }
    }
}

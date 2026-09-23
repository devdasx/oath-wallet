import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct UnsafeCredentialWarningPresentationTests {
    @Test(arguments: [NativeListTestLayout.phone, .phoneLandscape, .pad, .largeTextRTL], [false, true])
    func warningOffersOnePartialHeightDetent(
        layout: NativeListTestLayout, walletSwitcher: Bool
    ) async throws {
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        settings.setLanguageIdentifier(layout.direction == .rightToLeft ? "ar" : "en")
        let warning = UnsafeCredentialImportWarning(finding: WalletCredentialSafetyFinding(
            credentialKind: .recoveryPhrase, reason: .publiclyKnown
        ))
        let host = try NativeListTestHost(layout: layout) {
            Color.clear
                .sheet(isPresented: .constant(true)) {
                    Group {
                        if walletSwitcher {
                            WalletSwitcherUnsafeCredentialWarningScreen(warning: warning, onChooseDifferent: {})
                        } else {
                            UnsafeCredentialImportWarningSheet(warning: warning, onChooseDifferent: {})
                        }
                    }
                    .environment(settings)
                    .environment(\.verticalSizeClass, layout == .phoneLandscape ? .compact : .regular)
                }
                .environment(settings)
        }
        defer {
            host.rootView.window?.rootViewController?.dismiss(animated: false)
            host.close()
        }
        var presented: UIViewController?
        for _ in 0..<100 {
            host.rootView.layoutIfNeeded()
            presented = host.rootView.window?.rootViewController?.presentedViewController
            if let sheet = presented?.sheetPresentationController, !sheet.detents.isEmpty,
               presented?.transitionCoordinator == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let controller = try #require(presented)
        let sheet = try #require(controller.sheetPresentationController)
        #expect(sheet.detents.count == 1)
        #expect(!sheet.detents.contains { $0.identifier == .large })
        if layout != .phoneLandscape {
            #expect(sheet.detents.first?.identifier == .medium)
        }
        #expect(controller.isModalInPresentation)
        #expect(sheet.prefersGrabberVisible)
        let scrollViews = descendants(UIScrollView.self, in: controller.view)
        #expect(scrollViews.isEmpty)
        #expect(controller.view.bounds.height > 0)
    }

    private func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }
}

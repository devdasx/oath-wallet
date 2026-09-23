import Observation
import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
struct OnboardingPasscodeNavigationTests {
    @Test
    func passcodeScreensPushAndPopWithoutPresentingAModal() async throws {
        let destinations: [OnboardingDestination] = [
            .creationPasscode,
            .importPasscode,
            .physicalEntropy(.passcode)
        ]
        let layouts: [(CGSize, LayoutDirection, DynamicTypeSize)] = [
            (CGSize(width: 393, height: 852), .leftToRight, .large),
            (CGSize(width: 852, height: 393), .leftToRight, .large),
            (CGSize(width: 1_024, height: 1_366), .leftToRight, .large),
            (CGSize(width: 393, height: 852), .rightToLeft, .accessibility3)
        ]

        for destination in destinations {
            for (size, direction, textSize) in layouts {
                try await verifyPushAndPop(
                    destination,
                    size: size,
                    direction: direction,
                    textSize: textSize
                )
            }
        }
    }

    private func verifyPushAndPop(
        _ destination: OnboardingDestination,
        size: CGSize,
        direction: LayoutDirection,
        textSize: DynamicTypeSize
    ) async throws {
        let model = OnboardingPasscodeNavigationModel()
        let host = UIHostingController(
            rootView: OnboardingPasscodeNavigationHarness(model: model)
                .environment(\.layoutDirection, direction)
                .environment(\.dynamicTypeSize, textSize)
        )
        let scene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()

        let navigation = try #require(findNavigationController(in: host))
        #expect(navigation.viewControllers.count == 1)

        model.path = OnboardingNavigationTransition.pushing(
            destination,
            onto: model.path
        )
        try await settleNavigation(in: host) {
            navigation.viewControllers.count == 2
                && navigation.transitionCoordinator == nil
        }

        #expect(navigation.viewControllers.count == 2)
        #expect(navigation.topViewController?.navigationItem.title
            == WalletLocalization.string("passcode.navigation.set"))
        #expect(navigation.topViewController?.navigationItem.hidesBackButton
            == false)
        #expect(!containsPresentedController(in: host))
        #expect(model.path == [destination])

        navigation.popViewController(animated: false)
        try await settleNavigation(in: host) {
            navigation.viewControllers.count == 1 && model.path.isEmpty
        }

        #expect(navigation.viewControllers.count == 1)
        #expect(model.path.isEmpty)
        #expect(!containsPresentedController(in: host))
    }

    private func settleNavigation(
        in host: UIViewController,
        until isSettled: () -> Bool
    ) async throws {
        for _ in 0..<100 {
            await Task.yield()
            host.view.layoutIfNeeded()
            if isSettled() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(isSettled(), "Native navigation did not finish")
    }

    private func findNavigationController(
        in controller: UIViewController
    ) -> UINavigationController? {
        if let navigation = controller as? UINavigationController {
            return navigation
        }
        for child in controller.children {
            if let navigation = findNavigationController(in: child) {
                return navigation
            }
        }
        return nil
    }

    private func containsPresentedController(
        in controller: UIViewController
    ) -> Bool {
        controller.presentedViewController != nil
            || controller.children.contains {
                containsPresentedController(in: $0)
            }
    }
}

@MainActor
@Observable
private final class OnboardingPasscodeNavigationModel {
    var path: [OnboardingDestination] = []
}

private struct OnboardingPasscodeNavigationHarness: View {
    @Bindable var model: OnboardingPasscodeNavigationModel

    var body: some View {
        NavigationStack(path: $model.path) {
            Color.clear
                .navigationDestination(for: OnboardingDestination.self) {
                    destination in
                    switch destination {
                    case .creationPasscode:
                        PINSetupFlowView { _ in }
                    case .importPasscode:
                        OnboardingImportPasscodeScreen { _ in }
                    case .physicalEntropy(.passcode):
                        OnboardingPhysicalEntropyPasscodeScreen(
                            isSaving: false,
                            onPasscodeConfirmed: { _ in }
                        )
                    default:
                        EmptyView()
                    }
                }
        }
    }
}

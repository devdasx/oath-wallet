import GRDB
import Observation
import SwiftUI
import Testing
import UIKit
@testable import Aperture

/// Hosts the production completion screens without creating wallets or taking screenshots.
@Suite(.serialized)
@MainActor
struct WalletSuccessLayoutTests {
    @Test(arguments: WalletSuccessKind.allCases, [true, false])
    func backupRowsExistBeforePersistenceAndKeepTheirListWhenReady(kind: WalletSuccessKind, allowsManualBackup: Bool) async throws {
        let fixture = try ICloudReplacementFixture()
        defer { fixture.cleanUp() }
        let database = try await fixture.database()
        if !allowsManualBackup {
            try await database.pool.write { db in
                try db.execute(sql: "UPDATE wallets SET kind = ?", arguments: [DatabaseWalletKind.importedPrivateKey.rawValue])
            }
        }
        let rowCount = allowsManualBackup ? 2 : 1
        let state = SuccessBackupContextTestState()
        let host = try NativeListTestHost {
            SuccessBackupContextTestView(state: state, kind: kind, allowsManualBackup: allowsManualBackup)
        }
        defer { host.close() }
        let list = try await host.list {
            $0.numberOfSections == 1 && $0.numberOfItems(inSection: 0) == rowCount
        }
        let first = IndexPath(item: 0, section: 0)
        let second = IndexPath(item: 1, section: 0)
        _ = try await host.cell(at: first, in: list)
        if allowsManualBackup { _ = try await host.cell(at: second, in: list) }
        let initialFrame = try #require(list.layoutAttributesForItem(at: first)).frame
        #expect(SendEntryUIProbe.views(UIActivityIndicatorView.self, in: host.rootView).isEmpty)

        state.context = WalletSuccessBackupContext(database: database, walletID: fixture.wallet.id)
        state.isPreparing = false
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UISwitch.self, in: host.rootView).first?.isEnabled == true
        }
        let readyList = try await host.list()
        #expect(readyList === list, "Saving must not replace the success screen's list")
        #expect(list.numberOfItems(inSection: 0) == rowCount)
        let readyFrame = try #require(list.layoutAttributesForItem(at: first)).frame
        #expect(readyFrame == initialFrame)
        #expect(SendEntryUIProbe.views(UIActivityIndicatorView.self, in: host.rootView).isEmpty)
    }

    @Test(arguments: SuccessFlow.allCases, SuccessLayout.allCases)
    func completionFitsWithAccessibleText(flow: SuccessFlow, layout: SuccessLayout) async throws {
        let host = try SuccessScreenHost(flow: flow, layout: layout)
        defer { host.close() }
        await host.layout()

        #expect(!scrollViews(in: host.view).isEmpty,
                "The confirmation and backup rows must share one native list from the first frame")
        #expect(host.view.bounds.width > 0)
        #expect(host.view.bounds.height > 0)
        let fitted = host.fittedSize(in: layout.size)
        #expect(fitted.width <= layout.size.width + 1)
        #expect(fitted.height <= layout.size.height + 1)
    }

    @Test(arguments: SuccessLayout.allCases)
    func heroFitsAboveTheNativeAction(layout: SuccessLayout) {
        let action = UIHostingController(rootView: PrimaryWalletButton(
            title: "success.open", action: {}
        )
        .environment(\.dynamicTypeSize, layout.textSize))
        let actionSize = action.sizeThatFits(in: CGSize(
            width: min(560, layout.size.width - 56), height: layout.size.height
        ))
        // Reserve the safe areas, the native action's measured height, and its spacing.
        let available = CGSize(
            width: layout.size.width,
            height: layout.size.height - actionSize.height - 120
        )
        #expect(available.height > 0)

        let hero = UIHostingController(rootView: WalletSuccessHero()
        .environment(\.dynamicTypeSize, layout.textSize)
        .environment(\.layoutDirection, layout.direction)
        .environment(\.locale, layout.locale))
        let fitted = hero.sizeThatFits(in: available)
        #expect(fitted.width <= available.width + 1)
        #expect(fitted.height <= available.height + 1)
        #expect(fitted.width.isFinite && fitted.height.isFinite)
    }

    @Test(arguments: SuccessFlow.allCases)
    func rotatingAnExistingScreenKeepsTheNativeList(flow: SuccessFlow) async throws {
        let host = try SuccessScreenHost(flow: flow, layout: .phone)
        defer { host.close() }

        for layout in [SuccessLayout.phone, .phoneLandscape, .phone, .padSplit] {
            host.resize(to: layout.size)
            await host.layout()
            #expect(!scrollViews(in: host.view).isEmpty)
            #expect(host.view.bounds.size == layout.size)
        }
    }

    /// Persistence runs behind the finished screen: it starts on the first frame
    /// and exactly once, and nothing about it reaches the UI.
    @Test
    func pendingPreparationStartsOnceAndStaysOutOfTheUI() async throws {
        var preparationRequests = 0
        let host = try SuccessScreenHost(
            layout: .phone,
            screen: AnyView(
                WalletSuccessView(
                    isReady: false,
                    onPrepare: { preparationRequests += 1 },
                    onContinue: {}
                )
            )
        )
        defer { host.close() }

        await host.layout()
        // The screen shows its finished state while persistence is still running:
        // no spinner stands in for the confirmation mark. (Identifier lookups
        // cannot see a SwiftUI tree here, so this reads the rendered UIKit view.)
        #expect(SendEntryUIProbe.views(UIActivityIndicatorView.self, in: host.view).isEmpty)

        for _ in 0..<20 where preparationRequests == 0 {
            try await Task.sleep(for: .milliseconds(20))
            host.view.layoutIfNeeded()
        }
        #expect(preparationRequests == 1)

        try await Task.sleep(for: .milliseconds(80))
        host.view.layoutIfNeeded()
        #expect(preparationRequests == 1)
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func accessibilityElement(
        identifiedBy identifier: String,
        in root: NSObject
    ) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        return accessibilityElement(
            identifiedBy: identifier,
            in: root,
            visited: &visited
        )
    }

    private func accessibilityElement(
        identifiedBy identifier: String,
        in object: NSObject,
        visited: inout Set<ObjectIdentifier>
    ) -> NSObject? {
        guard visited.insert(ObjectIdentifier(object)).inserted else {
            return nil
        }
        let count = object.accessibilityElementCount()
        if count > 0, count < 1_000 {
            for index in 0..<count {
                guard let child = object.accessibilityElement(at: index)
                    as? NSObject else { continue }
                if let match = accessibilityElement(
                    identifiedBy: identifier,
                    in: child,
                    visited: &visited
                ) {
                    return match
                }
            }
        }
        if let view = object as? UIView {
            for child in view.subviews {
                if let match = accessibilityElement(
                    identifiedBy: identifier,
                    in: child,
                    visited: &visited
                ) {
                    return match
                }
            }
        }
        if object.responds(
            to: #selector(getter: UIView.accessibilityIdentifier)
        ), object.value(forKey: "accessibilityIdentifier") as? String
            == identifier {
            return object
        }
        return nil
    }
}

enum SuccessFlow: CaseIterable, Sendable {
    case onboarding, settingsCreation, physicalEntropy, walletSwitcher

    @MainActor @ViewBuilder
    var screen: some View {
        switch self {
        case .onboarding: WalletSuccessView(onContinue: {})
        case .settingsCreation: SettingsWalletCreationSuccessScreen(onDone: {})
        case .physicalEntropy: OnboardingPhysicalEntropySuccessScreen(onContinue: {})
        case .walletSwitcher:
            WalletSwitcherSetupSuccessScreen(
                isFinishing: false,
                onDone: {}
            )
        }
    }
}

enum SuccessLayout: CaseIterable, Sendable {
    case smallPhone, phone, phoneLandscape, accessiblePhone, accessibleLandscape
    case pad, padLandscape, padSplit, rightToLeft

    var size: CGSize {
        switch self {
        case .smallPhone: CGSize(width: 320, height: 568)
        case .phone, .accessiblePhone, .rightToLeft: CGSize(width: 393, height: 852)
        case .phoneLandscape, .accessibleLandscape: CGSize(width: 852, height: 393)
        case .pad: CGSize(width: 1_024, height: 1_366)
        case .padLandscape: CGSize(width: 1_366, height: 1_024)
        case .padSplit: CGSize(width: 320, height: 700)
        }
    }

    var textSize: DynamicTypeSize {
        switch self {
        case .accessiblePhone, .accessibleLandscape, .padSplit: .accessibility5
        case .rightToLeft: .accessibility3
        default: .large
        }
    }

    var direction: LayoutDirection { self == .rightToLeft ? .rightToLeft : .leftToRight }
    var locale: Locale { Locale(identifier: self == .rightToLeft ? "ar" : "en") }
    var colorScheme: ColorScheme {
        switch self {
        case .phoneLandscape, .pad, .rightToLeft: .dark
        default: .light
        }
    }
}

@MainActor
private final class SuccessScreenHost {
    private let controller: UIHostingController<AnyView>
    private let window: UIWindow
    private weak var previousKeyWindow: UIWindow?

    convenience init(flow: SuccessFlow, layout: SuccessLayout) throws {
        try self.init(layout: layout, screen: AnyView(flow.screen))
    }

    init(layout: SuccessLayout, screen: AnyView) throws {
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.keyWindow
        controller = UIHostingController(rootView: AnyView(NavigationStack {
            screen
        }
        .environment(\.dynamicTypeSize, layout.textSize)
        .environment(\.layoutDirection, layout.direction)
        .environment(\.locale, layout.locale)
        .environment(\.colorScheme, layout.colorScheme)))
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: layout.size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
    }

    var view: UIView { controller.view }

    func fittedSize(in size: CGSize) -> CGSize { controller.sizeThatFits(in: size) }

    func resize(to size: CGSize) {
        window.frame = CGRect(origin: .zero, size: size)
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
    }

    func layout() async {
        for _ in 0..<3 {
            await Task.yield()
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
        }
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }
}

@Suite("Shared native primary actions", .serialized)
@MainActor
struct WalletPrimaryActionStyleTests {
    @Test(arguments: NativeListTestLayout.allCases)
    func homeMatchesOnboardingMetrics(
        layout: NativeListTestLayout
    ) {
        let available = CGSize(width: min(360, layout.size.width - 40), height: layout.size.height)
        let reference = measuredSize(in: available, layout: layout) {
            PrimaryWalletButton(title: "common.continue", action: {})
        }
        let home = measuredSize(in: available, layout: layout) {
            MutedWalletActionButton(
                title: "common.continue", prominence: .primary,
                action: {}
            )
        }
        let disabled = measuredSize(in: available, layout: layout) {
            MutedWalletActionButton(
                title: "common.continue", prominence: .primary,
                action: {}
            ).disabled(true)
        }
        let secondary = measuredSize(in: available, layout: layout) {
            SecondaryWalletButton(title: "common.continue", action: {})
        }
        let mutedSecondary = measuredSize(in: available, layout: layout) {
            MutedWalletActionButton(title: "common.continue", prominence: .secondary, action: {})
        }
        #expect(reference == secondary)
        #expect(reference == mutedSecondary)
        #expect(abs(reference.width - home.width) < 1)
        #expect(abs(reference.height - home.height) < 1)
        #expect(home.width <= available.width)
        #expect(home.height >= 44)
        #expect(disabled == home)
    }

    private func measuredSize<Content: View>(
        in available: CGSize,
        layout: NativeListTestLayout,
        @ViewBuilder content: () -> Content
    ) -> CGSize {
        let host = UIHostingController(rootView: content()
            .environment(\.dynamicTypeSize, layout.textSize)
            .environment(\.layoutDirection, layout.direction)
            .environment(\.colorScheme, layout.colorScheme))
        return host.sizeThatFits(in: available)
    }
}

@MainActor
@Observable
private final class SuccessBackupContextTestState {
    var context: WalletSuccessBackupContext?
    var isPreparing = true
}

private struct SuccessBackupContextTestView: View {
    let state: SuccessBackupContextTestState
    let kind: WalletSuccessKind
    let allowsManualBackup: Bool

    var body: some View {
        NavigationStack {
            WalletSuccessPresentation(
                kind: kind, isPreparing: state.isPreparing,
                backupContext: state.context,
                allowsManualBackup: allowsManualBackup
            ) {
                Text("success.open")
            }
        }
    }
}

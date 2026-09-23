import SwiftUI
import Testing
import UIKit
@testable import Aperture

enum NativeListTestLayout: CaseIterable, Sendable {
    case phone, phoneLandscape, pad, padLandscape, largeTextLTR, largeTextRTL

    var size: CGSize {
        switch self {
        case .phone, .largeTextLTR, .largeTextRTL: CGSize(width: 393, height: 852)
        case .phoneLandscape: CGSize(width: 852, height: 393)
        case .pad: CGSize(width: 1_024, height: 1_366)
        case .padLandscape: CGSize(width: 1_366, height: 1_024)
        }
    }

    var direction: LayoutDirection { self == .largeTextRTL ? .rightToLeft : .leftToRight }
    var textSize: DynamicTypeSize {
        switch self {
        case .largeTextLTR, .largeTextRTL: .accessibility3
        default: .large
        }
    }
    var colorScheme: ColorScheme {
        switch self {
        case .phoneLandscape, .pad, .largeTextRTL: .dark
        default: .light
        }
    }
}

@MainActor
final class ListActionRecorder<Action> {
    var actions: [Action] = []
}

/// Exercises SwiftUI's real UIKit-backed List, without screenshots or live wallet data.
@MainActor
final class NativeListTestHost {
    private let host: UIHostingController<AnyView>
    private let window: UIWindow
    private weak var previousKeyWindow: UIWindow?

    init<Content: View>(
        layout: NativeListTestLayout = .phone,
        size: CGSize? = nil,
        @ViewBuilder content: () -> Content
    ) throws {
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.keyWindow
        host = UIHostingController(rootView: AnyView(content()
            .environment(\.layoutDirection, layout.direction)
            .environment(\.dynamicTypeSize, layout.textSize)
            .environment(\.colorScheme, layout.colorScheme)
            .environment(\.locale, Locale(identifier: layout.direction == .rightToLeft ? "ar" : "en"))))
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size ?? layout.size)
        window.overrideUserInterfaceStyle = layout.colorScheme == .dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }

    var navigationController: UINavigationController? {
        findNavigationController(in: host)
    }

    var rootView: UIView { host.view }

    private func findNavigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        for child in controller.children {
            if let navigation = findNavigationController(in: child) { return navigation }
        }
        return nil
    }

    func list(
        matching isReady: (UICollectionView) -> Bool = { $0.numberOfSections > 0 }
    ) async throws -> UICollectionView {
        for _ in 0..<150 {
            await Task.yield()
            host.view.layoutIfNeeded()
            if let list = findCollectionView(in: host.view), isReady(list) {
                return list
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let list = try #require(findCollectionView(in: host.view))
        #expect(isReady(list), "Native list did not finish preparing its rows")
        return list
    }

    func cell(at indexPath: IndexPath, in list: UICollectionView) async throws -> UICollectionViewCell {
        list.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        for _ in 0..<50 {
            host.view.layoutIfNeeded()
            list.layoutIfNeeded()
            await Task.yield()
            if let cell = list.cellForItem(at: indexPath) { return cell }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(list.cellForItem(at: indexPath))
    }

    func selectRow(_ indexPath: IndexPath, in list: UICollectionView) async throws {
        let cell = try await cell(at: indexPath, in: list)
        #expect(list.delegate?.collectionView?(list, shouldHighlightItemAt: indexPath) == true)
        cell.isHighlighted = true
        list.delegate?.collectionView?(list, didHighlightItemAt: indexPath)
        cell.layoutIfNeeded()
        #expect(cell.isHighlighted)
        #expect(cell.bounds.height > 0 && cell.bounds.width > 0)
        #expect(list.delegate?.collectionView?(list, canPerformPrimaryActionForItemAt: indexPath) == true)
        list.delegate?.collectionView?(list, performPrimaryActionForItemAt: indexPath)
        cell.isHighlighted = false
        list.delegate?.collectionView?(list, didUnhighlightItemAt: indexPath)
        await Task.yield()
    }

    func selectNavigationRow(_ indexPath: IndexPath, in list: UICollectionView) async throws {
        let cell = try await cell(at: indexPath, in: list)
        #expect(list.delegate?.collectionView?(list, shouldHighlightItemAt: indexPath) == true)
        #expect(list.delegate?.collectionView?(list, shouldSelectItemAt: indexPath) == true)
        cell.isHighlighted = true
        list.delegate?.collectionView?(list, didHighlightItemAt: indexPath)
        #expect(cell.isHighlighted)
        list.selectItem(at: indexPath, animated: false, scrollPosition: [])
        list.delegate?.collectionView?(list, didSelectItemAt: indexPath)
        cell.isHighlighted = false
        list.delegate?.collectionView?(list, didUnhighlightItemAt: indexPath)
        await Task.yield()
    }

    func accessibilityAction(label: String, in view: UIView) -> NSObject? {
        accessibilityAction(in: view) { $0 == label }
    }

    func accessibilityAction(
        in view: UIView, labelMatches: (String) -> Bool
    ) -> NSObject? {
        var visited: Set<ObjectIdentifier> = []
        return findAccessibilityAction(labelMatches: labelMatches, in: view, visited: &visited)
    }

    private func findAccessibilityAction(
        labelMatches: (String) -> Bool, in object: NSObject, visited: inout Set<ObjectIdentifier>
    ) -> NSObject? {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
        if let label = object.accessibilityLabel, labelMatches(label),
           object.accessibilityTraits.contains(.button) { return object }
        let count = object.accessibilityElementCount()
        if count > 0, count < 1_000 {
            for index in 0..<count {
                if let child = object.accessibilityElement(at: index) as? NSObject,
                   let match = findAccessibilityAction(labelMatches: labelMatches, in: child, visited: &visited) {
                    return match
                }
            }
        }
        if let view = object as? UIView {
            for child in view.subviews {
                if let match = findAccessibilityAction(labelMatches: labelMatches, in: child, visited: &visited) {
                    return match
                }
            }
        }
        return nil
    }

    private func findCollectionView(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for child in view.subviews {
            if let list = findCollectionView(in: child) { return list }
        }
        return nil
    }
}

enum NativeListTestFixtures {
    static let address = "0x0000000000000000000000000000000000000042"

    static var wallet: ManagedWallet {
        ManagedWallet(
            id: "native-list-test-wallet",
            name: "List Test Wallet",
            kind: .watchOnly,
            address: address,
            fiatUSDBalance: 123,
            isSelected: false,
            notificationsEnabledWhenInactive: false,
            backupState: .notVerified,
            backupVerifiedAt: nil,
            iCloudBackupUpdatedAt: nil,
            mnemonicWordCount: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }

    static var sendChoices: [SendAssetChoice] {
        [
            SendAssetChoice(
                id: "eth:native", name: "Ethereum", symbol: "ETH", networkID: "eth",
                networkName: "Ethereum", blockchain: .ethereum, contractAddress: nil,
                decimals: 18, logoSource: .nativeCoin(blockchain: .ethereum),
                networkLogoSource: .nativeCoin(blockchain: .ethereum),
                balance: 2, fiatValue: 6_000, sourceAddress: address
            ),
            SendAssetChoice(
                id: "polygon:native", name: "Polygon", symbol: "POL", networkID: "polygon",
                networkName: "Polygon", blockchain: .polygon, contractAddress: nil,
                decimals: 18, logoSource: .nativeCoin(blockchain: .polygon),
                networkLogoSource: .nativeCoin(blockchain: .polygon),
                balance: 20, fiatValue: 10, sourceAddress: address
            )
        ]
    }
}

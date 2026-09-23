import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
struct OnboardingWalletEntryTests {
    @Test
    func importOptionsIncludeManualEntropyCreation() {
        for offersDeviceTransfer in [false, true] {
            let options = makeImportOptions(
                onSelect: { _ in },
                offersDeviceTransfer: offersDeviceTransfer
            ).options

            var expected: [ImportWalletOption] = [
                .recoveryPhrase,
                .privateKey,
                .physicalEntropy,
                .restoreICloud
            ]
            if offersDeviceTransfer {
                expected.append(.transferFromIPhone)
            }
            #expect(options == expected)
        }
    }

    @Test
    func everyImportOptionInvokesOnlyItsOwnAction() {
        var selected: [ImportWalletOption] = []
        let view = makeImportOptions(
            onSelect: { selected.append($0) },
            offersDeviceTransfer: true
        )

        for option in view.options {
            selected.removeAll()
            view.select(option)
            #expect(selected == [option])
        }
    }

    @Test
    func deviceTransferOptionDoesNotMisidentifyTheDestination() throws {
        let detail = ImportWalletOption.transferFromIPhone.detail

        #expect(
            detail == "Scan the transfer code displayed on your old iPhone "
                + "to restore the complete app."
        )
        #expect(!detail.localizedCaseInsensitiveContains("this iPhone"))

        for language in Bundle.main.localizations where language != "Base" {
            let path = try #require(Bundle.main.path(
                forResource: language,
                ofType: "lproj"
            ))
            let bundle = try #require(Bundle(path: path))
            let localizedDetail = bundle.localizedString(
                forKey: "device_migration.import.option.detail",
                value: "MISSING",
                table: nil
            )
            #expect(localizedDetail != "MISSING")
            #expect(!localizedDetail.isEmpty)
            #expect(
                localizedDetail.components(separatedBy: "iPhone").count <= 2,
                "\(language) still names both source and destination as iPhone"
            )
        }
    }

    @Test
    func physicalEntropyImportOptionClearlyDescribesWalletCreation() {
        let option = ImportWalletOption.physicalEntropy

        #expect(
            option.titleKey == "onboarding.creation.method.physical.title"
        )
        #expect(option.detail == WalletLocalization.string(
            "onboarding.creation.method.physical.subtitle"
        ))
        #expect(ImportWalletOption.allCases.contains(option))
    }

    @Test(arguments: ImportWalletOption.allCases)
    func everyImportMethodUsesAValidSettingsSizedSymbol(
        option: ImportWalletOption
    ) throws {
        let symbol = try #require(UIImage(
            systemName: option.systemImage,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: SettingsIconMetrics.symbolPointSize,
                weight: .semibold,
                scale: .medium
            )
        ))

        #expect(symbol.size.width > 0)
        #expect(symbol.size.height > 0)
        #expect(symbol.size.width <= SettingsIconMetrics.size - 4)
        #expect(symbol.size.height <= SettingsIconMetrics.size - 4)
    }

    @Test(arguments: ImportWalletOption.allCases)
    func importMethodTilesMatchSettingsAcrossDynamicType(
        option: ImportWalletOption
    ) {
        let textSizes: [DynamicTypeSize] = [
            .small, .large, .xxxLarge, .accessibility3,
            .accessibility5
        ]

        for textSize in textSizes {
            let importHost = UIHostingController(
                rootView: ImportMethodIconTile(option: option)
                    .environment(\.dynamicTypeSize, textSize)
            )
            let settingsHost = UIHostingController(
                rootView: SettingsIconTile(icon: .wallets)
                    .environment(\.dynamicTypeSize, textSize)
            )
            let proposal = CGSize(width: 500, height: 500)
            let actual = importHost.sizeThatFits(in: proposal)
            let expected = settingsHost.sizeThatFits(in: proposal)

            #expect(abs(actual.width - actual.height) < 0.01)
            #expect(abs(actual.width - expected.width) < 0.01)
            #expect(abs(actual.height - expected.height) < 0.01)
        }
    }

    @Test(arguments: [
        UIUserInterfaceStyle.light,
        .dark
    ], [
        UIAccessibilityContrast.normal,
        .high
    ])
    func importMethodPaletteUsesAdaptiveSettingsColors(
        appearance: UIUserInterfaceStyle,
        contrast: UIAccessibilityContrast
    ) {
        let traits = UITraitCollection {
            $0.userInterfaceStyle = appearance
            $0.accessibilityContrast = contrast
        }
        let palette: [(ImportWalletOption, UIColor)] = [
            (.recoveryPhrase, .systemBlue),
            (.privateKey, .systemGreen),
            (.physicalEntropy, .systemOrange),
            (.restoreICloud, .systemIndigo),
            (.transferFromIPhone, .systemGray)
        ]

        #expect(palette.count == ImportWalletOption.allCases.count)
        for (option, expected) in palette {
            #expect(
                colorComponents(
                    UIColor(option.iconColor),
                    traits: traits
                ) == colorComponents(expected, traits: traits)
            )
        }
    }

    @Test
    func existingProfileEntropyCreationDoesNotRequireAnotherPasscode() throws {
        let session = OnboardingPhysicalEntropyCreationSession(
            database: try WalletDatabase.temporary(),
            usesExistingProfileSecurity: true
        )
        defer { session.cancelOwnedWork() }

        #expect(session.confirmedPasscode.isEmpty)
        guard case .reuseExistingProfile = try session.persistenceSecurity else {
            Issue.record("Adding a wallet must preserve the existing profile security.")
            return
        }
    }

    @Test
    func firstWalletEntropyCreationStillRequiresPasscodeSetup() throws {
        let session = OnboardingPhysicalEntropyCreationSession(
            database: try WalletDatabase.temporary()
        )
        defer { session.cancelOwnedWork() }

        #expect(throws: WalletCreationPersistenceError.self) {
            try session.persistenceSecurity
        }
    }

    @Test
    func firstWalletEntropyCreationContinuesFromWordsToNativePasscodeRoute()
        async throws
    {
        let session = OnboardingPhysicalEntropyCreationSession(
            database: try WalletDatabase.temporary()
        )
        let navigation = PhysicalEntropyNavigationRecorder()
        defer { session.cancelOwnedWork() }

        // A public, deterministic BIP39 fixture, never a funded wallet.
        session.generateWallet(Data(repeating: 0, count: 32)) {
            navigation.destinations.append($0)
        }
        await session.generationTask?.value

        #expect(session.words.count == 24)
        #expect(navigation.destinations == [.recoveryPhrase])
        session.continueAfterRecoveryPhrase {
            navigation.destinations.append($0)
        }
        #expect(navigation.destinations == [.recoveryPhrase, .passcode])
        #expect(!session.isPersistingWallet)
    }

    @Test
    func newWalletEntryStartsQuickCreationWithoutMethodOptions()
        async throws
    {
        let layouts: [(CGSize, LayoutDirection, DynamicTypeSize)] = [
            (CGSize(width: 393, height: 852), .leftToRight, .large),
            (CGSize(width: 852, height: 393), .leftToRight, .large),
            (CGSize(width: 1_024, height: 1_366), .leftToRight, .large),
            (CGSize(width: 393, height: 852), .rightToLeft, .accessibility3)
        ]
        for (size, direction, textSize) in layouts {
            let host = UIHostingController(
                rootView: OnboardingView(
                    database: try WalletDatabase.temporary(),
                    startAction: .createWallet
                )
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

            for _ in 0..<200 {
                await Task.yield()
                host.view.layoutIfNeeded()
                if let navigation = findNavigationController(in: host),
                   navigation.viewControllers.count == 2,
                   navigation.transitionCoordinator == nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }

            let navigation = try #require(findNavigationController(in: host))
            #expect(navigation.viewControllers.count == 2)
            #expect(navigation.topViewController?.navigationItem.title
                == WalletLocalization.string(
                    "passcode.navigation.set"
                ))
            #expect(!containsPresentedController(in: host))
        }
    }

    private func makeImportOptions(
        onSelect: @escaping (ImportWalletOption) -> Void,
        offersDeviceTransfer: Bool
    ) -> ImportWalletOptionsView {
        ImportWalletOptionsView(
            onRecoveryPhrase: { onSelect(.recoveryPhrase) },
            onPrivateKey: { onSelect(.privateKey) },
            onPhysicalEntropy: { onSelect(.physicalEntropy) },
            onRestoreICloud: { onSelect(.restoreICloud) },
            onTransferFromIPhone: offersDeviceTransfer
                ? { onSelect(.transferFromIPhone) }
                : nil,
            onMuunRecovery: {},
            onTrustWalletRestore: { _ in }
        )
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

    private func containsPresentedController(in controller: UIViewController) -> Bool {
        controller.presentedViewController != nil
            || controller.children.contains {
                containsPresentedController(in: $0)
            }
    }

    private func colorComponents(
        _ color: UIColor,
        traits: UITraitCollection
    ) -> [CGFloat] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #expect(
            color.resolvedColor(with: traits).getRed(
                &red,
                green: &green,
                blue: &blue,
                alpha: &alpha
            )
        )
        return [red, green, blue, alpha]
    }
}

@MainActor
private final class PhysicalEntropyNavigationRecorder {
    var destinations: [OnboardingPhysicalEntropyDestination] = []
}

@Suite
struct OnboardingWelcomePageTests {
    @Test
    func tourOpensWithTheNetworksAndClosesOnVerification() {
        #expect(OnboardingWelcomePage.allCases == [
            .networks, .entropy, .activity, .security, .openSource
        ])
        #expect(OnboardingWelcomePage.networks.rawValue == 0)
    }

    /// Every page resolves to real English copy, and no two pages share a headline.
    @Test
    func everyPageResolvesDistinctEnglishCopy() {
        let bundle = WalletAppLanguage.localizedBundle(for: "en")
        var headlines: Set<String> = []
        for page in OnboardingWelcomePage.allCases {
            let title = bundle.localizedString(forKey: page.titleKey, value: nil, table: nil)
            let subtitle = bundle.localizedString(forKey: page.subtitleKey, value: nil, table: nil)
            #expect(title != page.titleKey, "\(page) has no English headline")
            #expect(subtitle != page.subtitleKey, "\(page) has no English subtitle")
            headlines.insert(title)
        }
        #expect(headlines.count == OnboardingWelcomePage.allCases.count)
    }
}

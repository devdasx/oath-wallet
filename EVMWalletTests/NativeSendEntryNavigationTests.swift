import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct NativeSendEntryNavigationTests {
    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL], ["bitcoin", "dogecoin", "solana"])
    func emptyRecipientDisplaysTheLocalizedChainPrompt(
        layout: NativeListTestLayout, networkID: String
    ) async throws {
        let database = try WalletDatabase.temporary()
        let network = try #require(AssetNetworkSelectorOption.allSupported.first { $0.id == networkID })
        let asset = try SendEntryTestFixtures.nativeChoice(for: network)
        let draft = SendEntryTestFixtures.draft(asset: asset, recipient: "")
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendRecipientScreen(database: database, draft: draft) { _ in }
            }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections >= 2 }
        let cell = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        let input = try #require(SendEntryUIProbe.views(UITextView.self, in: cell).first)
        #expect(input.text.isEmpty)
        let locale = layout.direction == .rightToLeft ? "ar" : "en"
        let path = try #require(Bundle.main.path(forResource: locale, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let expected = bundle.localizedString(
            forKey: SendRecipientPlaceholder.key(for: networkID), value: nil, table: nil
        )
        try await SendEntryUIProbe.wait(in: host.rootView) {
            recipientPromptText(in: cell).contains { $0.contains(expected) }
        }
        #expect(SendEntryUIProbe.element("sendRecipientContinue", in: host.rootView)?
            .accessibilityTraits.contains(.notEnabled) == true)
    }

    private func recipientPromptText(in root: NSObject) -> [String] {
        var visited: Set<ObjectIdentifier> = []
        var text: [String] = []
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            text.append(contentsOf: [object.accessibilityLabel, object.accessibilityValue].compactMap { $0 })
            if let label = object as? UILabel, let value = label.text { text.append(value) }
            if let field = object as? UITextField, let value = field.placeholder { text.append(value) }
            let count = object.accessibilityElementCount()
            if count > 0 && count < 1_000 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { visit(child) }
                }
            }
            if let view = object as? UIView { view.subviews.forEach(visit) }
        }
        visit(root)
        return text
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad])
    func productionFlowPushesRecipientAmountAndReviewAndPreservesBackState(
        layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        let asset = SendEntryTestFixtures.ethereum
        let host = try NativeListTestHost(layout: layout) {
            SendFlowView(
                database: database,
                walletAddress: NativeListTestFixtures.address,
                walletAssets: [],
                preparationRevision: UUID(),
                initialRoute: SendFlowPlanner.manualEntryRoute(for: asset)
            )
            .environment(settings)
            .environment(SendActivityStore())
            .environment(\.walletCurrencyContext, SendEntryTestFixtures.currency)
        }
        defer { host.close() }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            host.navigationController?.viewControllers.count == 2
                && SendEntryUIProbe.element("sendRecipientInput", in: host.rootView) != nil
        }
        let navigation = try #require(host.navigationController)
        let recipientView = try #require(navigation.topViewController?.view)
        #expect(SendEntryUIProbe.element("sendAmountBalance", in: recipientView) == nil)
        #expect(SendEntryUIProbe.element("sendRecipientSelectedAsset", in: recipientView) != nil)
        #expect(SendEntryUIProbe.views(UITextView.self, in: recipientView).count == 1)
        let input = try #require(SendEntryUIProbe.views(UITextView.self, in: recipientView).first)
        let continueButton = try #require(SendEntryUIProbe.element("sendRecipientContinue", in: recipientView))
        #expect(continueButton.accessibilityTraits.contains(.notEnabled))

        // Recipient owns only address entry actions; transaction options begin
        // on Amount after a recipient has been chosen.
        let toolbar = navigation.navigationBar
        #expect(SendEntryUIProbe.element("sendRecipientPaste", in: toolbar) == nil)
        #expect(SendEntryUIProbe.element("sendRecipientPaste", in: recipientView) != nil)
        #expect(SendEntryUIProbe.element("sendRecipientScan", in: toolbar) == nil)
        #expect(SendEntryUIProbe.element("sendRecipientScan", in: recipientView) != nil)
        #expect(SendEntryUIProbe.element("sendRecipientOptions", in: toolbar) == nil)
        let toolbarItems = navigation.topViewController?.navigationItem.trailingItemGroups
            .flatMap(\.barButtonItems) ?? []
        #expect(toolbarItems.isEmpty)

        input.text = SendEntryTestFixtures.address(for: .ethereum)
        input.delegate?.textViewDidChange?(input)
        try await SendEntryUIProbe.wait(in: recipientView) {
            SendEntryUIProbe.element("sendRecipientContinue", in: recipientView)?
                .accessibilityTraits.contains(.notEnabled) == false
        }
        try SendEntryUIProbe.activate("sendRecipientContinue", in: recipientView)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            navigation.viewControllers.count == 3 && navigation.transitionCoordinator == nil
                && SendEntryUIProbe.element("sendAmountValue", in: navigation.topViewController!.view) != nil
        }
        #expect(navigation.presentedViewController == nil)
        var amountView = try #require(navigation.topViewController?.view)
        #expect(SendEntryUIProbe.element("sendAmountOptions", in: toolbar) != nil)
        #expect(SendEntryUIProbe.views(UITextField.self, in: amountView).isEmpty)
        #expect(!input.isFirstResponder)
        let amountList = try #require(SendEntryUIProbe.views(UICollectionView.self, in: amountView).first)
        #expect(amountList.numberOfSections == 2)
        let balanceCell = try await host.cell(at: IndexPath(item: 0, section: 0), in: amountList)
        #expect(SendEntryUIProbe.element("sendAmountBalance", in: balanceCell) != nil)
        let keypad = try #require(SendEntryUIProbe.element("sendAmountKeypad", in: amountView))
        for key in ["Decimal", "1", "2", "Delete", "2"] {
            try SendEntryUIProbe.activate("sendAmountKey" + key, in: keypad)
            await Task.yield()
        }
        try await SendEntryUIProbe.wait(in: amountView) {
            SendEntryUIProbe.element("sendAmountReview", in: amountView)?
                .accessibilityTraits.contains(.notEnabled) == false
        }
        try SendEntryUIProbe.activate("sendAmountReview", in: amountView)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            navigation.viewControllers.count == 4 && navigation.transitionCoordinator == nil
                && navigation.topViewController?.navigationItem.title == String(localized: "send.review.title", locale: Locale(identifier: "en"))
        }
        #expect(navigation.presentedViewController == nil)

        navigation.popViewController(animated: false)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            navigation.viewControllers.count == 3 && navigation.transitionCoordinator == nil
        }
        amountView = try #require(navigation.topViewController?.view)
        var restoredList = try #require(SendEntryUIProbe.views(UICollectionView.self, in: amountView).first)
        var amountCell = try await host.cell(at: IndexPath(item: 0, section: 1), in: restoredList)
        #expect(SendEntryUIProbe.element("sendAmountValue", in: amountCell)?.accessibilityValue == "0.12 ETH")

        navigation.popViewController(animated: false)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil
        }
        let returnedRecipient = try #require(SendEntryUIProbe.views(UITextView.self, in: navigation.topViewController!.view).first)
        #expect(returnedRecipient.text == SendEntryTestFixtures.address(for: .ethereum))
        try SendEntryUIProbe.activate("sendRecipientContinue", in: navigation.topViewController!.view)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            navigation.viewControllers.count == 3 && navigation.transitionCoordinator == nil
        }
        amountView = try #require(navigation.topViewController?.view)
        restoredList = try #require(SendEntryUIProbe.views(UICollectionView.self, in: amountView).first)
        amountCell = try await host.cell(at: IndexPath(item: 0, section: 1), in: restoredList)
        #expect(SendEntryUIProbe.element("sendAmountValue", in: amountCell)?.accessibilityValue == "0 ETH")
        #expect(SendEntryUIProbe.element("sendAmountReview", in: amountView)?.accessibilityTraits.contains(.notEnabled) == true)
        #expect(SendEntryUIProbe.views(UITextField.self, in: amountView).isEmpty)
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad])
    func localCurrencySelectionPersistsIntoTheNextTransfer(
        layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        let firstSettings = WalletSettingsStore(database: database)
        let asset = SendEntryTestFixtures.ethereum

        do {
            let host = try NativeListTestHost(layout: layout) {
                NavigationStack {
                    SendAmountScreen(
                        database: database,
                        draft: SendEntryTestFixtures.draft(
                            asset: asset,
                            amount: "0.01"
                        )
                    ) { _ in }
                }
                .environment(firstSettings)
                .environment(
                    \.walletCurrencyContext,
                    SendEntryTestFixtures.currency
                )
            }
            defer { host.close() }

            let list = try await host.list { $0.numberOfSections == 2 }
            let cell = try await host.cell(
                at: IndexPath(item: 0, section: 1),
                in: list
            )
            try await SendEntryUIProbe.wait(in: host.rootView) {
                SendEntryUIProbe.element(
                    "sendAmountValue",
                    in: cell
                )?.accessibilityValue == "0.01 ETH"
            }

            try SendEntryUIProbe.activate("sendAmountMode", in: cell)
            try await SendEntryUIProbe.wait(in: host.rootView) {
                SendEntryUIProbe.element(
                    "sendAmountValue",
                    in: cell
                )?.accessibilityValue == "30 USD"
            }
            #expect(firstSettings.sendAmountEntryMode == .localCurrency)
            #expect(await firstSettings.flush())
        }

        let nextTransferSettings = WalletSettingsStore(database: database)
        #expect(nextTransferSettings.sendAmountEntryMode == .localCurrency)

        let nextHost = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendAmountScreen(
                    database: database,
                    draft: SendEntryTestFixtures.draft(
                        asset: asset,
                        amount: "0.02"
                    )
                ) { _ in }
            }
            .environment(nextTransferSettings)
            .environment(
                \.walletCurrencyContext,
                SendEntryTestFixtures.currency
            )
        }
        defer { nextHost.close() }

        let nextList = try await nextHost.list {
            $0.numberOfSections == 2
        }
        let nextCell = try await nextHost.cell(
            at: IndexPath(item: 0, section: 1),
            in: nextList
        )
        try await SendEntryUIProbe.wait(in: nextHost.rootView) {
            SendEntryUIProbe.element(
                "sendAmountValue",
                in: nextCell
            )?.accessibilityValue == "60 USD"
                && SendEntryUIProbe.element(
                    "sendAmountMode",
                    in: nextCell
                )?.accessibilityValue == "0.02 ETH"
        }
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func amountCounterpartAppearsBelowEntryOnlyWhenPriced(
        layout: NativeListTestLayout
    ) async throws {
        for mode in ["native", "fiat", "unpriced"] {
            let original = SendEntryTestFixtures.ethereum
            let asset = SendAssetChoice(
                id: original.id, name: original.name, symbol: original.symbol,
                networkID: original.networkID, networkName: original.networkName,
                blockchain: original.blockchain, contractAddress: original.contractAddress,
                decimals: original.decimals, logoSource: original.logoSource,
                networkLogoSource: original.networkLogoSource,
                balance: original.balance, fiatValue: mode == "unpriced" ? 0 : original.fiatValue
            )
            let currency = mode == "fiat"
                ? WalletCurrencyContext(code: "AED", ratePerUSD: Decimal(string: "3.6725")!)
                : SendEntryTestFixtures.currency
            let database = try WalletDatabase.temporary()
            let settings = WalletSettingsStore(database: database)
            settings.setSendAmountEntryMode(mode == "native" ? .asset : .localCurrency)
            let recorder = ListActionRecorder<SendDraft>()
            let draft = SendEntryTestFixtures.draft(asset: asset, amount: "0.01")
            let host = try NativeListTestHost(layout: layout) {
                NavigationStack {
                    SendAmountScreen(database: database, draft: draft) {
                        recorder.actions.append($0)
                    }
                }
                .environment(settings)
            .environment(SendActivityStore())
                .environment(\.walletCurrencyContext, currency)
            }
            defer { host.close() }
            let list = try await host.list { $0.numberOfSections == 2 }
            let cell = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
            let expectedValue = mode == "fiat" ? "110.175 AED" : "0.01 ETH"
            try await SendEntryUIProbe.wait(in: host.rootView) {
                SendEntryUIProbe.element("sendAmountValue", in: cell)?.accessibilityValue == expectedValue
            }
            let value = try #require(SendEntryUIProbe.element("sendAmountValue", in: cell))
            if mode == "unpriced" {
                #expect(SendEntryUIProbe.element("sendAmountMode", in: cell) == nil)
            } else {
                let counterpart = try #require(SendEntryUIProbe.element("sendAmountMode", in: cell))
                #expect(counterpart.accessibilityValue == (mode == "fiat" ? "0.01 ETH" : "$30.00"))
                #expect(counterpart.accessibilityFrame.minY >= value.accessibilityFrame.maxY)
                #expect(abs(counterpart.accessibilityFrame.midX - value.accessibilityFrame.midX) < 2)
            }
            #expect(SendEntryUIProbe.views(UITextField.self, in: cell).isEmpty)
            try SendEntryUIProbe.activate("sendAmountReview", in: host.rootView)
            #expect(recorder.actions.first?.amount == "0.01")
        }
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func conversionPillBelowAmountSwitchesUnitsAndPreservesMaximum(
        layout: NativeListTestLayout
    ) async throws {
        let network = try #require(
            AssetNetworkSelectorOption.allSupported.first {
                $0.blockchain == .bitcoincash
            }
        )
        let fixtureAsset = try SendEntryTestFixtures.nativeChoice(for: network)
        let asset = SendAssetChoice(
            id: fixtureAsset.id,
            name: fixtureAsset.name,
            symbol: BitcoinFamilyChain.bitcoinCash.symbol,
            networkID: fixtureAsset.networkID,
            networkName: fixtureAsset.networkName,
            blockchain: fixtureAsset.blockchain,
            contractAddress: fixtureAsset.contractAddress,
            decimals: fixtureAsset.decimals,
            logoSource: fixtureAsset.logoSource,
            networkLogoSource: fixtureAsset.networkLogoSource,
            balance: fixtureAsset.balance,
            fiatValue: fixtureAsset.fiatValue,
            balanceAtomic: fixtureAsset.balanceAtomic,
            sourceAddress: fixtureAsset.sourceAddress
        )
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        settings.setSendAmountEntryMode(.asset)
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendAmountScreen(
                    database: database,
                    draft: SendEntryTestFixtures.draft(
                        asset: asset,
                        amount: "1"
                    )
                ) { _ in }
            }
            .environment(settings)
            .environment(SendActivityStore())
            .environment(
                \.walletCurrencyContext,
                SendEntryTestFixtures.currency
            )
        }
        defer { host.close() }

        let list = try await host.list { $0.numberOfSections == 2 }
        let cell = try await host.cell(
            at: IndexPath(item: 0, section: 1),
            in: list
        )
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element(
                "sendAmountValue",
                in: cell
            )?.accessibilityValue == "1 BCH"
        }

        let mode = try #require(
            SendEntryUIProbe.element("sendAmountMode", in: cell)
        )
        let maximum = try #require(
            SendEntryUIProbe.element("sendAmountMax", in: cell)
        )
        let cellFrame = UIAccessibility.convertToScreenCoordinates(
            cell.bounds,
            in: cell
        )
        let languageIdentifier = layout.direction == .rightToLeft ? "ar" : "en"
        let localizedBundle = WalletAppLanguage.localizedBundle(
            for: languageIdentifier
        )
        #expect(mode.accessibilityValue == "$2.00")
        #expect(
            mode.accessibilityLabel
                == localizedBundle.localizedString(
                    forKey: "send.amount.entry_mode",
                    value: nil,
                    table: nil
                )
        )
        #expect(
            maximum.accessibilityLabel
                == localizedBundle.localizedString(
                    forKey: "send.amount.max_action",
                    value: nil,
                    table: nil
                )
        )
        let amount = try #require(SendEntryUIProbe.element("sendAmountValue", in: cell))
        #expect(mode.accessibilityTraits.contains(.button))
        #expect(mode.accessibilityFrame.width > mode.accessibilityFrame.height)
        #expect(mode.accessibilityFrame.height >= 44)
        #expect(mode.accessibilityFrame.minY >= amount.accessibilityFrame.maxY)
        #expect(abs(mode.accessibilityFrame.midX - cellFrame.midX) < 2)
        #expect(cellFrame.contains(mode.accessibilityFrame))
        #expect(abs(maximum.accessibilityFrame.width - maximum.accessibilityFrame.height) < 2)
        if layout.direction == .leftToRight {
            #expect(maximum.accessibilityFrame.midX < cellFrame.midX)
        } else {
            #expect(maximum.accessibilityFrame.midX > cellFrame.midX)
        }

        try SendEntryUIProbe.activate("sendAmountMode", in: cell)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element(
                "sendAmountValue",
                in: cell
            )?.accessibilityValue == "2 USD"
                && SendEntryUIProbe.element(
                    "sendAmountMode",
                    in: cell
                )?.accessibilityValue == "1 BCH"
        }
        #expect(settings.sendAmountEntryMode == .localCurrency)

        try SendEntryUIProbe.activate("sendAmountMode", in: cell)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element(
                "sendAmountValue",
                in: cell
            )?.accessibilityValue == "1 BCH"
        }
        #expect(settings.sendAmountEntryMode == .asset)

        try SendEntryUIProbe.activate("sendAmountMax", in: cell)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element(
                "sendAmountValue",
                in: cell
            )?.accessibilityValue == "100 BCH"
        }
        try SendEntryUIProbe.activate("sendAmountMode", in: cell)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendAmountValue", in: cell)?.accessibilityValue == "200 USD"
                && SendEntryUIProbe.element("sendAmountMode", in: cell)?.accessibilityValue == "100 BCH"
        }
        try SendEntryUIProbe.activate("sendAmountMode", in: cell)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendAmountValue", in: cell)?.accessibilityValue == "100 BCH"
                && SendEntryUIProbe.element("sendAmountMode", in: cell)?.accessibilityValue == "$200.00"
        }
    }

    @Test
    func maximumActionHasLocalizedLabelInEverySupportedLanguage() {
        for identifier in WalletAppLanguage.supportedIdentifiers {
            let value = WalletAppLanguage.localizedBundle(for: identifier)
                .localizedString(
                    forKey: "send.amount.max_action",
                    value: nil,
                    table: nil
                )
            #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(value != "send.amount.max_action", "Missing Max label for \(identifier)")
        }
    }

    @Test
    func longAmountShrinksWithoutMovingTheSurroundingAmountLayout()
        async throws
    {
        let original = SendEntryTestFixtures.ethereum
        let largeBalance = try #require(
            Decimal(string: "999999999999999999")
        )
        let asset = SendAssetChoice(
            id: original.id,
            name: original.name,
            symbol: original.symbol,
            networkID: original.networkID,
            networkName: original.networkName,
            blockchain: original.blockchain,
            contractAddress: original.contractAddress,
            decimals: original.decimals,
            logoSource: original.logoSource,
            networkLogoSource: original.networkLogoSource,
            balance: largeBalance,
            fiatValue: largeBalance,
            balanceAtomic: original.balanceAtomic,
            sourceAddress: original.sourceAddress
        )
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        settings.setSendAmountEntryMode(.asset)
        let host = try NativeListTestHost(layout: .phone) {
            NavigationStack {
                SendAmountScreen(
                    database: database,
                    draft: SendEntryTestFixtures.draft(asset: asset)
                ) { _ in }
            }
            .environment(settings)
            .environment(SendActivityStore())
            .environment(
                \.walletCurrencyContext,
                SendEntryTestFixtures.currency
            )
        }
        defer { host.close() }

        let list = try await host.list { $0.numberOfSections == 2 }
        let cell = try await host.cell(
            at: IndexPath(item: 0, section: 1),
            in: list
        )
        try await SendEntryUIProbe.wait(in: cell) {
            SendEntryUIProbe.element("sendAmountValue", in: cell)?
                .accessibilityValue == "0 ETH"
        }

        let stableCellIdentifiers = [
            "sendAmountMode",
            "sendAmountMax"
        ]
        let initialFrames = try Dictionary(uniqueKeysWithValues:
            stableCellIdentifiers.map { identifier in
                (
                    identifier,
                    try #require(
                        SendEntryUIProbe.element(identifier, in: cell)
                    ).accessibilityFrame
                )
            }
        )
        let initialCellFrame = UIAccessibility.convertToScreenCoordinates(
            cell.bounds,
            in: cell
        )
        let initialReviewFrame = try #require(
            SendEntryUIProbe.element("sendAmountReview", in: host.rootView)
        ).accessibilityFrame
        let initialKeypadFrame = try #require(
            SendEntryUIProbe.element("sendAmountKeypad", in: host.rootView)
        ).accessibilityFrame
        let initialValueFrame = try #require(
            SendEntryUIProbe.element("sendAmountValue", in: cell)
        ).accessibilityFrame

        for _ in 0..<12 {
            try SendEntryUIProbe.activate(
                "sendAmountKey1",
                in: host.rootView
            )
            await Task.yield()
        }
        try await SendEntryUIProbe.wait(in: cell) {
            SendEntryUIProbe.element("sendAmountValue", in: cell)?
                .accessibilityValue == "111111111111 ETH"
        }

        let updatedCellFrame = UIAccessibility.convertToScreenCoordinates(
            cell.bounds,
            in: cell
        )
        #expect(abs(updatedCellFrame.height - initialCellFrame.height) < 1)
        #expect(abs(updatedCellFrame.minY - initialCellFrame.minY) < 1)
        for identifier in stableCellIdentifiers {
            let initial = try #require(initialFrames[identifier])
            let updated = try #require(
                SendEntryUIProbe.element(identifier, in: cell)
            ).accessibilityFrame
            #expect(abs(updated.minY - initial.minY) < 1)
            #expect(abs(updated.height - initial.height) < 1)
        }
        let updatedValueFrame = try #require(
            SendEntryUIProbe.element("sendAmountValue", in: cell)
        ).accessibilityFrame
        #expect(updatedValueFrame.height < initialValueFrame.height)
        #expect(abs(updatedValueFrame.midY - initialValueFrame.midY) < 1)
        let updatedReviewFrame = try #require(
            SendEntryUIProbe.element("sendAmountReview", in: host.rootView)
        ).accessibilityFrame
        let updatedKeypadFrame = try #require(
            SendEntryUIProbe.element("sendAmountKeypad", in: host.rootView)
        ).accessibilityFrame
        #expect(abs(updatedReviewFrame.minY - initialReviewFrame.minY) < 1)
        #expect(abs(updatedReviewFrame.height - initialReviewFrame.height) < 1)
        #expect(updatedKeypadFrame == initialKeypadFrame)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func amountKeypadStaysBelowReviewAtScreenBottomOutsideNativeList(
        layout: NativeListTestLayout
    ) async throws {
        let recorder = ListActionRecorder<SendDraft>()
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        let draft = SendEntryTestFixtures.draft()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendAmountScreen(database: database, draft: draft) {
                    recorder.actions.append($0)
                }
            }
            .environment(settings)
            .environment(SendActivityStore())
            .environment(\.walletCurrencyContext, SendEntryTestFixtures.currency)
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 2 }
        #expect(SendEntryUIProbe.views(UITextField.self, in: host.rootView).isEmpty)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendAmountKeypad", in: host.rootView)?.accessibilityFrame.height ?? 0 > 0
        }
        let keypad = try #require(SendEntryUIProbe.element("sendAmountKeypad", in: host.rootView))
        let review = try #require(SendEntryUIProbe.element("sendAmountReview", in: host.rootView))
        let screen = try #require(host.navigationController?.topViewController?.view)
        let safeFrame = UIAccessibility.convertToScreenCoordinates(screen.safeAreaLayoutGuide.layoutFrame, in: screen)
        #expect(SendEntryUIProbe.element("sendAmountKeypad", in: list) == nil)
        #expect(SendEntryUIProbe.element("sendAmountReview", in: list) == nil)
        #expect(safeFrame.insetBy(dx: -1, dy: -1).contains(review.accessibilityFrame))
        #expect(review.accessibilityFrame.height >= 44)
        #expect(review.accessibilityFrame.maxY <= keypad.accessibilityFrame.minY)
        let bottomSpacing: CGFloat = layout == .phoneLandscape ? 4 : 8
        #expect(abs(safeFrame.maxY - keypad.accessibilityFrame.maxY - bottomSpacing) <= 2)
        #expect(list.bounds.height >= 80)
        for key in (0...9).map(String.init) + ["Decimal", "Delete"] {
            let control = try #require(SendEntryUIProbe.element("sendAmountKey" + key, in: keypad))
            #expect(control.accessibilityTraits.contains(.button))
            #expect(control.accessibilityFrame.width >= 44)
            #expect(control.accessibilityFrame.height >= (layout == .phoneLandscape ? 44 : 64))
            #expect(keypad.accessibilityFrame.insetBy(dx: -1, dy: -1).contains(control.accessibilityFrame))
            #expect(safeFrame.insetBy(dx: -1, dy: -1).contains(control.accessibilityFrame))
            if let digit = Int(key) {
                #expect(control.accessibilityLabel == String(digit))
            }
        }
        for row in [
            ["1", "2", "3"],
            ["4", "5", "6"],
            ["7", "8", "9"],
            ["Decimal", "0", "Delete"]
        ] {
            let frames = try row.map { key in
                try #require(
                    SendEntryUIProbe.element(
                        "sendAmountKey" + key,
                        in: keypad
                    )
                ).accessibilityFrame
            }
            #expect(frames[0].midX < frames[1].midX)
            #expect(frames[1].midX < frames[2].midX)
        }
        let backspace = try #require(SendEntryUIProbe.element("sendAmountKeyDelete", in: keypad))
        #expect(backspace.accessibilityLabel == WalletLocalization.string("send.amount.delete_action"))
        #expect(backspace.accessibilityTraits.contains(.notEnabled))
        let pinnedFrame = keypad.accessibilityFrame
        _ = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        #expect(keypad.accessibilityFrame == pinnedFrame)
        for key in ["1", "Decimal", "5", "9", "Delete"] {
            try SendEntryUIProbe.activate("sendAmountKey" + key, in: keypad)
            await Task.yield()
        }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendAmountReview", in: host.rootView)?
                .accessibilityTraits.contains(.notEnabled) == false
        }
        #expect(SendEntryUIProbe.element("sendAmountKeyDecimal", in: keypad)?
            .accessibilityTraits.contains(.notEnabled) == true)
        try SendEntryUIProbe.activate("sendAmountReview", in: host.rootView)
        #expect(recorder.actions.count == 1)
        #expect(recorder.actions.first?.amount == "1.5")
        #expect(recorder.actions.first?.recipient == draft.recipient)
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad])
    func amountDockReflowsOnRotationWithoutLosingInput(layout: NativeListTestLayout) async throws {
        let recorder = ListActionRecorder<SendDraft>()
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        let draft = SendEntryTestFixtures.draft()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendAmountScreen(database: database, draft: draft) {
                    recorder.actions.append($0)
                }
            }
            .environment(settings)
            .environment(SendActivityStore())
            .environment(\.walletCurrencyContext, SendEntryTestFixtures.currency)
        }
        defer { host.close() }
        _ = try await host.list { $0.numberOfSections == 2 }
        for key in ["1", "Decimal", "5"] {
            try SendEntryUIProbe.activate("sendAmountKey" + key, in: host.rootView)
            await Task.yield()
        }
        let window = try #require(host.rootView.window)
        for size in [CGSize(width: layout.size.height, height: layout.size.width), layout.size] {
            window.frame = CGRect(origin: .zero, size: size)
            host.rootView.frame = window.bounds
            window.setNeedsLayout()
            window.layoutIfNeeded()
            try await SendEntryUIProbe.wait(in: host.rootView) {
                guard let keypad = SendEntryUIProbe.element("sendAmountKeypad", in: host.rootView),
                      let review = SendEntryUIProbe.element("sendAmountReview", in: host.rootView),
                      let screen = host.navigationController?.topViewController?.view else { return false }
                let safeFrame = UIAccessibility.convertToScreenCoordinates(
                    screen.safeAreaLayoutGuide.layoutFrame, in: screen
                )
                let bottomSpacing: CGFloat = size.width >= 600 && size.height < 500 ? 4 : 8
                return review.accessibilityFrame.maxY <= keypad.accessibilityFrame.minY
                    && abs(safeFrame.maxY - keypad.accessibilityFrame.maxY - bottomSpacing) <= 2
            }
            let list = try await host.list { $0.numberOfSections == 2 }
            let amountCell = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
            #expect(SendEntryUIProbe.element("sendAmountValue", in: amountCell)?.accessibilityValue == "1.5 ETH")
        }
        try SendEntryUIProbe.activate("sendAmountReview", in: host.rootView)
        #expect(recorder.actions.count == 1)
        #expect(recorder.actions.first?.amount == "1.5")
        #expect(recorder.actions.first?.recipient == draft.recipient)
    }

    @Test(arguments: [NativeListTestLayout.largeTextLTR, .largeTextRTL])
    func shortAccessibilityWindowKeepsBackspaceAndReviewReachable(layout: NativeListTestLayout) async throws {
        let recorder = ListActionRecorder<SendDraft>()
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendAmountScreen(
                    database: database,
                    draft: SendEntryTestFixtures.draft()
                ) {
                    recorder.actions.append($0)
                }
            }
            .environment(settings)
            .environment(SendActivityStore())
            .environment(\.walletCurrencyContext, SendEntryTestFixtures.currency)
        }
        defer { host.close() }
        _ = try await host.list { $0.numberOfSections == 2 }
        let window = try #require(host.rootView.window)
        window.frame = CGRect(origin: .zero, size: CGSize(width: 852, height: 320))
        host.rootView.frame = window.bounds
        window.setNeedsLayout()
        window.layoutIfNeeded()
        // SwiftUI's native scroll view extends beneath the navigation bar and
        // home indicator; its adjusted insets define the usable viewport.
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.views(UIScrollView.self, in: host.rootView).contains {
                !($0 is UICollectionView)
                    && $0.contentSize.height > $0.bounds.inset(by: $0.adjustedContentInset).height
            }
        }
        let scroll = try #require(SendEntryUIProbe.views(UIScrollView.self, in: host.rootView).first {
            !($0 is UICollectionView)
                && $0.contentSize.height > $0.bounds.inset(by: $0.adjustedContentInset).height
        })
        for key in ["1", "Decimal", "5"] {
            try SendEntryUIProbe.activate("sendAmountKey" + key, in: host.rootView)
            await Task.yield()
        }
        scroll.setContentOffset(CGPoint(
            x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        ), animated: false)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            guard let backspace = SendEntryUIProbe.element("sendAmountKeyDelete", in: host.rootView) else { return false }
            let viewport = UIAccessibility.convertToScreenCoordinates(
                scroll.bounds.inset(by: scroll.adjustedContentInset), in: scroll
            )
            return viewport.insetBy(dx: -1, dy: -1).contains(backspace.accessibilityFrame)
        }
        try SendEntryUIProbe.activate("sendAmountKeyDelete", in: host.rootView)
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            guard let review = SendEntryUIProbe.element("sendAmountReview", in: host.rootView) else { return false }
            let viewport = UIAccessibility.convertToScreenCoordinates(
                scroll.bounds.inset(by: scroll.adjustedContentInset), in: scroll
            )
            return viewport.insetBy(dx: -1, dy: -1).contains(review.accessibilityFrame)
                && !review.accessibilityTraits.contains(.notEnabled)
        }
        try SendEntryUIProbe.activate("sendAmountReview", in: host.rootView)
        #expect(recorder.actions.count == 1)
        #expect(recorder.actions.first?.amount == "1")
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func recipientKeepsAddressActionsInsideInputWithoutOptionsToolbarAcrossLayouts(
        layout: NativeListTestLayout
    ) async throws {
        let recorder = ListActionRecorder<SendDraft>()
        let draft = SendEntryTestFixtures.draft()
        let database = try WalletDatabase.temporary()
        _ = try await SendRecipientHistoryTestFixtures.seed(database)
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendRecipientScreen(database: database, draft: draft) { recorder.actions.append($0) }
            }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 2 }
        #expect(list.numberOfSections == 2)
        #expect(list.numberOfItems(inSection: 0) == 1)
        #expect(list.numberOfItems(inSection: 1) == 1)
        #expect(SendEntryUIProbe.views(UITextView.self, in: host.rootView).count == 1)
        #expect(SendEntryUIProbe.element("sendAmountBalance", in: host.rootView) == nil)
        #expect(SendEntryUIProbe.element("sendRecipientSelectedAsset", in: host.rootView) != nil)
        #expect(SendEntryUIProbe.element("sendAmountKeypad", in: host.rootView) == nil)
        let toolbar = try #require(host.navigationController?.navigationBar)
        #expect(SendEntryUIProbe.element("sendRecipientPaste", in: toolbar) == nil)
        #expect(SendEntryUIProbe.element("sendRecipientPaste", in: host.rootView) != nil)
        #expect(SendEntryUIProbe.element("sendRecipientScan", in: toolbar) == nil)
        #expect(SendEntryUIProbe.element("sendRecipientScan", in: host.rootView) != nil)
        #expect(SendEntryUIProbe.element("sendRecipientOptions", in: toolbar) == nil)
        try SendEntryUIProbe.activate("sendRecipientContinue", in: host.rootView)
        #expect(recorder.actions.count == 1)
        #expect(recorder.actions.first?.recipient == draft.recipient)
        #expect(recorder.actions.first?.amount == nil)
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad])
    func inputScanPresentsModalAndClosePreservesRecipient(
        layout: NativeListTestLayout
    ) async throws {
        let database = try WalletDatabase.temporary()
        let settings = WalletSettingsStore(database: database)
        _ = try await SendRecipientHistoryTestFixtures.seed(database)
        let draft = SendEntryTestFixtures.draft()
        let recorder = ListActionRecorder<SendDraft>()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendRecipientScreen(database: database, draft: draft) { recorder.actions.append($0) }
            }
            .environment(settings)
            .environment(SendActivityStore())
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 2 }
        let inputCell = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        let navigation = try #require(host.navigationController)
        let initialDepth = navigation.viewControllers.count
        let input = try #require(SendEntryUIProbe.views(UITextView.self, in: inputCell).first)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendRecipientScan", in: inputCell) != nil
        }
        try SendEntryUIProbe.activate("sendRecipientScan", in: inputCell)
        let root = try #require(host.rootView.window?.rootViewController)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            guard let sheet = root.presentedViewController else { return false }
            return !sheet.isBeingPresented
                && SendEntryUIProbe.element("qrScannerClose", in: sheet.view) != nil
        }
        #expect(navigation.viewControllers.count == initialDepth)
        #expect(!input.isFirstResponder)
        #expect(recorder.actions.isEmpty)
        let scanner = try #require(root.presentedViewController)
        try NativeQRScannerUIProbe.close(scanner)
        try await SendEntryUIProbe.wait(in: host.rootView) {
            root.presentedViewController == nil && navigation.viewControllers.count == initialDepth
                && SendEntryUIProbe.element("sendRecipientInput", in: host.rootView) != nil
        }
        let restoredInput = try #require(SendEntryUIProbe.views(UITextView.self, in: host.rootView).first)
        #expect(restoredInput.text == draft.recipient)
        try SendEntryUIProbe.activate("sendRecipientContinue", in: host.rootView)
        #expect(recorder.actions.count == 1)
        #expect(recorder.actions.first?.recipient == draft.recipient)
    }
}

/// Reads native view/accessibility state only; never captures screenshots.
@MainActor
enum SendEntryUIProbe {
    static func views<ViewType: UIView>(_ type: ViewType.Type, in root: UIView) -> [ViewType] {
        ((root as? ViewType).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }

    static func element(_ identifier: String, in root: NSObject) -> NSObject? {
        var visited: Set<ObjectIdentifier> = []
        return element(identifier, in: root, visited: &visited)
    }

    static func activate(_ identifier: String, in root: NSObject) throws {
        let control = try #require(element(identifier, in: root), "Missing control: \(identifier)")
        #expect(!control.accessibilityTraits.contains(.notEnabled), "Disabled control: \(identifier)")
        #expect(control.accessibilityActivate(), "Could not activate: \(identifier)")
    }

    static func wait(
        in view: UIView,
        sourceLocation: SourceLocation = #_sourceLocation,
        until condition: () -> Bool
    ) async throws {
        for _ in 0..<150 {
            await Task.yield()
            view.layoutIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Native Send navigation or controls did not settle", sourceLocation: sourceLocation)
    }

    private static func element(
        _ identifier: String,
        in object: NSObject,
        visited: inout Set<ObjectIdentifier>
    ) -> NSObject? {
        guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
        // SwiftUI's accessibility nodes expose the UIKit getter dynamically without
        // declaring conformance to UIAccessibilityIdentification to Swift's runtime.
        if object.responds(to: #selector(getter: UIView.accessibilityIdentifier)),
           object.value(forKey: "accessibilityIdentifier") as? String == identifier {
            return object
        }
        let count = object.accessibilityElementCount()
        if count > 0, count < 1_000 {
            for index in 0..<count {
                if let child = object.accessibilityElement(at: index) as? NSObject,
                   let result = element(identifier, in: child, visited: &visited) { return result }
            }
        }
        if let view = object as? UIView {
            for child in view.subviews {
                if let result = element(identifier, in: child, visited: &visited) { return result }
            }
        }
        return nil
    }
}

import SwiftUI
import Observation
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct NativeListInteractionTests {
    @Test(arguments: NativeListTestLayout.allCases)
    func importOptionsUseNativeRowHighlightAndSelection(layout: NativeListTestLayout) async throws {
        let recorder = ListActionRecorder<ImportWalletOption>()
        let host = try NativeListTestHost(layout: layout) {
            ImportWalletOptionsView(
                onRecoveryPhrase: { recorder.actions.append(.recoveryPhrase) },
                onPrivateKey: { recorder.actions.append(.privateKey) },
                onPhysicalEntropy: {
                    recorder.actions.append(.physicalEntropy)
                },
                onRestoreICloud: { recorder.actions.append(.restoreICloud) },
                onTransferFromIPhone: { recorder.actions.append(.transferFromIPhone) },
                onMuunRecovery: {},
                onTrustWalletRestore: { _ in }
            )
        }
        defer { host.close() }
        let list = try await host.list()
        let section = try #require((0..<list.numberOfSections).first {
            list.numberOfItems(inSection: $0) == ImportWalletOption.allCases.count
        })

        for (row, option) in ImportWalletOption.allCases.enumerated() {
            recorder.actions.removeAll()
            try await host.selectRow(IndexPath(item: row, section: section), in: list)
            #expect(recorder.actions == [option])
        }
    }

    @Test
    func disabledImportOptionsKeepNativeDisabledBehavior() async throws {
        let recorder = ListActionRecorder<ImportWalletOption>()
        let host = try NativeListTestHost {
            ImportWalletOptionsView(
                onRecoveryPhrase: { recorder.actions.append(.recoveryPhrase) },
                onPrivateKey: { recorder.actions.append(.privateKey) },
                onPhysicalEntropy: {
                    recorder.actions.append(.physicalEntropy)
                },
                onRestoreICloud: { recorder.actions.append(.restoreICloud) },
                onTransferFromIPhone: { recorder.actions.append(.transferFromIPhone) },
                onMuunRecovery: {},
                onTrustWalletRestore: { _ in }
            )
            .disabled(true)
        }
        defer { host.close() }
        let list = try await host.list()
        let section = try #require((0..<list.numberOfSections).first {
            list.numberOfItems(inSection: $0) == ImportWalletOption.allCases.count
        })
        for (row, option) in ImportWalletOption.allCases.enumerated() {
            let path = IndexPath(item: row, section: section)
            let cell = try await host.cell(at: path, in: list)
            #expect(list.delegate?.collectionView?(list, shouldHighlightItemAt: path) == false)
            let label = WalletAppLanguage.localizedBundle(for: "en")
                .localizedString(forKey: option.titleKey, value: nil, table: nil)
            let action = try #require(host.accessibilityAction(label: label, in: cell))
            #expect(action.accessibilityTraits.contains(.notEnabled))
            _ = action.accessibilityActivate()
            #expect(recorder.actions.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func settingsActionsKeepNativeHighlightAndDisabledBehavior(isAuthorizing: Bool) async throws {
        let recorder = ListActionRecorder<String>()
        let settings = WalletSettingsStore(database: try WalletDatabase.temporary())
        let host = try NativeListTestHost {
            NavigationStack {
                WalletSettingsView(
                    isSecurityAuthorizationInProgress: isAuthorizing,
                    onSecurityRequested: {
                        recorder.actions.append("security")
                    },
                    onResetRequested: { recorder.actions.append("reset") }
                )
                .navigationDestination(for: WalletSettingsSearchRoute.self) { _ in
                    Text("common.done")
                }
            }
            .environment(settings)
        }
        defer { host.close() }
        let list = try await host.list()
        let security = IndexPath(item: 1, section: 1)
        if isAuthorizing {
            let cell = try await host.cell(at: security, in: list)
            #expect(list.delegate?.collectionView?(list, shouldHighlightItemAt: security) == false)
            let label = WalletAppLanguage.localizedBundle(for: "en")
                .localizedString(forKey: "settings.security.title", value: nil, table: nil)
            let action = try #require(host.accessibilityAction(label: label, in: cell))
            #expect(action.accessibilityTraits.contains(.notEnabled))
            _ = action.accessibilityActivate()
            #expect(recorder.actions.isEmpty)
        } else {
            #expect(list.delegate?.collectionView?(list, shouldHighlightItemAt: security) == true)
            #expect(list.delegate?.collectionView?(
                list,
                canPerformPrimaryActionForItemAt: security
            ) == true)
            try await host.selectRow(security, in: list)
            #expect(recorder.actions == ["security"])
        }
        recorder.actions.removeAll()
        try await host.selectRow(IndexPath(item: 0, section: 4), in: list)
        #expect(recorder.actions == ["reset"])
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func walletSelectionAndInformationRemainSeparate(layout: NativeListTestLayout) async throws {
        let recorder = ListActionRecorder<String>()
        let host = try NativeListTestHost(layout: layout) {
            List {
                Section {
                    ZStack(alignment: .trailing) {
                        WalletSettingsManagementRow(
                            wallet: NativeListTestFixtures.wallet, walletCount: 2,
                            isBalanceHidden: false,
                            onSelect: { recorder.actions.append("select") }
                        )
                        WalletRowInformationButton { recorder.actions.append("info") }
                    }
                }
            }
        }
        defer { host.close() }
        let list = try await host.list()
        let path = IndexPath(item: 0, section: 0)
        try await host.selectRow(path, in: list)
        #expect(recorder.actions == ["select"])

        recorder.actions.removeAll()
        let cell = try await host.cell(at: path, in: list)
        let label = WalletAppLanguage.localizedBundle(
            for: layout.direction == .rightToLeft ? "ar" : "en"
        ).localizedString(forKey: "settings.wallets.wallet_settings", value: nil, table: nil)
        let info = try #require(host.accessibilityAction(
            label: label, in: cell
        ))
        #expect(info.accessibilityActivate())
        #expect(recorder.actions == ["info"])
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func broadcastNetworkFeeInformationUsesAnIsolatedNativeAccessory(
        layout: NativeListTestLayout
    ) async throws {
        let state = NetworkFeeInfoTestState()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                List {
                    Section {
                        LabeledContent {
                            Text(verbatim: "$0.01")
                        } label: {
                            SendBroadcastNetworkFeeLabel(
                                showsInformationButton: true,
                                isInformationPresented: Binding(
                                    get: { state.isPresented },
                                    set: { state.isPresented = $0 }
                                )
                            )
                        }

                        LabeledContent {
                            Text(verbatim: "—")
                        } label: {
                            SendBroadcastNetworkFeeLabel(
                                showsInformationButton: false,
                                isInformationPresented: .constant(true)
                            )
                        }
                    }
                }
            }
        }
        defer { host.close() }

        let list = try await host.list {
            $0.numberOfSections == 1
                && $0.numberOfItems(inSection: 0) == 2
        }
        let availablePath = IndexPath(item: 0, section: 0)
        _ = try await host.cell(
            at: availablePath,
            in: list
        )
        #expect(
            list.delegate?.collectionView?(
                list,
                shouldHighlightItemAt: availablePath
            ) == false
        )
        let root = try #require(host.rootView.window?.rootViewController)
        // A loading row cannot present information even if its binding is true.
        #expect(root.presentedViewController == nil)
        state.isPresented = true
        for _ in 0..<100 {
            host.rootView.layoutIfNeeded()
            await Task.yield()
            if let presented = root.presentedViewController, !presented.isBeingPresented { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let presented = try #require(root.presentedViewController)
        defer { presented.dismiss(animated: false) }
        let popover = try #require(presented.popoverPresentationController)
        #expect(presented.modalPresentationStyle == .popover)
        #expect(popover.sourceView != nil)
        #expect(popover.sourceRect.width.rounded() == 44)
        #expect(popover.sourceRect.height.rounded() == 44)
        let frame = popover.frameOfPresentedViewInContainerView
        #expect(frame.width < host.rootView.bounds.width)
        #expect(frame.height > 100 && frame.height <= host.rootView.bounds.height)
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func identityRowsHighlightAsOneActionAndPassiveRowsDoNot(layout: NativeListTestLayout) async throws {
        let recorder = ListActionRecorder<Int>()
        let titles: [LocalizedStringKey] = [
            "wallet.transaction.details.from", "wallet.transaction.details.to",
            "wallet.transaction.details.hash", "send.recipient.section",
            "send.broadcast.transaction_id.title"
        ]
        let host = try NativeListTestHost(layout: layout) {
            List {
                Section {
                    Text("wallet.transaction.details.date")
                    ForEach(titles.indices, id: \.self) { index in
                        WalletIdentityActionRow(
                            title: titles[index], value: NativeListTestFixtures.address,
                            displayedValue: "0x000000...000042", showsDisclosureIndicator: true
                        ) {
                            recorder.actions.append(index)
                        }
                    }
                }
            }
        }
        defer { host.close() }
        let list = try await host.list()
        #expect(list.delegate?.collectionView?(
            list, shouldHighlightItemAt: IndexPath(item: 0, section: 0)
        ) == false)
        for row in titles.indices {
            recorder.actions.removeAll()
            try await host.selectRow(IndexPath(item: row + 1, section: 0), in: list)
            #expect(recorder.actions == [row])
        }
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func sendAssetSelectionUsesNativeRows(layout: NativeListTestLayout) async throws {
        let recorder = ListActionRecorder<String>()
        let choices = NativeListTestFixtures.sendChoices
        let settings = WalletSettingsStore(database: try WalletDatabase.temporary())
        let request = try SendPaymentRequestParser.parse(NativeListTestFixtures.address)
        let expected = SendAssetChoiceCatalog.filtered(choices, networkID: nil, searchText: "")
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendAssetSelectionScreen(request: request, choices: choices, transactions: []) { choice in
                    recorder.actions.append(choice.id)
                    return nil
                }
            }
            .environment(settings)
        }
        defer { host.close() }
        let list = try await host.list()
        for (row, choice) in expected.enumerated() {
            recorder.actions.removeAll()
            try await host.selectRow(IndexPath(item: row, section: 0), in: list)
            #expect(recorder.actions == [choice.id])
        }
    }

    @Test
    func privateKeyExportNetworkChoicesUseNativeRowsWithoutExposingKeys() async throws {
        let recorder = ListActionRecorder<String>()
        let items = ["network.ethereum", "network.bitcoin.name"].enumerated().map { index, title in
            WalletPrivateKeyExportItem(
                id: String(index), titleKey: title,
                logoSource: .nativeCoin(blockchain: index == 0 ? .ethereum : .bitcoin),
                backupNetwork: index == 0 ? .evm : .bitcoin,
                detail: .derivationPath("m/44'/60'/0'/0/0"),
                privateKey: ""
            )
        }
        let host = try NativeListTestHost {
            WalletPrivateKeyExportSelectionScreen(items: items) { recorder.actions.append($0.id) }
        }
        defer { host.close() }
        let list = try await host.list()
        for row in items.indices {
            recorder.actions.removeAll()
            try await host.selectRow(IndexPath(item: row, section: 0), in: list)
            #expect(recorder.actions == [items[row].id])
        }
    }

    @Test(arguments: ["", "List Test Wallet", "Bitcoin Cash", "Face ID"])
    func universalSearchActionsWalletsAndNetworksUseNativeRows(query: String) async throws {
        let database = try WalletDatabase.temporary()
        let actions = ListActionRecorder<WalletUniversalSearchAction>()
        let wallets = ListActionRecorder<String>()
        let networks = ListActionRecorder<String>()
        let index = await WalletUniversalSearchIndex.make(
            assets: [], transactions: [], wallets: [NativeListTestFixtures.wallet]
        )
        let expected = index.localResults(matching: query)
        let expectedActions = query.isEmpty ? index.suggestions().actions : expected.actions
        #expect(!expectedActions.isEmpty || !expected.wallets.isEmpty || !expected.networks.isEmpty)
        let host = try NativeListTestHost {
            NavigationStack {
                WalletHomeSearchView(
                    database: database, query: query, index: index, assets: [], transactions: [],
                    walletAddress: NativeListTestFixtures.address, capabilities: .fullWallet,
                    isBalanceHidden: false, onSendAsset: { _ in }, onReceiveAsset: { _ in },
                    onScanAsset: { _ in }, onPasteAsset: { _, _ in },
                    onAction: { actions.actions.append($0) },
                    onWalletSelected: { wallets.actions.append($0.id) },
                    onNetworkSelected: { networks.actions.append($0) }
                )
            }
        }
        defer { host.close() }
        let list = try await host.list { list in
            (0..<list.numberOfSections).contains { section in
                list.numberOfItems(inSection: section) > 0 && list.delegate?.collectionView?(
                    list, shouldHighlightItemAt: IndexPath(item: 0, section: section)
                ) == true
            }
        }
        var section = query.isEmpty ? 1 : 0
        if !expectedActions.isEmpty {
            for (row, item) in expectedActions.enumerated() {
                actions.actions.removeAll()
                try await host.selectRow(IndexPath(item: row, section: section), in: list)
                #expect(actions.actions == [item.action])
            }
            section += 1
        }
        if !expected.wallets.isEmpty {
            for (row, wallet) in expected.wallets.enumerated() {
                wallets.actions.removeAll()
                try await host.selectRow(IndexPath(item: row, section: section), in: list)
                #expect(wallets.actions == [wallet.id])
            }
            section += 1
        }
        for (row, network) in expected.networks.enumerated() {
            networks.actions.removeAll()
            try await host.selectRow(IndexPath(item: row, section: section), in: list)
            #expect(networks.actions == [network.id])
        }
    }

    @Test
    func recoveryCopyUsesANativeActionWithoutReadingOrWritingClipboard() async throws {
        let host = try NativeListTestHost {
            WalletRecoveryPhraseDisplayScreen(words: [], passphrase: "")
        }
        defer { host.close() }
        let list = try await host.list()
        let copyRow = IndexPath(item: 0, section: 1)
        _ = try await host.cell(at: copyRow, in: list)
        #expect(list.delegate?.collectionView?(list, shouldHighlightItemAt: copyRow) == true)
        #expect(list.delegate?.collectionView?(list, canPerformPrimaryActionForItemAt: copyRow) == true)
    }

    @Test
    func nativeSelectionDistinguishesAutomaticFromPlainButtons() async throws {
        let recorder = ListActionRecorder<Int>()
        let host = try NativeListTestHost {
            List {
                Section {
                    Button("common.continue") { recorder.actions.append(0) }
                    Button("common.cancel") { recorder.actions.append(1) }
                        .buttonStyle(.plain)
                }
            }
        }
        defer { host.close() }
        let list = try await host.list()

        try await host.selectRow(IndexPath(item: 0, section: 0), in: list)
        #expect(recorder.actions == [0])
        #expect(list.delegate?.collectionView?(
            list, shouldHighlightItemAt: IndexPath(item: 1, section: 0)
        ) == false)
    }
}

@MainActor
@Suite(.serialized)
struct WalletPrivateKeyCloudBackupPresentationTests {
    @Test(arguments: NativeListTestLayout.allCases, [false, true])
    func backupToggleUsesNativeListAcrossLayouts(
        layout: NativeListTestLayout,
        settingsFlow: Bool
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let service = WalletAutomaticCloudBackupService(
            documentStore: WalletICloudDriveBackupStore(
                containerURLProvider: { root }
            )
        )
        let item = WalletPrivateKeyExportItem(
            id: "evm-layout",
            titleKey: "network.ethereum",
            logoSource: .nativeCoin(blockchain: .ethereum),
            backupNetwork: .evm,
            detail: .derivationPath("m/44'/60'/0'/0/0"),
            privateKey: String(repeating: "0", count: 63) + "1"
        )
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                if settingsFlow {
                    SettingsBackupPrivateKeyDisplayScreen(
                        wallet: NativeListTestFixtures.wallet,
                        item: item,
                        cloudBackupService: service
                    )
                } else {
                    WalletPrivateKeyExportDisplayScreen(
                        wallet: NativeListTestFixtures.wallet,
                        item: item,
                        cloudBackupService: service
                    )
                }
            }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 3 }
        let backupCell = try await host.cell(
            at: IndexPath(item: 0, section: 1), in: list
        )

        try await SendEntryUIProbe.wait(in: host.rootView) {
            guard let scroll = SendEntryUIProbe
                .views(UIScrollView.self, in: host.rootView)
                .max(by: { $0.contentSize.height < $1.contentSize.height }),
                let backupSwitch = SendEntryUIProbe
                    .views(UISwitch.self, in: host.rootView)
                    .first
            else { return false }
            return scroll.bounds.width > 0
                && scroll.contentSize.height > 0
                && backupSwitch.bounds.width > 0
                && backupSwitch.isEnabled
        }

        let scroll = try #require(
            SendEntryUIProbe.views(UIScrollView.self, in: host.rootView)
                .max { $0.contentSize.height < $1.contentSize.height }
        )
        let backupSwitch = try #require(
            SendEntryUIProbe.views(UISwitch.self, in: host.rootView).first
        )
        let switchFrame = backupSwitch.convert(
            backupSwitch.bounds,
            to: host.rootView
        )
        let switchFrameInScroll = backupSwitch.convert(
            backupSwitch.bounds,
            to: scroll
        )
        #expect(backupSwitch.isDescendant(of: backupCell))
        #expect(backupSwitch.isEnabled)
        #expect(switchFrame.minX >= 0)
        #expect(switchFrame.maxX <= layout.size.width)
        #expect(switchFrameInScroll.minY >= 0)
        #expect(switchFrameInScroll.maxY <= scroll.contentSize.height + 1)
        #expect(scroll.contentSize.width <= scroll.bounds.width + 1)
    }

    /// The QR card fills its row like the backup row's background does, so the key
    /// text sits exactly the card's own 20pt padding inside the backup row's edges
    /// instead of a further row inset in — and the card, backup row and copy action
    /// are separated by one and the same gap.
    @Test(arguments: NativeListTestLayout.allCases, [false, true])
    func cardSharesTheBackupRowEdgesAndGaps(
        layout: NativeListTestLayout,
        settingsFlow: Bool
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let service = WalletAutomaticCloudBackupService(
            documentStore: WalletICloudDriveBackupStore(
                containerURLProvider: { root }
            )
        )
        let item = WalletPrivateKeyExportItem(
            id: "evm-edges",
            titleKey: "network.ethereum",
            logoSource: .nativeCoin(blockchain: .ethereum),
            backupNetwork: .evm,
            detail: .derivationPath("m/44'/60'/0'/0/0"),
            privateKey: String(repeating: "0", count: 63) + "1"
        )
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                if settingsFlow {
                    SettingsBackupPrivateKeyDisplayScreen(
                        wallet: NativeListTestFixtures.wallet,
                        item: item,
                        cloudBackupService: service
                    )
                } else {
                    WalletPrivateKeyExportDisplayScreen(
                        wallet: NativeListTestFixtures.wallet,
                        item: item,
                        cloudBackupService: service
                    )
                }
            }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 3 }
        let cardCell = try await host.cell(at: IndexPath(item: 0, section: 0), in: list)
        let backupCell = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        let copyCell = try await host.cell(at: IndexPath(item: 0, section: 2), in: list)
        let warningCell = try await host.cell(at: IndexPath(item: 1, section: 2), in: list)

        try await SendEntryUIProbe.wait(in: host.rootView) {
            guard let keyText = SendEntryUIProbe.views(UITextView.self, in: cardCell).first,
                  let backupSwitch = SendEntryUIProbe.views(UISwitch.self, in: backupCell).first
            else { return false }
            return keyText.bounds.width > 0 && backupSwitch.bounds.width > 0
        }

        let keyText = try #require(SendEntryUIProbe.views(UITextView.self, in: cardCell).first)
        let keyFrame = keyText.convert(keyText.bounds, to: list)
        let backupFrame = backupCell.convert(backupCell.bounds, to: list)
        let inset = WalletQRCodeCardMetrics.textInset
        #expect(abs(keyFrame.minX - (backupFrame.minX + inset)) < 0.5, "\(keyFrame) vs \(backupFrame)")
        #expect(abs(keyFrame.maxX - (backupFrame.maxX - inset)) < 0.5, "\(keyFrame) vs \(backupFrame)")
        for cell in [cardCell, copyCell, warningCell] {
            let frame = cell.convert(cell.bounds, to: list)
            #expect(abs(frame.minX - backupFrame.minX) < 0.5)
            #expect(abs(frame.maxX - backupFrame.maxX) < 0.5)
        }
        // The copy action is a glass button, which UIKit backs with an interaction
        // view sized to the button: with zero row insets every laid-out view in the
        // row spans the backup row's edges rather than sitting a row inset in.
        let copyViews = SendEntryUIProbe.views(UIView.self, in: copyCell)
            .filter { $0.bounds.width > 0 && $0.bounds.height > 0 }
        #expect(copyViews.count > 1)
        for view in copyViews {
            let frame = view.convert(view.bounds, to: list)
            #expect(abs(frame.minX - backupFrame.minX) < 0.5, "\(type(of: view)) \(frame)")
            #expect(abs(frame.maxX - backupFrame.maxX) < 0.5, "\(type(of: view)) \(frame)")
        }

        // Layout attributes describe every row whether or not its cell is on screen.
        let rowFrames = try (0..<3).map { section in
            try #require(list.layoutAttributesForItem(
                at: IndexPath(item: 0, section: section)
            )).frame
        }
        let gaps = zip(rowFrames, rowFrames.dropFirst()).map { $1.minY - $0.maxY }
        #expect(gaps.count == 2)
        for gap in gaps {
            #expect(abs(gap - 24) < 0.5, "section gaps \(gaps)")
        }
    }
}

@MainActor
@Observable
private final class NetworkFeeInfoTestState {
    var isPresented = false
}

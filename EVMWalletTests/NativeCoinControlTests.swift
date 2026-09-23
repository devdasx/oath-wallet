import SwiftUI
import Testing
import UIKit
@testable import Aperture

@MainActor
@Suite(.serialized)
struct NativeCoinControlTests {
    @Test(arguments: NativeListTestLayout.allCases)
    func automaticModeShowsOnlyThePlannedInputs(layout: NativeListTestLayout) async throws {
        let fixture = try CoinControlTestFixtures.make()
        let database = try WalletDatabase.temporary()
        let inputs = fixture.inputs
        let change = fixture.change.address
        let recipient = fixture.recipient.address
        let recorder = ListActionRecorder<SendBitcoinFamilyOptions>()
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendBitcoinCoinControlScreen(database: database, draft: fixture.draft(amount: "0.00065"),
                    chain: .bitcoin, nativeUnitUSDPrice: 60_000,
                    inputLoader: { _ in inputs }, planLoader: { draft, inputs in
                        try SendBitcoinHDTransactionPlanner.prepare(draft: draft, outputs: inputs.outputs,
                            requestedAtomic: 65_000, byteFee: 5,
                            fee: SendResolvedNetworkFee(model: .utxoPerVByte, primaryValue: "5", secondaryValue: nil),
                            options: .automatic, changeAddress: change, recipientAddress: recipient).selection
                    }, onApply: { recorder.actions.append($0) })
            }
            .environment(\.walletCurrencyContext, SendEntryTestFixtures.currency)
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 2 && $0.numberOfItems(inSection: 1) == 2 }
        for index in 0..<2 {
            let cell = try await host.cell(at: IndexPath(item: index, section: 1), in: list)
            let output = inputs.outputs[index]
            let element = try #require(SendEntryUIProbe.element("sendAutomaticOutput.\(output.id)", in: cell))
            #expect(!element.accessibilityTraits.contains(.button))
            #expect(text(in: cell).contains(output.owner!.addressType.localizedName))
        }
        try confirm(in: host)
        #expect(recorder.actions.last?.coinSelection == .automatic)
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func emptyAmountExplainsHowToGetASelection(layout: NativeListTestLayout) async throws {
        let fixture = try CoinControlTestFixtures.make()
        let database = try WalletDatabase.temporary()
        let inputs = fixture.inputs
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendBitcoinCoinControlScreen(database: database, draft: fixture.draft(amount: nil),
                    chain: .bitcoin, nativeUnitUSDPrice: 60_000,
                    inputLoader: { _ in inputs }, planLoader: { _, _ in
                        Issue.record("An empty amount must not request a transaction plan")
                        return SendBitcoinSelectionPlan(outputs: [], feeAtomic: "0")
                    }, onApply: { _ in })
            }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 2 }
        let cell = try await host.cell(at: IndexPath(item: 0, section: 1), in: list)
        #expect(SendEntryUIProbe.element("sendCoinControlAmountRequired", in: cell) != nil)
        #expect(SendEntryUIProbe.element("sendCoinControlClose", in: host.rootView) != nil)
    }

    @Test(arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func manualRowsExposeTheirAddressTypesAndSelection(layout: NativeListTestLayout) async throws {
        let fixture = try CoinControlTestFixtures.make()
        let database = try WalletDatabase.temporary()
        let inputs = fixture.inputs
        let host = try NativeListTestHost(layout: layout) {
            NavigationStack {
                SendBitcoinCoinControlScreen(database: database, draft: fixture.draft(amount: nil, manual: true),
                    chain: .bitcoin, nativeUnitUSDPrice: 60_000,
                    inputLoader: { _ in inputs }, onApply: { _ in })
            }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfSections == 2 && $0.numberOfItems(inSection: 1) == 4 }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendManualOutput.\(inputs.outputs[0].id)", in: host.rootView) != nil
        }
        for index in inputs.outputs.indices {
            let cell = try await host.cell(at: IndexPath(item: index, section: 1), in: list)
            let output = inputs.outputs[index]
            try await SendEntryUIProbe.wait(in: cell) {
                SendEntryUIProbe.element("sendManualOutput.\(output.id)", in: cell) != nil
            }
            let element = try #require(SendEntryUIProbe.element("sendManualOutput.\(output.id)", in: cell))
            #expect(element.accessibilityTraits.contains(.selected) == (index == 0))
            #expect(text(in: cell).contains(output.owner!.addressType.localizedName))
        }
    }

    @Test
    func manualRowsDoNotWaitForTheAutomaticFeePlan() async throws {
        let fixture = try CoinControlTestFixtures.make()
        let database = try WalletDatabase.temporary()
        let inputs = fixture.inputs
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let host = try NativeListTestHost {
            NavigationStack {
                SendBitcoinCoinControlScreen(database: database,
                    draft: fixture.draft(amount: "0.0001", manual: true),
                    chain: .bitcoin, nativeUnitUSDPrice: 60_000,
                    inputLoader: { _ in inputs }, planLoader: { _, _ in
                        for await _ in stream { }
                        throw CancellationError()
                    }, onApply: { _ in })
            }
        }
        defer { continuation.finish(); host.close() }
        let list = try await host.list { $0.numberOfSections == 2 && $0.numberOfItems(inSection: 1) == 4 }
        try await SendEntryUIProbe.wait(in: host.rootView) {
            SendEntryUIProbe.element("sendManualOutput.\(inputs.outputs[0].id)", in: host.rootView) != nil
        }
        #expect(list.numberOfItems(inSection: 1) == inputs.outputs.count)
    }

    private func confirm(in host: NativeListTestHost) throws {
        let navigation = try #require(host.navigationController)
        let item = try #require(navigation.topViewController?.navigationItem)
        let items = item.trailingItemGroups.flatMap(\.barButtonItems)
            + item.leadingItemGroups.flatMap(\.barButtonItems)
            + (item.rightBarButtonItems ?? []) + (item.leftBarButtonItems ?? [])
        let button = try #require(items.first {
            $0.accessibilityIdentifier == "sendCoinControlConfirm"
                || $0.customView.map { SendEntryUIProbe.element("sendCoinControlConfirm", in: $0) != nil } == true
        })
        #expect(button.isEnabled)
        let action = try #require(button.action)
        #expect(UIApplication.shared.sendAction(action, to: button.target, from: button, for: nil))
    }

    @Test
    func systemCheckmarkDoesNotMirrorItsGlyph() throws {
        let image = try #require(UIImage(systemName: "checkmark"))
        #expect(!image.flipsForRightToLeftLayoutDirection)
    }

    private func text(in root: NSObject) -> String {
        var strings: [String] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let label = object.accessibilityLabel { strings.append(label) }
            if let label = object as? UILabel, let value = label.text { strings.append(value) }
            let count = object.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { visit(child) }
                }
            }
            if let view = object as? UIView { view.subviews.forEach(visit) }
        }
        visit(root)
        return strings.joined(separator: " ")
    }
}

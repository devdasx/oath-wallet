import Observation
import SwiftUI
import Testing
@testable import Aperture

@MainActor
@Suite(.serialized)
struct WalletTransactionValueTests {
    @Observable
    final class Selection {
        var amount = false
        var fee = false
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func nativeRowsSwitchUnitsIndependentlyAndBack(layout: NativeListTestLayout) async throws {
        let selection = Selection()
        let currency = WalletCurrencyContext(code: "EUR", ratePerUSD: Decimal(string: "0.92")!)
        let host = try NativeListTestHost(layout: layout) {
            List {
                Section {
                    WalletTransactionValue(
                        title: "wallet.transaction.details.amount",
                        nativeValue: "-11.872640000000001 DOGE",
                        localValue: EnglishNumbers.currency(-1, using: currency),
                        isBalanceHidden: false,
                        showsNative: Binding(get: { selection.amount }, set: { selection.amount = $0 })
                    )
                    WalletTransactionValue(
                        title: "wallet.transaction.details.network_fee",
                        nativeValue: "0.11429498 DOGE",
                        localValue: EnglishNumbers.networkFeeCurrency(Decimal(string: "0.009")!, using: currency),
                        isBalanceHidden: false,
                        showsNative: Binding(get: { selection.fee }, set: { selection.fee = $0 })
                    )
                }
            }
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfItems(inSection: 0) == 2 }
        #expect(!selection.amount && !selection.fee)
        for row in 0..<2 {
            // Exercise the real List primary action, including row highlight and
            // selection, instead of assuming an in-process accessibility tree exists.
            try await host.selectRow(IndexPath(item: row, section: 0), in: list)
            #expect(row == 0 ? selection.amount && !selection.fee : selection.fee && !selection.amount)
            try await host.selectRow(IndexPath(item: row, section: 0), in: list)
            #expect(!selection.amount && !selection.fee)
        }
    }

    @Test(arguments: ["native-only", "local-only", "hidden", "unavailable"])
    func missingValuesAndPrivacyDoNotOfferAnInvalidToggle(scenario: String) async throws {
        let selection = Selection()
        let host = try NativeListTestHost {
            List {
                WalletTransactionValue(
                    title: "wallet.transaction.details.amount",
                    nativeValue: ["local-only", "unavailable"].contains(scenario) ? nil : "1 BTC",
                    localValue: ["native-only", "unavailable"].contains(scenario) ? nil : "$1.00",
                    isBalanceHidden: scenario == "hidden",
                    showsNative: Binding(get: { selection.amount }, set: { selection.amount = $0 })
                )
            }
        }
        defer { host.close() }
        let list = try await host.list()
        let path = IndexPath(item: 0, section: 0)
        _ = try await host.cell(at: path, in: list)
        #expect(list.delegate?.collectionView?(list, shouldHighlightItemAt: path) == false)
        list.delegate?.collectionView?(list, performPrimaryActionForItemAt: path)
        await Task.yield()
        #expect(!selection.amount)
    }
}

@MainActor
@Suite(.serialized)
struct WalletTransactionPresentationTests {
    @Test(arguments: AssetNetworkSelectorOption.allSupported)
    func persistedOutcomesOverrideBothDirectionsOnEveryNetwork(network: AssetNetworkSelectorOption) throws {
        for incoming in [false, true] {
            for outcome in ["canceled", "replaced", "failed", "notFound"] {
                var record = record(networkID: network.id, incoming: incoming,
                    status: outcome == "replaced" ? "canceled" : outcome == "notFound" ? "pending" : outcome)
                record.observedStatus = ["replaced", "notFound"].contains(outcome) ? outcome : nil
                let transaction = try project(record)
                let expectedKey = "wallet.activity.status.\(outcome == "notFound" ? "not_found" : outcome)"
                #expect(transaction.activityTitle == WalletLocalization.string(expectedKey))
                #expect(transaction.activityTitle != transaction.kind.localizedTitle)
                #expect(transaction.activitySubtitle.isEmpty)
                #expect(transaction.activityAmountColor == WalletTheme.secondaryLabel)
                // The historical amounts stay exact even though their display is muted.
                #expect(transaction.displayAssetAmountText == (incoming ? "+1" : "-1"))
                #expect(transaction.fiatValue == (incoming ? 10 : -10))
                if outcome == "replaced" {
                    #expect(transaction.status == .replaced)
                    #expect(transaction.activityBadgeSymbol == "exclamationmark")
                    #expect(transaction.activityBadgeColor == WalletTheme.warning)
                }
            }
        }
    }

    @Test(arguments: AssetNetworkSelectorOption.allSupported)
    func validTransfersKeepTheirDirectionAndPendingRemainsExplicit(network: AssetNetworkSelectorOption) throws {
        for status in ["pending", "confirmed"] {
            for incoming in [false, true] {
                let transaction = try project(record(networkID: network.id, incoming: incoming, status: status))
                #expect(transaction.activityTitle == WalletLocalization.string(incoming
                    ? "wallet.transaction.details.direction.received" : "wallet.transaction.details.direction.sent"))
                #expect(transaction.activitySubtitle == WalletLocalization.string("wallet.activity.status.\(status)"))
                #expect(transaction.activityAmountColor == WalletTheme.primaryLabel)
            }
            let transaction = try project(record(networkID: network.id, status: status, direction: "self"))
            #expect(transaction.activityTitle == WalletLocalization.string("wallet.activity.self_transfer.title"))
            if status == "confirmed" {
                #expect(transaction.activityBadgeSymbol == "arrow.left.arrow.right")
                #expect(transaction.activityBadgeColor == WalletTheme.accent)
            }
        }
    }

    @Test(arguments: AssetNetworkSelectorOption.allSupported.filter { BitcoinFamilyChain(rawValue: $0.id) == nil })
    func accountTransfersToTheSameAddressAreRecognizedInExistingHistory(network: AssetNetworkSelectorOption) throws {
        let address = SendEntryTestFixtures.address(for: network.blockchain)
        for incoming in [true, false] {
            var record = record(networkID: network.id, incoming: incoming, status: "confirmed")
            record.fromAddress = address
            record.toAddress = address
            let transaction = try project(record)
            #expect(transaction.kind == .selfTransfer(assetSymbol: record.assetSymbol))
        }
    }

    @Test
    func addressComparisonRespectsNetworkRulesAndDoesNotGuessUTXOOwnership() throws {
        var ethereum = record(networkID: "eth", status: "confirmed")
        ethereum.fromAddress = "0x8ba1f109551bD432803012645Ac136ddd64DBA72"
        ethereum.toAddress = ethereum.fromAddress?.lowercased()
        #expect(try project(ethereum).kind == .selfTransfer(assetSymbol: ethereum.assetSymbol))

        var solana = record(networkID: "solana", status: "confirmed")
        solana.fromAddress = SendEntryTestFixtures.address(for: .solana)
        solana.toAddress = solana.fromAddress?.lowercased()
        #expect(try project(solana).kind == .sent(assetSymbol: solana.assetSymbol))

        var bitcoin = record(networkID: "bitcoin", status: "confirmed")
        bitcoin.fromAddress = SendEntryTestFixtures.address(for: .bitcoin)
        bitcoin.toAddress = bitcoin.fromAddress
        // A single displayed recipient can be change in a multi-output payment.
        #expect(try project(bitcoin).kind == .sent(assetSymbol: bitcoin.assetSymbol))

        ethereum.fromAddress = ""
        ethereum.toAddress = ""
        #expect(try project(ethereum).kind == .sent(assetSymbol: ethereum.assetSymbol))
    }

    @Test
    func currentOutcomeNeverReusesAStoredPendingSubtitle() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for outcome in ["confirmed", "failed", "canceled"] {
            var record = record(networkID: "bitcoin", status: outcome)
            record.timestamp = date.timeIntervalSince1970
            #expect(try project(record).activitySubtitle == EnglishNumbers.walletActivityTimestamp(date))
        }
        var pending = record(networkID: "bitcoin", status: "pending")
        pending.timestamp = date.timeIntervalSince1970
        #expect(try project(pending).activitySubtitle == WalletLocalization.string("wallet.activity.status.pending"))
    }

    @Test(arguments: NativeListTestLayout.allCases)
    func outcomeRowsFitNativeListsIncludingLargeTextAndRTL(layout: NativeListTestLayout) async throws {
        let transactions = try ["pending", "confirmed", "canceled", "failed"].map { status in
            try project(record(networkID: "bitcoin", status: status))
        }
        let host = try NativeListTestHost(layout: layout) {
            List {
                Section {
                    ForEach(transactions) { transaction in
                        WalletTransactionRow(transaction: transaction, isBalanceHidden: false)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        defer { host.close() }
        let list = try await host.list { $0.numberOfItems(inSection: 0) == transactions.count }
        for index in transactions.indices {
            let cell = try await host.cell(at: IndexPath(item: index, section: 0), in: list)
            #expect(cell.bounds.height > 0)
            #expect(cell.bounds.width <= list.bounds.width)
        }
    }

    private func record(networkID: String, incoming: Bool = false, status: String,
                        direction: String? = nil) -> DBTransactionRecord {
        var record = SendRecipientHistoryTestFixtures.transaction(
            scope: .init(walletID: "presentation-test", networkID: networkID),
            kind: incoming ? "received" : "sent",
            direction: direction ?? (incoming ? "incoming" : "outgoing"),
            status: status, usdValue: "10"
        )
        record.fromAddress = nil
        record.toAddress = nil
        record.timestamp = nil
        record.displayTime = WalletLocalization.string("wallet.activity.status.pending")
        return record
    }

    private func project(_ record: DBTransactionRecord) throws -> WalletTransaction {
        try #require(WalletDatabase.walletTransaction(record, assetsByID: [:], networkByID: [:]))
    }
}

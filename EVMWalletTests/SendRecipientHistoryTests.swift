import Foundation
import GRDB
import Testing
import WalletCore
@testable import Aperture

@Suite("Send recipient history")
struct SendRecipientHistoryTests {
    private typealias Fixtures = SendRecipientHistoryTestFixtures

    @Test(arguments: AssetNetworkSelectorOption.allSupported)
    func onlyAcceptedAppBroadcastsCountOnEverySupportedNetwork(network: AssetNetworkSelectorOption) async throws {
        let database = try WalletDatabase.temporary()
        let asset = try SendEntryTestFixtures.nativeChoice(for: network)
        let scope = try await Fixtures.seed(database, asset: asset)
        let address = SendEntryTestFixtures.address(for: network.blockchain)
        try await Fixtures.save([
            Fixtures.transaction(hash: "api-confirmed", scope: scope, address: address),
            Fixtures.transaction(hash: "api-pending", scope: scope, address: address, status: "pending")
        ], in: database)
        let imported = try await database.sendRecipientHistorySnapshot(scope: scope)
        #expect(imported.recentRecipients.isEmpty)
        #expect(imported.assessment(address: address, networkID: network.id) == .newRecipient)

        for hash in ["first", "second"] {
            try await Fixtures.broadcast(in: database, asset: asset, hash: hash, address: address)
        }
        try await Fixtures.broadcast(in: database, asset: asset, hash: "unknown", address: address, outcome: .outcomeUnknown)
        try await Fixtures.broadcast(in: database, asset: asset, hash: "failed", address: address, outcome: .executionFailed)
        let captured = try await database.sendRecipientHistoryScope(asset: asset)
        #expect(captured.walletID == scope.walletID)
        let snapshot = try await database.sendRecipientHistorySnapshot(scope: scope)
        #expect(snapshot.assessment(address: address, networkID: network.id) == .previouslySent(count: 2))
        #expect(snapshot.recentRecipients.count == 1)
    }

    @Test
    func countsBeyondHomeHistoryLimitWithoutImportingOtherWalletsOrNetworks() async throws {
        let database = try WalletDatabase.temporary()
        let scope = try await Fixtures.seed(database)
        let other = try await Fixtures.seed(database, walletID: "other-wallet", selected: false)
        let polygon = try SendEntryTestFixtures.nativeChoice(for: #require(
            AssetNetworkSelectorOption.allSupported.first { $0.id == "polygon" }
        ))
        _ = try await Fixtures.seed(database, asset: polygon)
        for number in 0..<125 {
            try await Fixtures.broadcast(in: database, hash: "tx\(number)", date: Double(number))
        }
        try await Fixtures.broadcast(in: database, walletID: other.walletID)
        try await Fixtures.broadcast(in: database, asset: polygon, address: Fixtures.recipient)
        try await Fixtures.save([
            Fixtures.transaction(hash: "api-confirmed"),
            Fixtures.transaction(hash: "api-missing", address: nil),
            Fixtures.transaction(hash: "api-received", kind: "received", direction: "incoming"),
            Fixtures.transaction(hash: "api-self", direction: "self"),
            Fixtures.transaction(hash: "api-swap", kind: "swapped"),
            Fixtures.transaction(hash: "api-zero", amount: "0"),
            Fixtures.transaction(hash: "api-invalid", amount: "invalid")
        ], in: database)
        let snapshot = try await database.sendRecipientHistorySnapshot(scope: scope)
        #expect(snapshot.recentRecipients.count == 1)
        #expect(snapshot.recentRecipients.first?.sendCount == 125)
        #expect(snapshot.assessment(address: Fixtures.anotherRecipient, networkID: "eth") == .newRecipient)
    }

    @Test
    func recentListIsBoundedButOlderRecipientCountsRemainAvailable() async throws {
        let database = try WalletDatabase.temporary()
        let scope = try await Fixtures.seed(database)
        try await Fixtures.broadcast(in: database, hash: "old", date: 1)
        for number in 1...25 {
            let address = "0x" + String(repeating: "0", count: 38) + String(format: "%02x", number)
            try await Fixtures.broadcast(in: database, hash: "tx\(number)", address: address, date: Double(number + 1))
        }
        let snapshot = try await database.sendRecipientHistorySnapshot(scope: scope)
        #expect(snapshot.recentRecipients.count == 20)
        #expect(snapshot.assessment(address: Fixtures.recipient, networkID: "eth") == .previouslySent(count: 1))
        #expect(!snapshot.recentRecipients.contains { $0.address == Fixtures.recipient })
        #expect(snapshot.recentRecipients.first?.lastSentAt == Date(timeIntervalSince1970: 26))
    }

    @Test
    func canonicalAddressAliasesMatchWithoutLowercasingBase58() throws {
        func identity(_ address: String, _ network: String) throws -> SendRecipientAddressIdentity {
            try #require(SendRecipientAddressIdentity(address: address, networkID: network))
        }
        #expect(try identity(Fixtures.recipient, "eth") == identity(Fixtures.recipient.lowercased(), "eth"))
        #expect(try identity("0x1", "aptos") == identity("0x" + String(repeating: "0", count: 63) + "1", "aptos"))
        #expect(try identity("0x2", "sui") == identity("0x" + String(repeating: "0", count: 63) + "2", "sui"))
        let ton = SendEntryTestFixtures.address(for: .ton)
        #expect(try identity(ton, "ton") == identity(#require(TONAddress.rawAddress(from: ton)), "ton"))
        #expect(try identity(ton, "ton") == identity(#require(TONAddress.userFriendlyAddress(from: ton, bounceable: true)), "ton"))
        let bch = SendEntryTestFixtures.address(for: .bitcoincash)
        #expect(try identity(bch, "bitcoin_cash") == identity("bitcoincash:" + bch, "bitcoin_cash"))
        #expect(try identity(bch, "bitcoin_cash") == identity("1BpEi6DfDAUFd7GtittLSdBeYJvcoaVggu", "bitcoin_cash"))
        let btc = SendEntryTestFixtures.address(for: .bitcoin)
        #expect(try identity(btc, "bitcoin") == identity(btc.uppercased(), "bitcoin"))
        let xrp = SendEntryTestFixtures.address(for: .xrp)
        #expect(try identity(xrp, "xrp") == identity(#require(XRPAddress.signingDestination(classicAddress: xrp, destinationTag: 0)), "xrp"))
        let solana = SendEntryTestFixtures.address(for: .solana)
        #expect(try identity(solana, "solana").value == solana)
        #expect(SendRecipientAddressIdentity(address: solana.lowercased(), networkID: "solana")
            != SendRecipientAddressIdentity(address: solana, networkID: "solana"))
        #expect(SendRecipientAddressIdentity(address: "not-an-address", networkID: "eth") == nil)
        #expect(SendRecipientAddressIdentity(address: Fixtures.recipient, networkID: "unsupported") == nil)
    }

    @Test
    func silentPaymentIdentityUsesCanonicalReusableAddress() throws {
        let address =
            "sp1qqgste7k9hx0qftg6qmwlkqtwuy6cycyavzmzj85c6qdfhjdpdjtdgqjuex"
            + "zk6murw56suy3e0rd2cgqvycxttddwsvgxe2usfpxumr70xc9pkqwv"
        let canonical = try #require(
            SendRecipientAddressIdentity(
                address: address,
                networkID: BitcoinFamilyChain.bitcoin.networkID
            )
        )
        let uppercase = try #require(
            SendRecipientAddressIdentity(
                address: address.uppercased(),
                networkID: BitcoinFamilyChain.bitcoin.networkID
            )
        )

        #expect(canonical == uppercase)
        #expect(canonical.value == "silent-payment:\(address)")
    }

    @Test @MainActor
    func observationTracksAcceptedBroadcastsAndNeverFallsBackToAnotherWallet() async throws {
        let database = try WalletDatabase.temporary()
        _ = try await Fixtures.seed(database)
        let other = try await Fixtures.seed(database, walletID: "other-wallet", selected: false)
        let model = SendRecipientHistoryModel()
        #expect(model.assessment(address: Fixtures.recipient, networkID: "eth") == nil)
        let task = Task { await model.observe(database: database, asset: SendEntryTestFixtures.ethereum) }
        defer { task.cancel() }
        try await wait { model.snapshot != nil }
        #expect(model.assessment(address: Fixtures.recipient, networkID: "eth") == .newRecipient)
        try await Fixtures.save([Fixtures.transaction()], in: database)
        #expect(model.recentRecipients.isEmpty)
        try await Fixtures.broadcast(in: database)
        try await wait { model.recentRecipients.first?.sendCount == 1 }
        try await WalletDataStore(database: database).selectWallet(id: other.walletID)
        try await wait { model.errorMessage != nil }
        #expect(model.snapshot == nil)
        #expect(model.assessment(address: Fixtures.recipient, networkID: "eth") == nil)
    }

    @Test @MainActor
    func databaseReadFailureShowsSanitizedCauseInsteadOfNewRecipient() async throws {
        let database = try WalletDatabase.temporary()
        _ = try await Fixtures.seed(database)
        try await database.pool.write { db in try db.execute(sql: "DROP TABLE sendRecipientBroadcasts") }
        let model = SendRecipientHistoryModel()
        await model.observe(database: database, asset: SendEntryTestFixtures.ethereum)
        #expect(model.snapshot == nil)
        #expect(model.errorMessage?.contains("sqlite_") == true)
        #expect(model.errorMessage?.contains(Fixtures.recipient) == false)
        #expect(model.assessment(address: Fixtures.recipient, networkID: "eth") == nil)
    }

    @Test @MainActor
    func recentSelectionRevalidatesAndPreservesOtherDraftFields() throws {
        let model = SendRecipientEntryModel(draft: SendEntryTestFixtures.draft(amount: "1.5"))
        model.note = "Local note"
        let recent = try Fixtures.recent(address: Fixtures.anotherRecipient)
        model.applyRecentRecipient(recent)
        #expect(model.recipient == Fixtures.anotherRecipient)
        #expect(model.continueDraft()?.amount == "1.5")
        #expect(model.continueDraft()?.note == "Local note")
        model.applyRecentRecipient(SendRecentRecipient(
            id: recent.id, address: "not-an-address", sendCount: 1, lastSentAt: .now
        ))
        #expect(model.recipient == Fixtures.anotherRecipient)
    }

    @Test @MainActor
    func recentSelectionNeverCarriesAnotherRecipientsTagOrMemo() throws {
        for networkID in [XRPConstants.networkID, StellarConstants.networkID] {
            let network = try #require(AssetNetworkSelectorOption.allSupported.first { $0.id == networkID })
            let asset = try SendEntryTestFixtures.nativeChoice(for: network)
            let model = SendRecipientEntryModel(draft: SendEntryTestFixtures.draft(asset: asset, amount: "1", memo: "123"))
            model.applyRecentRecipient(try Fixtures.recent(
                address: SendEntryTestFixtures.address(for: network.blockchain), networkID: networkID
            ))
            #expect(model.networkMemo.isEmpty)
            #expect(model.continueDraft()?.request.memo == nil)
            #expect(model.continueDraft()?.amount == "1")
        }
    }

    @Test @MainActor
    func resolvedNameUsesAppSendsAndEditingInvalidatesTheAssessment() async throws {
        let database = try WalletDatabase.temporary()
        _ = try await Fixtures.seed(database)
        try await Fixtures.broadcast(in: database)
        let history = SendRecipientHistoryModel()
        let task = Task { await history.observe(database: database, asset: SendEntryTestFixtures.ethereum) }
        defer { task.cancel() }
        try await wait { history.snapshot != nil }
        let resolver = SendRecipientNameResolutionModel(resolve: { _, _ in Fixtures.recipient })
        let entry = SendRecipientEntryModel(draft: SendEntryTestFixtures.draft(recipient: ""), nameResolution: resolver)
        entry.setRecipient("example.eth")
        #expect(history.assessment(address: entry.resolvedRecipient, networkID: "eth") == nil)
        await resolver.waitForScheduledResolution()
        #expect(history.assessment(address: entry.resolvedRecipient, networkID: "eth") == .previouslySent(count: 1))
        entry.setRecipient("invalid")
        #expect(history.assessment(address: entry.resolvedRecipient, networkID: "eth") == nil)
    }

    @MainActor
    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Recipient history observation did not update")
    }
}

import XCTest
import OathBitcoin
@testable import OathDatabase

@MainActor final class ReceiptContactTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try await OathDatabase.open(at: directory.appendingPathComponent("receipt.sqlite"))
        let chains = UTXONetwork.allCases.map { ($0.rawValue, "utxo") } + [
            ("ethereum", "evm"), ("base", "evm"), ("solana", "solana")
        ]
        try await database.seed(networks: chains.enumerated().map { index, chain in
            NetworkRecord(id: chain.0, name: chain.0, family: chain.1, symbol: chain.0.uppercased(),
                          decimals: 8, derivationPath: "fixture", logo: "fixture", sortOrder: index)
        }, assets: [])
        return (database, directory)
    }

    func testReceiptSaveAndObservationForEveryBitcoinFamilyAddressType() async throws {
        let (db, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for chain in UTXONetwork.allCases {
            // Public deterministic fixture only; never funded or broadcast.
            let wallet = try chain.wallet(seed: Data(0..<32))
            for branch in wallet.branches {
                let address = try BitcoinKeys.addresses(branch: branch, range: 0..<1)[0].address
                var changes = db.observeContactAddress(networkID: chain.rawValue, address: address).makeAsyncIterator()
                let before = try await changes.next()
                XCTAssertEqual(before, false, chain.rawValue)
                let saved = try await db.saveContact(id: UUID().uuidString, name: "Recipient",
                    addresses: [.init(networkID: chain.rawValue, address: address, label: "Personal")], rejectExistingAddresses: true)
                let after = try await changes.next()
                XCTAssertEqual(after, true, chain.rawValue)
                let reopened = try await OathDatabase.open(at: directory.appendingPathComponent("receipt.sqlite"))
                let persisted = try await reopened.contact(saved.contact.id)
                XCTAssertEqual(persisted?.contact.name, "Recipient")
                XCTAssertEqual(persisted?.addresses.first?.networkID, chain.rawValue)
                XCTAssertEqual(persisted?.addresses.first?.address, address)
                XCTAssertEqual(persisted?.addresses.first?.label, "Personal")
                try await db.deleteContact(saved.contact.id, expectedRevision: saved.contact.revision)
                let removed = try await changes.next()
                XCTAssertEqual(removed, false)
            }
        }
    }

    func testCashAddrAliasesMatchWithoutCrossingNetworks() async throws {
        let (db, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = "1BpEi6DfDAUFd7GtittLSdBeYJvcoaVggu"
        let cash = "bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a"
        _ = try await db.saveContact(id: UUID().uuidString, name: "BTC only", addresses: [.init(networkID: "bitcoin", address: legacy)])
        var bch = db.observeContactAddress(networkID: "bitcoincash", address: cash).makeAsyncIterator()
        let notSavedOnBCH = try await bch.next()
        XCTAssertEqual(notSavedOnBCH, false)
        _ = try await db.saveContact(id: UUID().uuidString, name: "BCH", addresses: [.init(networkID: "bitcoincash", address: legacy)])
        for alias in [cash, cash.uppercased(), String(cash.dropFirst("bitcoincash:".count)), legacy] {
            var lookup = db.observeContactAddress(networkID: "bitcoincash", address: alias).makeAsyncIterator()
            let saved = try await lookup.next()
            XCTAssertEqual(saved, true)
            do {
                _ = try await db.saveContact(id: UUID().uuidString, name: "Duplicate",
                    addresses: [.init(networkID: "bitcoincash", address: alias)], rejectExistingAddresses: true)
                XCTFail("Equivalent BCH destination created a duplicate")
            } catch { XCTAssertEqual(error as? ContactStoreError, .duplicateAddress) }
        }
        let all = try await db.contacts()
        XCTAssertEqual(all.count, 2)
    }

    func testEVMCaseMatchingAndOtherCaseSensitiveNetworks() async throws {
        let (db, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let address = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
        _ = try await db.saveContact(id: UUID().uuidString, name: "ETH", addresses: [.init(networkID: "ethereum", address: address)])
        for (network, query, expected) in [("ethereum", address.uppercased(), true), ("base", address, false)] {
            var lookup = db.observeContactAddress(networkID: network, address: query).makeAsyncIterator()
            let found = try await lookup.next()
            XCTAssertEqual(found, expected)
        }
        // Storage accepts printable identifiers; this fixture checks case semantics only.
        _ = try await db.saveContact(id: UUID().uuidString, name: "Case sensitive",
            addresses: [.init(networkID: "solana", address: "PublicCaseSensitiveFixture")])
        var lookup = db.observeContactAddress(networkID: "solana", address: "publiccasesensitivefixture").makeAsyncIterator()
        let found = try await lookup.next()
        XCTAssertEqual(found, false)
    }

    func testConcurrentReceiptSavesCommitExactlyOneContact() async throws {
        let (db, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recipient = ContactAddressInput(networkID: "bitcoincash", address: "bitcoincash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a")
        func save() async throws -> Bool {
            do {
                _ = try await db.saveContact(id: UUID().uuidString, name: "Receipt", addresses: [recipient], rejectExistingAddresses: true)
                return true
            } catch ContactStoreError.duplicateAddress { return false }
        }
        async let first = save()
        async let second = save()
        let results = try await [first, second]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let contacts = try await db.contacts()
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts.first?.addressCount, 1)
    }

    func testInvalidQuickAddLeavesNoNameOnlyContact() async throws {
        let (db, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await db.saveContact(id: UUID().uuidString, name: "Receipt",
                addresses: [.init(networkID: "bitcoin", address: "public-fixture", label: String(repeating: "x", count: 61))],
                rejectExistingAddresses: true)
            XCTFail("Invalid label saved")
        } catch { XCTAssertEqual(error as? ContactStoreError, .invalidLabel) }
        let contacts = try await db.contacts()
        XCTAssertTrue(contacts.isEmpty)
    }
}

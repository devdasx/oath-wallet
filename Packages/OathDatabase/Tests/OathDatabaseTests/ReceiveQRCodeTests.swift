import Foundation
import GRDB
import OathBitcoin
import OathAnkr
import Vision
import XCTest
@testable import OathDatabase

@MainActor final class ReceiveQRCodeTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OathQR-" + UUID().uuidString).appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        for chain in ["bitcoin", "ethereum", "solana", "ton"] {
            try await db.seed(networks: [.init(id: chain, name: chain, family: "fixture", symbol: chain, decimals: 8,
                derivationPath: "fixture", logo: chain, sortOrder: 0)], assets: [])
        }
        return (db, url)
    }

    private func decode(_ image: CGImage, matches address: String) throws {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        XCTAssertTrue(request.results?.contains { $0.payloadStringValue == address } == true,
                      "Independent decoder must recover exactly the requested public fixture")
    }

    private func cached(_ db: OathDatabase, account: String, address: String) async throws -> Data? {
        try await db.pool.read { db in
            try Data.fetchOne(db, sql: "SELECT image FROM receiveQRCodes WHERE accountID=? AND address=?", arguments: [account, address])
        }
    }

    func testGramRawAndFriendlyAccountsShareOneVerifiedReceivePayload() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Synthetic account, independently encoded with CRC16-CCITT (initial 0).
        let raw = "0:" + String(repeating: "ab", count: 32)
        let friendly = "UQCrq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq5jh"
        let bounceable = try TonIdentity.friendly(raw)
        for (index, storedAddress) in [raw, bounceable, friendly].enumerated() {
            let wallet = "wallet-\(index)", account = "account-\(index)"
            try await db.importWalletIfNeeded(.init(id: wallet, name: "Fixture", kind: "tonMultisig", vaultReference: wallet, createdAt: 1),
                accounts: [.init(id: account, walletID: wallet, networkID: "ton", address: storedAddress, derivationPath: "ton-multisig-v1")])
            // Insertion creates the old persisted QR; the read must upgrade it.
            let presentation = try await db.receivePresentation(accountID: account, address: storedAddress)
            XCTAssertEqual(presentation.address, friendly)
            XCTAssertEqual(try TonIdentity.raw(presentation.address), raw)
            try decode(presentation.image, matches: friendly)
            let accounts = try await db.accounts(walletID: wallet)
            XCTAssertEqual(accounts.first?.address, storedAddress, "Presentation must not change the signing/ledger identity")
            let upgraded = try await cached(db, account: account, address: storedAddress)
            let reopened = try await OathDatabase.open(at: url)
            try decode(try await reopened.receiveQRCode(accountID: account, address: storedAddress), matches: friendly)
            let reused = try await cached(reopened, account: account, address: storedAddress)
            XCTAssertEqual(upgraded, reused, "The upgraded friendly QR is reused after restart")
            do {
                _ = try await db.receivePresentation(accountID: account, address: "0:" + String(repeating: "cd", count: 32))
                XCTFail("A different contract cannot be substituted")
            } catch StoreError.conflictingIdentity { }
        }
    }

    func testImportCreatesCacheAndReopenReusesIt() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let address = "0x" + String(repeating: "ab", count: 20)
        try await db.importWalletIfNeeded(.init(id: "wallet", name: "Fixture", kind: "imported", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "account", walletID: "wallet", networkID: "ethereum", address: address, derivationPath: "fixture")])
        let initialCache = try await cached(db, account: "account", address: address)
        let saved = try XCTUnwrap(initialCache)
        let reopened = try await OathDatabase.open(at: url)
        let start = ContinuousClock.now
        let image = try await reopened.receiveQRCode(accountID: "account", address: address)
        print("Loaded a persisted synthetic receive QR after database reopen in \(start.duration(to: .now))")
        try decode(image, matches: address)
        let reused = try await cached(reopened, account: "account", address: address)
        XCTAssertEqual(reused, saved, "A reopened receive reads the same persisted image")
        do {
            _ = try await reopened.receiveQRCode(accountID: "account", address: "different-address")
            XCTFail("An unsaved address must never be cached or displayed")
        } catch StoreError.conflictingIdentity { }
    }

    func testHDAddressesAndSolanaVariantsAreCachedAtSave() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let descriptor = try UTXONetwork.bitcoin.wallet(seed: Data(0..<32))
        let branch = try XCTUnwrap(descriptor.branches.first { $0.change == 0 })
        let first = try BitcoinKeys.addresses(branch: branch, range: 0..<1)[0]
        try await db.importWalletIfNeeded(.init(id: "wallet", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "btc", walletID: "wallet", networkID: "bitcoin", address: first.address, derivationPath: first.path)])
        let start = ContinuousClock.now
        try await db.prepareBitcoin(accountID: "btc", descriptor: descriptor)
        let counts = try await db.pool.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bitcoinAddresses WHERE accountID='btc'")!,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM receiveQRCodes WHERE accountID='btc' AND image IS NOT NULL")!)
        }
        XCTAssertEqual(counts.0, counts.1, "All saved HD receive/change/lookahead addresses have rendered cache entries")
        print("Prepared \(counts.0) synthetic HD address QR caches in \(start.duration(to: .now))")
        let next = try BitcoinKeys.addresses(branch: branch, range: 20..<21)[0]
        try await db.pool.write { db in try OathDatabase.saveBitcoinAddress(next, accountID: "btc", used: false, db: db) }
        let newCache = try await cached(db, account: "btc", address: next.address)
        XCTAssertNotNil(newCache, "New HD discovery addresses are cached by the same save boundary")
        try decode(try await db.receiveQRCode(accountID: "btc", address: next.address), matches: next.address)

        let trust = SolanaReceiveAddress(path: "m/44'/501'/0'", address: "GjJyeC1r2RgkuoCWMyPYkCWSGSGLcz266EaAkLA27AhL")
        let phantom = SolanaReceiveAddress(path: "m/44'/501'/0'/0'", address: "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk")
        try await db.importWalletIfNeeded(.init(id: "wallet", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "sol", walletID: "wallet", networkID: "solana", address: trust.address, derivationPath: trust.path)])
        _ = try await db.prepareSolanaReceive(accountID: "sol", addresses: [trust, phantom], preferredPath: phantom.path)
        for variant in [trust, phantom] {
            let saved = try await cached(db, account: "sol", address: variant.address)
            XCTAssertNotNil(saved)
            try decode(try await db.receiveQRCode(accountID: "sol", address: variant.address), matches: variant.address)
        }
    }

    func testCorruptOrMissingCacheRepairsAndDeletionCascades() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let address = "0x" + String(repeating: "cd", count: 20)
        try await db.importWalletIfNeeded(.init(id: "wallet", name: "Fixture", kind: "privateKey", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "account", walletID: "wallet", networkID: "ethereum", address: address, derivationPath: "imported")])
        for invalid in [Data(), ReceiveQRImage.encoded("different-address")!] {
            try await db.pool.write { db in try db.execute(sql: "UPDATE receiveQRCodes SET image=?", arguments: [invalid]) }
            try decode(try await db.receiveQRCode(accountID: "account", address: address), matches: address)
        }
        try await db.pool.write { db in try db.execute(sql: "DELETE FROM receiveQRCodes") }
        try decode(try await db.receiveQRCode(accountID: "account", address: address), matches: address)
        try await db.pool.write { db in try db.execute(sql: "DELETE FROM wallets WHERE id='wallet'") }
        let remaining = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM receiveQRCodes") }
        XCTAssertEqual(remaining, 0)
        do {
            _ = try await db.receiveQRCode(accountID: "account", address: address)
            XCTFail("Deleted wallet cache must not be recreated")
        } catch StoreError.conflictingIdentity { }
    }

    func testBrandedEncoderCharacterSetsAndPayloadBinding() throws {
        for address in ["bc1q" + String(repeating: "q", count: 38),
                        "bitcoincash:q" + String(repeating: "p", count: 41),
                        "0x" + String(repeating: "a3", count: 32),
                        "EQ" + String(repeating: "aB3_", count: 11) + "AB",
                        "G" + String(repeating: "B", count: 55),
                        "So11111111111111111111111111111111111111112"] {
            let stored = try XCTUnwrap(ReceiveQRImage.encoded(address))
            let image = try XCTUnwrap(ReceiveQRImage.decoded(stored, address: address))
            XCTAssertEqual(image.width % 8, 0)
            try decode(image, matches: address)
            XCTAssertNil(ReceiveQRImage.decoded(stored, address: "wrong-address"))
        }
        XCTAssertNil(ReceiveQRImage.image(for: ""))
        XCTAssertNil(ReceiveQRImage.image(for: String(repeating: "a", count: 1_025)))
    }
}

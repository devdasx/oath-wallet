import Foundation
import XCTest
@testable import OathDatabase

@MainActor final class SolanaReceiveTests: XCTestCase {
    // Public BIP39 zero-entropy fixture, independently derived with SLIP-0010.
    private let phantom = SolanaReceiveAddress(path: "m/44'/501'/0'/0'", address: "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk")
    private let trust = SolanaReceiveAddress(path: "m/44'/501'/0'", address: "GjJyeC1r2RgkuoCWMyPYkCWSGSGLcz266EaAkLA27AhL")

    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OathSolana-" + UUID().uuidString).appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: [.init(id: "solana", name: "Solana", family: "account", symbol: "SOL", decimals: 9,
            derivationPath: phantom.path, logo: "solana", sortOrder: 0)], assets: [
                .init(id: "solana:native", networkID: "solana", reference: "native", name: "Solana", symbol: "SOL", decimals: 9)])
        for n in 1...2 {
            try await db.importWalletIfNeeded(.init(id: "w\(n)", name: "Fixture", kind: "hd", vaultReference: "fixture-\(n)", createdAt: 1),
                accounts: [.init(id: "a\(n)", walletID: "w\(n)", networkID: "solana", address: trust.address, derivationPath: trust.path)])
        }
        return (db, url)
    }

    func testPathConventionsAndBounds() throws {
        XCTAssertEqual(try SolanaDerivation.phantom.path(accountIndex: 0), phantom.path)
        XCTAssertEqual(try SolanaDerivation.trustWallet.path(accountIndex: 7), "m/44'/501'/7'")
        XCTAssertEqual(SolanaDerivation.accountIndex(in: "m/44'/501'/7'/0'"), 7)
        XCTAssertEqual(SolanaDerivation.matching(path: trust.path), .trustWallet)
        for invalid in ["m/44/501/0", "m/44'/501'/00'", "m/44'/501'/0'/1'", "m/44'/501'/-1'", "m/44'/501'/2147483648'", "m/44'/501'/0'/0'/0'", "imported"] {
            XCTAssertNil(SolanaDerivation.matching(path: invalid))
        }
        XCTAssertThrowsError(try SolanaDerivation.phantom.path(accountIndex: -1))
        XCTAssertThrowsError(try SolanaDerivation.phantom.path(accountIndex: 2_147_483_648))
    }

    func testDefaultSwitchReopenAndWalletIsolation() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let initial = try await db.prepareSolanaReceive(accountID: "a1", addresses: [phantom, trust], preferredPath: phantom.path)
        XCTAssertEqual(initial.selected, phantom)
        let original = try await db.accounts(walletID: "w1")
        XCTAssertEqual(original.first?.address, trust.address, "Migration must preserve the old account identity")
        _ = try await db.prepareSolanaReceive(accountID: "a2", addresses: [phantom, trust], preferredPath: phantom.path)
        let changed = try await db.selectSolanaReceivePath(accountID: "a1", path: trust.path)
        XCTAssertEqual(changed.selected, trust)
        let reopened = try await OathDatabase.open(at: url)
        let persisted = try await reopened.solanaReceiveState(accountID: "a1")
        XCTAssertEqual(persisted?.selected, trust)
        let idempotent = try await reopened.prepareSolanaReceive(accountID: "a1", addresses: [trust, phantom], preferredPath: phantom.path)
        XCTAssertEqual(idempotent.selected, trust)
        let other = try await db.solanaReceiveState(accountID: "a2")
        XCTAssertEqual(other?.selected, phantom)
        do { _ = try await db.selectSolanaReceivePath(accountID: "a1", path: "m/44'/501'/9'"); XCTFail("Unknown path was selected") } catch { }
        let unchanged = try await db.solanaReceiveState(accountID: "a1")
        XCTAssertEqual(unchanged?.selected, trust)
    }

    func testReceiveRecordsAcceptBothOwnedAddressesOnly() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try await db.prepareSolanaReceive(accountID: "a1", addresses: [phantom, trust], preferredPath: phantom.path)
        for address in [phantom, trust] {
            try await db.saveReceive(.init(id: address.path, accountID: "a1", networkID: "solana", assetID: "solana:native",
                address: address.address, state: "open", createdAt: 1))
        }
        let requests = try await db.receives(accountID: "a1")
        XCTAssertEqual(Set(requests.map(\.address)), Set([phantom.address, trust.address]))
        do {
            try await db.saveReceive(.init(id: "foreign", accountID: "a2", networkID: "solana", assetID: "solana:native",
                address: phantom.address, state: "open", createdAt: 1))
            XCTFail("Another account's derived address was accepted")
        } catch { XCTAssertEqual(error as? StoreError, .conflictingIdentity) }
        do {
            _ = try await db.prepareSolanaReceive(accountID: "a1", addresses: [
                .init(path: phantom.path, address: trust.address), .init(path: trust.path, address: phantom.address)], preferredPath: phantom.path)
            XCTFail("Public derivations were overwritten")
        } catch { XCTAssertEqual(error as? StoreError, .conflictingIdentity) }
    }

    func testImportedKeyCannotSwitchAndResetRemovesDerivations() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = SolanaReceiveAddress(path: "imported", address: trust.address)
        try await db.importWalletIfNeeded(.init(id: "key", name: "Fixture", kind: "privateKey", vaultReference: "key", createdAt: 1),
            accounts: [.init(id: "key:a", walletID: "key", networkID: "solana", address: key.address, derivationPath: key.path)])
        let state = try await db.prepareSolanaReceive(accountID: "key:a", addresses: [key], preferredPath: key.path)
        XCTAssertEqual(state.addresses, [key])
        do { _ = try await db.prepareSolanaReceive(accountID: "key:a", addresses: [key, phantom], preferredPath: phantom.path); XCTFail("Raw key became HD") } catch { }
        _ = try await db.prepareSolanaReceive(accountID: "a1", addresses: [phantom, trust], preferredPath: phantom.path)
        let reset = try await db.beginWalletReset()
        do { _ = try await db.selectSolanaReceivePath(accountID: "a1", path: trust.path); XCTFail("Selection crossed the reset fence") } catch { }
        try await db.eraseWalletData(resetID: reset)
        let erased = try await db.solanaReceiveState(accountID: "a1")
        let erasedKey = try await db.solanaReceiveState(accountID: "key:a")
        XCTAssertNil(erased); XCTAssertNil(erasedKey)
    }
}

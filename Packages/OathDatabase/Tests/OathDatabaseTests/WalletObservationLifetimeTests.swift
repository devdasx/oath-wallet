import Foundation
import XCTest
@testable import OathDatabase

/// Real SQLite observations, using disposable public metadata only. These
/// distinguish a live missing wallet from expected observation teardown.
@MainActor final class WalletObservationLifetimeTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallet-observation-lifetime-" + UUID().uuidString)
        let store = try await OathDatabase.open(at: directory.appendingPathComponent("fixture.sqlite"))
        return (store, directory)
    }

    private func insert(_ id: String, into store: OathDatabase) async throws {
        try await store.importWalletIfNeeded(
            WalletRecord(id: id, name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1),
            accounts: [])
    }

    func testMissingWalletAtStartRemainsAnError() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var iterator = store.observeWallet(walletID: "absent", currency: "USD").makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Missing wallet must not look like an empty or successfully loaded wallet")
        } catch {
            XCTAssertEqual(error as? StoreError, .missingRecord)
        }
    }

    func testDeletingAnActivelyObservedWalletFailsInsteadOfLeavingAStaleSnapshot() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await insert("active", into: store)
        var iterator = store.observeWallet(walletID: "active", currency: "USD").makeAsyncIterator()
        let initial = try await iterator.next()
        XCTAssertEqual(initial?.wallet.id, "active")
        try await store.deleteWalletMetadata("active")
        do {
            _ = try await iterator.next()
            XCTFail("A live observer must invalidate its deleted wallet")
        } catch {
            XCTAssertEqual(error as? StoreError, .missingRecord)
        }
    }

    func testCancellationBeforeRemovalDoesNotDeliverMissingRecordAcross32WalletSwitches() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for round in 0..<32 {
            let id = "fixture-\(round)"
            try await insert(id, into: store)
            let ready = expectation(description: "Initial wallet \(round)")
            let finished = expectation(description: "Cancelled observation \(round)")
            let observer = Task { () -> (Int, StoreError?) in
                defer { finished.fulfill() }
                var count = 0
                do {
                    for try await snapshot in store.observeWallet(walletID: id, currency: "USD") {
                        count += 1
                        XCTAssertEqual(snapshot.wallet.id, id)
                        if count == 1 { ready.fulfill() }
                    }
                    return (count, nil)
                } catch is CancellationError {
                    return (count, nil)
                } catch {
                    XCTAssertNotNil(error as? StoreError, "Unexpected observation failure")
                    return (count, error as? StoreError)
                }
            }
            await fulfillment(of: [ready], timeout: 5)
            observer.cancel()
            // Commit immediately, before awaiting cancellation completion.
            try await store.deleteWalletMetadata(id)
            await fulfillment(of: [finished], timeout: 5)
            let result = await observer.value
            XCTAssertEqual(result.0, 1)
            XCTAssertNil(result.1, "Cancelled wallet observation, round \(round)")
        }
    }
}

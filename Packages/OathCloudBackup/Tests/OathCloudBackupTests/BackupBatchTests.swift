import XCTest
@testable import OathCloudBackup

final class BackupBatchTests: XCTestCase, @unchecked Sendable {
    actor Results {
        var attempted: [String] = []
        var succeeded: [String] = []
        var failed: [String] = []
        var documents: [String: Data] = [:]
        func attempt(_ id: String) { attempted.append(id) }
        func finish(_ id: String, error: (any Error)?) {
            if error == nil { succeeded.append(id) } else { failed.append(id) }
        }
        func save(_ data: Data, id: String) { documents[id] = data }
    }

    func testEveryWalletAttemptedOnceAndFailureDoesNotSkipLaterWallets() async throws {
        let results = Results()
        try await BackupBatch.prepare(walletIDs: ["a", "b", "a", "c"], operation: { id in
            await results.attempt(id)
            if id == "b" { throw CloudBackupError.unavailable }
        }, didFinish: { id, error in await results.finish(id, error: error) })
        let attempted = await results.attempted, succeeded = await results.succeeded, failed = await results.failed
        XCTAssertEqual(attempted, ["a", "b", "c"])
        XCTAssertEqual(succeeded, ["a", "c"])
        XCTAssertEqual(failed, ["b"])
    }

    func testCancellationStopsPreparingRemainingWallets() async throws {
        let results = Results()
        do {
            try await BackupBatch.prepare(walletIDs: ["a", "b", "c"], operation: { id in
                await results.attempt(id)
                if id == "b" { throw CancellationError() }
            }, didFinish: { id, error in await results.finish(id, error: error) })
            XCTFail("Cancellation must propagate")
        } catch is CancellationError { }
        let attempted = await results.attempted, succeeded = await results.succeeded, failed = await results.failed
        XCTAssertEqual(attempted, ["a", "b"])
        XCTAssertEqual(succeeded, ["a"])
        XCTAssertTrue(failed.isEmpty, "Cancellation is not a successful or failed upload")
    }

    func testOnePasswordProducesIndependentRestorableBackupsForAllWalletKinds() async throws {
        // Published BIP39 fixture and synthetic key bytes; never real wallets.
        let words = String(repeating: "abandon ", count: 11) + "about"
        let wallets = [
            BackupWallet(id: UUID(), name: "Mnemonic fixture", mnemonic: words, language: "english", createdAt: .now,
                accounts: [.init(network: "bitcoin", derivationPath: "m/84'/0'/0'/0/0", index: 0)]),
            BackupWallet(id: UUID(), name: "Passphrase fixture", mnemonic: words, language: "english", createdAt: .now,
                accounts: [.init(network: "ethereum", derivationPath: "m/44'/60'/0'/0/0", index: 0)], passphrase: "public-test-passphrase"),
            BackupWallet(id: UUID(), name: "Private key fixture", mnemonic: "", language: "", createdAt: .now,
                accounts: [.init(network: "ethereum", derivationPath: "imported", index: 0)],
                privateKey: .init(bytes: Data(repeating: 7, count: 32), networks: ["ethereum"]))
        ]
        let byID = Dictionary(uniqueKeysWithValues: wallets.map { ($0.id.uuidString, $0) })
        let results = Results()
        try await BackupBatch.prepare(walletIDs: wallets.map { $0.id.uuidString }, operation: { id in
            let data = try BackupDocument.seal(byID[id]!, password: "shared-fixture-password")
            await results.save(data, id: id)
        }, didFinish: { id, error in await results.finish(id, error: error) })
        let documents = await results.documents
        XCTAssertEqual(documents.count, wallets.count)
        for wallet in wallets {
            let data = try XCTUnwrap(documents[wallet.id.uuidString])
            XCTAssertEqual(try BackupDocument.open(data, password: "shared-fixture-password"), wallet)
            XCTAssertThrowsError(try BackupDocument.open(data, password: "wrong-password"))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(wallet.name))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(words))
        }
        XCTAssertEqual(Set(documents.values).count, wallets.count)
    }

    func testEmptyBatchDoesNotPrepareAnything() async throws {
        let results = Results()
        try await BackupBatch.prepare(walletIDs: [], operation: { id in
            await results.attempt(id)
        }, didFinish: { id, error in await results.finish(id, error: error) })
        let attempted = await results.attempted
        XCTAssertTrue(attempted.isEmpty)
    }
}

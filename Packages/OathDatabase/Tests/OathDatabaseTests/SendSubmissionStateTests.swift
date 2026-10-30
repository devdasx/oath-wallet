import Foundation
import GRDB
import XCTest
@testable import OathDatabase
@testable import OathAnkr

extension EVMSendJournalTests {
    func testInvalidBaseInclusionCannotPromoteOrReleaseSend() async throws {
        let (db, folder, plan) = try await fixture(network: .base)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await draft("invalid-inclusion", plan: plan, db: db)
        try await db.queueEVMSend(sendID: "invalid-inclusion", plan: plan)
        let signed = try EVMSendCrypto.sign(plan, privateKey: key)
        try await db.journalEVMSignature(sendID: "invalid-inclusion", signed: signed)
        for inclusion in [
            EVMSendInclusion(succeeded: true, blockHash: "bad", fee: 500, height: 123, timestamp: 123),
            .init(succeeded: true, blockHash: "0x" + String(repeating: "a", count: 64), fee: 500, height: 99, timestamp: 123),
            .init(succeeded: true, blockHash: "0x" + String(repeating: "a", count: 64), fee: 500, height: 123, timestamp: .nan),
            .init(succeeded: true, blockHash: "0x" + String(repeating: "a", count: 64), fee: 500, height: 123, timestamp: 123, deliveredAmount: "1")
        ] {
            do {
                try await db.settleEVMSend(sendID: "invalid-inclusion", receipt: .init(hash: signed.hash, outcome: .accepted, inclusion: inclusion))
                XCTFail("Invalid inclusion accepted")
            } catch { XCTAssertEqual(error as? EVMSendError, .changed) }
            let progress = try await db.sendSubmission(walletID: "w1", networkID: "base", hash: signed.hash)
            XCTAssertEqual(progress?.outcome, .checking)
        }
    }

    func testEveryEVMReceiptShowsInclusionAndRetainsTrackingThroughReorgAndFinality() async throws {
        for network in EVMSendNetwork.allCases where !network.isTestnet {
            let (db, folder, plan) = try await fixture(network: network)
            defer { try? FileManager.default.removeItem(at: folder) }
            try await draft("included", plan: plan, db: db)
            try await db.queueEVMSend(sendID: "included", plan: plan)
            let signed = try EVMSendCrypto.sign(plan, privateKey: key)
            try await db.journalEVMSignature(sendID: "included", signed: signed)
            _ = try await db.transitionSend("included", from: "signed", to: "broadcast")
            try await db.settleEVMSend(sendID: "included", receipt: .init(hash: signed.hash, outcome: .accepted))
            var observer = db.observeSendSubmission(walletID: "w1", networkID: network.rawValue, hash: signed.hash).makeAsyncIterator()
            let pending = try await observer.next()
            XCTAssertEqual(pending??.outcome, .submitted)
            let inclusion = EVMSendInclusion(succeeded: true, blockHash: "0x" + String(repeating: "a", count: 64), fee: 500, height: 123, timestamp: 123)
            try await db.settleEVMSend(sendID: "included", receipt: .init(hash: signed.hash, outcome: .accepted, inclusion: inclusion))
            let confirmed = try await observer.next()
            XCTAssertEqual(confirmed??.outcome, .confirmed, network.rawValue)
            let journal = try await db.send("included")
            XCTAssertEqual(journal?.state, "broadcast", "Do not release the nonce before finality")
            let work = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sendStatusChecks WHERE sendID='included'") }
            XCTAssertEqual(work, 1)
            let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
            let restored = try await reopened.sendSubmission(walletID: "w1", networkID: network.rawValue, hash: signed.hash)
            XCTAssertEqual(restored?.outcome, .confirmed)
            try await db.settleEVMSend(sendID: "included", receipt: .init(hash: signed.hash, outcome: .unknown))
            let reorg = try await observer.next()
            XCTAssertEqual(reorg??.outcome, .awaitingConfirmation)
            let reverted = EVMSendInclusion(succeeded: false, blockHash: "0x" + String(repeating: "b", count: 64), fee: 500, height: 124, timestamp: 124)
            try await db.settleEVMSend(sendID: "included", receipt: .init(hash: signed.hash, outcome: .accepted, inclusion: reverted))
            let failed = try await observer.next()
            XCTAssertEqual(failed??.outcome, .failed)
            try await db.settleEVMSend(sendID: "included", receipt: .init(hash: signed.hash, outcome: .failed, fee: 500, height: 124, timestamp: 124))
            let final = try await db.send("included")
            XCTAssertEqual(final?.state, "failed")
            let finalHash = try await db.pool.read { try String.fetchOne($0, sql: "SELECT blockHash FROM transactions WHERE id=?", arguments: [network.rawValue + ":" + signed.hash]) }
            XCTAssertNil(finalHash, "Do not retain an older block identity without final receipt evidence")
            let remaining = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sendStatusChecks WHERE sendID='included'") }
            XCTAssertEqual(remaining, 0)
        }
    }

    func testSubmissionAcknowledgementPromotesBeforeConfirmationAndSurvivesRestart() async throws {
        let (db, folder, plan) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await draft("submission", plan: plan, db: db)
        try await db.queueEVMSend(sendID: "submission", plan: plan)
        let signed = try EVMSendCrypto.sign(plan, privateKey: key)
        try await db.journalEVMSignature(sendID: "submission", signed: signed)
        var iterator = db.observeSendSubmission(walletID: "w1", networkID: plan.network.rawValue, hash: signed.hash).makeAsyncIterator()
        let signedState = try await iterator.next()
        XCTAssertEqual(signedState??.accepted, false)
        _ = try await db.transitionSend("submission", from: "signed", to: "broadcast")
        let attempted = try await iterator.next()
        XCTAssertEqual(attempted??.accepted, false, "An attempt is not acknowledgement")
        try await db.settleEVMSend(sendID: "submission", receipt: .init(hash: signed.hash, outcome: .accepted))
        let accepted = try await iterator.next()
        XCTAssertEqual(accepted??.accepted, true)
        XCTAssertEqual(accepted??.state, "broadcast", "Acceptance must not falsely confirm or release the send")
        try await db.settleEVMSend(sendID: "submission", receipt: .init(hash: signed.hash, outcome: .unknown))
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        let restored = try await reopened.sendSubmission(walletID: "w1", networkID: plan.network.rawValue, hash: signed.hash)
        XCTAssertEqual(restored?.accepted, true, "A later unknown response cannot erase acknowledgement")
        let otherWallet = try await reopened.sendSubmission(walletID: "w2", networkID: plan.network.rawValue, hash: signed.hash)
        XCTAssertNil(otherWallet)
        try await db.settleEVMSend(sendID: "submission", receipt: .init(hash: signed.hash, outcome: .failed, fee: 500, height: 123, timestamp: 123))
        let failed = try await iterator.next()
        XCTAssertEqual(failed??.state, "failed")
        XCTAssertEqual(failed??.accepted, false, "A terminal failure wins over old acknowledgement")
    }

    func testEveryAcknowledgementJournalFeedsSubmissionPresentation() async throws {
        // Presentation fixtures deliberately contain no real signed transaction.
        // Cryptographic settlement validation is covered by each chain's journal suite.
        for (network, table) in [
            ("bitcoin", "bitcoinSendPlans"), ("bitcoincash", "bitcoinSendPlans"),
            ("litecoin", "bitcoinSendPlans"), ("dogecoin", "bitcoinSendPlans"),
            ("ethereum", "evmSendPlans"), ("arc", "arcSendPlans"),
            ("aptos", "aptosSendPlans"), ("ton", "tonSendPlans"),
            ("solana", "solanaSendPlans"), ("tron", "tronSendPlans"),
            ("near", "nearSendPlans"), ("polkadot", "polkadotSendPlans"), ("thorchain", "thorchainSendPlans"),
            ("xrpl", "xrplSendPlans"), ("stellar", "stellarSendPlans"), ("sui", "suiSendPlans")
        ] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let db = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
            try await db.seed(networks: [.init(id: network, name: network, family: "account", symbol: "TEST", decimals: 8, derivationPath: "test", logo: network, sortOrder: 0)], assets: [.init(id: network + ":native", networkID: network, reference: "native", name: "Test", symbol: "TEST", decimals: 8)])
            try await db.importWalletIfNeeded(.init(id: "w", name: "Test", kind: "hd", vaultReference: "test", createdAt: 1), accounts: [.init(id: "a", walletID: "w", networkID: network, address: "test", derivationPath: "test")])
            try await db.saveDraft(.init(id: "s", walletID: "w", accountID: "a", networkID: network, assetID: network + ":native", idempotencyKey: "s", recipient: "test", amountAtomic: "1", state: "draft", createdAt: 1, updatedAt: 1))
            try await db.pool.write { sql in
                try TransactionRecord(id: network + ":hash", networkID: network, hash: "hash", state: "pending", timestamp: 1, updatedAt: 1).insert(sql)
                try sql.execute(sql: "INSERT INTO \(table)(sendID,plan) VALUES('s',X'00')")
                try sql.execute(sql: "UPDATE sends SET state='broadcast',signedPayload=X'00',transactionID=? WHERE id='s'", arguments: [network + ":hash"])
            }
            let before = try await db.sendSubmission(walletID: "w", networkID: network, hash: "hash")
            XCTAssertEqual(before?.accepted, false, network)
            if table == "bitcoinSendPlans" {
                do { try await db.acknowledgeBitcoinSend("s", hash: "wrong"); XCTFail("Wrong hash accepted") } catch {}
                try await db.acknowledgeBitcoinSend("s", hash: "hash")
                try await db.acknowledgeBitcoinSend("s", hash: "hash") // Idempotent retry.
            } else if network != "sui" {
                try await db.pool.write { try $0.execute(sql: "UPDATE \(table) SET submittedAt=1 WHERE sendID='s'") }
            } else {
                try await db.pool.write { try $0.execute(sql: "UPDATE sends SET state='confirmed' WHERE id='s'") }
            }
            let after = try await db.sendSubmission(walletID: "w", networkID: network, hash: "hash")
            XCTAssertEqual(after?.accepted, true, network)
            try await db.pool.write { try $0.execute(sql: "UPDATE sends SET state='failed' WHERE id='s'") }
            let failed = try await db.sendSubmission(walletID: "w", networkID: network, hash: "hash")
            XCTAssertEqual(failed?.accepted, false, network)
            try await db.reconcileWalletLifecycle([.init(id: "w", deletedAt: 10)])
            let deleted = try await db.sendSubmission(walletID: "w", networkID: network, hash: "hash")
            XCTAssertNil(deleted)
        }
    }
}

extension EVMSendJournalTests {
    func testReceiptKeepsObservingThroughAcknowledgementAndAllFinalOutcomes() async throws {
        for terminal: EVMSendReceipt.Outcome in [.confirmed, .failed, .cancelled, .replaced] {
            let (db, folder, plan) = try await fixture()
            defer { try? FileManager.default.removeItem(at: folder) }
            try await draft("live", plan: plan, db: db)
            try await db.queueEVMSend(sendID: "live", plan: plan)
            let signed = try EVMSendCrypto.sign(plan, privateKey: key)
            try await db.journalEVMSignature(sendID: "live", signed: signed)
            var observer = db.observeSendSubmission(walletID: "w1", networkID: plan.network.rawValue, hash: signed.hash).makeAsyncIterator()
            let initial = try await observer.next()
            XCTAssertEqual(initial??.outcome, .checking)
            try await db.settleEVMSend(sendID: "live", receipt: .init(hash: signed.hash, outcome: .accepted))
            let pending = try await observer.next()
            XCTAssertEqual(pending??.outcome, .submitted)
            let mined = terminal == .confirmed || terminal == .failed
            let replacement = mined ? nil : "0x" + String(repeating: "f", count: 64)
            try await db.settleEVMSend(sendID: "live", receipt: .init(hash: signed.hash, outcome: terminal,
                fee: mined ? 500 : nil, height: mined ? 123 : nil, timestamp: mined ? 123 : nil, replacementHash: replacement))
            let final = try await observer.next()
            let expected: SendSubmissionState.Outcome = terminal == .confirmed ? .confirmed : terminal == .failed ? .failed : terminal == .cancelled ? .cancelled : .replaced
            XCTAssertEqual(final??.outcome, expected)
            XCTAssertEqual(final??.replacementHash, replacement)
            // Reopening a screen gets the final result, not its original accepted flag.
            let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
            var newObserver = reopened.observeSendSubmission(walletID: "w1", networkID: plan.network.rawValue, hash: signed.hash).makeAsyncIterator()
            let restored = try await newObserver.next()
            XCTAssertEqual(restored??.outcome, expected)
        }
    }

    func testReceiptReorgReturnsToWaitingAndReconfirmsOnSameSubscription() async throws {
        let (db, folder, plan) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await draft("reorg", plan: plan, db: db)
        try await db.queueEVMSend(sendID: "reorg", plan: plan)
        let signed = try EVMSendCrypto.sign(plan, privateKey: key)
        try await db.journalEVMSignature(sendID: "reorg", signed: signed)
        try await db.settleEVMSend(sendID: "reorg", receipt: .init(hash: signed.hash, outcome: .confirmed, fee: 500, height: 123, timestamp: 123))
        var observer = db.observeSendSubmission(walletID: "w1", networkID: plan.network.rawValue, hash: signed.hash).makeAsyncIterator()
        let confirmed = try await observer.next()
        XCTAssertEqual(confirmed??.outcome, .confirmed)
        try await db.pool.write { try $0.execute(sql: "UPDATE transactions SET state='reorged',blockHeight=NULL WHERE hash=?", arguments: [signed.hash]) }
        let reorganized = try await observer.next()
        XCTAssertEqual(reorganized??.outcome, .awaitingConfirmation)
        let work = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sendStatusChecks WHERE sendID='reorg'") }
        XCTAssertEqual(work, 1, "A reorg must resume the existing network worker")
        try await db.settleEVMSend(sendID: "reorg", receipt: .init(hash: signed.hash, outcome: .confirmed, fee: 600, height: 124, timestamp: 124))
        let reconfirmed = try await observer.next()
        XCTAssertEqual(reconfirmed??.outcome, .confirmed)
    }

    func testReceiptExpiryAndBothCancellationSpellingsAreDistinctFromFailure() {
        XCTAssertEqual(SendSubmissionState(state: "failed", accepted: false, failureCode: "expired").outcome, .expired)
        for code in ["canceled", "cancelled"] {
            XCTAssertEqual(SendSubmissionState(state: "failed", accepted: false, failureCode: code).outcome, .cancelled)
        }
        XCTAssertEqual(SendSubmissionState(state: "failed", accepted: false, failureCode: "executionFailed").outcome, .failed)
        XCTAssertEqual(SendSubmissionState(state: "failed", accepted: false, failureCode: "replaced").outcome, .replaced)
        XCTAssertEqual(SendSubmissionState(state: "cancelled", accepted: false).outcome, .cancelled)
        XCTAssertEqual(SendSubmissionState(state: "broadcast", accepted: false).outcome, .checking)
    }
}


extension EVMSendJournalTests {
    func testForegroundAcknowledgementCannotMaskLaterFinalOrReorgState() {
        XCTAssertEqual(SendSubmissionState(state: "broadcast", accepted: false).presentationOutcome(broadcastAcknowledged: true), .submitted)
        XCTAssertEqual(SendSubmissionState(state: "broadcast", accepted: false).presentationOutcome(broadcastAcknowledged: false), .checking)
        for (code, expected): (String, SendSubmissionState.Outcome) in [("executionFailed", .failed), ("expired", .expired), ("cancelled", .cancelled), ("replaced", .replaced)] {
            XCTAssertEqual(SendSubmissionState(state: "failed", accepted: false, failureCode: code).presentationOutcome(broadcastAcknowledged: true), expected)
        }
        XCTAssertEqual(SendSubmissionState(state: "broadcast", accepted: false, awaitingConfirmation: true).presentationOutcome(broadcastAcknowledged: true), .awaitingConfirmation)
        XCTAssertEqual(SendSubmissionState(state: "confirmed", accepted: true).presentationOutcome(broadcastAcknowledged: true), .confirmed)
    }
}

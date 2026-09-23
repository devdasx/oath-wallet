import Foundation
import GRDB
import Testing
@testable import Aperture

struct SendPendingResourceTests {
    @Test(arguments: ["bitcoin", "litecoin", "bitcoin_cash", "dogecoin", "eth", "solana", "tron", "ton", "sui", "xrp", "near", "aptos", "stellar"])
    func pendingSubmissionReleasesAccountButKeepsItsResources(networkID: String) async throws {
        let database = try WalletDatabase.temporary()
        let material = try await seed(database, networkID: networkID)
        let first = try await database.acquireSendSpendReservation(material: material)
        let resource = resourceForNetwork(networkID)
        let receipt = receipt(material, hash: "first", resources: [resource])
        try await first.markSubmissionStarted(receipt: receipt)
        // No concurrent preparation is allowed until the network call exits.
        await #expect(throws: SendSpendReservationStoreError.self) {
            _ = try await database.acquireSendSpendReservation(material: material)
        }
        try await database.finishSendSpendSubmission(first)
        let second = try await database.acquireSendSpendReservation(material: material)
        #expect(second.reservationID != first.reservationID)
        #expect(try await second.pendingSpendResources().contains(resource))
        #expect(try await database.pendingSendSubmissionEvidence(accountID: material.account.id).count == 1)
    }

    @Test
    func resourcesCannotBeReusedAndFailureRollsBackAtomically() async throws {
        let database = try WalletDatabase.temporary()
        let material = try await seed(database)
        let first = try await database.acquireSendSpendReservation(material: material)
        let used = SendSpendResource.sequence("12")
        try await first.markSubmissionStarted(receipt: receipt(material, hash: "first", resources: [used]))
        try await database.finishSendSpendSubmission(first)
        let second = try await database.acquireSendSpendReservation(material: material)
        await #expect(throws: SendTransactionSubmissionError.self) {
            try await second.markSubmissionStarted(receipt: receipt(material, hash: "second", resources: [used, .sequence("13")]))
        }
        #expect(try await database.sendSpendReservationEvidence(accountID: material.account.id)?.state == .preparing)
        #expect(try await database.pendingSendSubmissionEvidence(accountID: material.account.id).count == 1)
        #expect(try await !second.pendingSpendResources().contains(.sequence("13")))
        // Rejection did not poison the next available nonce.
        #expect(try await second.nextSequence(networkValue: "12") == "13")
    }

    @Test
    func sequenceAllocationFillsGapsAndDoesNotLosePrecision() throws {
        let pending: Set<SendSpendResource> = [.sequence("9007199254740993"), .sequence("9007199254740995")]
        #expect(try SendSpendResource.nextSequence(networkValue: "9007199254740993", pending: pending) == "9007199254740994")
        #expect(try SendSpendResource.nextSequence(networkValue: "9007199254740996", pending: pending) == "9007199254740996")
        #expect(throws: SendTransactionSubmissionError.self) {
            try SendSpendResource.nextSequence(networkValue: "١٢", pending: [])
        }
    }

    @Test
    func sequenceAndTokenSendsShareOneQueue() async throws {
        let database = try WalletDatabase.temporary()
        let material = try await seed(database)
        let native = try await database.acquireSendSpendReservation(material: material)
        let nativeNonce = try await native.nextSequence(networkValue: "42")
        try await native.markSubmissionStarted(receipt: receipt(material, hash: "native", resources: [.sequence(nativeNonce)]))
        try await database.finishSendSpendSubmission(native)
        let token = try await database.acquireSendSpendReservation(material: material)
        let tokenNonce = try await token.nextSequence(networkValue: "42")
        #expect(tokenNonce == "43")
        try await token.markSubmissionStarted(receipt: receipt(material, hash: "token", resources: [.sequence(tokenNonce)]))
        try await database.finishSendSpendSubmission(token)
        #expect(try await token.nextSequence(networkValue: "42") == "44")
        // A definitively rejected send frees only its own slot; it never frees
        // a different pending transaction on the same native/token account.
        try await database.releaseSendSpendReservation(token)
        #expect(try await native.nextSequence(networkValue: "42") == "43")
    }

    @Test
    func confirmingEarlierSendCannotReleaseNewerPreparation() async throws {
        let database = try WalletDatabase.temporary()
        let material = try await seed(database)
        let first = try await database.acquireSendSpendReservation(material: material)
        let firstReceipt = receipt(material, hash: "first", resources: [.sequence("1")])
        try await first.markSubmissionStarted(receipt: firstReceipt)
        try await database.finishSendSpendSubmission(first)
        let second = try await database.acquireSendSpendReservation(material: material)
        _ = try await database.updateSubmittedSendStatus(receipt: firstReceipt, status: .confirmed)
        #expect(try await database.sendSpendReservationEvidence(accountID: material.account.id)?.reservationID == second.reservationID)
        #expect(try await second.pendingSpendResources().isEmpty)
    }

    @Test
    func duplicateSignedPayloadCannotBeReportedAsANewSend() async throws {
        let database = try WalletDatabase.temporary()
        let material = try await seed(database, networkID: "solana")
        let first = try await database.acquireSendSpendReservation(material: material)
        let same = receipt(material, hash: "SameCaseSensitiveSignature", resources: [.init(kind: .transactionID, value: "SameCaseSensitiveSignature")])
        try await first.markSubmissionStarted(receipt: same)
        try await database.finishSendSpendSubmission(first)
        let second = try await database.acquireSendSpendReservation(material: material)
        await #expect(throws: SendTransactionSubmissionError.self) {
            try await second.markSubmissionStarted(receipt: same)
        }
    }

    @Test
    func suiObjectVersionCanAdvanceWhileOldVersionRemainsReserved() async throws {
        let database = try WalletDatabase.temporary()
        let material = try await seed(database, networkID: "sui")
        let first = try await database.acquireSendSpendReservation(material: material)
        let object = SuiCoinObject(objectID: "0x123", version: 9, digest: "old", atomicBalance: 1000)
        let next = SuiCoinObject(objectID: "0x123", version: 10, digest: "new", atomicBalance: 800)
        try await first.markSubmissionStarted(receipt: receipt(material, hash: "digest", resources: [.object(object)]))
        try await database.finishSendSpendSubmission(first)
        let pending = try await first.pendingSpendResources()
        #expect(pending.contains(.object(object)))
        #expect(!pending.contains(.object(next)))
    }

    @Test
    func relaunchRetainsUnknownSpendEvidenceButAllowsIndependentSend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let material: SendResolvedSigningMaterial
        do {
            let database = try WalletDatabase.applicationDatabase(at: directory)
            material = try await seed(database)
            let first = try await database.acquireSendSpendReservation(material: material)
            // Simulate process exit after first network byte, even before saving
            // a local activity record or receiving the provider's response.
            try await first.markSubmissionStarted(receipt: receipt(material, hash: "unknown", resources: [.sequence("7")]))
        }
        let reopened = try WalletDatabase.applicationDatabase(at: directory)
        let second = try await reopened.acquireSendSpendReservation(material: material)
        #expect(try await second.nextSequence(networkValue: "7") == "8")
        #expect(try await reopened.pendingSendSubmissionEvidence(accountID: material.account.id).first?.transactionHash == "unknown")
    }

    @Test
    func legacyEvidenceRequiresExactHydrationBeforeUnlocking() async throws {
        let database = try WalletDatabase.temporary()
        let material = try await seed(database, networkID: "bitcoin")
        let first = try await database.acquireSendSpendReservation(material: material)
        var legacy = receipt(material, hash: "legacy", resources: [])
        try await first.markSubmissionStarted(receipt: legacy)
        try await database.finishSendSpendSubmission(first)
        await #expect(throws: SendSpendReservationStoreError.self) {
            _ = try await database.acquireSendSpendReservation(material: material)
        }
        // Adopt only exact matching transaction evidence; no schema data loss.
        legacy.spendResources = [.init(kind: .outpoint, value: "parent:0")]
        try await database.markSendSpendSubmissionStarted(reservation: first, receipt: legacy)
        try await database.finishSendSpendSubmission(first)
        let next = try await database.acquireSendSpendReservation(material: material)
        #expect(try await next.pendingSpendResources().contains(.init(kind: .outpoint, value: "parent:0")))
    }

    @Test
    func removalCascadesAndStaleReservationCannotInsertClaims() async throws {
        let database = try WalletDatabase.temporary()
        let material = try await seed(database)
        let first = try await database.acquireSendSpendReservation(material: material)
        try await database.releaseSendSpendReservation(first)
        await #expect(throws: SendSpendReservationStoreError.self) {
            try await database.markSendSpendSubmissionStarted(reservation: first, receipt: receipt(material, hash: "stale", resources: [.sequence("1")]))
        }
        #expect(try await first.pendingSpendResources().isEmpty)
        let next = try await database.acquireSendSpendReservation(material: material)
        try await next.markSubmissionStarted(receipt: receipt(material, hash: "next", resources: [.sequence("1")]))
        try await database.pool.write { db in
            try db.execute(sql: "DELETE FROM wallets WHERE id = ?", arguments: [material.walletID])
        }
        #expect(try await next.pendingSpendResources().isEmpty)
    }

    private func resourceForNetwork(_ networkID: String) -> SendSpendResource {
        if BitcoinFamilyChain(rawValue: networkID) != nil {
            return .init(kind: .outpoint, value: "parent:1")
        }
        if networkID == "sui" { return .init(kind: .objectVersion, value: "object:1") }
        if ["solana", "tron"].contains(networkID) { return .init(kind: .transactionID, value: "first") }
        return .sequence("1")
    }

    private func receipt(_ material: SendResolvedSigningMaterial, hash: String, resources: Set<SendSpendResource>) -> SendTransactionReceipt {
        SendTransactionReceipt(
            transactionHash: hash, accountID: material.account.id, networkID: material.account.networkID,
            fromAddress: material.account.address, toAddress: "recipient", assetID: "", assetSymbol: "",
            amount: "0", amountAtomic: "0", networkFee: nil, networkFeeAtomic: nil,
            networkFeeSymbol: "", submittedAt: Date(), spendResources: resources
        )
    }

    private func seed(_ database: WalletDatabase, networkID: String = "eth") async throws -> SendResolvedSigningMaterial {
        let walletID = UUID().uuidString
        let now = Date().timeIntervalSince1970
        let account = DBWalletAccountRecord(
            id: UUID().uuidString, walletID: walletID, networkID: networkID,
            address: "0x0000000000000000000000000000000000000001",
            normalizedAddress: "0x0000000000000000000000000000000000000001",
            label: nil, derivationPath: "m/44'/60'/0'/0/0", accountIndex: 0, publicKey: nil,
            isWatchOnly: false, isEnabled: true, createdAt: now, updatedAt: now, lastSyncedAt: nil
        )
        try await database.pool.write { db in
            try DBWalletRecord(
                id: walletID, profileID: WalletDatabase.defaultProfileID,
                name: "Fixture", kind: DatabaseWalletKind.created.rawValue, secretKeyReference: nil,
                isSelected: true, sortOrder: 0, createdAt: now, updatedAt: now, lastOpenedAt: now, archivedAt: nil
            ).insert(db)
            try account.insert(db)
        }
        return SendResolvedSigningMaterial(walletID: walletID, account: account, privateKey: Data(repeating: 1, count: 32))
    }
}

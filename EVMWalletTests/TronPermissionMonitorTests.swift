import Foundation
import GRDB
import Testing
import SwiftUI
import UIKit
@testable import Aperture

@Suite(.timeLimit(.minutes(1)))
struct TronPermissionMonitorTests {
    static let address = "TDqGdq76PDHrEXfEPMmNa2ayc7E4PKzfS1"
    static let other = "TUYootsUdz2v76orGP8an3L3La5ntszq83"

    @Test(arguments: ["{}", "{\"address\":\"TDqGdq76PDHrEXfEPMmNa2ayc7E4PKzfS1\"}"])
    func inactiveAndDefaultAccountsNeverWarn(json: String) throws {
        #expect(try !TronAccountPermissions.decode(Data(json.utf8), expectedAddress: Self.address).isRestricted)
    }

    @Test(arguments: [(Int64(1), Int64(1), Int64(1), false),
                      (2, 1, 1, true), (3, 2, 1, true), (2, 2, 1, false),
                      (9_007_199_254_740_993, 9_007_199_254_740_992, 1, true)])
    func thresholdAndWeightsAreExact(input: (Int64, Int64, Int64, Bool)) throws {
        let (threshold, first, second, expected) = input
        let data = try Self.account(threshold: threshold, weights: [first, second])
        let result = try TronAccountPermissions.decode(data, expectedAddress: Self.address)
        #expect(result.isRestricted == expected)
    }

    /// A single-key owner permission is still a takeover when that key is not ours.
    @Test
    func ownerPermissionMovedToAnotherKeyIsRestricted() throws {
        let data = try Self.account(threshold: 1, weights: [1], addresses: [Self.other])
        #expect(try TronAccountPermissions.decode(data, expectedAddress: Self.address).restrictedPermissionIDs == [0])
    }

    /// The live node response for an account whose owner and active permissions
    /// had all been moved to other keys. Every permission is single-key, so the
    /// old threshold rule called it healthy; its own key can sign nothing.
    @Test
    func takenOverAccountWithSingleKeyPermissionsIsRestricted() throws {
        let json = """
        {"address":"TDTcR8wBLadFYRekvobSSswHaj351EDNRT","owner_permission":{"permission_name":"Gana","threshold":1,"keys":[{"address":"TGxZme1LvLVqvPhbxF1en2kSsjeNGg6pNA","weight":1}]},"active_permission":[{"type":"Active","id":2,"permission_name":"active","threshold":1,"operations":"77ff07c0027e0300000000000000000000000000000000000000000000000000","keys":[{"address":"TGxZme1LvLVqvPhbxF1en2kSsjeNGg6pNA","weight":1}]},{"type":"Active","id":3,"permission_name":"Trans","threshold":1,"operations":"0200000000000000000000000000000000000000000000000000000000000000","keys":[{"address":"TC9Uxqske88JV7fKRp8LxmPUc2diFTgSNx","weight":1}]}]}
        """
        let result = try TronAccountPermissions.decode(
            Data(json.utf8), expectedAddress: "TDTcR8wBLadFYRekvobSSswHaj351EDNRT"
        )
        #expect(result.isActivated)
        #expect(result.restrictedPermissionIDs == [0])
    }

    /// Delegating an active permission to another key is legitimate while the
    /// owner permission stays with this wallet.
    @Test
    func delegatedActivePermissionWithOwnerIntactIsNotRestricted() throws {
        var object = try JSONSerialization.jsonObject(with: Self.account(threshold: 1, weights: [1])) as! [String: Any]
        object["active_permission"] = [[
            "id": 2, "type": "Active", "threshold": 1,
            "operations": "0200000000000000000000000000000000000000000000000000000000000000",
            "keys": [["address": Self.other, "weight": 1]]
        ]]
        let result = try TronAccountPermissions.decode(JSONSerialization.data(withJSONObject: object), expectedAddress: Self.address)
        #expect(!result.isRestricted)
    }

    @Test
    func activeMultisigIsDetectedWithoutClaimingOwnerIsBlocked() throws {
        var object = try JSONSerialization.jsonObject(with: Self.account(threshold: 1, weights: [1])) as! [String: Any]
        object["active_permission"] = [[
            "id": 2, "type": "Active", "threshold": 2,
            "operations": "7fff1fc0033e0300000000000000000000000000000000000000000000000000",
            "keys": [["address": Self.address, "weight": 1], ["address": Self.other, "weight": 1]]
        ]]
        let result = try TronAccountPermissions.decode(JSONSerialization.data(withJSONObject: object), expectedAddress: Self.address)
        #expect(result.restrictedPermissionIDs == [2])
    }

    @Test(arguments: ["{\"Error\":\"rate limit\"}", "{\"address\":\"invalid\"}",
                      "{\"address\":\"TDqGdq76PDHrEXfEPMmNa2ayc7E4PKzfS1\",\"owner_permission\":{}}"])
    func invalidOrIncompleteResponsesRemainUnknown(json: String) {
        #expect(throws: SendTransactionSubmissionError.self) {
            try TronAccountPermissions.decode(Data(json.utf8), expectedAddress: Self.address)
        }
    }

    @Test
    func invalidWeightsKeysAndOperationMasksAreRejected() throws {
        for data in [
            try Self.account(threshold: 3, weights: [1, 1]),
            try Self.account(threshold: 0, weights: [1]),
            try Self.account(threshold: 2, weights: [1, 1], addresses: [Self.address, Self.address]),
            try Self.account(threshold: 1, weights: [0]),
            try Self.account(threshold: Int64.max, weights: [Int64.max, 1])
        ] {
            #expect(throws: SendTransactionSubmissionError.self) {
                try TronAccountPermissions.decode(data, expectedAddress: Self.address)
            }
        }
        let data = try Self.account(threshold: 2, weights: [1, 1])
        #expect(throws: SendTransactionSubmissionError.self) {
            try TronAccountPermissions.decode(data, expectedAddress: Self.other)
        }
    }

    @Test(arguments: ["created", "watchOnly", "hardware"])
    func excludedWalletsNeverContactProvider(kind: String) async throws {
        let (db, _) = try await Self.database(kind: kind)
        let monitor = TronPermissionMonitor { _ in
            Issue.record("Excluded wallet contacted TRON permission provider")
            return try Self.multisig()
        }
        #expect(await monitor.check(database: db, displayedAddress: Self.address) == nil)
        #expect(try await db.pool.read { try TronPermissionCheckRecord.fetchCount($0) } == 0)
    }

    @Test(arguments: ["importedRecoveryPhrase", "importedPrivateKey"])
    func importedWalletsPersistOnlyVerifiedMultisig(kind: String) async throws {
        let (db, id) = try await Self.database(kind: kind)
        let monitor = TronPermissionMonitor { address in
            #expect(address == Self.address)
            return try Self.multisig()
        }
        let result = await monitor.check(database: db, displayedAddress: Self.address)
        #expect(result?.showsWarning == true)
        #expect(result?.walletID == id)
        #expect(try await db.pool.read { try TronPermissionCheckRecord.fetchOne($0, key: id) } == result)
    }

    @Test
    func confirmedMultisigSurvivesRefreshAndNewMonitorWithoutAnotherRequest() async throws {
        let (db, id) = try await Self.database()
        let initial = await TronPermissionMonitor { _ in try Self.multisig() }
            .check(database: db, displayedAddress: Self.address)
        let monitor = TronPermissionMonitor { _ in
            Issue.record("Confirmed multisig must not contact the provider again")
            throw URLError(.timedOut)
        }
        for _ in 0..<3 {
            #expect(await monitor.check(database: db, displayedAddress: Self.address) == initial)
        }
        #expect(try await db.confirmedTronCheck(walletID: id) == initial)
        let laterFailure = TronPermissionCheckRecord(walletID: id, address: Self.address,
            checkedAt: Date().timeIntervalSince1970 + 100, state: "unknown",
            permissionIDsJSON: "[]", failureCode: "timeout")
        #expect(try await !db.storeTronPermissionCheck(laterFailure))
        #expect(try await db.confirmedTronCheck(walletID: id) == initial)
    }

    @Test
    func unsuccessfulCheckIsRetriedAndCannotRestrictActions() async throws {
        let (db, id) = try await Self.database()
        #expect(await TronPermissionMonitor { _ in throw URLError(.timedOut) }
            .check(database: db, displayedAddress: Self.address) == nil)
        #expect(try await db.confirmedTronCheck(walletID: id) == nil)
        let result = await TronPermissionMonitor { _ in try Self.multisig() }
            .check(database: db, displayedAddress: Self.address)
        #expect(result?.showsWarning == true)
    }

    @Test
    func suspendedNetworkLeavesMainActorFreeAndCancellationDoesNotPublish() async throws {
        let (db, _) = try await Self.database()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let monitor = TronPermissionMonitor { _ in
            started.continuation.finish()
            for await _ in release.stream {}
            return try Self.multisig()
        }
        let task = Task { await monitor.check(database: db, displayedAddress: Self.address) }
        for await _ in started.stream {}
        // A real main-actor hop completes while the provider is suspended.
        await MainActor.run { #expect(true) }
        task.cancel()
        release.continuation.finish()
        #expect(await task.value == nil)
        #expect(try await db.pool.read { try TronPermissionCheckRecord.fetchCount($0) } == 0)
    }

    @Test
    func switchingWalletRejectsLatePresentationAndDeletionCascades() async throws {
        let (db, id) = try await Self.database()
        let monitor = TronPermissionMonitor { _ in
            try await db.pool.write { database in
                try database.execute(sql: "UPDATE wallets SET isSelected = 0 WHERE id = ?", arguments: [id])
            }
            return try Self.multisig()
        }
        #expect(await monitor.check(database: db, displayedAddress: Self.address) == nil)
        try await db.pool.write { database in
            try database.execute(sql: "DELETE FROM wallets WHERE id = ?", arguments: [id])
        }
        #expect(try await db.pool.read { try TronPermissionCheckRecord.fetchCount($0) } == 0)
    }

    @Test
    func liveMainnetPermissionRequestsUseProductionClient() async throws {
        let client = SendTronAPIClient()
        for address in [Self.address, "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"] {
            let started = ContinuousClock.now
            let result = try await client.accountPermissions(address: address)
            #expect(result.address == address)
            #expect(result.isActivated)
            print("Mainnet TRON permission read completed in \(started.duration(to: .now))")
        }
    }

    @Test
    func normalImportedAccountDoesNotRestrictActionsAndMayBeCheckedAgain() async throws {
        let (db, id) = try await Self.database()
        let normal = await TronPermissionMonitor { _ in
            try .decode(Self.account(threshold: 1, weights: [1]), expectedAddress: Self.address)
        }.check(database: db, displayedAddress: Self.address)
        #expect(normal?.state == "single")
        #expect(try await db.confirmedTronCheck(walletID: id) == nil)
        let changed = await TronPermissionMonitor { _ in try Self.multisig() }
            .check(database: db, displayedAddress: Self.address)
        #expect(changed?.showsWarning == true)
    }

    @Test
    func confirmedFindingNeverAppliesToDifferentAddressOrCreatedWallet() async throws {
        let (db, id) = try await Self.database()
        _ = await TronPermissionMonitor { _ in try Self.multisig() }
            .check(database: db, displayedAddress: Self.address)
        try await db.pool.write { database in
            try database.execute(sql: "UPDATE wallets SET kind = 'created' WHERE id = ?", arguments: [id])
        }
        #expect(try await db.confirmedTronCheck(walletID: id) == nil)
        try await db.pool.write { database in
            try database.execute(sql: "UPDATE wallets SET kind = 'importedRecoveryPhrase' WHERE id = ?", arguments: [id])
            try database.execute(sql: "UPDATE walletAccounts SET address = ? WHERE walletID = ?", arguments: [Self.other, id])
        }
        #expect(try await db.confirmedTronCheck(walletID: id) == nil)
    }

    @Test
    func errorsAndIncompleteRecordsNeverRestrictActions() {
        let bad = TronPermissionCheckRecord(walletID: "A", address: Self.address,
            checkedAt: 1, state: "multisignature", permissionIDsJSON: "[0]", failureCode: "error")
        let empty = TronPermissionCheckRecord(walletID: "A", address: Self.address,
            checkedAt: 1, state: "multisignature", permissionIDsJSON: "[]", failureCode: nil)
        #expect(!bad.showsWarning)
        #expect(!empty.showsWarning)
    }

    @Test
    func nonTronPrivateKeyAndWrongDisplayedWalletNeverContactProvider() async throws {
        let (db, _) = try await Self.database(kind: "importedPrivateKey", network: "bitcoin")
        let monitor = TronPermissionMonitor { _ in
            Issue.record("A non-TRON or unrelated wallet must not query permissions")
            return try Self.multisig()
        }
        #expect(await monitor.check(database: db, displayedAddress: Self.address) == nil)
        let (tronDB, _) = try await Self.database()
        #expect(await monitor.check(database: tronDB, displayedAddress: Self.other) == nil)
    }

    @Test
    func olderObservationCannotOverwriteNewerPermissions() async throws {
        let (db, id) = try await Self.database()
        let new = TronPermissionCheckRecord(walletID: id, address: Self.address,
            checkedAt: 2, state: "single", permissionIDsJSON: "[]", failureCode: nil)
        let old = TronPermissionCheckRecord(walletID: id, address: Self.address,
            checkedAt: 1, state: "multisignature", permissionIDsJSON: "[0]", failureCode: nil)
        #expect(try await db.storeTronPermissionCheck(new))
        #expect(try await !db.storeTronPermissionCheck(old))
        #expect(try await db.pool.read { try TronPermissionCheckRecord.fetchOne($0, key: id) } == new)
    }

    @Test
    func malformedActivePermissionDoesNotProducePartialFinding() throws {
        var object = try JSONSerialization.jsonObject(with: Self.account(threshold: 2, weights: [1, 1])) as! [String: Any]
        object["active_permission"] = [["id": 2, "type": "Active", "threshold": 1,
            "operations": "ff", "keys": [["address": Self.address, "weight": 1]]]]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: SendTransactionSubmissionError.self) {
            try TronAccountPermissions.decode(data, expectedAddress: Self.address)
        }
    }

    @Test
    func renderTimeWalletMatchHidesPreviousWarningBeforeTaskRestarts() {
        let record = TronPermissionCheckRecord(walletID: "imported-A", address: Self.address,
            checkedAt: 1, state: "multisignature", permissionIDsJSON: "[0]", failureCode: nil)
        #expect(record.showsWarning(for: "imported-A"))
        #expect(!record.showsWarning(for: "created-B"))
        #expect(!record.showsWarning(for: nil))
    }

    @MainActor
    @Test(.serialized, arguments: [NativeListTestLayout.phone, .pad, .largeTextRTL])
    func nativeTransferControlsRespectConfirmedRestriction(layout: NativeListTestLayout) async throws {
        for restricted in [true, false] {
            let host = try NativeListTestHost(layout: layout) {
                NavigationStack {
                    Text("settings.title")
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("wallet.home.action.send") {}
                                    .walletTransferAction()
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("wallet.home.action.receive") {}
                                    .walletTransferAction()
                            }
                        }
                }
                .environment(\.walletMultisigRestricted, restricted)
            }
            defer { host.close() }
            try await SendEntryUIProbe.wait(in: host.rootView) {
                host.navigationController?.topViewController?.navigationItem.leadingItemGroups
                    .first?.barButtonItems.first != nil
            }
            let item = try #require(host.navigationController?.topViewController?.navigationItem)
            let send = try #require(item.leadingItemGroups.first?.barButtonItems.first)
            let receive = try #require(item.trailingItemGroups.first?.barButtonItems.first)
            #expect(send.isEnabled == !restricted)
            #expect(receive.isEnabled == !restricted)
        }
    }

    private static func multisig() throws -> TronAccountPermissions {
        try .decode(account(threshold: 2, weights: [1, 1]), expectedAddress: address)
    }

    private static func account(threshold: Int64, weights: [Int64], addresses: [String] = [address, other]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "address": address,
            "owner_permission": ["threshold": threshold,
                "keys": zip(addresses, weights).map { ["address": $0.0, "weight": $0.1] as [String: Any] }]
        ])
    }

    private static func database(kind: String = "importedRecoveryPhrase", network: String = "tron") async throws -> (WalletDatabase, String) {
        let db = try WalletDatabase.temporary()
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        try await db.pool.write { database in
            try DBWalletRecord(id: id, profileID: WalletDatabase.defaultProfileID,
                name: "Permission Fixture", kind: kind, secretKeyReference: nil,
                isSelected: true, sortOrder: 0, createdAt: now, updatedAt: now,
                lastOpenedAt: now, archivedAt: nil).insert(database)
            try DBWalletAccountRecord(id: "\(id):tron:0", walletID: id, networkID: network,
                address: address, normalizedAddress: address, label: nil,
                derivationPath: "m/44'/195'/0'/0/0", accountIndex: 0, publicKey: "fixture-public-key",
                isWatchOnly: false, isEnabled: true, createdAt: now, updatedAt: now,
                lastSyncedAt: nil).insert(database)
        }
        return (db, id)
    }
}

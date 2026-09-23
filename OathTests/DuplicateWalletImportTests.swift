import GRDB
import Foundation
import Testing
@testable import Aperture

struct DuplicateWalletImportTests {
    @Test
    func recoveryPhraseMatchesAnExistingSecretBackedWallet()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let draft = try WalletCoreService.importRecoveryPhrase(
            "abandon abandon abandon abandon abandon abandon "
                + "abandon abandon abandon abandon abandon about"
        )
        try await insertWallet(
            id: "created-wallet",
            kind: .created,
            isSelected: true,
            networkID: PrivateKeyImportNetwork.evm.networkID,
            address: draft.address,
            normalizedAddress: draft.normalizedAddress,
            database: database
        )

        let duplicate = try await database.existingWallet(
            matching: draft
        )

        #expect(duplicate?.id == "created-wallet")
        #expect(duplicate?.isSelected == true)
        #expect(duplicate?.address == draft.address)
    }

    @Test
    func selectedDuplicateWinsWhenAnOlderDuplicateIsInactive()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let draft = try WalletCoreService.importRecoveryPhrase(
            "legal winner thank year wave sausage worth useful "
                + "legal winner thank yellow"
        )
        try await insertWallet(
            id: "older-inactive-wallet",
            kind: .importedRecoveryPhrase,
            isSelected: false,
            networkID: PrivateKeyImportNetwork.evm.networkID,
            address: draft.address,
            normalizedAddress: draft.normalizedAddress,
            createdAt: 1,
            database: database
        )
        try await insertWallet(
            id: "current-wallet",
            kind: .importedRecoveryPhrase,
            isSelected: true,
            networkID: PrivateKeyImportNetwork.evm.networkID,
            address: draft.address,
            normalizedAddress: draft.normalizedAddress,
            createdAt: 2,
            database: database
        )

        let duplicate = try await database.existingWallet(
            matching: draft
        )

        #expect(duplicate?.id == "current-wallet")
    }

    @Test
    func privateKeyRequiresTheMatchingImportNetwork()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let draft = try PrivateKeyImportService.importKey(
            String(repeating: "0", count: 63) + "1",
            network: .evm
        )
        try await insertWallet(
            id: "wrong-network-wallet",
            kind: .importedPrivateKey,
            isSelected: true,
            networkID: TronConstants.networkID,
            address: draft.address,
            normalizedAddress: draft.normalizedAddress,
            database: database
        )

        let duplicate = try await database.existingWallet(
            matching: draft
        )

        #expect(duplicate == nil)
    }

    @Test
    func privateKeyMatchesAnExistingWalletOnTheSameNetwork()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let draft = try PrivateKeyImportService.importKey(
            String(repeating: "0", count: 63) + "1",
            network: .evm
        )
        try await insertWallet(
            id: "existing-private-key-wallet",
            kind: .importedPrivateKey,
            isSelected: false,
            networkID: PrivateKeyImportNetwork.evm.networkID,
            address: draft.address,
            normalizedAddress: draft.normalizedAddress,
            database: database
        )

        let duplicate = try await database.existingWallet(
            matching: draft
        )

        #expect(duplicate?.id == "existing-private-key-wallet")
        #expect(duplicate?.isSelected == false)
    }

    @Test
    func watchOnlyWalletDoesNotBlockASecretImport() async throws {
        let database = try WalletDatabase.temporary()
        let draft = try WalletCoreService.importRecoveryPhrase(
            "letter advice cage absurd amount doctor acoustic "
                + "avoid letter advice cage above"
        )
        try await insertWallet(
            id: "watch-only-wallet",
            kind: .watchOnly,
            isSelected: true,
            networkID: PrivateKeyImportNetwork.evm.networkID,
            address: draft.address,
            normalizedAddress: draft.normalizedAddress,
            database: database
        )

        let duplicate = try await database.existingWallet(
            matching: draft
        )

        #expect(duplicate == nil)
    }

    private func insertWallet(
        id: String,
        kind: ManagedWalletKind,
        isSelected: Bool,
        networkID: String,
        address: String,
        normalizedAddress: String,
        createdAt: Double = Date().timeIntervalSince1970,
        database: WalletDatabase
    ) async throws {
        try await database.pool.write { connection in
            try DBWalletRecord(
                id: id,
                profileID: WalletDatabase.defaultProfileID,
                name: id,
                kind: kind.rawValue,
                secretKeyReference: "opaque-test-reference",
                isSelected: isSelected,
                sortOrder: 0,
                createdAt: createdAt,
                updatedAt: createdAt,
                lastOpenedAt: nil,
                archivedAt: nil
            ).insert(connection)
            try DBWalletAccountRecord(
                id: "\(id):\(networkID):0",
                walletID: id,
                networkID: networkID,
                address: address,
                normalizedAddress: normalizedAddress,
                label: nil,
                derivationPath: nil,
                accountIndex: 0,
                publicKey: "test-public-key",
                isWatchOnly: kind == .watchOnly,
                isEnabled: true,
                createdAt: createdAt,
                updatedAt: createdAt,
                lastSyncedAt: nil
            ).insert(connection)
        }
    }
}

import Foundation
import OathDatabase
import OathBitcoin

/// Exercise the production receive resolver against a real temporary SQLite
/// database, including a reopened pool and an unavailable vault fallback.
/// Fixed test material only; no device, Keychain, wallet credentials or network.
enum CheckReceivePreparation {
    enum Failure: Error { case unexpectedVaultAccess }

    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oath-receive-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.sqlite")
        let db = try await OathDatabase.open(at: url)
        for network in UTXONetwork.allCases {
            let id = network.rawValue
            try await db.seed(networks: [.init(id: id, name: id, family: "utxo", symbol: id,
                decimals: 8, derivationPath: "fixture", logo: id, sortOrder: 0)], assets: [
                    .init(id: id + ":native", networkID: id, reference: "native", name: id, symbol: id, decimals: 8)])
            let descriptor = try network.wallet(seed: Data(0..<32))
            let original = try BitcoinKeys.addresses(branch: descriptor.branches[0], range: 0..<1)[0]
            try await db.importWalletIfNeeded(.init(id: id, name: "Fixture", kind: "hd", vaultReference: "fixture-" + id, createdAt: 1),
                accounts: [.init(id: id, walletID: id, networkID: id, address: original.address, derivationPath: original.path)])
            let first = try await OathReceivePreparation.bitcoin(database: db, accountID: id, walletID: id, network: network) {
                try await db.prepareBitcoin(accountID: id, descriptor: descriptor)
            }
            precondition(first.state.descriptor == descriptor)
            let type = descriptor.types.first(where: { $0 != first.state.preferredType }) ?? first.state.preferredType
            let selected = try await OathReceivePreparation.bitcoin(database: db, accountID: id, walletID: id, network: network, type: type) {
                throw Failure.unexpectedVaultAccess
            }
            precondition(selected.state.preferredType == type)
            let reopened = try await OathDatabase.open(at: url)
            let start = ContinuousClock.now
            let again = try await OathReceivePreparation.bitcoin(database: reopened, accountID: id, walletID: id, network: network) {
                throw Failure.unexpectedVaultAccess
            }
            print("Host prepared \(id) receive after database reopen: \(start.duration(to: .now))")
            precondition(again.address == selected.address && again.state.preferredType == type,
                         "Reopening must retain the preferred type and unused address without entering the vault")
            do {
                _ = try await OathReceivePreparation.bitcoin(database: reopened, accountID: id, walletID: "different-wallet", network: network) {
                    throw Failure.unexpectedVaultAccess
                }
                preconditionFailure("Foreign wallet metadata must not resolve")
            } catch StoreError.conflictingIdentity { }
        }

        let phantom = SolanaReceiveAddress(path: "m/44'/501'/0'/0'", address: "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk")
        let trust = SolanaReceiveAddress(path: "m/44'/501'/0'", address: "GjJyeC1r2RgkuoCWMyPYkCWSGSGLcz266EaAkLA27AhL")
        try await db.seed(networks: [.init(id: "solana", name: "Solana", family: "account", symbol: "SOL", decimals: 9,
            derivationPath: trust.path, logo: "solana", sortOrder: 0)], assets: [
                .init(id: "solana:native", networkID: "solana", reference: "native", name: "Solana", symbol: "SOL", decimals: 9)])
        try await db.importWalletIfNeeded(.init(id: "solana", name: "Fixture", kind: "hd", vaultReference: "fixture-solana", createdAt: 1),
            accounts: [.init(id: "solana", walletID: "solana", networkID: "solana", address: trust.address, derivationPath: trust.path)])
        let first = try await OathReceivePreparation.solana(database: db, accountID: "solana", walletID: "solana") {
            try await db.prepareSolanaReceive(accountID: "solana", addresses: [phantom, trust], preferredPath: phantom.path)
        }
        precondition(first.selected == phantom, "First preparation uses the actual derived preference, not the old profile")
        let changed = try await OathReceivePreparation.solana(database: db, accountID: "solana", walletID: "solana", path: trust.path) {
            throw Failure.unexpectedVaultAccess
        }
        precondition(changed.selected == trust)
        let reopened = try await OathDatabase.open(at: url)
        let start = ContinuousClock.now
        let again = try await OathReceivePreparation.solana(database: reopened, accountID: "solana", walletID: "solana") {
            throw Failure.unexpectedVaultAccess
        }
        print("Host prepared Solana receive after database reopen: \(start.duration(to: .now))")
        precondition(again.selected == trust)
        do {
            _ = try await OathReceivePreparation.solana(database: db, accountID: "solana", walletID: "different-wallet") {
                throw Failure.unexpectedVaultAccess
            }
            preconditionFailure("Foreign wallet metadata must not resolve")
        } catch StoreError.conflictingIdentity { }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OathReceivePreparation.solana(database: db, accountID: "solana", walletID: "solana", path: phantom.path) {
                throw Failure.unexpectedVaultAccess
            }
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancelled receive must not change the path") }
        catch is CancellationError { }
        let unchanged = try await db.solanaReceiveState(accountID: "solana")
        precondition(unchanged?.selected == trust)
        print("Passed receive preparation: four UTXO networks and Solana, first setup, reopened metadata, persisted choices, wallet isolation and cancellation. Vault fallback is forbidden for every prepared read.")
    }
}

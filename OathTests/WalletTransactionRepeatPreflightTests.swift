import Foundation
import GRDB
import Testing
@testable import Aperture

struct WalletTransactionRepeatPreflightTests {
    @Test(arguments: ["0", "99000", "100000", "200000"])
    func stalePortfolioUsesCurrentSpendableOutputs(available: String) async throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84], value: 1_000_000)
        let draft = fixture.draft(options: .automatic, usesMaximumBalance: false)
        let database = try await database(for: draft)
        let outputs = available == "0" ? [] : [output(value: available, owner: fixture.owners[0])]
        let estimator = SendNetworkFeeEstimator(database: database, bitcoinOutputLoader: { _, _, _, _, _ in
            outputs
        })
        let preflight = WalletTransactionRepeatPreflight { candidate in
            try await estimator.validateBitcoinFunds(
                draft: candidate, fee: BitcoinOPReturnSigningFixture.fee()
            )
        }
        let failure = await preflight.failure(for: plan(draft))
        if available == "200000" {
            #expect(failure == nil)
        } else {
            // 100000 sats covers the amount but cannot also pay the fee.
            #expect(failure == .insufficientBalance || failure == .insufficientNetworkFeeBalance)
            #expect(failure?.localizedTitle == WalletLocalization.string(
                "wallet.transaction.details.repeat.insufficient.title"
            ))
        }
    }

    @Test
    func pendingSpentOutputCannotFundARepeat() async throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84], value: 1_000_000)
        let draft = fixture.draft(options: .automatic, usesMaximumBalance: false)
        let database = try await database(for: draft)
        let spent = output(value: "1000000", owner: fixture.owners[0])
        let estimator = SendNetworkFeeEstimator(database: database, bitcoinOutputLoader: { _, _, _, _, _ in
            SendSpendResource.availableBitcoinOutputs(
                [spent], excluding: [.init(kind: .outpoint, value: spent.id)]
            )
        })
        let preflight = WalletTransactionRepeatPreflight { candidate in
            try await estimator.validateBitcoinFunds(
                draft: candidate, fee: BitcoinOPReturnSigningFixture.fee()
            )
        }
        #expect(await preflight.failure(for: plan(draft)) == .insufficientBalance)
    }

    @Test
    func customTotalFeeStillChecksAvailableFunds() async throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84], value: 1_000_000)
        let draft = fixture.draft(options: .automatic, usesMaximumBalance: false)
        let database = try await database(for: draft)
        let available = output(value: "200000", owner: fixture.owners[0])
        let estimator = SendNetworkFeeEstimator(database: database, bitcoinOutputLoader: { _, _, _, _, _ in
            [available]
        })
        let preflight = WalletTransactionRepeatPreflight { candidate in
            try await estimator.validateBitcoinFunds(
                draft: candidate,
                fee: .init(model: .utxoPerVByte, primaryValue: "2", secondaryValue: nil,
                           totalBudgetAtomic: "150000")
            )
        }
        let failure = await preflight.failure(for: plan(draft))
        #expect(failure == .insufficientBalance || failure == .insufficientNetworkFeeBalance)
    }

    @Test
    func providerFailureKeepsItsCauseInTheDialog() async throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84], value: 1_000_000)
        let error = SendBitcoinUTXORepositoryError.provider("rpc_error_503")
        let preflight = WalletTransactionRepeatPreflight { _ in throw error }
        let failure = await preflight.failure(for: plan(fixture.draft(options: .automatic, usesMaximumBalance: false)))
        #expect(failure == .preflightFailed(message: error.localizedMessage))
    }

    @Test
    func cancellationCannotPresentSend() async throws {
        let fixture = try BitcoinOPReturnSigningFixture(types: [.bip84], value: 1_000_000)
        let preflight = WalletTransactionRepeatPreflight { _ in throw CancellationError() }
        #expect(await preflight.failure(for: plan(fixture.draft(options: .automatic, usesMaximumBalance: false))) == .presentationUnavailable)
    }

    private func plan(_ draft: SendDraft) -> WalletTransactionRepeatPlan {
        .init(draft: draft, walletAsset: WalletAsset(
            id: draft.asset.id, name: draft.asset.name, symbol: draft.asset.symbol,
            logoSource: draft.asset.logoSource, network: draft.asset.blockchain,
            balance: draft.asset.balance, fiatValue: draft.asset.fiatValue
        ))
    }

    private func output(value: String, owner: BitcoinHDDerivedAddress) -> SendBitcoinUTXO {
        .init(networkID: "bitcoin", outpoint: .init(
            transactionHash: String(repeating: "11", count: 32), outputIndex: 0
        ), valueAtomic: value, blockHeight: 0, confirmations: 0, owner: owner)
    }

    private func database(for draft: SendDraft) async throws -> WalletDatabase {
        let database = try WalletDatabase.temporary()
        let walletID = UUID().uuidString
        let address = try #require(draft.asset.sourceAddress)
        let now = Date().timeIntervalSince1970
        try await database.pool.write { db in
            try DBWalletRecord(
                id: walletID, profileID: WalletDatabase.defaultProfileID, name: "Repeat Test",
                kind: DatabaseWalletKind.importedRecoveryPhrase.rawValue,
                secretKeyReference: nil, isSelected: true, sortOrder: 0,
                createdAt: now, updatedAt: now, lastOpenedAt: now, archivedAt: nil
            ).insert(db)
            try DBWalletAccountRecord(
                id: "\(walletID):bitcoin:0", walletID: walletID, networkID: "bitcoin",
                address: address, normalizedAddress: address.lowercased(), label: nil,
                derivationPath: "m/84'/0'/0'/0/0", accountIndex: 0, publicKey: nil,
                isWatchOnly: false, isEnabled: true, createdAt: now, updatedAt: now,
                lastSyncedAt: nil
            ).insert(db)
        }
        return database
    }
}

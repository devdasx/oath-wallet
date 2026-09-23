import Foundation
import GRDB
import Testing
@testable import Aperture

struct TokenSafetyPolicyTests {
    private static let screenshotTronContracts = [
        "TARvMKuvsLPxnWTspYSC8vKH5U3Hy1hbRN",
        "TFefZs7uDTW2hnWAzJA3xxSVjWKJdbiG9e",
        "TTkyV7LtApRjacGDXQ2K4aitwxH32dumcZ",
        "TTQBdfP6zNmk2n6HN5poCMVfzr7j9DSdsy",
        "TVDKMkVYr4EqBkgyWRPjL285BRHFrWNmct",
        "TVh4nokXoSxQGxh7T6Tn6NTb2uSUhAhLwb",
        "TWxt3jw2qm7kocH7agXtVqL7AJTPkC29rR",
    ]

    @Test
    func screenshotContractsAreDeniedAndAbsentFromCatalogs() {
        let catalogContracts = Set(TronTokenCatalog.tokens.map(\.id))

        for contract in Self.screenshotTronContracts {
            #expect(
                TokenSafetyPolicy.isHardDenied(
                    networkID: TronConstants.networkID,
                    contractAddress: contract
                )
            )
            #expect(!catalogContracts.contains(contract))
        }
    }

    @Test
    func knownSuspiciousSolanaMintIsDeniedAndAbsent() {
        let mint =
            "AGFEad2et2ZJif9jaGpdMixQqvW5i81aBdvKe7PHNfz3"

        #expect(
            TokenSafetyPolicy.isHardDenied(
                networkID: SolanaConstants.networkID,
                contractAddress: mint
            )
        )
        #expect(SolanaTokenCatalog.byMint[mint] == nil)
    }

    @Test
    func cleanupDeletesHardDeniedAssets() async throws {
        let database = try WalletDatabase.temporary()
        let contract = Self.screenshotTronContracts[0]
        let assetID = "tron:\(contract)"
        let now = Date().timeIntervalSince1970

        try await database.pool.write { db in
            try DBAssetRecord(
                id: assetID,
                networkID: TronConstants.networkID,
                assetType: DatabaseAssetType.fungibleToken.rawValue,
                contractAddress: contract,
                normalizedContractAddress: contract,
                name: "Impersonation",
                symbol: "FAKE",
                decimals: 6,
                trustWalletBlockchain: WalletBlockchain.tron.rawValue,
                trustWalletContractAddress: contract,
                isVerified: true,
                isSpam: false,
                createdAt: now,
                updatedAt: now,
                metadataUpdatedAt: now
            ).insert(db)

            try WalletDatabase.removeHardDeniedAssets(database: db)
        }

        let remains = try await database.pool.read { db in
            try DBAssetRecord.fetchOne(db, key: assetID)
        }
        #expect(remains == nil)
    }
}

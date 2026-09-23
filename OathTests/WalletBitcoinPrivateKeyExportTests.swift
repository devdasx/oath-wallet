import Foundation
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct WalletBitcoinPrivateKeyExportTests {
    private static let mnemonic =
        "abandon abandon abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon about"

    struct ElectrumVector: Sendable {
        let phrase: String
        let addressType: BitcoinHDAddressType
        let firstAddress: String
    }

    @Test
    func recoveryPhraseExportIncludesEveryGeneratedBitcoinKey()
        async throws {
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(
            service: "bitcoin-private-export-tests.\(UUID().uuidString)"
        )
        defer { try? vault.deleteAll() }
        let draft = try WalletCoreService.restoreEVMWallet(
            mnemonic: Self.mnemonic
        )
        let identity = try await database.persistCreatedWallet(
            draft: draft,
            security: .reuseExistingProfile,
            vault: vault
        )
        let authorization = try await database
            .authorizeUnprotectedSecretExport(
                walletID: identity.walletID
            )

        let items = try await database.privateKeyExportItems(
            walletID: identity.walletID,
            authorization: authorization,
            vault: vault
        )
        let bitcoinItem = try #require(items.first {
            $0.id == BitcoinFamilyChain.bitcoin.rawValue
        })
        let catalog = try #require(bitcoinItem.bitcoinCatalog)

        #expect(bitcoinItem.privateKeys.isEmpty)
        #expect(
            catalog.addressTypes.map(\.addressType)
                == BitcoinHDAddressType.allCases
        )
        #expect(catalog.addressTypes.allSatisfy {
            $0.generatedCount == 40
        })
        #expect(catalog.silentPayments != nil)
        #expect(
            BitcoinSilentPaymentAddress.isValidMainnet(
                try #require(catalog.silentPayments?.address)
            )
        )

        let derivation = BitcoinHDDerivationService()
        for addressType in BitcoinHDAddressType.allCases {
            for branch in [
                BitcoinHDAddressBranch.external,
                .change,
            ] {
                let entries = try #require(
                    catalog.addressTypes.first {
                        $0.addressType == addressType
                    }
                ).addresses.filter {
                    $0.state.derived.branch == branch
                }
                #expect(entries.map { $0.state.derived.index }
                    == Array(0..<20))
                for entry in [
                    try #require(entries.first),
                    try #require(entries.last),
                ] {
                    let privateKey = try BitcoinHDDerivationService
                        .privateKey(fromBitcoinWIF: entry.wif)
                    let derived = try derivation.derivedAddress(
                        addressType: addressType,
                        branch: branch,
                        index: entry.state.derived.index,
                        publicKey: privateKey.getPublicKeySecp256k1(
                            compressed: true
                        )
                    )
                    #expect(derived.address == entry.state.derived.address)
                    #expect(
                        derived.derivationPath
                            == entry.state.derived.derivationPath
                    )
                }
            }
        }
    }

    @Test
    func silentPaymentCatalogRoutesEachDiscoveredOutputKey()
        throws {
        let address = try BitcoinSilentPaymentAddress(
            "sp1qqgste7k9hx0qftg6qmwlkqtwuy6cycyavzmzj85c6qdfhjdpdjtdgqjuex"
                + "zk6murw56suy3e0rd2cgqvycxttddwsvgxe2usfpxumr70xc9pkqwv"
        )
        let account = BitcoinSilentPaymentAccount(
            walletID: "wallet",
            address: address,
            birthHeight: WalletDatabase
                .bitcoinSilentPaymentActivationHeight,
            lastScanHeight: WalletDatabase
                .bitcoinSilentPaymentActivationHeight,
            scanTargetHeight: WalletDatabase
                .bitcoinSilentPaymentActivationHeight,
            balanceIsAuthoritative: true
        )
        let hash = String(repeating: "ab", count: 32)
        let output = BitcoinSilentPaymentOutput(
            walletID: "wallet",
            transactionHash: hash,
            outputIndex: 2,
            valueAtomic: try BitcoinFamilyAtomicInteger(
                validating: "125000"
            ),
            scriptPubKey: Data([0x51, 0x20])
                + Data(repeating: 1, count: 32),
            outputPublicKey: Data(repeating: 1, count: 32),
            blockHeight: 800_000,
            blockTimestamp: nil,
            isSpent: false,
            spentByTransactionHash: nil
        )
        let catalog = WalletBitcoinPrivateKeyExportCatalog(
            hdEntries: [],
            silentPaymentAccount: account,
            silentPaymentEntries: [
                BitcoinSilentPaymentPrivateKeyExportEntry(
                    output: output,
                    descriptor: "public-test-descriptor"
                )
            ]
        )

        let routed = try #require(catalog.silentPaymentOutput(
            transactionHash: hash,
            outputIndex: 2
        ))
        #expect(routed.output == output)
        #expect(routed.descriptor == "public-test-descriptor")
        #expect(routed.displayItem.privateKeys.first?.value
            == "public-test-descriptor")
    }

    @Test(arguments: [
        ElectrumVector(
            phrase: "cycle rocket west magnet parrot shuffle foot correct "
                + "salt library feed song",
            addressType: .bip44,
            firstAddress: "1NNkttn1YvVGdqBW4PR6zvc3Zx3H5owKRf"
        ),
        ElectrumVector(
            phrase: "bitter grass shiver impose acquire brush forget axis "
                + "eager alone wine silver",
            addressType: .bip84,
            firstAddress: "bc1q3g5tmkmlvxryhh843v4dz026avatc0zzr6h3af"
        ),
    ])
    func electrumExportShowsItsGeneratedTypeWithoutSilentPayments(
        _ vector: ElectrumVector
    ) async throws {
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(
            service: "bitcoin-private-export-electrum-tests.\(UUID().uuidString)"
        )
        defer { try? vault.deleteAll() }
        let draft = try WalletCoreService.importRecoveryPhrase(
            vector.phrase
        )
        let identity = try await database.persistImportedWallet(
            draft: draft,
            security: .reuseExistingProfile,
            vault: vault
        )
        let authorization = try await database
            .authorizeUnprotectedSecretExport(
                walletID: identity.walletID
            )

        let items = try await database.privateKeyExportItems(
            walletID: identity.walletID,
            authorization: authorization,
            vault: vault
        )
        let bitcoinItem = try #require(items.first)
        let catalog = try #require(bitcoinItem.bitcoinCatalog)

        #expect(items.count == 1)
        #expect(bitcoinItem.id == BitcoinFamilyChain.bitcoin.rawValue)
        #expect(catalog.addressTypes.count == 1)
        #expect(catalog.addressTypes.first?.addressType == vector.addressType)
        #expect(catalog.addressTypes.first?.generatedCount == 40)
        #expect(
            catalog.addressTypes.first?.addresses.first?
                .state.derived.address == vector.firstAddress
        )
        #expect(catalog.silentPayments == nil)
    }
}

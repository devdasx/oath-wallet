import Foundation
import GRDB
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct ElectrumSeedTests {
    private static let standardPhrase =
        "cycle rocket west magnet parrot shuffle foot correct "
        + "salt library feed song"
    private static let segwitPhrase =
        "bitter grass shiver impose acquire brush forget axis "
        + "eager alone wine silver"

    @Test
    func electrumPBKDF2MatchesOfficialVectors() throws {
        let phrase =
            "wild father tree among universe such mobile favorite "
            + "target dynamic credit identify"
        #expect(
            try ElectrumSeed.seed(
                phrase: phrase,
                passphrase: ""
            ).hexString
                == "aac2a6302e48577ab4b46f23dbae0774"
                + "e2e62c796f797d0a1b5faeb528301e30"
                + "64342dafb79069e7c4c6b8c38ae11d7a"
                + "973bec0d4f70626f8cc5184a8d0b0756"
        )
        #expect(
            try ElectrumSeed.seed(
                phrase: phrase,
                passphrase:
                    "Did you ever hear the tragedy of Darth "
                    + "Plagueis the Wise?"
            ).hexString
                == "4aa29f2aeb0127efb55138ab9e7be83b"
                + "36750358751906f86c662b21a1ea1370"
                + "f949e6d1a12fa56d3d93cadda93038c7"
                + "6ac8118597364e46f5156fde6183c82f"
        )
    }

    @Test
    func standardSeedMatchesOfficialXpubAndAddressVectors() throws {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.standardPhrase
        )
        #expect(credential.scheme == .electrumStandard)
        let descriptor = try #require(
            BitcoinHDDerivationService()
                .accountDescriptors(credential: credential).first
        )
        #expect(descriptor.addressType == .bip44)
        #expect(descriptor.accountPath == "m")
        #expect(
            descriptor.extendedPublicKey
                == "xpub661MyMwAqRbcFWohJWt7PHsFEJfZ"
                + "Avw9ZxwQoDa4SoMgsDDM1T7WK3u9E4e"
                + "dkC4ugRnZ8E4xDZRpk8Rnts3Nbt97dPw"
                + "T52CwBdDWroaZf8U"
        )
        let service = BitcoinHDDerivationService()
        let receive = try service.deriveAddress(
            credential: credential,
            addressType: .bip44,
            branch: .external,
            index: 0
        )
        let change = try service.deriveAddress(
            credential: credential,
            addressType: .bip44,
            branch: .change,
            index: 0
        )
        #expect(receive.address == "1NNkttn1YvVGdqBW4PR6zvc3Zx3H5owKRf")
        #expect(change.address == "1KSezYMhAJMWqFbVFB2JshYg69UpmEXR4D")
        #expect(receive.derivationPath == "m/0/0")
        #expect(change.derivationPath == "m/1/0")
        #expect(
            try service.childKeyCacheEntry(
                credential: credential,
                addressType: .bip44,
                branch: .external,
                index: 0
            ).address == receive.address
        )
    }

    @Test
    func segwitSeedMatchesOfficialZpubAndAddressVectors() throws {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.segwitPhrase
        )
        #expect(credential.scheme == .electrumSegwit)
        let descriptor = try #require(
            BitcoinHDDerivationService()
                .accountDescriptors(credential: credential).first
        )
        #expect(descriptor.addressType == .bip84)
        #expect(descriptor.accountPath == "m/0'")
        #expect(
            descriptor.extendedPublicKey
                == "zpub6nsHdRuY92FsMKdbn9BfjBCG6X8p"
                + "yhCibNP6uDvpnw2cyrVhecvHRMa3Ne8k"
                + "dJZxjxgwnpbHLkcR4bfnhHy6auHPJyDT"
                + "Q3kianeuVLdkCYQ"
        )
        let service = BitcoinHDDerivationService()
        let receive = try service.deriveAddress(
            credential: credential,
            addressType: .bip84,
            branch: .external,
            index: 0
        )
        let change = try service.deriveAddress(
            credential: credential,
            addressType: .bip84,
            branch: .change,
            index: 0
        )
        #expect(
            receive.address
                == "bc1q3g5tmkmlvxryhh843v4dz026avatc0zzr6h3af"
        )
        #expect(
            change.address
                == "bc1qdy94n2q5qcp0kg7v9yzwe6wvfkhnvyzje7nx2p"
        )
        #expect(receive.derivationPath == "m/0'/0/0")
        #expect(change.derivationPath == "m/0'/1/0")
    }

    @Test
    func versionedCredentialEnvelopePreservesElectrumSchemeAndPassphrase()
        throws
    {
        let original = try WalletRecoveryCredential(
            mnemonic: Self.segwitPhrase,
            passphrase: "electrum test extension"
        )
        let decoded = try WalletRecoveryCredential.decode(
            original.encodedData()
        )
        #expect(decoded == original)
        #expect(decoded.scheme == .electrumSegwit)
        #expect(decoded.makeHDWallet() == nil)
    }

    @Test
    func rejectsLegacyAndTrustedCoinTwoFactorSeeds() {
        let legacy =
            "cell dumb heartbeat north boom tease ship baby "
            + "bright kingdom rare squeeze"
        let twoFactor =
            "science dawn member doll dutch real can brick "
            + "knife deny drive list"
        #expect(throws: WalletRecoveryCredentialError.self) {
            try WalletRecoveryCredential(mnemonic: legacy)
        }
        #expect(throws: WalletRecoveryCredentialError.self) {
            try WalletRecoveryCredential(mnemonic: twoFactor)
        }
    }

    @Test(arguments: [
        ImportVector(
            phrase: standardPhrase,
            scheme: .electrumStandard,
            addressType: .bip44,
            receive0: "1NNkttn1YvVGdqBW4PR6zvc3Zx3H5owKRf",
            change0: "1KSezYMhAJMWqFbVFB2JshYg69UpmEXR4D"
        ),
        ImportVector(
            phrase: segwitPhrase,
            scheme: .electrumSegwit,
            addressType: .bip84,
            receive0: "bc1q3g5tmkmlvxryhh843v4dz026avatc0zzr6h3af",
            change0: "bc1qdy94n2q5qcp0kg7v9yzwe6wvfkhnvyzje7nx2p"
        ),
    ])
    func simulatorImportPersistsSpendableTwentyAddressGap(
        _ vector: ImportVector
    ) async throws {
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(
            service: "electrum-import-tests.\(UUID().uuidString)"
        )
        defer { try? vault.deleteAll() }

        let draft = try WalletCoreService.importRecoveryPhrase(
            vector.phrase
        )
        #expect(draft.address == vector.receive0)
        let identity = try await database.persistImportedWallet(
            draft: draft,
            security: .reuseExistingProfile,
            vault: vault
        )

        let credential = try await database.recoveryCredential(
            walletID: identity.walletID,
            authorization: BitcoinFamilySecretDerivationAuthorization(
                walletID: identity.walletID
            ),
            vault: vault
        )
        #expect(credential.scheme == vector.scheme)
        let descriptors = try await database.bitcoinHDAccountDescriptors(
            walletID: identity.walletID
        )
        #expect(descriptors.count == 1)
        #expect(descriptors.first?.addressType == vector.addressType)

        let receive = try await database.bitcoinHDAddresses(
            walletID: identity.walletID,
            addressType: vector.addressType,
            branch: .external
        )
        let change = try await database.bitcoinHDAddresses(
            walletID: identity.walletID,
            addressType: vector.addressType,
            branch: .change
        )
        #expect(receive.map(\.derived.index) == Array(0..<20))
        #expect(change.map(\.derived.index) == Array(0..<20))
        #expect(receive.first?.derived.address == vector.receive0)
        #expect(change.first?.derived.address == vector.change0)
        #expect(
            try await database.cachedBitcoinHDWIF(
                walletID: identity.walletID,
                addressType: vector.addressType,
                branch: .external,
                index: 19,
                vault: vault
            ) != nil
        )
        let accounts = try await database.pool.read { rawDatabase in
            try DBWalletAccountRecord
                .filter(Column("walletID") == identity.walletID)
                .fetchAll(rawDatabase)
        }
        #expect(accounts.count == 1)
        #expect(accounts.first?.networkID == "bitcoin")
        #expect(accounts.first?.address == vector.receive0)
    }

    @Test(arguments: [
        ImportVector(
            phrase: standardPhrase,
            scheme: .electrumStandard,
            addressType: .bip44,
            receive0: "1NNkttn1YvVGdqBW4PR6zvc3Zx3H5owKRf",
            change0: "1KSezYMhAJMWqFbVFB2JshYg69UpmEXR4D"
        ),
        ImportVector(
            phrase: segwitPhrase,
            scheme: .electrumSegwit,
            addressType: .bip84,
            receive0: "bc1q3g5tmkmlvxryhh843v4dz026avatc0zzr6h3af",
            change0: "bc1qdy94n2q5qcp0kg7v9yzwe6wvfkhnvyzje7nx2p"
        ),
    ])
    func signsSpendFromOfficialElectrumSeedVector(
        _ vector: ImportVector
    ) throws {
        let credential = try WalletRecoveryCredential(
            mnemonic: vector.phrase
        )
        let derivation = BitcoinHDDerivationService()
        let owner = try derivation.deriveAddress(
            credential: credential,
            addressType: vector.addressType,
            branch: .external,
            index: 0
        )
        let recipient = try derivation.deriveAddress(
            credential: credential,
            addressType: vector.addressType,
            branch: .external,
            index: 1
        )
        let change = try derivation.deriveAddress(
            credential: credential,
            addressType: vector.addressType,
            branch: .change,
            index: 0
        )
        let output = SendBitcoinUTXO(
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            outpoint: SendBitcoinOutpoint(
                transactionHash: String(repeating: "12", count: 32),
                outputIndex: 0
            ),
            valueAtomic: "100000",
            blockHeight: 800_000,
            confirmations: 10,
            owner: owner
        )
        let options = SendBitcoinFamilyOptions(
            coinSelection: .manual([output]),
            replaceByFee: true
        )
        let draft = SendDraft(
            request: .manualEntry(
                networkID: BitcoinFamilyChain.bitcoin.networkID
            ),
            asset: Self.bitcoinAsset(sourceAddress: owner.address),
            recipient: recipient.address,
            amount: "0.0005",
            note: nil,
            bitcoinFamilyOptions: options
        )
        let material = SendResolvedSigningMaterial(
            walletID: "electrum-signing-test",
            account: Self.account(owner),
            privateKey: Data(),
            bitcoinHDRecoveryCredential: credential
        )
        let signed = try SendBitcoinHDTransactionSigner.sign(
            draft: draft,
            material: material,
            outputs: [output],
            requestedAtomic: 50_000,
            byteFee: 2,
            fee: SendResolvedNetworkFee(
                model: .utxoPerVByte,
                primaryValue: "2",
                secondaryValue: nil
            ),
            options: options,
            changeAddress: change.address,
            recipientAddress: recipient.address
        )

        let transaction = try ParsedBitcoinTransaction(signed.encoded)
        #expect(transaction.transactionID == signed.transactionID)
        #expect(transaction.inputs.count == 1)
        #expect(transaction.outputs.count == 2)
        #expect(transaction.inputs[0].sequence == 0xffff_fffd)
        switch vector.addressType {
        case .bip44:
            #expect(!transaction.hasWitness)
            #expect(!transaction.inputs[0].script.isEmpty)
            #expect(transaction.inputs[0].witness.isEmpty)
        case .bip84:
            #expect(transaction.hasWitness)
            #expect(transaction.inputs[0].script.isEmpty)
            #expect(transaction.inputs[0].witness.count == 2)
        case .bip49, .bip86, .brdLegacy, .brdSegwit:
            Issue.record("Unexpected Electrum address type")
        }
    }

    private static func bitcoinAsset(
        sourceAddress: String
    ) -> SendAssetChoice {
        SendAssetChoice(
            id: "bitcoin:native",
            name: "Bitcoin",
            symbol: "BTC",
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            networkName: "Bitcoin",
            blockchain: .bitcoin,
            contractAddress: nil,
            decimals: 8,
            logoSource: .nativeCoin(blockchain: .bitcoin),
            networkLogoSource: .nativeCoin(blockchain: .bitcoin),
            balance: 0.001,
            fiatValue: 0,
            balanceAtomic: "100000",
            sourceAddress: sourceAddress
        )
    }

    private static func account(
        _ owner: BitcoinHDDerivedAddress
    ) -> DBWalletAccountRecord {
        DBWalletAccountRecord(
            id: "electrum-signing-test:bitcoin:0",
            walletID: "electrum-signing-test",
            networkID: BitcoinFamilyChain.bitcoin.networkID,
            address: owner.address,
            normalizedAddress: owner.address.lowercased(),
            label: nil,
            derivationPath: owner.derivationPath,
            accountIndex: 0,
            publicKey: owner.publicKey.hexString,
            isWatchOnly: false,
            isEnabled: true,
            createdAt: 0,
            updatedAt: 0,
            lastSyncedAt: nil
        )
    }

    struct ImportVector: Sendable, CustomTestStringConvertible {
        let phrase: String
        let scheme: WalletRecoveryCredential.Scheme
        let addressType: BitcoinHDAddressType
        let receive0: String
        let change0: String

        var testDescription: String { scheme.rawValue }
    }
}

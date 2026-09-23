import Foundation
import GRDB
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct BitcoinHDWalletTests {
    @Test
    func receiveAddressTypeNamesRemainEnglishInEveryShippedLanguage() {
        let expectedNames: [BitcoinHDAddressType: String] = [
            .bip44: "BIP44 · Legacy",
            .bip49: "BIP49 · Nested SegWit",
            .bip84: "BIP84 · Native SegWit",
            .bip86: "BIP86 · Taproot",
            .brdLegacy: "BRD · Legacy",
            .brdSegwit: "BRD · Native SegWit",
        ]
        for language in WalletAppLanguage.supportedIdentifiers {
            let bundle = WalletAppLanguage.localizedBundle(for: language)
            for addressType in BitcoinHDAddressType.allCases {
                let value = bundle.localizedString(
                    forKey: addressType.localizationKey,
                    value: nil,
                    table: nil
                )
                #expect(
                    value == expectedNames[addressType],
                    "Translated Bitcoin type for \(language): \(value)"
                )
            }
            let silentPayments = bundle.localizedString(
                forKey: "receive.bitcoin.address_type.silent_payments",
                value: nil,
                table: nil
            )
            #expect(
                silentPayments == "Silent Payments",
                "Translated Silent Payments for \(language): \(silentPayments)"
            )
        }
    }

    @Test
    func receivePresentationRestoresLastStandardTypeAndNotSilentPayments()
        async throws
    {
        let fixture = try await Self.seededDatabase()
        let database = fixture.database
        let walletID = fixture.walletID
        let now = Date().timeIntervalSince1970
        try await database.pool.write { rawDatabase in
            try DBBitcoinHDPreferenceRecord(
                walletID: walletID,
                receiveAddressType: BitcoinHDAddressType.bip84.rawValue,
                usesSilentPayments: false,
                updatedAt: now
            ).save(rawDatabase)
        }

        try await database.setBitcoinUsesSilentPayments(
            true,
            walletID: walletID
        )
        let restoredBIP84 = try await database
            .restoreBitcoinStandardReceiveAddressType(walletID: walletID)
        #expect(restoredBIP84 == .bip84)
        #expect(
            try await database.bitcoinUsesSilentPayments(walletID: walletID)
                == false
        )
        #expect(
            BitcoinReceiveAddressMode.restored(from: restoredBIP84)
                == .hd(.bip84)
        )

        try await database.setBitcoinReceiveAddressType(
            .bip86,
            walletID: walletID
        )
        let restoredBIP86 = try await database
            .restoreBitcoinStandardReceiveAddressType(walletID: walletID)
        #expect(restoredBIP86 == .bip86)
        #expect(
            BitcoinReceiveAddressMode.restored(from: restoredBIP86)
                == .hd(.bip86)
        )
    }

    @Test
    func legacyAutomaticBIP44DefaultMigratesWithoutChangingExplicitBIP44()
        async throws
    {
        let fixture = try await Self.seededDatabase()
        let database = fixture.database
        let walletID = fixture.walletID
        let initializedAt = try #require(
            await database.pool.read { rawDatabase in
                try Double.fetchOne(
                    rawDatabase,
                    sql: """
                    SELECT createdAt
                    FROM bitcoinHDAccounts
                    WHERE walletID = ?
                    LIMIT 1
                    """,
                    arguments: [walletID]
                )
            }
        )
        try await database.pool.write { rawDatabase in
            try DBBitcoinHDPreferenceRecord(
                walletID: walletID,
                receiveAddressType: BitcoinHDAddressType.bip44.rawValue,
                usesSilentPayments: false,
                updatedAt: initializedAt
            ).save(rawDatabase)
            try WalletDatabase.migrateAutomaticBitcoinBIP44ReceiveDefaults(
                in: rawDatabase
            )
        }
        #expect(
            try await database.bitcoinReceiveAddressType(walletID: walletID)
                == .bip84
        )

        try await database.pool.write { rawDatabase in
            try DBBitcoinHDPreferenceRecord(
                walletID: walletID,
                receiveAddressType: BitcoinHDAddressType.bip44.rawValue,
                usesSilentPayments: false,
                updatedAt: initializedAt + 1
            ).save(rawDatabase)
            try WalletDatabase.migrateAutomaticBitcoinBIP44ReceiveDefaults(
                in: rawDatabase
            )
        }
        #expect(
            try await database.bitcoinReceiveAddressType(walletID: walletID)
                == .bip44
        )
    }

    private static let mnemonic =
        "abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon abandon abandon about"

    @Test
    func bip44Bip49Bip84AndBip86MatchIndependentMainnetVectors()
        throws
    {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.mnemonic
        )
        let wallet = try #require(credential.makeHDWallet())
        let service = BitcoinHDDerivationService()
        let descriptors = try service.accountDescriptors(wallet: wallet)
        let byType = Dictionary(
            uniqueKeysWithValues: descriptors.map {
                ($0.addressType, $0)
            }
        )

        let vectors: [BitcoinHDAddressType: Vector] = [
            .bip44: Vector(
                extendedPublicKey:
                    "xpub6BosfCnifzxcFwrSzQiqu2DBVTshkCXacvNsWGYJ"
                    + "VVhhawA7d4R5WSWGFNbi8Aw6ZRc1brxMyWMzG3DSSS"
                    + "SoekkudhUd9yLb6qx39T9nMdj",
                external0: "1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA",
                external1: "1Ak8PffB2meyfYnbXZR9EGfLfFZVpzJvQP",
                change0: "1J3J6EvPrv8q6AC3VCjWV45Uf3nssNMRtH",
                external0WIF:
                    "L4p2b9VAf8k5aUahF1JCJUzZkgNEAqLfq8DDdQiyAprQ"
                    + "AKSbu8hf"
            ),
            .bip49: Vector(
                extendedPublicKey:
                    "ypub6Ww3ibxVfGzLrAH1PNcjyAWenMTbbAosGNB6Vvm"
                    + "SEgytSER9azLDWCxoJwW7Ke7icmizBMXrzBx9979Ffa"
                    + "HxHcrArf3zbeJJJUZPf663zsP",
                external0: "37VucYSaXLCAsxYyAPfbSi9eh4iEcbShgf",
                external1: "3LtMnn87fqUeHBUG414p9CWwnoV6E2pNKS",
                change0: "34K56kSjgUCUSD8GTtuF7c9Zzwokbs6uZ7",
                external0WIF:
                    "KyvHbRLNXfXaHuZb3QRaeqA5wovkjg4RuUpFGCxdH5UWc"
                    + "1Foih9o"
            ),
            .bip84: Vector(
                extendedPublicKey:
                    "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYf"
                    + "G1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUU"
                    + "kgDKf31mGDtKsAYz2oz2AGutZYs",
                external0:
                    "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu",
                external1:
                    "bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g",
                change0:
                    "bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el",
                external0WIF:
                    "KyZpNDKnfs94vbrwhJneDi77V6jF64PWPF8x5cdJb8ifg"
                    + "g2DUc9d"
            ),
            .bip86: Vector(
                extendedPublicKey:
                    "xpub6BgBgsespWvERF3LHQu6CnqdvfEvtMcQjYrcRzx"
                    + "53QJjSxarj2afYWcLteoGVky7D3UKDP9QyrLprQ3V"
                    + "CECoY49yfdDEHGCtMMj92pReUsQ",
                external0:
                    "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20"
                    + "cac6yqjjwudpxqkedrcr",
                external1:
                    "bc1p4qhjn9zdvkux4e44uhx8tc55attvtyu358kutc"
                    + "qkudyccelu0was9fqzwh",
                change0:
                    "bc1p3qkhfews2uk44qtvauqyr2ttdsw7svhkl9nkm9"
                    + "s9c3x4ax5h60wqwruhk7",
                external0WIF:
                    "KyRv5iFPHG7iB5E4CqvMzH3WFJVhbfYK4VY7XAedd9Ys6"
                    + "9mEsPLQ"
            )
        ]

        #expect(byType.count == BitcoinHDAddressType.allCases.count)
        for addressType in BitcoinHDAddressType.standardTypes {
            let descriptor = try #require(byType[addressType])
            let vector = try #require(vectors[addressType])
            #expect(descriptor.accountPath == addressType.accountPath)
            #expect(
                descriptor.extendedPublicKey
                    == vector.extendedPublicKey
            )

            let external0 = try service.deriveAddress(
                descriptor: descriptor,
                branch: .external,
                index: 0
            )
            let external1 = try service.deriveAddress(
                descriptor: descriptor,
                branch: .external,
                index: 1
            )
            let change0 = try service.deriveAddress(
                descriptor: descriptor,
                branch: .change,
                index: 0
            )
            #expect(external0.address == vector.external0)
            #expect(external1.address == vector.external1)
            #expect(change0.address == vector.change0)
            #expect(!external0.scriptPubKey.isEmpty)
            #expect(external0.scriptHash.count == 64)

            let privateExternal0 = try service.deriveAddress(
                wallet: wallet,
                addressType: addressType,
                branch: .external,
                index: 0
            )
            #expect(privateExternal0 == external0)
            let childKey = try service.childKeyCacheEntry(
                wallet: wallet,
                addressType: addressType,
                branch: .external,
                index: 0
            )
            #expect(childKey.address == vector.external0)
            #expect(childKey.wif == vector.external0WIF)
        }
    }

    @Test
    func gapLimitRequiresTwentyChildrenAfterLastUsedOrReserved()
        throws
    {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.mnemonic
        )
        let wallet = try #require(credential.makeHDWallet())
        let service = BitcoinHDDerivationService()
        let addresses = try (0...20).map {
            try service.deriveAddress(
                wallet: wallet,
                addressType: .bip84,
                branch: .external,
                index: $0
            )
        }
        let unused = addresses.map {
            Self.state($0, isUsed: false, isReserved: false)
        }
        #expect(BitcoinHDDiscoveryService.hasGapLimitAfterLastUsed(
            Array(unused.prefix(20))
        ))

        var usedAtZero = unused
        usedAtZero[0] = Self.state(
            addresses[0],
            isUsed: true,
            isReserved: false
        )
        #expect(!BitcoinHDDiscoveryService.hasGapLimitAfterLastUsed(
            Array(usedAtZero.prefix(20))
        ))
        #expect(BitcoinHDDiscoveryService.hasGapLimitAfterLastUsed(
            usedAtZero
        ))

        var reservedAtZero = unused
        reservedAtZero[0] = Self.state(
            addresses[0],
            isUsed: false,
            isReserved: true
        )
        #expect(!BitcoinHDDiscoveryService.hasGapLimitAfterLastUsed(
            Array(reservedAtZero.prefix(20))
        ))
        #expect(BitcoinHDDiscoveryService.hasGapLimitAfterLastUsed(
            reservedAtZero
        ))
    }

    @Test
    func everyAddressTypeUsesIndependentExternalAndChangeChains()
        throws
    {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.mnemonic
        )
        let wallet = try #require(credential.makeHDWallet())
        let service = BitcoinHDDerivationService()
        for addressType in BitcoinHDAddressType.allCases {
            let external = try service.deriveAddress(
                wallet: wallet,
                addressType: addressType,
                branch: .external,
                index: 7
            )
            let change = try service.deriveAddress(
                wallet: wallet,
                addressType: addressType,
                branch: .change,
                index: 7
            )
            #expect(external.address != change.address)
            #expect(external.publicKey != change.publicKey)
            #expect(external.scriptHash != change.scriptHash)
            #expect(
                BitcoinHDAddressType.location(
                    for: external.derivationPath, addressType: addressType
                ) == BitcoinHDAddressLocation(
                    addressType: addressType,
                    branch: .external,
                    index: 7
                )
            )
        }
    }

    @Test
    func databaseInitializationIsConcurrentIdempotentAndAdvancesFreshChildren()
        async throws
    {
        let fixture = try await Self.seededDatabase()
        let database = fixture.database
        let walletID = fixture.walletID

        let initializationResults = try await withThrowingTaskGroup(
            of: Bool.self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await database.ensureBitcoinHDWallet(
                        walletID: walletID
                    )
                }
            }
            var results: [Bool] = []
            while let result = try await group.next() {
                results.append(result)
            }
            return results
        }
        #expect(initializationResults.count == 8)
        #expect(initializationResults.allSatisfy { $0 })
        #expect(
            try await database.bitcoinReceiveAddressType(walletID: walletID)
                == .bip84
        )

        let descriptors = try await database.bitcoinHDAccountDescriptors(
            walletID: walletID
        )
        let states = try await database.bitcoinHDAddresses(
            walletID: walletID
        )
        #expect(descriptors.count == BitcoinHDAddressType.allCases.count)
        #expect(
            states.count
                == BitcoinHDAddressType.allCases.count
                    * 2
                    * BitcoinHDDerivationService.gapLimit
        )

        let first = try #require(
            await database.freshBitcoinReceiveAddress(
                walletID: walletID,
                addressType: .bip84
            )
        )
        #expect(first.index == 0)
        #expect(
            try await database.bitcoinHDWalletOwnsAddress(
                walletID: walletID,
                address: first.address
            )
        )
        try await database.saveBitcoinHDAddressStates(
            [Self.state(first, isUsed: true, isReserved: false)],
            walletID: walletID
        )
        let second = try #require(
            await database.freshBitcoinReceiveAddress(
                walletID: walletID,
                addressType: .bip84
            )
        )
        #expect(second.index == 1)
        #expect(second.address != first.address)

        try await database.setBitcoinReceiveAddressType(
            .bip86,
            walletID: walletID
        )
        _ = try await database.ensureBitcoinHDWallet(walletID: walletID)
        #expect(
            try await database.bitcoinReceiveAddressType(walletID: walletID)
                == .bip86
        )
        let selected = try #require(
            await database.freshBitcoinReceiveAddress(
                walletID: walletID,
                addressType: .bip86
            )
        )
        let account = try await database.pool.read { database in
            try DBWalletAccountRecord.fetchOne(
                database,
                key: "\(walletID):bitcoin:0"
            )
        }
        #expect(account?.address == selected.address)
        #expect(account?.derivationPath == selected.derivationPath)
    }

    @Test
    func lazyInitializationCreatesEveryPoolAndReplenishesExactGap()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(
            service: "bitcoin-hd-tests.\(UUID().uuidString)"
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
        #expect(
            try await database.bitcoinReceiveAddressType(
                walletID: identity.walletID
            ) == .bip84
        )
        #expect(
            try await database.bitcoinHDAddresses(
                walletID: identity.walletID
            ).isEmpty
        )
        #expect(
            try await database.ensureBitcoinHDWallet(
                walletID: identity.walletID,
                vault: vault
            )
        )

        let initial = try await database.bitcoinHDAddresses(
            walletID: identity.walletID
        )
        let exportAuthorization = try await database
            .authorizeUnprotectedSecretExport(walletID: identity.walletID)
        #expect(initial.count == BitcoinHDAddressType.allCases.count * 2 * 20)
        for addressType in BitcoinHDAddressType.allCases {
            for branch in [
                BitcoinHDAddressBranch.external,
                BitcoinHDAddressBranch.change
            ] {
                let chain = initial.filter {
                    $0.derived.addressType == addressType
                        && $0.derived.branch == branch
                }
                #expect(chain.map(\.derived.index) == Array(0..<20))
                #expect(
                    try await database.cachedBitcoinHDWIF(
                        walletID: identity.walletID,
                        addressType: addressType,
                        branch: branch,
                        index: 19,
                        vault: vault
                    ) != nil
                )
            }
        }
        #expect(
            try await database.bitcoinHDWIFForExport(
                walletID: identity.walletID,
                addressType: .bip84,
                branch: .external,
                index: 19,
                authorization: exportAuthorization,
                vault: vault
            ) != nil
        )

        let used = try #require(initial.first {
            $0.derived.addressType == .bip84
                && $0.derived.branch == .external
                && $0.derived.index == 11
        })
        try await database.saveBitcoinHDAddressStates(
            [Self.state(used.derived, isUsed: true, isReserved: false)],
            walletID: identity.walletID,
            vault: vault
        )
        let replenished = try await database.bitcoinHDAddresses(
            walletID: identity.walletID,
            addressType: .bip84,
            branch: .external
        )
        #expect(replenished.map(\.derived.index) == Array(0...31))
        #expect(
            try await database.cachedBitcoinHDWIF(
                walletID: identity.walletID,
                addressType: .bip84,
                branch: .external,
                index: 31,
                vault: vault
            ) != nil
        )
        #expect(
            try await database.cachedBitcoinHDWIF(
                walletID: identity.walletID,
                addressType: .bip84,
                branch: .external,
                index: 32,
                vault: vault
            ) == nil
        )
    }

    @Test
    func staleFullDiscoveryCannotOverwriteNewerBitcoinBalance()
        async throws
    {
        let fixture = try await Self.seededDatabase()
        let database = fixture.database
        let walletID = fixture.walletID
        _ = try await database.ensureBitcoinHDWallet(walletID: walletID)

        let staleState = try #require(
            try await database.bitcoinHDAddresses(
                walletID: walletID,
                addressType: .bip84,
                branch: .external
            ).first
        )
        let fundedAmount = try BitcoinFamilyAtomicInteger(
            validating: "6281"
        )
        try await database.saveBitcoinHDAddressStates(
            [
                BitcoinHDAddressState(
                    derived: staleState.derived,
                    isUsed: true,
                    isReserved: false,
                    confirmedBalanceAtomic: fundedAmount,
                    unconfirmedBalanceAtomic: .zero
                )
            ],
            walletID: walletID
        )

        // This is the zero observation held by a slower history discovery
        // that began before the balance-only request completed.
        try await database.saveBitcoinHDAddressDiscoveryStates(
            [
                BitcoinHDAddressState(
                    derived: staleState.derived,
                    isUsed: true,
                    isReserved: false,
                    confirmedBalanceAtomic: .zero,
                    unconfirmedBalanceAtomic: .zero
                )
            ],
            walletID: walletID
        )

        let persisted = try #require(
            try await database.bitcoinHDAddresses(
                walletID: walletID,
                addressType: .bip84,
                branch: .external
            ).first(where: {
                $0.derived.index == staleState.derived.index
            })
        )
        #expect(persisted.confirmedBalanceAtomic == fundedAmount)
        #expect(persisted.isUsed)
    }

    @Test
    func recoveryPhraseImportLazilyCreatesPublicAndPrivatePools()
        async throws
    {
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(
            service: "bitcoin-hd-import-tests.\(UUID().uuidString)"
        )
        defer { try? vault.deleteAll() }
        let mnemonic = WalletCredentialTestFixtures.recoveryPhrase()
        let creation = try WalletCoreService.restoreEVMWallet(
            mnemonic: mnemonic
        )
        let imported = WalletImportDraft(
            secret: .recoveryPhrase(
                mnemonic: creation.mnemonic,
                passphrase: creation.passphrase,
                wordCount: creation.words.count
            ),
            address: creation.address,
            normalizedAddress: creation.normalizedAddress,
            derivationPath: creation.derivationPath,
            publicKey: creation.publicKey
        )
        let identity = try await database.persistImportedWallet(
            draft: imported,
            security: .reuseExistingProfile,
            vault: vault
        )
        #expect(
            try await database.bitcoinReceiveAddressType(
                walletID: identity.walletID
            ) == .bip84
        )
        #expect(
            try await database.bitcoinHDAddresses(
                walletID: identity.walletID
            ).isEmpty
        )
        #expect(
            try await database.ensureBitcoinHDWallet(
                walletID: identity.walletID,
                vault: vault
            )
        )

        #expect(
            try await database.bitcoinHDAddresses(
                walletID: identity.walletID
            ).count == BitcoinHDAddressType.allCases.count * 2 * 20
        )
        let cacheCount = try await database.pool.read { rawDatabase in
            try DBBitcoinHDKeyCacheRecord
                .filter(Column("walletID") == identity.walletID)
                .fetchCount(rawDatabase)
        }
        #expect(cacheCount == BitcoinHDAddressType.allCases.count * 2)
        for addressType in BitcoinHDAddressType.allCases {
            for branch in [
                BitcoinHDAddressBranch.external,
                BitcoinHDAddressBranch.change
            ] {
                #expect(
                    try await database.cachedBitcoinHDWIF(
                        walletID: identity.walletID,
                        addressType: addressType,
                        branch: branch,
                        index: 19,
                        vault: vault
                    ) != nil
                )
            }
        }
    }

    @Test
    func concurrentChangeReservationsNeverReuseAChild() async throws {
        let fixture = try await Self.seededDatabase()
        let database = fixture.database
        let walletID = fixture.walletID
        _ = try await database.ensureBitcoinHDWallet(
            walletID: walletID
        )

        let reservations = try await withThrowingTaskGroup(
            of: BitcoinHDDerivedAddress.self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    try #require(
                        await database.reserveFreshBitcoinChangeAddress(
                            walletID: walletID,
                            addressType: .bip84
                        )
                    )
                }
            }
            var results: [BitcoinHDDerivedAddress] = []
            while let result = try await group.next() {
                results.append(result)
            }
            return results
        }
        #expect(Set(reservations.map(\.address)).count == 8)
        #expect(Set(reservations.map(\.index)) == Set(0..<8))
        #expect(reservations.allSatisfy { $0.branch == .change })
    }

    @Test
    func professionalAddressSelectionControlsFreshReceiveAndNextChange()
        async throws {
        let fixture = try await Self.seededDatabase()
        let database = fixture.database
        let walletID = fixture.walletID
        _ = try await database.ensureBitcoinHDWallet(walletID: walletID)

        try await database.setBitcoinHDPreferredAddress(
            walletID: walletID,
            addressType: .bip84,
            branch: .external,
            index: 12
        )
        let receive = try #require(
            await database.freshBitcoinReceiveAddress(
                walletID: walletID,
                addressType: .bip84
            )
        )
        #expect(receive.index == 12)
        #expect(
            try await database.bitcoinHDPreferredAddressIndex(
                walletID: walletID,
                addressType: .bip84,
                branch: .external
            ) == 12
        )

        try await database.setBitcoinHDPreferredAddress(
            walletID: walletID,
            addressType: .bip84,
            branch: .change,
            index: 9
        )
        let change = try #require(
            await database.reserveFreshBitcoinChangeAddress(
                walletID: walletID,
                addressType: .bip84
            )
        )
        #expect(change.index == 9)
        #expect(
            try await database.bitcoinHDPreferredAddressIndex(
                walletID: walletID,
                addressType: .bip84,
                branch: .change
            ) == nil
        )
        let next = try #require(
            await database.reserveFreshBitcoinChangeAddress(
                walletID: walletID,
                addressType: .bip84
            )
        )
        #expect(next.index == 10)
    }

    @Test
    func manualGenerationCreatesEveryChildAndKeyCacheThroughTarget()
        async throws {
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(
            service: "bitcoin-hd-generation-tests.\(UUID().uuidString)"
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

        let generated = try await database.generateBitcoinHDAddresses(
            walletID: identity.walletID,
            addressType: .bip86,
            branch: .external,
            through: 35,
            vault: vault
        )
        #expect(generated.map(\.derived.index) == Array(0...35))
        #expect(
            try await database.cachedBitcoinHDWIF(
                walletID: identity.walletID,
                addressType: .bip86,
                branch: .external,
                index: 35,
                vault: vault
            ) != nil
        )
    }

    @Test
    func settingsBalanceCombinesEveryHDTypeAndSilentPayments()
        async throws {
        let fixture = try await Self.seededDatabase()
        let database = fixture.database
        let walletID = fixture.walletID
        _ = try await database.ensureBitcoinHDWallet(walletID: walletID)

        let states = try await database.bitcoinHDAddresses(
            walletID: walletID
        )
        var funded: [BitcoinHDAddressState] = []
        for (offset, addressType) in BitcoinHDAddressType.allCases.enumerated() {
            let address = try #require(states.first {
                $0.derived.addressType == addressType
                    && $0.derived.branch == .external
                    && $0.derived.index == 0
            })
            funded.append(
                BitcoinHDAddressState(
                    derived: address.derived,
                    isUsed: true,
                    isReserved: false,
                    confirmedBalanceAtomic:
                        try BitcoinFamilyAtomicInteger(
                            validating: String((offset + 1) * 1_000)
                        ),
                    unconfirmedBalanceAtomic: .zero
                )
            )
        }
        try await database.saveBitcoinHDAddressStates(
            funded,
            walletID: walletID
        )

        let silentAddress = try BitcoinSilentPaymentAddress(
            "sp1qqgste7k9hx0qftg6qmwlkqtwuy6cycyavzmzj85c6qdfhjdpdjtdgqjuex"
                + "zk6murw56suy3e0rd2cgqvycxttddwsvgxe2usfpxumr70xc9pkqwv"
        )
        let outputPublicKey = Data(repeating: 0x07, count: 32)
        let now = Date().timeIntervalSince1970
        try await database.pool.write { rawDatabase in
            try DBBitcoinSilentPaymentAccountRecord(
                walletID: walletID,
                address: silentAddress.encoded,
                scanPublicKey: silentAddress.scanPublicKey,
                spendPublicKey: silentAddress.spendPublicKey,
                keychainReference: "test-silent-account",
                birthHeight:
                    WalletDatabase.bitcoinSilentPaymentActivationHeight,
                lastScanHeight:
                    WalletDatabase.bitcoinSilentPaymentActivationHeight - 1,
                balanceIsAuthoritative: false,
                createdAt: now,
                updatedAt: now
            ).insert(rawDatabase)
            try DBBitcoinSilentPaymentOutputRecord(
                walletID: walletID,
                transactionHash: String(repeating: "ab", count: 32),
                outputIndex: 0,
                valueAtomic: "5000",
                scriptPubKey: Data([0x51, 0x20]) + outputPublicKey,
                outputPublicKey: outputPublicKey,
                keychainReference: "test-silent-output",
                blockHeight: 800_000,
                blockTimestamp: nil,
                isSpent: false,
                spentByTransactionHash: nil,
                createdAt: now,
                updatedAt: now
            ).insert(rawDatabase)
        }

        let snapshot = try await BitcoinWalletSettingsRepository(
            database: database
        ).load(walletID: walletID)
        #expect(snapshot.types.count == BitcoinHDAddressType.allCases.count)
        #expect(snapshot.silentPayments.balanceAtomic.decimalText == "5000")
        #expect(snapshot.balanceAtomic.decimalText == "26000")
    }

    private static func seededDatabase() async throws -> (
        database: WalletDatabase,
        walletID: String
    ) {
        let database = try WalletDatabase.temporary()
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.mnemonic
        )
        let wallet = try #require(credential.makeHDWallet())
        let derivation = BitcoinHDDerivationService()
        let descriptors = try derivation.accountDescriptors(wallet: wallet)
        let initial = try derivation.deriveAddress(
            wallet: wallet,
            addressType: .bip84,
            branch: .external,
            index: 0
        )
        let walletID = UUID().uuidString.lowercased()
        let now = Date().timeIntervalSince1970
        try await database.pool.write { rawDatabase in
            try DBWalletRecord(
                id: walletID,
                profileID: WalletDatabase.defaultProfileID,
                name: "Bitcoin HD Test Wallet",
                kind: DatabaseWalletKind.importedRecoveryPhrase.rawValue,
                secretKeyReference: nil,
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil
            ).insert(rawDatabase)
            try DBWalletAccountRecord(
                id: "\(walletID):bitcoin:0",
                walletID: walletID,
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                address: initial.address,
                normalizedAddress: initial.address.lowercased(),
                label: nil,
                derivationPath: initial.derivationPath,
                accountIndex: 0,
                publicKey: initial.publicKey.hexString,
                isWatchOnly: false,
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil
            ).insert(rawDatabase)
            for descriptor in descriptors {
                try DBBitcoinHDAccountRecord(
                    walletID: walletID,
                    addressType: descriptor.addressType.rawValue,
                    accountIndex: descriptor.accountIndex,
                    accountPath: descriptor.accountPath,
                    extendedPublicKey: descriptor.extendedPublicKey,
                    createdAt: now,
                    updatedAt: now
                ).insert(rawDatabase)
            }
        }
        return (database, walletID)
    }

    private static func state(
        _ address: BitcoinHDDerivedAddress,
        isUsed: Bool,
        isReserved: Bool
    ) -> BitcoinHDAddressState {
        BitcoinHDAddressState(
            derived: address,
            isUsed: isUsed,
            isReserved: isReserved,
            confirmedBalanceAtomic: .zero,
            unconfirmedBalanceAtomic: .zero
        )
    }

    private struct Vector {
        let extendedPublicKey: String
        let external0: String
        let external1: String
        let change0: String
        let external0WIF: String
    }
}

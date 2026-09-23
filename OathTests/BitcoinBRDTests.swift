import Foundation
import GRDB
import Testing
import WalletCore
@testable import Aperture

struct BitcoinBRDTests {
    // Public BIP39 test vector, never a user's wallet. Expected values were
    // independently generated with bip_utils, not this app's derivation code.
    static let mnemonic = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"
    static let xpub = "xpub68jrRzQopSUQm76hJ6TNtiJMJfhj38u1X12xCzExrw388hcN443UVnYpswdUkV7vPJ3KayiCdp3Q5E23s4wvkucohVTh7eSstJdBFyn2DMx"
    struct Vector: Sendable, CustomTestStringConvertible {
        var testDescription: String { "public fixture branch \(branch), index \(index)" }
        let branch: Int
        let index: Int
        let legacy: String
        let segwit: String
        let publicKey: String
        let wif: String
    }
    static let vectors: [Vector] = [
        Vector(branch: 0, index: 0, legacy: "17871ErDqdevLTLWBH6WzjUc1EKGDQzCMA", segwit: "bc1qgv52mt89gpev6p56huggl970sppqkgftxakv7f", publicKey: "026666422d00f1b308fc7527198749f06fedb028b979c09f60d0348ef79c985e41", wif: "L4zvqB8Cme7xRmTWxQ6TVmQs7smCNKD1rfAKmYZx6DAqyLjm4sp4"),
        Vector(branch: 0, index: 1, legacy: "1B4ynFJzDPqvuttzgF16jccWGxvdJwHSWr", segwit: "bc1qdec7wsahwjs4tgg7a66gk9g7vul0ufjhemdpqz", publicKey: "0384257cf895f1ca492bbee5d7485ae0ef479036fdf59e15b92e37970a98d6fe75", wif: "Kze6YryiB5bfUTddt8fQi2ZPY2f944W1PWuJPFf5CSTy1owCpQGZ"),
        Vector(branch: 0, index: 19, legacy: "13fLv5Xn9AMVcjuJ5TFiqbHXe9sJZP9qt6", segwit: "bc1qr5c2adpn0y7dl6spy5dk7wafzxv9ztuuq4e5lm", publicKey: "0269b798f6b2cd179a4f82bb3fb36853930962e51f3bba0cea2930c9e00f65cf81", wif: "L5NVHYhHsCkKFg9uqiXB66tMTn7djJ9ZcmVRNbnfPC4HE1VQyZdL"),
        Vector(branch: 1, index: 0, legacy: "1MseVFBWLkbPeGMpkAsahBujinBq3QjGo4", segwit: "bc1qunmfkdmckn76c8nmf3g22du699gne5q8c3xqhl", publicKey: "030247a355c3263a69dce173ac12fcc49408260b76b089ab02dc68f3389fc57cb8", wif: "KxiKRsSXMTSzAeBMyriBwDbu482pdWHAE5cGYNiFQNMaYwRJKkTB"),
        Vector(branch: 1, index: 1, legacy: "1AopQaJaiEt9sw2cDyf3CqSHZfiNtrWzxd", segwit: "bc1qdwfad4n29p6kwh7dh6ecz0c8uv4z0u0f0njxhf", publicKey: "0394e33c4c819a55235cde10baed2df62f2787be0607d920dc3947069b23633022", wif: "L4tetqr49fjQreYr6nMJyPsBERh9XvWoWWyNz9NHeEUs9CsFV6xK"),
        Vector(branch: 1, index: 19, legacy: "17WN3LW1wDuMC9uxQeJBfz36uVZrK8M32v", segwit: "bc1qga0xryskut8ejh7thwyjtttrn7rg8nu3jfc6st", publicKey: "0286ac5c8dba3d0929942f5eb6581533de976178294bdb8bdb6127e9a1c3e04f2f", wif: "L3fKujUFPCdc68VqxesLXa9F5NFuvuDvz7HWGYvKnZNbn28PxTnz"),
    ]

    @Test(arguments: [BitcoinHDAddressType.brdLegacy, .brdSegwit], vectors)
    func matchesIndependentPublicAndPrivateVectors(type: BitcoinHDAddressType, vector: Vector) throws {
        let wallet = try #require(HDWallet(mnemonic: Self.mnemonic, passphrase: ""))
        let descriptor = try BitcoinBRDDerivation.accountDescriptor(wallet: wallet, type: type)
        #expect(descriptor.extendedPublicKey == Self.xpub)
        #expect(descriptor.accountPath == "m/0'")
        let branch = try #require(BitcoinHDAddressBranch(rawValue: vector.branch))
        let service = BitcoinHDDerivationService()
        let derived = try service.deriveAddress(descriptor: descriptor, branch: branch, index: vector.index)
        #expect(derived.address == (type == .brdLegacy ? vector.legacy : vector.segwit))
        #expect(derived.publicKey.hexString == vector.publicKey)
        #expect(derived.derivationPath == "m/0'/\(vector.branch)/\(vector.index)")
        #expect(try service.deriveAddress(wallet: wallet, addressType: type, branch: branch, index: vector.index) == derived)
        let key = try service.privateKey(wallet: wallet, addressType: type, branch: branch, index: vector.index)
        #expect(BitcoinHDDerivationService.bitcoinWIF(privateKey: key) == vector.wif)
        #expect(BitcoinHDAddressType.location(for: derived.derivationPath, addressType: type)?.addressType == type)
        #expect(SendBitcoinTransactionPolicy.changeOutputScriptSize(for: type) == derived.scriptPubKey.count)
    }

    @Test
    func rejectsWrongAccountRootsVersionsAndHardenedChildIndexes() throws {
        let wallet = try #require(HDWallet(mnemonic: Self.mnemonic, passphrase: ""))
        let service = BitcoinHDDerivationService()
        let correct = try BitcoinBRDDerivation.accountDescriptor(wallet: wallet, type: .brdSegwit)
        let wrongRoot = wallet.getExtendedPublicKeyAccount(purpose: .bip44, coin: .bitcoin, derivation: .default, version: .xpub, account: 0)
        for key in ["invalid", String(Self.xpub.dropLast()) + "1", wrongRoot] {
            let descriptor = BitcoinHDAccountDescriptor(addressType: .brdSegwit, accountIndex: 0, accountPath: "m/0'", extendedPublicKey: key)
            #expect(throws: (any Error).self) { try service.deriveAddress(descriptor: descriptor, branch: .external, index: 0) }
        }
        for index in [-1, Int(0x8000_0000 as UInt32)] {
            #expect(throws: (any Error).self) { try service.deriveAddress(descriptor: correct, branch: .external, index: index) }
        }
        #expect(BitcoinHDAddressType.location(for: "m/0'/0/2147483648", addressType: .brdSegwit) == nil)
        #expect(BitcoinHDAddressType.location(for: "m/84'/0'/0'/0/0", addressType: .brdSegwit) == nil)
    }

    @Test
    func sharesKeysButNeverAddressesOrSingleKeyAliases() throws {
        let wallet = try #require(HDWallet(mnemonic: Self.mnemonic, passphrase: ""))
        let service = BitcoinHDDerivationService()
        let descriptors = try service.accountDescriptors(wallet: wallet)
        #expect(descriptors.count == 6)
        let addresses = try descriptors.map { try service.deriveAddress(descriptor: $0, branch: .external, index: 0) }
        #expect(Set(addresses.map(\.address)).count == 6)
        let legacy = try #require(addresses.first { $0.addressType == .brdLegacy })
        let segwit = try #require(addresses.first { $0.addressType == .brdSegwit })
        #expect(legacy.publicKey == segwit.publicKey)
        #expect(legacy.scriptHash != segwit.scriptHash)
        let credential = try WalletRecoveryCredential(mnemonic: Self.mnemonic)
        for address in [legacy, segwit] {
            #expect(BitcoinHDAddressType.location(for: address.derivationPath, address: address.address, credential: credential)?.addressType == address.addressType)
        }
        let key = try service.privateKey(wallet: wallet, addressType: .brdLegacy, branch: .external, index: 0)
        #expect(try service.singleKeyAddresses(privateKeyData: key.data, format: .wifCompressed).count == 4)
    }

    @Test
    func migrationPreservesExistingRowsAndAllowsSharedBRDPath() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("fixture") { db in
            try db.execute(sql: "CREATE TABLE wallets(id TEXT PRIMARY KEY); INSERT INTO wallets VALUES ('fixture');")
        }
        WalletDatabase.registerBitcoinHDWalletMigration(on: &migrator)
        WalletDatabase.registerBitcoinHDChangeReservationMigration(on: &migrator)
        WalletDatabase.registerBitcoinHDKeyCacheMigration(on: &migrator)
        WalletDatabase.registerBitcoinSilentPaymentMigration(on: &migrator)
        WalletDatabase.registerBitcoinHDAddressSelectionMigration(on: &migrator)
        try migrator.migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO bitcoinHDAccounts VALUES ('fixture', 'bip84', 0, 'm/84''/0''/0''', 'old-public-root', 1, 2);
                INSERT INTO bitcoinHDAddresses
                    (walletID,addressType,branch,addressIndex,derivationPath,address,publicKey,scriptPubKey,scriptHash,
                     isUsed,isReserved,confirmedBalanceAtomic,unconfirmedBalanceAtomic,createdAt,updatedAt)
                    VALUES ('fixture','bip84',1,3,'m/84''/0''/0''/1/3','public-fixture',X'01',X'02','hash',1,1,'12345678901234567890','-123',1,2);
                INSERT INTO bitcoinHDPreferences VALUES ('fixture','bip84',2,1);
                INSERT INTO bitcoinHDKeyCaches VALUES ('fixture','bip84',1,'opaque-keychain-reference',19,1,2);
                INSERT INTO bitcoinHDAddressSelections VALUES ('fixture','bip84',0,1,3,2);
                """)
        }
        let tables = ["bitcoinHDAccounts", "bitcoinHDAddresses", "bitcoinHDPreferences", "bitcoinHDKeyCaches", "bitcoinHDAddressSelections"]
        let before = try queue.read { db in try tables.map { try Row.fetchAll(db, sql: "SELECT * FROM \($0)") } }
        WalletDatabase.registerBitcoinBRDMigration(on: &migrator)
        try migrator.migrate(queue)
        let after = try queue.read { db in try tables.map { try Row.fetchAll(db, sql: "SELECT * FROM \($0)") } }
        #expect(before == after)
        try queue.write { db in
            for type in ["brdLegacy", "brdSegwit"] {
                try db.execute(sql: "INSERT INTO bitcoinHDAccounts VALUES ('fixture', ?, 0, ?, ?, 3, 3)",
                               arguments: [type, "m/0'", Self.xpub])
                try db.execute(sql: "INSERT INTO bitcoinHDKeyCaches VALUES ('fixture', ?, 0, ?, 19, 3, 3)",
                               arguments: [type, "opaque-" + type])
                try db.execute(sql: "UPDATE bitcoinHDPreferences SET receiveAddressType = ?", arguments: [type])
            }
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bitcoinHDAccounts") == 3)
        }
    }

    @Test
    func existingWalletAddsBRDWithoutResettingExistingState() async throws {
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(service: "brd-upgrade-tests.\(UUID())")
        defer { try? vault.deleteAll() }
        let creation = try WalletCoreService.restoreEVMWallet(mnemonic: WalletCredentialTestFixtures.recoveryPhrase())
        let draft = WalletImportDraft(
            secret: .recoveryPhrase(mnemonic: creation.mnemonic, passphrase: creation.passphrase, wordCount: creation.words.count),
            address: creation.address, normalizedAddress: creation.normalizedAddress,
            derivationPath: creation.derivationPath, publicKey: creation.publicKey
        )
        let identity = try await database.persistImportedWallet(draft: draft, security: .reuseExistingProfile, vault: vault)
        try await database.ensureBitcoinHDWallet(walletID: identity.walletID, vault: vault)
        let walletID = identity.walletID
        // Model an existing four-format wallet with a funded/reserved change address.
        try await database.pool.write { db in
            try db.execute(sql: "DELETE FROM bitcoinHDAccounts WHERE walletID = ? AND addressType IN ('brdLegacy','brdSegwit')", arguments: [walletID])
            try db.execute(sql: "DELETE FROM bitcoinHDKeyCaches WHERE walletID = ? AND addressType IN ('brdLegacy','brdSegwit')", arguments: [walletID])
            try db.execute(sql: "UPDATE bitcoinHDPreferences SET receiveAddressType = 'bip86' WHERE walletID = ?", arguments: [walletID])
            try db.execute(sql: "UPDATE bitcoinHDAddresses SET isUsed = 1, isReserved = 1, confirmedBalanceAtomic = '987654321' WHERE walletID = ? AND addressType = 'bip84' AND branch = 1 AND addressIndex = 0", arguments: [walletID])
        }
        for _ in 0..<2 {
            try await database.ensureBitcoinHDWallet(walletID: walletID, vault: vault)
            #expect(try await database.bitcoinHDAccountDescriptors(walletID: walletID).count == 6)
            #expect(try await database.bitcoinReceiveAddressType(walletID: walletID) == .bip86)
            let addresses = try await database.bitcoinHDAddresses(walletID: walletID)
            let preserved = try #require(addresses.first { $0.derived.addressType == .bip84 && $0.derived.branch == .change && $0.derived.index == 0 })
            #expect(preserved.isUsed && preserved.isReserved)
            #expect(preserved.confirmedBalanceAtomic.decimalText == "987654321")
            #expect(addresses.filter { $0.derived.addressType.isBRD }.count == 80)
        }
        let credential = try WalletRecoveryCredential(mnemonic: creation.mnemonic, passphrase: creation.passphrase)
        let wallet = try #require(credential.makeHDWallet())
        for type in [BitcoinHDAddressType.brdLegacy, .brdSegwit] {
            try await database.setBitcoinReceiveAddressType(type, walletID: walletID)
            let account = try #require(await database.pool.read { db in
                try DBWalletAccountRecord.filter(Column("walletID") == walletID && Column("networkID") == "bitcoin").fetchOne(db)
            })
            let rows = try await database.pool.read { db in
                try DBBitcoinHDAddressRecord.filter(Column("walletID") == walletID).fetchAll(db)
            }
            #expect(BitcoinHDReceiveAccountProjection.matches(account, addresses: rows))
            let derivedIdentity = try DeviceMigrationAccountSecretVerifier.recoveryPhraseIdentity(
                credential: credential, wallet: wallet, account: account, family: .bitcoinFamily
            )
            #expect(derivedIdentity.address == account.address)
            #expect(derivedIdentity.publicKey == account.publicKey)
            #expect(try await database.restoreBitcoinStandardReceiveAddressType(walletID: walletID) == type)
        }
    }

#if LIVE_MAINNET_TESTS
    @Test
    func liveMainnetReadsBothBRDFormatsAndBranches() async throws {
        let descriptors = [BitcoinHDAddressType.brdLegacy, .brdSegwit].map {
            BitcoinHDAccountDescriptor(addressType: $0, accountIndex: 0, accountPath: "m/0'", extendedPublicKey: Self.xpub)
        }
        let service = BitcoinHDDerivationService()
        var hashes: [String] = []
        for descriptor in descriptors {
            for branch in [BitcoinHDAddressBranch.external, .change] {
                hashes.append(try service.deriveAddress(descriptor: descriptor, branch: branch, index: 0).scriptHash)
            }
        }
        let client = BitcoinFamilyElectrumClient.shared
        for method in ["blockchain.scripthash.get_balance", "blockchain.scripthash.get_history", "blockchain.scripthash.listunspent"] {
            let results = try await client.callStringParameterBatch(chain: .bitcoin, method: method, parameters: hashes)
            #expect(results.count == 4)
            for result in results {
                if method.hasSuffix("get_balance") {
                    #expect(result.value.object?["confirmed"]?.atomicInteger != nil)
                    #expect(result.value.object?["unconfirmed"]?.atomicInteger != nil)
                } else { #expect(result.value.array != nil) }
            }
        }
    }
#endif
}

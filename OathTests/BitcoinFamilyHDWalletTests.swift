import Foundation
import GRDB
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct BitcoinFamilyHDWalletTests {
    private static let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    @Test
    func publishedMnemonicProducesIndependentMainnetAccounts() throws {
        let credential = try WalletRecoveryCredential(mnemonic: Self.mnemonic)
        let vectors: [(BitcoinFamilyChain, BitcoinHDAddressType, String)] = [
            (.dogecoin, .bip44, "DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC"),
            (.litecoin, .bip44, "LUWPbpM43E2p7ZSh8cyTBEkvpHmr3cB8Ez"),
            (.litecoin, .bip49, "M7wtsL7wSHDBJVMWWhtQfTMSYYkyooAAXM"),
            (.litecoin, .bip84, "ltc1qjmxnz78nmc8nq77wuxh25n2es7rzm5c2rkk4wh"),
            (.bitcoinCash, .bip44, "bitcoincash:qqyx49mu0kkn9ftfj6hje6g2wfer34yfnq5tahq3q6"),
        ]
        for (chain, type, expected) in vectors {
            let descriptor = try #require(BitcoinFamilyHDDerivation.descriptors(credential: credential, chain: chain).first { $0.type == type })
            let child = try BitcoinFamilyHDDerivation.address(descriptor: descriptor, branch: .external, index: 0)
            #expect(child.address == expected)
            #expect(child.derivationPath == "m/\(type.purposeNumber)'/\(chain.coin.rawValue)'/0'/0/0")
            let change = try BitcoinFamilyHDDerivation.address(descriptor: descriptor, branch: .change, index: 4)
            let key = try BitcoinFamilyHDDerivation.privateKey(credential: credential, chain: chain, owner: change)
            #expect(key.getPublicKeySecp256k1(compressed: true).data == change.publicKey)
            #expect(change.address != child.address)
        }
        #expect(BitcoinFamilyHDDerivation.gapLimit == 5)
        #expect(BitcoinHDDerivationService.gapLimit == 20)
    }

    @Test
    func gapUsesHistoryAndHonorsRememberedChangeAddresses() async throws {
        let states = try await HDGapDiscovery.scan(gapLimit: 5, highestKnownUsedIndex: -1) { range in
            range.map { HDGapDiscovery.Observation(index: $0, isUsed: [4, 9].contains($0), value: $0) }
        }
        #expect(states == Array(0..<15))
        let remembered = try await HDGapDiscovery.scan(gapLimit: 5, highestKnownUsedIndex: 20) { range in
            range.map { HDGapDiscovery.Observation(index: $0, isUsed: false, value: $0) }
        }
        #expect(remembered == Array(0..<26))
        await #expect(throws: HDGapDiscovery.Failure.self) {
            try await HDGapDiscovery.scan(gapLimit: 5, highestKnownUsedIndex: -1) { _ in
                [HDGapDiscovery.Observation(index: 0, isUsed: false, value: 0)]
            }
        }
    }

    @Test
    func existingMnemonicWalletLazilyInitializesAllThreeChainsWithoutChangingAccounts() async throws {
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(service: "family-hd-tests.\(UUID().uuidString)")
        defer { try? vault.deleteAll() }
        let draft = try WalletCoreService.restoreEVMWallet(mnemonic: Self.mnemonic)
        let identity = try await database.persistCreatedWallet(draft: draft, security: .reuseExistingProfile, vault: vault)
        let original = try await database.pool.read {
            try DBWalletAccountRecord.filter(Column("walletID") == identity.walletID).fetchAll($0)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for chain in [BitcoinFamilyChain.dogecoin, .litecoin, .bitcoinCash] {
                group.addTask {
                    #expect(try await database.ensureBitcoinFamilyHDWallet(walletID: identity.walletID, chain: chain, vault: vault))
                    let states = try await database.bitcoinFamilyHDAddresses(walletID: identity.walletID, chain: chain)
                    #expect(states.count == chain.familyHDTypes.count * 2 * 5)
                    let first = try await database.freshBitcoinFamilyHDAddress(walletID: identity.walletID, chain: chain)
                    let account = try #require(original.first { $0.networkID == chain.networkID })
                    #expect(first.address == account.address)
                    let changes = try await withThrowingTaskGroup(of: BitcoinHDDerivedAddress.self) { reservations in
                        for _ in 0..<5 {
                            reservations.addTask {
                                try await database.freshBitcoinFamilyHDAddress(walletID: identity.walletID, chain: chain,
                                    branch: .change, reserve: true)
                            }
                        }
                        var values: [BitcoinHDDerivedAddress] = []
                        for try await value in reservations { values.append(value) }
                        return values
                    }
                    #expect(Set(changes.map(\.index)) == Set(0..<5))
                    let current = try await database.pool.read { try DBWalletAccountRecord.fetchOne($0, key: account.id) }
                    #expect(current?.address == account.address)
                    #expect(current?.derivationPath == account.derivationPath)
                }
            }
            try await group.waitForAll()
        }
    }
}

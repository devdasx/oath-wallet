#if LIVE_MAINNET_TESTS
import CryptoKit
import Foundation
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct LiveBitcoinHDIntegrationTests {
    private static let fixtureMnemonic =
        "abandon abandon abandon abandon abandon abandon abandon abandon "
        + "abandon abandon abandon about"

    @Test
    func literalExtendedPublicKeysAndAddressesResolveOnMainnet()
        async throws
    {
        let vectors: [(
            type: BitcoinHDAddressType,
            extendedPublicKey: String,
            address: String
        )] = [
            (
                .bip44,
                "xpub6BosfCnifzxcFwrSzQiqu2DBVTshkCXacvNsWGYJ"
                    + "VVhhawA7d4R5WSWGFNbi8Aw6ZRc1brxMyWMzG3DSSS"
                    + "SoekkudhUd9yLb6qx39T9nMdj",
                "1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA"
            ),
            (
                .bip49,
                "ypub6Ww3ibxVfGzLrAH1PNcjyAWenMTbbAosGNB6Vvm"
                    + "SEgytSER9azLDWCxoJwW7Ke7icmizBMXrzBx9979Ffa"
                    + "HxHcrArf3zbeJJJUZPf663zsP",
                "37VucYSaXLCAsxYyAPfbSi9eh4iEcbShgf"
            ),
            (
                .bip84,
                "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYf"
                    + "G1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUU"
                    + "kgDKf31mGDtKsAYz2oz2AGutZYs",
                "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"
            ),
            (
                .bip86,
                "xpub6BgBgsespWvERF3LHQu6CnqdvfEvtMcQjYrcRzx"
                    + "53QJjSxarj2afYWcLteoGVky7D3UKDP9QyrLprQ3V"
                    + "CECoY49yfdDEHGCtMMj92pReUsQ",
                "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20"
                    + "cac6yqjjwudpxqkedrcr"
            ),
        ]
        let derivation = BitcoinHDDerivationService()
        var scriptHashes: [String] = []

        for vector in vectors {
            let derived = try derivation.deriveAddress(
                descriptor: BitcoinHDAccountDescriptor(
                    addressType: vector.type,
                    accountIndex: 0,
                    accountPath: vector.type.accountPath,
                    extendedPublicKey: vector.extendedPublicKey
                ),
                branch: .external,
                index: 0
            )
            #expect(derived.address == vector.address)

            let directScript = BitcoinScript.lockScriptForAddress(
                address: vector.address,
                coin: .bitcoin
            ).data
            let directScriptHash = Data(SHA256.hash(data: directScript))
                .reversed()
                .map { String(format: "%02x", $0) }
                .joined()
            #expect(derived.scriptHash == directScriptHash)
            scriptHashes.append(directScriptHash)
        }

        async let balancesValue = BitcoinFamilyElectrumClient.shared
            .callStringParameterBatch(
                chain: .bitcoin,
                method: "blockchain.scripthash.get_balance",
                parameters: scriptHashes
            )
        async let historiesValue = BitcoinFamilyElectrumClient.shared
            .callStringParameterBatch(
                chain: .bitcoin,
                method: "blockchain.scripthash.get_history",
                parameters: scriptHashes,
                maximumResponseBytes:
                    BitcoinFamilyElectrumClient.maximumHistoryResponseBytes
            )
        let (balances, histories) = try await (
            balancesValue,
            historiesValue
        )

        #expect(balances.count == vectors.count)
        #expect(histories.count == vectors.count)
        #expect(balances.allSatisfy {
            $0.value.object?["confirmed"]?.atomicInteger != nil
                && $0.value.object?["unconfirmed"]?.atomicInteger != nil
        })
        #expect(histories.allSatisfy { $0.value.array != nil })
    }

    @Test
    func publicWIFImportResolvesEveryOwnedScriptOnMainnet() async throws {
        let privateKey = Data(repeating: 0, count: 31) + Data([0x01])
        var compressedPayload = Data([0x80])
        compressedPayload.append(privateKey)
        compressedPayload.append(0x01)
        let publicTestWIF = Base58.encode(data: compressedPayload)
        let draft = try PrivateKeyImportService.importKey(
            publicTestWIF,
            network: .bitcoin
        )
        guard case let .privateKey(
            importedKey,
            importedNetwork,
            importedFormat
        ) = draft.secret else {
            Issue.record("Expected a Bitcoin private-key import draft")
            return
        }
        #expect(importedKey == privateKey)
        #expect(importedNetwork == .bitcoin)
        #expect(importedFormat == .wifCompressed)

        let compressedAddresses = try BitcoinHDDerivationService()
            .singleKeyAddresses(
                privateKeyData: importedKey,
                format: importedFormat
            )
        let uncompressedAddresses = try BitcoinHDDerivationService()
            .singleKeyAddresses(
                privateKeyData: privateKey,
                format: .wifUncompressed
            )
        #expect(
            Set(compressedAddresses.map(\.addressType))
                == Set(BitcoinHDAddressType.allCases)
        )
        #expect(uncompressedAddresses.map(\.addressType) == [.bip44])
        let scriptHashes = (
            compressedAddresses + uncompressedAddresses
        ).map(\.scriptHash)

        async let balancesValue = BitcoinFamilyElectrumClient.shared
            .callStringParameterBatch(
                chain: .bitcoin,
                method: "blockchain.scripthash.get_balance",
                parameters: scriptHashes
            )
        async let historiesValue = BitcoinFamilyElectrumClient.shared
            .callStringParameterBatch(
                chain: .bitcoin,
                method: "blockchain.scripthash.get_history",
                parameters: scriptHashes,
                maximumResponseBytes:
                    BitcoinFamilyElectrumClient.maximumHistoryResponseBytes
            )
        let (balances, histories) = try await (
            balancesValue,
            historiesValue
        )

        #expect(balances.count == scriptHashes.count)
        #expect(histories.count == scriptHashes.count)
        #expect(balances.allSatisfy {
            $0.value.object?["confirmed"]?.atomicInteger != nil
                && $0.value.object?["unconfirmed"]?.atomicInteger != nil
        })
        #expect(histories.allSatisfy { $0.value.array != nil })
    }

    @Test
    func balanceOnlyScansFiveThousandRealDerivedAddresses() async throws {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.fixtureMnemonic
        )
        let wallet = try #require(credential.makeHDWallet())
        let derivation = BitcoinHDDerivationService()
        let descriptors = try derivation.accountDescriptors(wallet: wallet)
        let byType = Dictionary(
            uniqueKeysWithValues: descriptors.map {
                ($0.addressType, $0)
            }
        )
        var scriptHashes: [String] = []
        scriptHashes.reserveCapacity(5_000)
        for addressType in BitcoinHDAddressType.allCases {
            let descriptor = try #require(byType[addressType])
            for branch in [
                BitcoinHDAddressBranch.external,
                BitcoinHDAddressBranch.change
            ] {
                for index in 0..<625 {
                    scriptHashes.append(
                        try derivation.deriveAddress(
                            descriptor: descriptor,
                            branch: branch,
                            index: index
                        ).scriptHash
                    )
                }
            }
        }

        let coldStarted = ContinuousClock.now
        let coldBalances = try await BitcoinFamilyElectrumClient.shared
            .callStringParameterBatch(
                chain: .bitcoin,
                method: "blockchain.scripthash.get_balance",
                parameters: scriptHashes
            )
        let coldElapsed = coldStarted.duration(to: .now)
        print(
            "[BalanceBenchmark] bitcoin 5000 cold addresses: \(coldElapsed)"
        )

        let warmStarted = ContinuousClock.now
        let warmBalances = try await BitcoinFamilyElectrumClient.shared
            .callStringParameterBatch(
                chain: .bitcoin,
                method: "blockchain.scripthash.get_balance",
                parameters: scriptHashes
            )
        let warmElapsed = warmStarted.duration(to: .now)
        print(
            "[BalanceBenchmark] bitcoin 5000 warm addresses: \(warmElapsed)"
        )

        #expect(coldBalances.count == 5_000)
        #expect(warmBalances.count == 5_000)
        #expect(coldBalances.allSatisfy {
            $0.value.object?["confirmed"]?.atomicInteger != nil
                && $0.value.object?["unconfirmed"]?.atomicInteger != nil
        })
        #expect(warmBalances.allSatisfy {
            $0.value.object?["confirmed"]?.atomicInteger != nil
                && $0.value.object?["unconfirmed"]?.atomicInteger != nil
        })
    }

    @Test
    func batchesFiveThousandAddressesAcrossVerifiedPool() async throws {
        let credential = try WalletRecoveryCredential(
            mnemonic: Self.fixtureMnemonic
        )
        let wallet = try #require(credential.makeHDWallet())
        let derivation = BitcoinHDDerivationService()
        let descriptors = try derivation.accountDescriptors(wallet: wallet)
        let byType = Dictionary(
            uniqueKeysWithValues: descriptors.map {
                ($0.addressType, $0)
            }
        )
        var derived: [BitcoinHDDerivedAddress] = []
        derived.reserveCapacity(5_000)
        for addressType in BitcoinHDAddressType.allCases {
            let descriptor = try #require(byType[addressType])
            for branch in [
                BitcoinHDAddressBranch.external,
                BitcoinHDAddressBranch.change
            ] {
                for index in 0..<625 {
                    derived.append(
                        try derivation.deriveAddress(
                            descriptor: descriptor,
                            branch: branch,
                            index: index
                        )
                    )
                }
            }
        }
        #expect(derived.count == 5_000)
        #expect(Set(derived.map(\.address)).count == 5_000)
        #expect(Set(derived.map(\.scriptHash)).count == 5_000)

        let fundedAddress = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
        let fundedScript = BitcoinScript.lockScriptForAddress(
            address: fundedAddress,
            coin: .bitcoin
        ).data
        let fundedScriptHash = Data(SHA256.hash(data: fundedScript))
            .reversed()
            .map { String(format: "%02x", $0) }
            .joined()
        let derivedHashes = derived.map(\.scriptHash)

        async let balancesValue = BitcoinFamilyElectrumClient.shared
            .callStringParameterBatch(
                chain: .bitcoin,
                method: "blockchain.scripthash.get_balance",
                parameters: derivedHashes + [fundedScriptHash]
            )
        async let historiesValue = BitcoinFamilyElectrumClient.shared
            .callStringParameterBatch(
                chain: .bitcoin,
                method: "blockchain.scripthash.get_history",
                parameters: derivedHashes,
                maximumResponseBytes:
                    BitcoinFamilyElectrumClient.maximumHistoryResponseBytes
            )
        let (balances, histories) = try await (
            balancesValue,
            historiesValue
        )

        #expect(balances.count == 5_001)
        #expect(histories.count == 5_000)
        #expect(balances.allSatisfy {
            $0.value.object?["confirmed"]?.atomicInteger != nil
                && $0.value.object?["unconfirmed"]?.atomicInteger != nil
        })
        #expect(histories.allSatisfy { $0.value.array != nil })
        let fundedBalance = try #require(
            balances.first(where: {
                $0.parameter == fundedScriptHash
            })?.value.object?["confirmed"]?.atomicInteger
        )
        #expect(fundedBalance.isPositive)
    }
}
#endif

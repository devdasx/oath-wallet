import Foundation
import GRDB
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct BitcoinBIP38Tests {
    // Published BIP38 vectors plus independently generated compressed-EC fixtures
    // and the user's explicitly provided testing key. Never production secrets.
    struct Vector: Sendable, CustomTestStringConvertible {
        let id: Int
        let encrypted: String
        let password: String
        let wif: String
        let address: String
        var testDescription: String { "public BIP38 fixture \(id)" }
    }
    static let vectors: [Vector] = [
        Vector(id: 0, encrypted: "6PRVWUbkzzsbcVac2qwfssoUJAN1Xhrg6bNk8J7Nzm5H7kxEbn2Nh2ZoGg", password: "TestingOneTwoThree", wif: "5KN7MzqK5wt2TP1fQCYyHBtDrXdJuXbUzm4A9rKAteGu3Qi5CVR", address: "1Jq6MksXQVWzrznvZzxkV6oY57oWXD9TXB"),
        Vector(id: 1, encrypted: "6PRNFFkZc2NZ6dJqFfhRoFNMR9Lnyj7dYGrzdgXXVMXcxoKTePPX1dWByq", password: "Satoshi", wif: "5HtasZ6ofTHP6HCwTqTkLDuLQisYPah7aUnSKfC7h4hMUVw2gi5", address: "1AvKt49sui9zfzGeo8EyL8ypvAhtR2KwbL"),
        Vector(id: 2, encrypted: "6PRW5o9FLp4gJDDVqJQKJFTpMvdsSGJxMYHtHaQBF3ooa8mwD69bapcDQn", password: "ϓ\u{0}𐐀💩", wif: "5Jajm8eQ22H3pGWLEVCXyvND8dQZhiQhoLJNKjYXk9roUFTMSZ4", address: "16ktGzmfrurhbhi6JGqsMWf7TyqK9HNAeF"),
        Vector(id: 3, encrypted: "6PYNKZ1EAgYgmQfmNVamxyXVWHzK5s6DGhwP4J5o44cvXdoY7sRzhtpUeo", password: "TestingOneTwoThree", wif: "L44B5gGEpqEDRS9vVPz7QT35jcBG2r3CZwSwQ4fCewXAhAhqGVpP", address: "164MQi977u9GUteHr4EPH27VkkdxmfCvGW"),
        Vector(id: 4, encrypted: "6PYLtMnXvfG3oJde97zRyLYFZCYizPU5T3LwgdYJz1fRhh16bU7u6PPmY7", password: "Satoshi", wif: "KwYgW8gcxj1JWJXhPSu4Fqwzfhp5Yfi42mdYmMa4XqK7NJxXUSK7", address: "1HmPbwsvG5qJ3KJfxzsZRZWhbm1xBMuS8B"),
        Vector(id: 5, encrypted: "6PfQu77ygVyJLZjfvMLyhLMQbYnu5uguoJJ4kMCLqWwPEdfpwANVS76gTX", password: "TestingOneTwoThree", wif: "5K4caxezwjGCGfnoPTZ8tMcJBLB7Jvyjv4xxeacadhq8nLisLR2", address: "1PE6TQi6HTVNz5DLwB1LcpMBALubfuN2z2"),
        Vector(id: 6, encrypted: "6PfLGnQs6VZnrNpmVKfjotbnQuaJK4KZoPFrAjx1JMJUa1Ft8gnf5WxfKd", password: "Satoshi", wif: "5KJ51SgxWaAYR13zd9ReMhJpwrcX47xTJh2D3fGPG9CM8vkv5sH", address: "1CqzrtZC6mXSAhoxtFwVjz8LtwLJjDYU3V"),
        Vector(id: 7, encrypted: "6PgNBNNzDkKdhkT6uJntUXwwzQV8Rr2tZcbkDcuC9DZRsS6AtHts4Ypo1j", password: "MOLON LABE", wif: "5JLdxTtcTHcfYcmJsNVy1v2PMDx432JPoYcBTVVRHpPaxUrdtf8", address: "1Jscj8ALrYu2y9TD8NrpvDBugPedmbj4Yh"),
        Vector(id: 8, encrypted: "6PgGWtx25kUg8QWvwuJAgorN6k9FbE25rv5dMRwu5SKMnfpfVe5mar2ngH", password: "ΜΟΛΩΝ ΛΑΒΕ", wif: "5KMKKuUmAkiNbA3DazMQiLfDq47qs8MAEThm4yL8R2PhV1ov33D", address: "1Lurmih3KruL4xDB5FmHof38yawNtP9oGf"),
        Vector(id: 9, encrypted: "6PnYjKMuVad4NckPcFteS2wge47aGbic2mrJTBrn2VHiB64kYmCXisUC46", password: "compressed EC fixture", wif: "KwY5wxEUDvf2tYPD7fT8ZHic4ZmNHvihZfhJ227MFGQ3ouVZ2wGc", address: "1LZB2Y1QS8CmQH1vLVr6GDb6a5hQLrVNgt"),
        Vector(id: 10, encrypted: "6PoHzjnjrcoEZPeRwjk1dcSCWLnFu3UokwnxVhoV96zYLoFXTRDqdsLneJ", password: "compressed EC fixture", wif: "KynbEta1MRJMcVbcyxUTdEoz7A7EqPFQbmbainuA71pV3ecppf8i", address: "1GEUeD88izZEYMn3W4KCxYneWhbN4msaYP"),
        Vector(id: 11, encrypted: "6PYLR6Ro58TkMG8SaLxd3Sep25NYsUvpyrZGo4zDby4qqBdPXHkkzF8gzr", password: "TestingOneTwoThree", wif: "KyDsWYeJ7ByuWwmxtYK1poNNJmbG1XGvW9rENhYUgC7QVkx977TB", address: "1EkWhXo9o675FJW9AU6PRBanPTRjRmrj3X"),
    ]

    @Test(arguments: vectors)
    func decryptsIndependentVectorsAndPreservesWIFIdentity(_ vector: Vector) async throws {
        #expect(BitcoinBIP38.recognizes(vector.encrypted, network: .bitcoin))
        let decrypted = try await BitcoinBIP38Decryptor.shared.decrypt(vector.encrypted, password: vector.password)
        let original = try PrivateKeyImportService.importKey(vector.wif, network: .bitcoin)
        #expect(decrypted.address == original.address)
        #expect(decrypted.publicKey == original.publicKey)
        #expect(decrypted.derivationPath == original.derivationPath)
        guard case let .privateKey(data, network, format) = decrypted.secret,
              case let .privateKey(expected, _, expectedFormat) = original.secret else {
            Issue.record("Expected an ordinary Bitcoin private-key import draft")
            return
        }
        let legacy = try BitcoinFamilyDerivationService().derive(
            privateKey: data, chain: .bitcoin, format: format == .wifCompressed ? .extendedLegacy : .wifUncompressed
        )
        #expect(legacy.address == vector.address)
        let addresses = try BitcoinHDDerivationService().singleKeyAddresses(privateKeyData: data, format: format)
        let expectedTypes: Set<BitcoinHDAddressType> = format == .wifCompressed
            ? [.bip44, .bip49, .bip84, .bip86] : [.bip44]
        #expect(Set(addresses.map(\.addressType)) == expectedTypes)
        #expect(addresses.count == expectedTypes.count)
        #expect(addresses.allSatisfy { $0.branch == .external && $0.index == 0 })
        #expect(addresses.allSatisfy { !$0.derivationPath.hasPrefix("m/") })
        #expect(data == expected)
        #expect(network == .bitcoin && format == expectedFormat)
        #expect(try PrivateKeyImportService.revalidate(privateKeyData: data, network: network, format: format).address == original.address)
    }

    @Test
    func matchesBlueWallet801PublishedSingleKeyAddresses() throws {
        // Independent public fixtures from BlueWallet tag 8.0.1, tests/unit/
        // legacy-wallet, segwit-p2sh-wallet, segwit-bech32-wallet, taproot-wallet.
        let fixtures: [(String, BitcoinHDAddressType, String)] = [
            ("L4ccWrPMmFDZw4kzAKFqJNxgHANjdy6b7YKNXMwB4xac4FLF3Tov", .bip44, "14YZ6iymQtBVQJk6gKnLCk49UScJK7SH4M"),
            ("Ky1vhqYGCiCbPd8nmbUeGfwLdXB1h5aGwxHwpXrzYRfY5cTZPDo4", .bip49, "3CKN8HTCews4rYJYsyub5hjAVm5g5VFdQJ"),
            ("L4vn2KxgMLrEVpxjfLwxfjnPPQMnx42DCjZJ2H7nN4mdHDyEUWXd", .bip84, "bc1q3rl0mkyk0zrtxfmqn9wpcd3gnaz00yv9yp0hxe"),
            ("L4PKRVk1Peaar5WuH5LiKfkTygWtFfGrFeH2g2t3YVVqiwpJjMoF", .bip86, "bc1pm6lqlel3qxefsx0v39nshtghasvvp6ghn3e5hd5q280j5m9h7csqrkzssu")
        ]
        for (wif, type, expectedAddress) in fixtures {
            let draft = try PrivateKeyImportService.importKey(wif, network: .bitcoin)
            guard case let .privateKey(data, _, format) = draft.secret else {
                Issue.record("Expected a single-key draft")
                return
            }
            let addresses = try BitcoinHDDerivationService().singleKeyAddresses(privateKeyData: data, format: format)
            #expect(addresses.first { $0.addressType == type }?.address == expectedAddress)
        }
    }

    @Test
    func rejectsWrongPasswordsCorruptionUnsupportedFlagsAndOtherNetworks() throws {
        let vector = try #require(Self.vectors.last)
        for password in ["wrong password", " TestingOneTwoThree", "testingonetwothree"] {
            #expect(throws: BitcoinBIP38Error.incorrectPassword) {
                try BitcoinBIP38.decrypt(vector.encrypted, password: password)
            }
        }
        for type in [0x42, 0x43] {
            var payload = Data(repeating: 0, count: 39)
            payload[0] = 1; payload[1] = UInt8(type); payload[2] = 0xff
            let invalid = Base58.encode(data: payload)
            #expect(!BitcoinBIP38.recognizes(invalid, network: .bitcoin))
        }
        for invalid in ["", "6P", String(vector.encrypted.dropLast()) + "1", vector.encrypted + "x", vector.wif] {
            #expect(!BitcoinBIP38.recognizes(invalid, network: .bitcoin))
            #expect(throws: BitcoinBIP38Error.invalidEncoding) { try BitcoinBIP38.decrypt(invalid, password: vector.password) }
        }
        for network in PrivateKeyImportNetwork.allCases where network != .bitcoin {
            #expect(!BitcoinBIP38.recognizes(vector.encrypted, network: network))
        }
        #expect(BitcoinBIP38.recognizes(" \n" + vector.encrypted + "\n", network: .bitcoin))
        #expect(!PrivateKeyImportService.isValid(vector.encrypted, network: .bitcoin))
        #expect(PrivateKeyImportService.isValid(vector.wif, network: .bitcoin))
    }

    @Test
    func scannerAcceptsEncryptedBitcoinWithoutInventingAnAddress() throws {
        let vector = try #require(Self.vectors.last)
        let review = try ImportCredentialScanReview.parse(vector.encrypted, mode: .privateKey(.bitcoin))
        #expect(review.derivedAddress.isEmpty)
        #expect(review.normalizedValue == vector.encrypted)
        #expect(!review.presentation.rows.contains { $0.id == "account" })
        #expect(throws: ImportCredentialScanError.invalidPrivateKey) {
            try ImportCredentialScanReview.parse(vector.encrypted, mode: .privateKey(.litecoin))
        }
        let normal = try ImportCredentialScanReview.parse(vector.wif, mode: .privateKey(.bitcoin))
        #expect(normal.derivedAddress == (try PrivateKeyImportService.importKey(vector.wif, network: .bitcoin)).address)
    }

    @Test
    func decryptedTestWalletPersistsAndRestoresThroughExistingKeychainPath() async throws {
        let vector = try #require(Self.vectors.last)
        let draft = try await BitcoinBIP38Decryptor.shared.decrypt(vector.encrypted, password: vector.password)
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(service: "bip38-import-tests.\(UUID())")
        defer { try? vault.deleteAll() }
        let identity = try await database.persistImportedWallet(draft: draft, security: .reuseExistingProfile, vault: vault)
        let account = try #require(await database.pool.read { db in
            try DBWalletAccountRecord.filter(Column("walletID") == identity.walletID && Column("networkID") == "bitcoin").fetchOne(db)
        })
        #expect(account.address == draft.address)
        let wallet = try #require(await database.bitcoinSingleKeyWallet(walletID: identity.walletID, vault: vault))
        #expect(wallet.addresses.count == 4)
        #expect(wallet.address(for: .bip44)?.address == vector.address)
        let authorization = try await database.authorizeUnprotectedSecretExport(walletID: identity.walletID)
        let exported = try await database.privateKeyExportItems(walletID: identity.walletID, authorization: authorization, vault: vault)
        #expect(!exported.isEmpty)
    }

#if LIVE_MAINNET_TESTS
    @Test
    func liveMainnetReadsAllAddressesOfProvidedTestKey() async throws {
        let vector = try #require(Self.vectors.last)
        let draft = try await BitcoinBIP38Decryptor.shared.decrypt(vector.encrypted, password: vector.password)
        guard case let .privateKey(data, _, format) = draft.secret else {
            Issue.record("Expected a decrypted key")
            return
        }
        let addresses = try BitcoinHDDerivationService().singleKeyAddresses(privateKeyData: data, format: format)
        for method in ["blockchain.scripthash.get_balance", "blockchain.scripthash.get_history", "blockchain.scripthash.listunspent"] {
            let responses = try await BitcoinFamilyElectrumClient.shared.callStringParameterBatch(
                chain: .bitcoin, method: method, parameters: addresses.map(\.scriptHash)
            )
            #expect(responses.count == 4)
            for response in responses {
                if method.hasSuffix("get_balance") {
                    #expect(response.value.object?["confirmed"]?.atomicInteger != nil)
                    #expect(response.value.object?["unconfirmed"]?.atomicInteger != nil)
                } else { #expect(response.value.array != nil) }
            }
        }
    }
#endif
}

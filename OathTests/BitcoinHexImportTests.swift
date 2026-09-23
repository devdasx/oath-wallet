import Foundation
import GRDB
import Testing
import WalletCore
@testable import Aperture

struct BitcoinHexImportTests {
    // Public, deliberately insecure fixture: scalar 1. Never a funded wallet.
    private static let scalarOne = String(repeating: "0", count: 63) + "1"

    @Test(arguments: ["", "0x", "0X"])
    func importsHexWithOptionalPrefixAndFindsAllStandardAddresses(prefix: String) throws {
        let draft = try PrivateKeyImportService.importKey(" \n" + prefix + Self.scalarOne + "\n", network: .bitcoin)
        guard case let .privateKey(data, network, format) = draft.secret else {
            Issue.record("Expected a private-key draft")
            return
        }
        #expect(network == .bitcoin)
        #expect(format == .wifCompressed)
        #expect(data.count == 32 && data.last == 1)
        let addresses = try BitcoinHDDerivationService().singleKeyAddresses(privateKeyData: data, format: format)
        #expect(addresses.count == 4)
        // Independently checked with bip_utils, including the BIP86 tweaked key.
        #expect(addresses.first { $0.addressType == .bip44 }?.address == "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH")
        #expect(addresses.first { $0.addressType == .bip49 }?.address == "3JvL6Ymt8MVWiCNHC7oWU6nLeHNJKLZGLN")
        #expect(addresses.first { $0.addressType == .bip84 }?.address == "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
        #expect(addresses.first { $0.addressType == .bip86 }?.address == "bc1pmfr3p9j00pfxjh0zmgp99y8zftmd3s5pmedqhyptwy6lm87hf5sspknck9")
        #expect(draft.address == addresses.first { $0.addressType == .bip84 }?.address)
        let wif = Base58.encode(data: Data([0x80]) + data + Data([1]))
        let original = try PrivateKeyImportService.importKey(wif, network: .bitcoin)
        #expect(original.address == draft.address)
        #expect(original.publicKey == draft.publicKey)
        #expect(try PrivateKeyImportService.revalidate(privateKeyData: data, network: network, format: format).address == draft.address)
        let review = try ImportCredentialScanReview.parse(prefix + Self.scalarOne, mode: .privateKey(.bitcoin))
        #expect(review.derivedAddress == draft.address)
        #expect(!BitcoinBIP38.recognizes(prefix + Self.scalarOne, network: .bitcoin))
    }

    @Test
    func caseDoesNotChangeIdentity() throws {
        let hex = String(repeating: "ab", count: 32)
        let lower = try PrivateKeyImportService.importKey(hex, network: .bitcoin)
        let upper = try PrivateKeyImportService.importKey("0X" + hex.uppercased(), network: .bitcoin)
        #expect(lower.address == upper.address)
        #expect(lower.publicKey == upper.publicKey)
    }

    @Test
    func rejectsInvalidLengthsCharactersAndOutOfRangeScalars() {
        let invalid = [
            "1", String(Self.scalarOne.dropFirst()), Self.scalarOne + "0", Self.scalarOne + "01",
            String(repeating: "0", count: 64), String(repeating: "f", count: 64),
            "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141",
            String(repeating: "g", count: 64), String(repeating: "０", count: 64),
            String(repeating: "0", count: 31) + " " + String(repeating: "0", count: 32) + "1",
            "0x0x" + Self.scalarOne,
        ]
        for input in invalid {
            #expect(!PrivateKeyImportService.isValid(input, network: .bitcoin))
            #expect(throws: ImportCredentialScanError.invalidPrivateKey) {
                try ImportCredentialScanReview.parse(input, mode: .privateKey(.bitcoin))
            }
        }
    }

    @Test
    func hexWalletPersistsAndRestoresAllOwnedAddresses() async throws {
        // Scalar 1 is correctly blocked by the app's existing weak-key policy.
        // Use the prior BIP38 testing fixture for the persistence round trip.
        let vector = try #require(BitcoinBIP38Tests.vectors.last)
        let original = try PrivateKeyImportService.importKey(vector.wif, network: .bitcoin)
        guard case let .privateKey(data, _, _) = original.secret else {
            Issue.record("Expected a private-key draft")
            return
        }
        let draft = try PrivateKeyImportService.importKey(data.hexString, network: .bitcoin)
        #expect(draft.address == original.address)
        #expect(WalletCredentialSafetyService.finding(for: draft) == nil)
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(service: "bitcoin-hex-test.\(UUID())")
        defer { try? vault.deleteAll() }
        let identity = try await database.persistImportedWallet(draft: draft, security: .reuseExistingProfile, vault: vault)
        let wallet = try #require(await database.bitcoinSingleKeyWallet(walletID: identity.walletID, vault: vault))
        #expect(wallet.addresses.count == 4)
        #expect(wallet.address(for: .bip44)?.address == vector.address)
        #expect(wallet.address(for: .bip84)?.address == draft.address)
        let authorization = try await database.authorizeUnprotectedSecretExport(walletID: identity.walletID)
        let exports = try await database.privateKeyExportItems(walletID: identity.walletID, authorization: authorization, vault: vault)
        #expect(!exports.isEmpty)
    }
}

struct BitcoinBase64ImportTests {
    // Use independently checked, public Bitcoin Core fixtures, never user keys.
    static func document(key: Data) -> String {
        """
        {"format":"bitcoinImportedWallet","material":{"sources":[{"descriptor":{"compressed":true,"key":"\(key.base64EncodedString())","path":[],"script":"rawtr"},"internalBranch":false,"nextIndex":0,"rangeEnd":1,"rangeStart":0}]},"version":1}
        """
    }

    @Test(arguments: 1...8, [false, true])
    func bareKeyKeepsStandardAndRawTaprootAddresses(index: Int, padded: Bool) throws {
        let vector = try BitcoinRawTaprootImportTests.vector(index)
        let key = try BitcoinPrivateDescriptor(vector.descriptor).key
        let encoded = key.base64EncodedString()
        let input = padded ? encoded : String(encoded.dropLast())
        let draft = try PrivateKeyImportService.importKey(" \n" + input + "\n", network: .bitcoin)
        guard case let .bitcoinImportedWallet(material) = draft.secret else {
            Issue.record("Expected all script policies for the bare Base64 key")
            return
        }
        #expect(material.sources.count == 5)
        #expect(material.sources.allSatisfy { $0.descriptor.key == key && $0.descriptor.compressed })
        let addresses = try material.sources.map { try $0.descriptor.address().address }
        let standard = try BitcoinHDDerivationService().singleKeyAddresses(privateKeyData: key, format: .wifCompressed)
        #expect(Set(addresses) == Set(standard.map(\.address) + [vector.address]))
        #expect(addresses.contains(vector.bip86) && addresses.contains(vector.address))
        #expect(draft.address == standard.first { $0.addressType == .bip84 }?.address)
        #expect(try BitcoinImportedWalletMaterial.decode(material.encoded()) == material)
        #expect(try ImportCredentialScanReview.parse(input, mode: .privateKey(.bitcoin)).derivedAddress == draft.address)
        for network: PrivateKeyImportNetwork in [.bitcoinCash, .litecoin, .dogecoin] {
            #expect(!PrivateKeyImportService.isValid(input, network: network))
        }
    }

    @Test
    func base64StartingWithMiniPrefixOrContainingAlphabetSymbolsImportsUnchanged() async throws {
        for first: UInt8 in [0x48, 0xfb, 0xff] {
            let key = Data([first]) + Data(repeating: 0x12, count: 31)
            let padded = key.base64EncodedString()
            if first == 0x48 { #expect(padded.hasPrefix("S")) }
            if first == 0xfb { #expect(padded.contains("+")) }
            if first == 0xff { #expect(padded.contains("/")) }
            for text in [padded, String(padded.dropLast())] {
                #expect(try BitcoinImportKeyEncoding.base64(text).key == key)
                let formats = [text, "private_key,label\n\(text),Fixture", "[\"\(text)\"]",
                               "{\"keys\":[{\"private_key\":\"\(text)\"}]}"]
                for input in formats {
                    let material = try await BitcoinImportFileParser.shared.parse(Data(input.utf8))
                    #expect(material.sources.count == 5)
                    #expect(material.sources.allSatisfy { $0.descriptor.key == key })
                    #expect(material.sources.last?.descriptor.script == .rawtr)
                }
            }
        }
    }

    @Test
    func rejectsMalformedBase64AndInvalidSecp256k1Scalars() throws {
        let scalarOne = Data(repeating: 0, count: 31) + Data([1])
        let encoded = scalarOne.base64EncodedString()
        let curveOrder = try #require(Data(hexString: "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"))
        let invalid: [String] = [
            Data(repeating: 0, count: 32).base64EncodedString(),
            Data(repeating: 0xff, count: 32).base64EncodedString(),
            curveOrder.base64EncodedString(),
            Data(repeating: 0x12, count: 31).base64EncodedString(),
            Data(repeating: 0x12, count: 33).base64EncodedString(),
            String(encoded.dropLast(2)) + "F=", // nonzero padding bits
            encoded + "=", String(encoded.dropLast(2)), "!" + String(encoded.dropFirst()),
            "Ａ" + String(encoded.dropFirst()), String(encoded.prefix(10)) + "\n" + String(encoded.dropFirst(10)),
            String(encoded.prefix(10)) + " " + String(encoded.dropFirst(10)),
            "_" + String(encoded.dropFirst()), "-" + String(encoded.dropFirst())
        ]
        for input in invalid {
            #expect(throws: BitcoinImportError.invalidKey) { try BitcoinImportKeyEncoding.base64(input) }
            #expect(!PrivateKeyImportService.isValid(input, network: .bitcoin))
            #expect(throws: ImportCredentialScanError.invalidPrivateKey) {
                try ImportCredentialScanReview.parse(input, mode: .privateKey(.bitcoin))
            }
        }
        // A different encoding must not bypass the existing weak-key guard.
        let draft = try PrivateKeyImportService.importKey(encoded, network: .bitcoin)
        #expect(WalletCredentialSafetyService.finding(for: draft) != nil)
    }

    @Test
    func importedKeySurvivesPersistenceExportCloudRestoreAndDeviceMigration() async throws {
        let vector = try BitcoinRawTaprootImportTests.vector(1)
        let key = try BitcoinPrivateDescriptor(vector.descriptor).key
        let draft = try PrivateKeyImportService.importKey(key.base64EncodedString(), network: .bitcoin)
        guard case let .bitcoinImportedWallet(material) = draft.secret else {
            Issue.record("Expected imported Bitcoin material")
            return
        }
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(service: "bitcoin-base64-test.\(UUID())")
        defer { try? vault.deleteAll() }
        let identity = try await database.persistImportedWallet(draft: draft, security: .reuseExistingProfile, vault: vault)
        #expect(try await database.bitcoinImportedMaterial(walletID: identity.walletID, vault: vault) == material)
        let addresses = try await database.bitcoinImportedAddresses(walletID: identity.walletID, material: material)
        #expect(addresses.count == 5)
        #expect(try await database.bitcoinImportedWalletOwnsAddress(walletID: identity.walletID, address: vector.address, vault: vault))
        #expect(try await database.bitcoinImportedWalletOwnsAddress(walletID: identity.walletID, address: vector.bip86, vault: vault))
        let authorization = try await database.authorizeUnprotectedSecretExport(walletID: identity.walletID)
        let exports = try await database.privateKeyExportItems(walletID: identity.walletID, authorization: authorization, vault: vault)
        let export = try #require(exports.first?.privateKeys.first).value
        #expect(try await BitcoinImportFileParser.shared.parse(Data(export.utf8)) == material)
        let payload = WalletCloudBackupPayload(version: 2, walletName: "Base64 fixture", walletKind: ManagedWalletKind.importedPrivateKey.rawValue,
            address: draft.address, secret: try material.encoded(), hasPassphrase: nil,
            privateKeyNetwork: "bitcoin", privateKeyFormat: BitcoinImportedWalletMaterial.accountMarker, createdAt: 0, backedUpAt: 0)
        #expect(try ICloudWalletRestoreValidator.validate(payload).draft == draft)
        try DeviceMigrationAccountSecretVerifier.validate(source: database.pool,
            secrets: [.init(walletID: identity.walletID, kind: .bitcoinImportedWallet, data: try material.encoded())])
    }

    @Test
    func rejectsUnknownOrDamagedImportEnvelopesWithoutImportingPartialKeys() async throws {
        let key = try BitcoinPrivateDescriptor(BitcoinRawTaprootImportTests.vector(1).descriptor).key
        let original = try #require(JSONSerialization.jsonObject(with: Data(Self.document(key: key).utf8)) as? [String: Any])
        var invalid: [[String: Any]] = []
        let envelopeMutations: [(String, Any)] = [
            ("format", "otherWallet"), ("format", NSNull()), ("version", 0), ("version", 2),
            ("version", "1"), ("version", true), ("material", NSNull()), ("sources", [])
        ]
        for (field, value) in envelopeMutations {
            var document = original
            document[field] = value
            invalid.append(document)
        }
        for field in ["format", "version", "material"] {
            var document = original
            document.removeValue(forKey: field)
            invalid.append(document)
        }
        let originalMaterial = try #require(original["material"] as? [String: Any])
        let originalSources = try #require(originalMaterial["sources"] as? [[String: Any]])
        let originalSource = try #require(originalSources.first)
        let originalDescriptor = try #require(originalSource["descriptor"] as? [String: Any])
        let descriptorMutations: [(String, Any)] = [
            ("key", Data(repeating: 0, count: 32).base64EncodedString()),
            ("key", Data(repeating: 0xff, count: 32).base64EncodedString()),
            ("key", Data(repeating: 0x12, count: 31).base64EncodedString()),
            ("key", "not-base64"), ("compressed", false), ("script", "unknown")
        ]
        for (field, value) in descriptorMutations {
            var descriptor = originalDescriptor
            descriptor[field] = value
            var source = originalSource
            source["descriptor"] = descriptor
            var material = originalMaterial
            // No partial import when a valid source precedes an invalid one.
            material["sources"] = [originalSource, source]
            var document = original
            document["material"] = material
            invalid.append(document)
        }
        for (field, value) in [("rangeStart", -1), ("rangeEnd", 0), ("rangeEnd", 2), ("nextIndex", 2), ("discoveryGap", 0)] {
            var source = originalSource
            source[field] = value
            var material = originalMaterial
            material["sources"] = [source]
            var document = original
            document["material"] = material
            invalid.append(document)
        }
        for document in invalid {
            let data = try JSONSerialization.data(withJSONObject: document)
            #expect(throws: (any Error).self) { try BitcoinImportedWalletMaterial.decode(data) }
            #expect(!PrivateKeyImportService.isValid(String(decoding: data, as: UTF8.self), network: .bitcoin))
            await #expect(throws: (any Error).self) { try await BitcoinImportFileParser.shared.parse(data) }
        }
    }
}

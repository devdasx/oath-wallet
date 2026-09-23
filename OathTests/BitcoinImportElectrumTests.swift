import Foundation
import Testing
import WalletCore
@testable import Aperture

struct BitcoinImportElectrumTests {
    struct Reference: Decodable { let branch: Int; let index: Int; let address: String; let wif: String }
    struct Fixture: Decodable { let name: String; let password: String; let kind: String; let references: [Reference] }
    private static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ElectrumImport")
    private static func data(_ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name)) }
    static let names = (0..<6).flatMap { i in
        ["standard", "p2wpkh-p2sh", "p2wpkh"].flatMap { script in
            ["clear", "keys-encrypted", "file-encrypted"].map { "custom-\(i)-\(script)-\($0).wallet" }
        }
    } + ["electrum-standard", "electrum-segwit", "electrum-old", "imported-mixed"].flatMap { name in
        ["clear", "keys-encrypted", "file-encrypted"].map { "\(name)-\($0).wallet" }
    } + ["journal.wallet"]

    @Test(arguments: names)
    func matchesElectrumGeneratedFilesAndFutureChildren(name: String) async throws {
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Self.data("manifest.json"))
        let fixture = try #require(fixtures.first { $0.name == name })
        let material = try await BitcoinImportFileParser.shared.parse(Self.data(name), password: fixture.password.isEmpty ? nil : fixture.password)
        if fixture.kind == "standard" {
            #expect(material.sources.count == 2)
            #expect(material.sources[0].discoveryGap == (name == "journal.wallet" ? 31 : 27))
            #expect(material.sources[1].discoveryGap == 9)
            for reference in fixture.references {
                let source = material.sources[reference.branch]
                let derived = try source.descriptor.address(index: reference.index, sourceID: String(reference.branch))
                #expect(derived.address == reference.address)
                let expected = try BitcoinImportKeyEncoding.electrumDescriptor(reference.wif)
                #expect(try material.privateKey(path: derived.derivationPath) == expected.key)
                #expect(source.internalBranch == (reference.branch == 1))
            }
        } else {
            let actual = try Set(material.sources.map { try $0.descriptor.address().address })
            #expect(actual == Set(fixture.references.map(\.address)))
            #expect(material.sources.count == 4)
        }
        #expect(try BitcoinImportedWalletMaterial.decode(material.encoded()) == material)
        #expect(try material.importDraft().derivationPath == BitcoinImportedWalletMaterial.accountMarker)
    }

    @Test(arguments: ["client_1_9_8_seeded.wallet"] + ["2_0_4", "2_1_1", "2_2_0", "2_3_2", "2_4_3", "2_5_4", "2_6_4", "2_7_18", "2_8_3", "2_9_3"].flatMap { release in
        ["seeded", "importedkeys"].map { "client_\(release)_\($0).wallet" }
    })
    func matchesHistoricalFilesOpenedByElectrum(name: String) async throws {
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Self.data("historical-manifest.json"))
        #expect(fixtures.count >= 19)
        for fixture in fixtures where fixture.name == name {
            let material = try await BitcoinImportFileParser.shared.parse(Self.data(fixture.name))
            for reference in fixture.references {
                if fixture.kind == "standard" {
                    let derived = try material.sources[reference.branch].descriptor.address(index: reference.index, sourceID: String(reference.branch))
                    #expect(derived.address == reference.address, "Electrum historical fixture: \(fixture.name)")
                    #expect(try material.privateKey(path: derived.derivationPath) == BitcoinImportKeyEncoding.electrumDescriptor(reference.wif).key)
                } else {
                    #expect(try material.sources.contains { try $0.descriptor.address().address == reference.address })
                }
            }
        }
    }

    @Test(arguments: ["electrum-old-clear.wallet", "custom-5-p2wpkh-clear.wallet"])
    func restoresSavedGapAndChangeAfterKeychainRoundTrip(name: String) async throws {
        let material = try await BitcoinImportFileParser.shared.parse(Self.data(name))
        let database = try WalletDatabase.temporary()
        let vault = WalletSecretVault(service: "electrum-import-test.\(UUID())")
        defer { try? vault.deleteAll() }
        let identity = try await database.persistImportedWallet(draft: material.importDraft(), security: .reuseExistingProfile, vault: vault)
        let restored = try await database.bitcoinImportedMaterial(walletID: identity.walletID, vault: vault)
        #expect(restored == material)
        let addresses = try await database.bitcoinImportedAddresses(walletID: identity.walletID, material: material)
        #expect(addresses.count == 36)
        let type = material.sources[0].descriptor.script.addressType
        let first = try await database.bitcoinImportedReceiveAddress(walletID: identity.walletID, material: material, type: type, reserveChange: true)
        let second = try await database.bitcoinImportedReceiveAddress(walletID: identity.walletID, material: material, type: type, reserveChange: true)
        #expect(first.address == (try material.sources[1].descriptor.address(index: 0).address))
        #expect(second.address == (try material.sources[1].descriptor.address(index: 1).address))
        #expect(try material.privateKey(path: second.derivationPath) == material.sources[1].descriptor.privateKey(index: 1))
        #expect(try await database.bitcoinImportedWalletOwnsAddress(walletID: identity.walletID, address: second.address, vault: vault))
    }

    @Test(arguments: ["keys-encrypted", "file-encrypted"])
    func encryptedFilesRequirePasswordAndRejectWrongPassword(mode: String) async throws {
        let bytes = try Self.data("electrum-segwit-\(mode).wallet")
        await #expect(throws: BitcoinImportError.passwordRequired) { try await BitcoinImportFileParser.shared.parse(bytes) }
        await #expect(throws: BitcoinImportError.incorrectPassword) { try await BitcoinImportFileParser.shared.parse(bytes, password: "wrong") }
    }

    @Test
    func rejectsMismatchedPublicNodeAndAddressListsWithoutImportingSubset() async throws {
        let original = try #require(JSONSerialization.jsonObject(with: Self.data("custom-5-p2wpkh-clear.wallet")) as? [String: Any])
        var object = original
        var addresses = try #require(object["addresses"] as? [String: [String]])
        addresses["change"]![8] = "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH"
        object["addresses"] = addresses
        await #expect(throws: BitcoinImportError.invalidFile) {
            try await BitcoinImportFileParser.shared.parse(JSONSerialization.data(withJSONObject: object))
        }
        object = original
        var store = try #require(object["keystore"] as? [String: Any])
        let other = try #require(JSONSerialization.jsonObject(with: Self.data("electrum-segwit-clear.wallet")) as? [String: Any])
        store["xpub"] = (other["keystore"] as? [String: Any])?["xpub"]
        object["keystore"] = store
        await #expect(throws: BitcoinImportError.invalidFile) {
            try await BitcoinImportFileParser.shared.parse(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test(arguments: ["2fa", "2of3", "hardware", "watch-only", "lightning"])
    func rejectsDifferentSigningPolicies(kind: String) async throws {
        var object = try #require(JSONSerialization.jsonObject(with: Self.data("electrum-segwit-clear.wallet")) as? [String: Any])
        if kind == "2fa" || kind == "2of3" { object["wallet_type"] = kind }
        else if kind == "lightning" { object["channels"] = ["channel": ["state": "OPEN"]] }
        else {
            var store = try #require(object["keystore"] as? [String: Any])
            store.removeValue(forKey: "xprv")
            if kind == "hardware" { store["type"] = "hardware" }
            object["keystore"] = store
        }
        await #expect(throws: (any Error).self) { try await BitcoinImportFileParser.shared.parse(JSONSerialization.data(withJSONObject: object)) }
    }

    @Test
    func rejectsCorruptEncryptedEnvelopeAndInvalidJournal() async throws {
        let text = try String(decoding: Self.data("electrum-segwit-file-encrypted.wallet"), as: UTF8.self)
        var bytes = try #require(Data(base64Encoded: text))
        bytes[40] ^= 1
        await #expect(throws: BitcoinImportError.incorrectPassword) {
            try await BitcoinImportFileParser.shared.parse(Data(bytes.base64EncodedString().utf8), password: "ElectrumFixture-é-测试")
        }
        let original = try Self.data("electrum-segwit-clear.wallet")
        let invalidPatch = Data(", {\"op\":\"replace\",\"path\":\"/missing\",\"value\":0}".utf8)
        await #expect(throws: BitcoinImportError.invalidFile) { try await BitcoinImportFileParser.shared.parse(original + invalidPatch) }
        await #expect(throws: (any Error).self) { try await BitcoinImportFileParser.shared.parse(Data(original.dropLast(20))) }
    }
}

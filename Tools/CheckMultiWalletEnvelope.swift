import Foundation
import CryptoKit
import OathCloudBackup

/// Public fixtures only. Exercises the actual production envelope on the host;
/// never reads the app's Keychain, installation, database, or recovery material.
@main struct CheckMultiWalletEnvelope {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func rejects(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure(message) }
            catch { checks += 1 }
        }
        let first = OathWalletSecret(id: UUID(), mnemonic: String(repeating: "abandon ", count: 11) + "about",
                                     language: "english", createdAt: Date(timeIntervalSince1970: 1), backedUp: true)
        let second = OathWalletSecret(id: UUID(), mnemonic: "legal winner thank year wave sausage worth useful legal winner thank yellow",
                                      language: "english", createdAt: Date(timeIntervalSince1970: 2), backedUp: true)
        let pin: [UInt8] = [2, 9, 4, 8, 1, 6]
        let (legacy, existingKey) = try OathVaultEnvelope.seal(first, digits: pin)
        let legacyBytes = try JSONEncoder().encode(legacy)
        let decodedLegacy = try JSONDecoder().decode(OathVaultEnvelope.self, from: legacyBytes)
        check(decodedLegacy.version == 1 && decodedLegacy.walletIDs == nil, "Legacy format stays readable")
        var contents = try decodedLegacy.openContents(using: existingKey)
        check(contents.wallets.count == 1 && contents.wallets[0].mnemonic == first.mnemonic,
              "An existing installation preserves its original secret")
        check(try contents.selectedWalletID(nil) == first.id, "Legacy selection defaults to its wallet")
        contents.wallets.append(second)
        let upgraded = try OathVaultEnvelope.seal(contents, rootID: first.id, key: existingKey,
                                                 salt: legacy.salt, iterations: legacy.iterations)
        let bytes = try JSONEncoder().encode(upgraded)
        let reopened = try JSONDecoder().decode(OathVaultEnvelope.self, from: bytes)
        check(reopened.version == 2 && reopened.memberIDs == [first.id, second.id], "Every member survives serialization")
        check(reopened.id == legacy.id && reopened.salt == legacy.salt && reopened.iterations == legacy.iterations,
              "Adding wallets retains the existing app lock and biometric anchor")
        let unlocked = try reopened.openContents(using: reopened.key(for: pin))
        check(unlocked.wallets.map(\.id) == [first.id, second.id], "One existing PIN opens all wallets")
        check(unlocked.wallets[0].mnemonic == first.mnemonic && unlocked.wallets[1].mnemonic == second.mnemonic,
              "Adding a wallet never replaces another wallet's recovery material")
        check(try reopened.openContents(using: existingKey).wallets.count == 2,
              "An already-enrolled biometric key works without re-enrollment")
        for wallet in [first, second] {
            check(bytes.range(of: Data(wallet.mnemonic.utf8)) == nil, "No plaintext recovery phrase is stored")
            check(try unlocked.selectedWalletID(wallet.id.uuidString) == wallet.id, "Stored selection resolves to the right member")
        }
        check(try unlocked.selectedWalletID(UUID().uuidString) == first.id, "SQL cannot select a foreign wallet")
        check(try unlocked.selectedWalletID("invalid-id") == first.id, "Malformed selection safely falls back")
        check(OathVaultContents.reference(for: first.id, rootID: first.id) == "vault-v1", "Legacy SQL reference is retained")
        check(OathVaultContents.reference(for: second.id, rootID: first.id) != "vault-v1", "Additional SQL references are unique")
        rejects("Wrong PIN cannot open the collection") {
            _ = try reopened.openContents(using: reopened.key(for: [0, 0, 0, 0, 0, 0]))
        }
        rejects("Another installation's biometric key cannot open the collection") {
            _ = try reopened.openContents(using: SymmetricKey(size: .bits256))
        }
        var tamperedBytes = reopened.sealed
        tamperedBytes[tamperedBytes.count - 1] ^= 1
        rejects("Ciphertext modification must fail authentication") {
            _ = try OathVaultEnvelope(version: 2, id: reopened.id, salt: reopened.salt,
                iterations: reopened.iterations, sealed: tamperedBytes, walletIDs: reopened.walletIDs).openContents(using: existingKey)
        }
        for ids in [[first.id], [first.id, UUID()], [first.id, second.id, UUID()], [second.id, first.id], [first.id, first.id]] {
            rejects("The public membership index must be authenticated, never trusted as authority") {
                _ = try OathVaultEnvelope(version: 2, id: reopened.id, salt: reopened.salt,
                    iterations: reopened.iterations, sealed: reopened.sealed, walletIDs: ids).openContents(using: existingKey)
            }
        }
        rejects("A version change cannot reinterpret existing ciphertext") {
            _ = try OathVaultEnvelope(version: 1, id: reopened.id, salt: reopened.salt,
                iterations: reopened.iterations, sealed: reopened.sealed).openContents(using: existingKey)
        }
        for invalid in [OathVaultContents(wallets: []), .init(wallets: [first, first]), .init(wallets: [second, first])] {
            rejects("Invalid membership must fail before any write") {
                _ = try OathVaultEnvelope.seal(invalid, rootID: first.id, key: existingKey,
                                              salt: legacy.salt, iterations: legacy.iterations)
            }
        }
        // A metadata change to one member must preserve every other member.
        let rewritten = try OathVaultEnvelope.seal(contents, rootID: first.id, key: existingKey,
                                                  salt: legacy.salt, iterations: legacy.iterations)
        let afterUpdate = try rewritten.openContents(using: existingKey)
        check(afterUpdate.wallets[1].mnemonic == second.mnemonic, "Rewriting one member preserves the others")
        check(rewritten.sealed != reopened.sealed, "Each update receives a fresh authenticated-encryption nonce")
        for material in [
            OathImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: [.bitcoin], compressed: false),
            OathImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: [.bitcoin], compressed: true,
                                   bitcoinExtendedKey: "xprv-serialization-fixture")
        ] {
            let bitcoin = OathWalletSecret(id: UUID(), mnemonic: "", language: "", createdAt: .now,
                                            backedUp: true, imported: true, privateKey: material)
            let (sealed, key) = try OathVaultEnvelope.seal(bitcoin, digits: pin)
            check(sealed.version == 5, "Old readers must reject extended/uncompressed Bitcoin material")
            check(try sealed.openContents(using: key).wallets.first?.privateKey == material,
                  "Bitcoin key scope and compression survive local encrypted round trip")
            let portable = try JSONEncoder().encode(sealed)
            check(portable.range(of: material.bytes) == nil, "Bitcoin private bytes stay encrypted")
            if let extended = material.bitcoinExtendedKey {
                check(portable.range(of: Data(extended.utf8)) == nil, "Bitcoin extended key stays encrypted")
            }
            let downgraded = OathVaultEnvelope(version: 2, id: sealed.id, salt: sealed.salt,
                iterations: sealed.iterations, sealed: sealed.sealed, walletIDs: sealed.walletIDs)
            rejects("Downgraded Bitcoin envelope accepted") { _ = try downgraded.openContents(using: key) }
        }
        for material in [
            OathImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: [.dogecoin], compressed: false),
            OathImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: [.dogecoin], compressed: true,
                                   dogecoinExtendedKey: "dgpv-serialization-fixture")
        ] {
            let dogecoin = OathWalletSecret(id: UUID(), mnemonic: "", language: "", createdAt: .now,
                                            backedUp: true, imported: true, privateKey: material)
            let (sealed, key) = try OathVaultEnvelope.seal(dogecoin, digits: pin)
            check(sealed.version == 6, "Old readers must reject extended/uncompressed Dogecoin material")
            check(try sealed.openContents(using: key).wallets.first?.privateKey == material,
                  "Dogecoin key scope and compression survive local encrypted round trip")
            let portable = try JSONEncoder().encode(sealed)
            check(portable.range(of: material.bytes) == nil, "Dogecoin private bytes stay encrypted")
            if let extended = material.dogecoinExtendedKey {
                check(portable.range(of: Data(extended.utf8)) == nil, "Dogecoin extended key stays encrypted")
            }
            let downgraded = OathVaultEnvelope(version: 2, id: sealed.id, salt: sealed.salt,
                iterations: sealed.iterations, sealed: sealed.sealed, walletIDs: sealed.walletIDs)
            rejects("Downgraded Dogecoin envelope accepted") { _ = try downgraded.openContents(using: key) }
            let backup = BackupWallet(id: dogecoin.id, name: "Dogecoin fixture", mnemonic: "", language: "", createdAt: dogecoin.createdAt,
                accounts: [.init(network: "dogecoin", derivationPath: "imported", index: 0)],
                privateKey: .init(bytes: material.bytes, networks: ["dogecoin"], compressed: material.compressed,
                                  dogecoinExtendedKey: material.dogecoinExtendedKey))
            let restored = try OathRestoredWallet(backup: backup)
            check(restored.secret.privateKey == material, "Cloud restoration adapter must preserve Dogecoin scope and compression")
        }
        for material in [
            OathImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: [.litecoin], compressed: false),
            OathImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: [.litecoin], compressed: true,
                                   litecoinExtendedKey: "Ltpv-serialization-fixture")
        ] {
            let litecoin = OathWalletSecret(id: UUID(), mnemonic: "", language: "", createdAt: .now,
                                            backedUp: true, imported: true, privateKey: material)
            let (sealed, key) = try OathVaultEnvelope.seal(litecoin, digits: pin)
            check(sealed.version == 7, "Old readers must reject extended/uncompressed Litecoin material")
            check(try sealed.openContents(using: key).wallets.first?.privateKey == material,
                  "Litecoin key scope and compression survive local encrypted round trip")
            let portable = try JSONEncoder().encode(sealed)
            check(portable.range(of: material.bytes) == nil, "Litecoin private bytes stay encrypted")
            if let extended = material.litecoinExtendedKey {
                check(portable.range(of: Data(extended.utf8)) == nil, "Litecoin extended key stays encrypted")
            }
            let downgraded = OathVaultEnvelope(version: 2, id: sealed.id, salt: sealed.salt,
                iterations: sealed.iterations, sealed: sealed.sealed, walletIDs: sealed.walletIDs)
            rejects("Downgraded Litecoin envelope accepted") { _ = try downgraded.openContents(using: key) }
            let backup = BackupWallet(id: litecoin.id, name: "Litecoin fixture", mnemonic: "", language: "", createdAt: litecoin.createdAt,
                accounts: [.init(network: "litecoin", derivationPath: "imported", index: 0)],
                privateKey: .init(bytes: material.bytes, networks: ["litecoin"], compressed: material.compressed,
                                  litecoinExtendedKey: material.litecoinExtendedKey))
            let restored = try OathRestoredWallet(backup: backup)
            check(restored.secret.privateKey == material, "Cloud restoration adapter must preserve Litecoin scope and compression")
        }
        for material in [
            OathImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: [.bitcoincash], compressed: false),
            OathImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: [.bitcoincash], compressed: true,
                                   bitcoinCashExtendedKey: "xprv-serialization-fixture")
        ] {
            let bitcoincash = OathWalletSecret(id: UUID(), mnemonic: "", language: "", createdAt: .now,
                                            backedUp: true, imported: true, privateKey: material)
            let (sealed, key) = try OathVaultEnvelope.seal(bitcoincash, digits: pin)
            check(sealed.version == 8, "Old readers must reject extended/uncompressed Bitcoin Cash material")
            check(try sealed.openContents(using: key).wallets.first?.privateKey == material,
                  "Bitcoin Cash key scope and compression survive local encrypted round trip")
            let portable = try JSONEncoder().encode(sealed)
            check(portable.range(of: material.bytes) == nil, "Bitcoin Cash private bytes stay encrypted")
            if let extended = material.bitcoinCashExtendedKey {
                check(portable.range(of: Data(extended.utf8)) == nil, "Bitcoin Cash extended key stays encrypted")
            }
            let downgraded = OathVaultEnvelope(version: 2, id: sealed.id, salt: sealed.salt,
                iterations: sealed.iterations, sealed: sealed.sealed, walletIDs: sealed.walletIDs)
            rejects("Downgraded Bitcoin Cash envelope accepted") { _ = try downgraded.openContents(using: key) }
            let backup = BackupWallet(id: bitcoincash.id, name: "Bitcoin Cash fixture", mnemonic: "", language: "", createdAt: bitcoincash.createdAt,
                accounts: [.init(network: "bitcoincash", derivationPath: "imported", index: 0)],
                privateKey: .init(bytes: material.bytes, networks: ["bitcoincash"], compressed: material.compressed,
                                  bitcoinCashExtendedKey: material.bitcoinCashExtendedKey))
            let restored = try OathRestoredWallet(backup: backup)
            check(restored.secret.privateKey == material, "Cloud restoration adapter must preserve Bitcoin Cash scope and compression")
        }
        // Version 9 makes the credential anchor independent of membership and
        // authenticates tombstones/journal together with retained recovery keys.
        var lifecycle = OathVaultContents(wallets: [first, second], lifecycleVersion: 1)
        lifecycle.wallets[0].deletedAt = Date(timeIntervalSince1970: 100)
        let deleted = try OathVaultEnvelope.seal(lifecycle, rootID: first.id, key: existingKey,
            salt: legacy.salt, iterations: legacy.iterations)
        check(deleted.version == 9, "Lifecycle ciphertext uses a format older binaries reject")
        let recoveredLifecycle = try deleted.openContents(using: existingKey)
        check(recoveredLifecycle.wallets.first?.deletedAt == Date(timeIntervalSince1970: 100), "Deletion deadlines are authenticated and retained")
        check(try recoveredLifecycle.selectedWalletID(first.id.uuidString) == second.id, "Removed wallet can never be selected")
        let downgradedLifecycle = OathVaultEnvelope(version: 2, id: deleted.id, salt: deleted.salt,
            iterations: deleted.iterations, sealed: deleted.sealed, walletIDs: deleted.walletIDs)
        rejects("A lifecycle envelope cannot be downgraded") { _ = try downgradedLifecycle.openContents(using: existingKey) }
        lifecycle.wallets.removeFirst(); lifecycle.purgedWalletIDs = [first.id]
        let rootRemoved = try OathVaultEnvelope.seal(lifecycle, rootID: first.id, key: existingKey,
            salt: legacy.salt, iterations: legacy.iterations)
        check(try rootRemoved.openContents(using: existingKey).purgedWalletIDs == [first.id], "Purge journal survives root member removal")
        lifecycle.wallets = []; lifecycle.purgedWalletIDs = nil
        let empty = try OathVaultEnvelope.seal(lifecycle, rootID: first.id, key: existingKey,
            salt: legacy.salt, iterations: legacy.iterations)
        check(try empty.openContents(using: empty.key(for: pin)).wallets.isEmpty, "An empty v9 vault preserves the app PIN")
        rejects("Journal cannot purge a retained member") {
            _ = try OathVaultEnvelope.seal(.init(wallets: [second], lifecycleVersion: 1, purgedWalletIDs: [second.id]),
                rootID: first.id, key: existingKey, salt: legacy.salt, iterations: legacy.iterations)
        }
        lifecycle.wallets = [first]; lifecycle.wallets[0].deletedAt = .init(timeIntervalSince1970: .infinity)
        rejects("Invalid removal dates must not be persisted") {
            _ = try OathVaultEnvelope.seal(lifecycle, rootID: first.id, key: existingKey, salt: legacy.salt, iterations: legacy.iterations)
        }
        print("Passed \(checks) multi-wallet envelope checks")
    }
}

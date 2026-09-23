import Foundation
import Testing
import WalletCore
@testable import Aperture

// Public fixtures below are standard Hardhat and Trezor BIP-39 test vectors.
// They must never be used to hold funds. No user-supplied credentials belong here.
struct WalletCredentialSafetyServiceTests {
    @Test
    func rejectsPublishedDevelopmentMnemonicFingerprint() {
        let phrase = "test test test test test test test test test test test junk"
        let finding = WalletCredentialSafetyService
            .recoveryPhraseFinding(phrase)

        #expect(finding?.credentialKind == .recoveryPhrase)
        #expect(finding?.reason == .publiclyKnown)
    }

    @Test(arguments: [
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
    ])
    func rejectsStandardPublicMnemonicFingerprint(_ phrase: String) {
        let finding = WalletCredentialSafetyService
            .recoveryPhraseFinding(phrase)

        #expect(BIP39Mnemonic.isValid(phrase))
        #expect(finding?.credentialKind == .recoveryPhrase)
        #expect(finding?.reason == .publiclyKnown)
    }

    @Test
    func rejectsPublishedDevelopmentAccountPrivateKey() throws {
        let phrase =
            "test test test test test test test test test test test junk"
        let wallet = try #require(
            HDWallet(mnemonic: phrase, passphrase: "")
        )
        let privateKey = wallet.getKeyForCoin(coin: .ethereum)
        let finding = WalletCredentialSafetyService
            .privateKeyFinding(privateKey.data)

        #expect(finding?.credentialKind == .privateKey)
        #expect(finding?.reason == .publiclyKnown)
    }

    @Test
    func rejectsHighlyPredictableMnemonicPattern() {
        let phrase = Array(repeating: "abandon", count: 11)
            .appending("zoo")
            .joined(separator: " ")
        let finding = WalletCredentialSafetyService
            .recoveryPhraseFinding(phrase)

        #expect(finding?.credentialKind == .recoveryPhrase)
        #expect(finding?.reason == .predictablyWeak)
    }

    @Test
    func publishedValidMnemonicReachesMandatorySafetyWarning() throws {
        let phrase = "test test test test test test test test test test test junk"

        #expect(BIP39Mnemonic.isValid(phrase))
        #expect(WalletCoreService.isValidRecoveryPhrase(phrase))
        let draft = try WalletCoreService.importRecoveryPhrase(phrase)
        let finding = WalletCredentialSafetyService.finding(for: draft)

        #expect(finding?.credentialKind == .recoveryPhrase)
        #expect(finding?.reason == .publiclyKnown)
        #expect(!draft.address.isEmpty)
    }

    @Test(arguments: [
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        "legal winner thank year wave sausage worth useful legal winner thank yellow"
    ])
    func auditedPublicVectorsReachUnsafeHandlingWithoutPersistence(_ phrase: String) throws {
        let variants = [
            phrase,
            phrase + " ",
            " \n" + phrase.replacingOccurrences(of: " ", with: "  \t") + "\n"
        ]
        for passphrase in ["", "TREZOR"] {
            let canonical = try WalletCoreService.importRecoveryPhrase(
                phrase, passphrase: passphrase
            )
            for input in variants {
                #expect(RecoveryPhraseInputFeedback.evaluate(input) == nil)
                let draft = try WalletCoreService.importRecoveryPhrase(
                    input, passphrase: passphrase
                )
                #expect(draft.address == canonical.address)
                #expect(WalletCredentialSafetyService.finding(for: draft)?.reason == .publiclyKnown)
            }
        }
    }

    @Test(arguments: [
        "test test test test test test test test test test test junk",
    ])
    func persistenceBoundaryRejectsPublishedCredential(_ phrase: String) async throws {
        let database = try WalletDatabase.temporary()
        let draft = try WalletCoreService.importRecoveryPhrase(phrase)

        await #expect(throws: WalletCreationPersistenceError.self) {
            try await database.persistImportedWallet(
                draft: draft,
                security: .reuseExistingProfile
            )
        }
    }


    @Test
    func rejectsSmallPrivateKeyScalar() {
        var key = Data(repeating: 0, count: 32)
        key[key.index(before: key.endIndex)] = 42
        let finding = WalletCredentialSafetyService.privateKeyFinding(key)

        #expect(finding?.credentialKind == .privateKey)
        #expect(finding?.reason == .predictablyWeak)
    }

    @Test
    func allowsNonPatternedPrivateKey() {
        let key = Data([
            0x7d, 0x12, 0xa6, 0x49, 0xd1, 0x03, 0x84, 0xfe,
            0x20, 0xb7, 0x65, 0x93, 0x4a, 0xce, 0x19, 0x58,
            0xe3, 0x76, 0x0f, 0xbc, 0x95, 0x31, 0xda, 0x47,
            0x62, 0x8b, 0xf4, 0x25, 0x9e, 0x50, 0xc8, 0x11
        ])

        #expect(WalletCredentialSafetyService.privateKeyFinding(key) == nil)
    }
}

private extension Array {
    func appending(_ element: Element) -> [Element] {
        self + [element]
    }
}

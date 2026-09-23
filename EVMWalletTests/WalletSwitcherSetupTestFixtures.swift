import Foundation
import WalletCore
@testable import Aperture

/// Fresh credentials for tests that cross the production import boundary.
/// They are generated at runtime so no reusable secret is committed as a
/// persistence fixture.
enum WalletCredentialTestFixtures {
    static func recoveryPhrase() -> String {
        for _ in 0..<16 {
            guard
                let draft = try? WalletCoreService.generateEVMWallet(),
                WalletCredentialSafetyService.recoveryPhraseFinding(
                    draft.mnemonic
                ) == nil
            else {
                continue
            }
            return draft.mnemonic
        }
        preconditionFailure("Unable to generate a safe recovery phrase fixture.")
    }

    static func privateKey() -> Data {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<16 {
            let data = Data((0..<32).map { _ in
                UInt8.random(in: .min ... .max, using: &generator)
            })
            guard
                PrivateKey(data: data) != nil,
                WalletCredentialSafetyService.privateKeyFinding(data) == nil
            else {
                continue
            }
            return data
        }
        preconditionFailure("Unable to generate a safe private-key fixture.")
    }
}

/// Public BIP39 test vectors only. No app Keychain or real wallet is used.
@MainActor
enum WalletSwitcherSetupTestFixtures {
    static func creation(passphrase: String = "") throws -> WalletCreationDraft {
        try WalletCoreService.restoreEVMWallet(
            mnemonic: Array(repeating: "abandon", count: 11).joined(separator: " ") + " about",
            passphrase: passphrase
        )
    }

    static func imported(passphrase: String = "") throws -> WalletImportDraft {
        let draft = try creation(passphrase: passphrase)
        return WalletImportDraft(
            secret: .recoveryPhrase(
                mnemonic: draft.mnemonic, passphrase: draft.passphrase, wordCount: 12
            ),
            address: draft.address,
            normalizedAddress: draft.normalizedAddress,
            derivationPath: draft.derivationPath,
            publicKey: draft.publicKey
        )
    }

    static let backup = WalletCloudBackupDescriptor(
        walletID: "switcher-test-backup", walletName: "Test Backup",
        backedUpAt: Date(timeIntervalSince1970: 1_700_000_000), hasPassphrase: false
    )

    static func services() -> WalletSwitcherSetupServices {
        WalletSwitcherSetupServices(
            generate: { entropy in
                if let entropy {
                    return try WalletCoreService.generateEVMWallet(entropy: entropy)
                }
                return try creation()
            },
            applyPassphrase: {
                try WalletCoreService.restoreEVMWallet(mnemonic: $0, passphrase: $1)
            },
            existingWallet: { _ in nil },
            create: { PersistedWalletIdentity(walletID: "created", address: $0.address) },
            importWallet: { draft, _, _ in
                PersistedWalletIdentity(walletID: "imported", address: draft.address)
            },
            selectWallet: {
                PersistedWalletIdentity(walletID: $0, address: NativeListTestFixtures.address)
            },
            didPersist: { _ in }
        )
    }
}

@MainActor
final class WalletSwitcherTestGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async -> Value {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

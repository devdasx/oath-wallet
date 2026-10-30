import Foundation
import CryptoKit
import Security
import OathDatabase
import OathCloudBackup
import OathDiagnostics
import OathBitcoin
import WalletCore

/// Retained origin and naming metadata inside authenticated ciphertext only.
/// Current import rules determine the destination accounts and address types.
struct OathLegacyWalletMetadata: Codable, Sendable {
    let wallet: LegacyWallet
    let accounts: [LegacyAccount]
}

protocol OathLegacySecretReading: Sendable {
    func read(reference: String) throws -> Data
}

struct OathLegacyKeychain: OathLegacySecretReading {
    func read(reference: String) throws -> Data {
        guard !reference.isEmpty, reference.utf8.count < 512 else { throw LegacyUpgradeError.keyUnavailable }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.codex.prototype.evmwallet.secrets",
            kSecAttrAccount as String: reference,
            kSecAttrSynchronizable as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnData as String: true
        ]
        #if !targetEnvironment(simulator)
        query[kSecAttrAccessGroup as String] = "C5T44SZNQX.com.aperture.wallet"
        #endif
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            OathDiagnostics.record(DiagnosticFailure("legacy_keychain_read"), component: "legacy_upgrade", operation: "keychain_read",
                                   context: ["stage": "read", "reason": "keychain_status_\(status)"])
            throw LegacyUpgradeError.keyUnavailable
        }
        return data
    }
}

struct OathLegacyPasscodeCredential: Decodable {
    let algorithm: String
    let iterations: UInt32
    let salt: Data
    let verifier: Data

    func validate() throws {
        guard algorithm == "pbkdf2-hmac-sha256", [210_000, 310_000].contains(iterations),
              salt.count == 32, verifier.count == 32 else { throw LegacyUpgradeError.invalidCredential }
    }

    static func read(reference: String, secrets: any OathLegacySecretReading) throws -> Self {
        func decoded(_ reference: String) throws -> Self {
            var data = try secrets.read(reference: reference)
            defer { data.resetBytes(in: 0..<data.count) }
            let credential = try JSONDecoder().decode(Self.self, from: data)
            try credential.validate()
            return credential
        }
        do { return try decoded(reference) }
        catch {
            // Old releases maintain this recovery alias. Only a missing/corrupt
            // credential permits fallback; an incorrect PIN never does.
            OathDiagnostics.record(DiagnosticFailure("legacy_verifier_primary_unavailable"), component: "legacy_upgrade", operation: "verifier_read")
            return try decoded(reference + ".passcode-verifier-backup")
        }
    }

    func matches(_ digits: [UInt8]) throws -> Bool {
        try validate()
        let candidate = try OathPasscodeRecord.make(digits: digits, salt: Array(salt), iterations: iterations).verifier
        return zip(candidate, verifier).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct OathLegacyUnlockAttempts: Codable {
    var failures: Int
    var blockedUntil: Date?
    mutating func recordAttempt(now: Date) {
        failures = min(failures + 1, 20)
        if failures >= 5 {
            let delays: [TimeInterval] = [5, 30, 300, 1_800, 3_600, 21_600]
            blockedUntil = now.addingTimeInterval(delays[min(failures - 5, delays.count - 1)])
        }
    }
}

enum OathLegacyUpgrade {
    static var sourceURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("WalletDatabase/wallet.sqlite")
    }

    private struct RecoveryEnvelope: Decodable {
        let format: String
        let version: Int
        let mnemonic: String
        let passphrase: String
        let scheme: String?
    }

    static func chain(_ network: String) throws -> OathImportChain {
        let aliases = ["eth": "ethereum", "bsc": "bnb", "xrp": "xrpl", "bitcoin_cash": "bitcoincash"]
        guard let chain = OathImportChain(rawValue: aliases[network] ?? network) else { throw LegacyUpgradeError.unsupportedWallet }
        return chain
    }

    /// Invoked only after the old passcode has been verified (or the old
    /// persisted security state explicitly says protection was disabled).
    static func prepare(_ source: LegacyWalletSnapshot, secrets: any OathLegacySecretReading) throws
        -> (OathVaultContents, LegacyUpgradeBatch) {
        let root = try rootID(for: source)
        let selected = source.activeWalletID.flatMap(UUID.init(uuidString:))
        // Missing bundled validation resources are an app installation problem,
        // not evidence that every wallet's recovery data is invalid.
        guard let validator = OathMnemonicValidator.bundled else {
            throw OathMnemonicValidator.ResourceError.missing
        }
        var migrated: [OathWalletSecret] = [], wallets: [WalletRecord] = [], accounts: [AccountRecord] = []
        var skippedRecoveryWalletCount = 0
        var skippedUnsupportedWalletCount = source.unreadableWalletCount ?? 0
        var skippedFailureKinds = Set<String>()
        let accountsByWallet = Dictionary(grouping: source.accounts, by: \.walletID)
        let unreadableAccounts = Set(source.unreadableAccountWalletIDs ?? [])
        for wallet in source.wallets {
            try Task.checkCancellation()
            do {
                guard !unreadableAccounts.contains(wallet.id) else { throw LegacyUpgradeError.invalidSource }
                guard let id = UUID(uuidString: wallet.id), !wallet.name.isEmpty, wallet.name.count <= 100,
                      wallet.createdAt.isFinite else { throw LegacyUpgradeError.invalidSource }
                guard ["created", "importedRecoveryPhrase", "importedPrivateKey"].contains(wallet.kind) else {
                    throw LegacyUpgradeError.unsupportedWallet
                }
                guard let reference = wallet.secretKeyReference else { throw LegacyUpgradeError.keyUnavailable }
                let publicAccounts = accountsByWallet[wallet.id] ?? []
                guard publicAccounts.contains(where: \.isEnabled), publicAccounts.allSatisfy({ !$0.isWatchOnly && !$0.address.isEmpty && ($0.accountIndex ?? 0) >= 0 }) else { throw LegacyUpgradeError.unsupportedWallet }
                var data = try secrets.read(reference: reference)
                defer { data.resetBytes(in: 0..<data.count) }
                let candidate: OathWalletSecret
                switch wallet.kind {
                case "created", "importedRecoveryPhrase":
                    let phrase: String, passphrase: String, scheme: String
                    if data.first == UInt8(ascii: "{") {
                        let envelope = try JSONDecoder().decode(RecoveryEnvelope.self, from: data)
                        guard envelope.format == "aperture.wallet.recovery-credential", [1, 2].contains(envelope.version) else {
                            throw LegacyUpgradeError.invalidCredential
                        }
                        phrase = envelope.mnemonic; passphrase = envelope.passphrase; scheme = envelope.scheme ?? "bip39"
                    } else {
                        guard let text = String(data: data, encoding: .utf8) else { throw LegacyUpgradeError.invalidCredential }
                        phrase = text; passphrase = ""; scheme = "bip39"
                    }
                    // Compatibility is per wallet. Never let an unsupported recovery
                    // format block unrelated wallets, or reinterpret it as BIP-39.
                    // The legacy database and Keychain item remain untouched.
                    guard scheme == "bip39", wallet.recoveryScheme == nil || wallet.recoveryScheme == scheme else {
                        skippedRecoveryWalletCount += 1
                        continue
                    }
                    guard passphrase.utf8.count <= 4_096 else { throw LegacyUpgradeError.invalidCredential }
                    guard let validated = validator.verifiedPhrase(phrase) else {
                        skippedRecoveryWalletCount += 1
                        continue
                    }
                    candidate = OathWalletSecret(id: id, mnemonic: validated.phrase, language: validated.language,
                        createdAt: Date(timeIntervalSince1970: wallet.createdAt), backedUp: wallet.backupState == "verified",
                        imported: wallet.kind != "created", createdWithCustomization: false,
                        passphrase: passphrase.isEmpty ? nil : passphrase,
                        legacy: .init(wallet: wallet, accounts: publicAccounts))
                case "importedPrivateKey":
                    let oldNetworks = try Array(Set(publicAccounts.map { try chain($0.networkID) }))
                    let networks = (oldNetworks.allSatisfy(\.isEVM) ? OathImportChain.allCases.filter(\.isEVM) : oldNetworks)
                        .sorted { $0.id < $1.id }
                    let material = try privateKey(data, networks: networks, accounts: publicAccounts)
                    guard material.isValidStructure else { throw LegacyUpgradeError.invalidCredential }
                    candidate = OathWalletSecret(id: id, mnemonic: "", language: "", createdAt: Date(timeIntervalSince1970: wallet.createdAt),
                        backedUp: wallet.backupState == "verified", imported: true, createdWithCustomization: false,
                        privateKey: material, legacy: .init(wallet: wallet, accounts: publicAccounts))
                default: throw LegacyUpgradeError.unsupportedWallet
                }
                // The current app owns supported chains, address types and default paths.
                // Preserve the secret and wallet identity; do not extend that policy
                // with retired legacy address types or cached discovery records.
                try verifyOwnership(candidate, accounts: publicAccounts)
                let profile = try OathWalletEngine.profile(for: candidate)
                migrated.append(candidate)
                var record = WalletRecord(id: id.uuidString, name: wallet.name,
                    kind: candidate.privateKey != nil ? "privateKey" : (wallet.kind == "created" ? "hd" : "imported"),
                    vaultReference: OathVaultContents.reference(for: id, rootID: root), createdAt: wallet.createdAt,
                    backedUp: candidate.backedUp, nameGroup: wallet.kind == "created" ? "main" : "imported")
                record.sortOrder = wallets.count; record.nameIndex = wallets.count
                wallets.append(record)
                accounts += profile.addresses.map {
                    AccountRecord(id: id.uuidString + ":" + $0.chain.id + ":" + String($0.accountIndex), walletID: id.uuidString, networkID: $0.chain.id, address: $0.address,
                                  derivationPath: $0.path, accountIndex: $0.accountIndex)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // A bad wallet must not block valid siblings. Preserve the old
                // records, omit the whole failed wallet, and report only a fixed
                // category, never error descriptions or recovery material.
                skippedUnsupportedWalletCount += 1
                let kind = failureKind(error)
                if skippedFailureKinds.insert(kind).inserted {
                    OathDiagnostics.record(DiagnosticFailure("legacy_wallet_skipped"),
                        component: "legacy_upgrade", operation: "skip_wallet",
                        context: ["stage": "prepare", "reason": kind])
                }
            }
        }
        let requestedDelay = source.security.autoLockSeconds ?? 60
        // Unsupported old grace intervals are shortened, never lengthened.
        let delay = [0, 60, 300, 600].last(where: { $0 <= requestedDelay }) ?? 0
        if skippedRecoveryWalletCount > 0 {
            // One safe compatibility report per attempt; never include recovery
            // material, wallet identities, names or Keychain references.
            OathDiagnostics.record(DiagnosticFailure("legacy_recovery_format_skipped"),
                component: "legacy_upgrade", operation: "skip_unsupported_recovery",
                context: ["stage": "prepare"])
        }
        let activeWalletID = wallets.first(where: { $0.id == selected?.uuidString })?.id ?? wallets.first?.id
        let batch = LegacyUpgradeBatch(sourceFingerprint: try source.fingerprint, wallets: wallets, accounts: accounts,
            activeWalletID: activeWalletID, settings: ["security.appSwitcherPrivacy": source.security.privacyShieldEnabled ? "true" : "false",
                "security.lockDelay": String(delay), "language": source.security.language, "currency": source.security.currency],
            skippedRecoveryWalletCount: skippedRecoveryWalletCount,
            skippedUnsupportedWalletCount: skippedUnsupportedWalletCount)
        return (OathVaultContents(wallets: migrated, lifecycleVersion: 1, legacyUpgrade: batch), batch)
    }

    static func rootID(for source: LegacyWalletSnapshot) throws -> UUID {
        if let id = source.wallets.compactMap({ UUID(uuidString: $0.id) }).first { return id }
        // All invalid identifiers still lead to an empty, protected collection.
        // A stable anchor makes an interrupted migration replayable.
        let hex = Array(try source.fingerprint.prefix(32))
        let value = [String(hex[0..<8]), String(hex[8..<12]), String(hex[12..<16]),
                     String(hex[16..<20]), String(hex[20..<32])].joined(separator: "-")
        guard let id = UUID(uuidString: value) else { throw LegacyUpgradeError.invalidSource }
        return id
    }

    private static func failureKind(_ error: any Error) -> String {
        switch error as? LegacyUpgradeError {
        case .keyUnavailable: return "key_unavailable"
        case .addressMismatch: return "ownership_mismatch"
        case .invalidCredential: return "invalid_credential"
        case .invalidSource: return "invalid_record"
        case .unsupportedWallet: return "unsupported_format"
        default: return error is DecodingError ? "invalid_encoding" : "import_failure"
        }
    }

    private static func verifyOwnership(_ secret: OathWalletSecret, accounts: [LegacyAccount]) throws {
        // Collections are checked against their original primary public key
        // while their descriptor document is available in privateKey(_:...).
        if accounts.allSatisfy({ $0.derivationPath == "bitcoin-imported-collection:v1" }) { return }
        let hd: HDWallet?
        if secret.privateKey == nil {
            hd = HDWallet(mnemonic: secret.mnemonic, passphrase: try secret.bip39Passphrase, check: false)
            guard hd != nil else { throw LegacyUpgradeError.invalidCredential }
        } else { hd = nil }
        for account in accounts {
            try Task.checkCancellation()
            let network = try chain(account.networkID)
            let key: PrivateKey
            if let material = secret.privateKey {
                guard PrivateKey.isValid(data: material.bytes, curve: network.walletCoin.curve),
                      let value = PrivateKey(data: material.bytes) else { throw LegacyUpgradeError.invalidCredential }
                key = value
            } else {
                guard let path = account.derivationPath, validIdentityPath(path),
                      let value = hd?.getKey(coin: network.walletCoin, derivationPath: path) else {
                    throw LegacyUpgradeError.invalidCredential
                }
                key = value
            }
            let publicKeys = network.walletCoin.curve == .secp256k1
                ? [key.getPublicKeySecp256k1(compressed: true).data, key.getPublicKeySecp256k1(compressed: false).data]
                : [key.getPublicKeyEd25519().data]
            if let recorded = account.publicKey, !recorded.isEmpty {
                guard matchesPublicKey(recorded, keys: publicKeys) else { throw LegacyUpgradeError.addressMismatch }
            } else {
                // Some early rows lack a public key. Require an independently
                // rederived address instead; absent evidence never means success.
                let derived = network.walletCoin.deriveAddress(privateKey: key)
                guard network.isEVM ? derived.lowercased() == account.address.lowercased() : derived == account.address else {
                    throw LegacyUpgradeError.addressMismatch
                }
            }
        }
    }

    private static func matchesPublicKey(_ recorded: String, keys: [Data]) -> Bool {
        guard recorded.utf8.count <= 132 else { return false }
        return keys.contains { key in
            let hex = key.map { String(format: "%02x", $0) }.joined()
            return recorded.lowercased() == hex || recorded.lowercased() == "0x" + hex
                || recorded == key.base64EncodedString()
                || recorded == "ed25519:" + Base58.encodeNoCheck(data: key)
        }
    }

    private static func validIdentityPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.utf8.count <= 512, parts.first == "m", (2...33).contains(parts.count) else { return false }
        return parts.dropFirst().allSatisfy { part in
            let number = part.hasSuffix("'") ? part.dropLast() : part[...]
            return !number.isEmpty && number.utf8.allSatisfy { (48...57).contains($0) }
                && UInt32(number).map { $0 < 0x8000_0000 } == true
        }
    }

    private static func privateKey(_ data: Data, networks: [OathImportChain], accounts: [LegacyAccount]) throws -> OathImportedPrivateKey {
        let formats: Set<String> = ["rawSecp256k1", "wifCompressed", "wifUncompressed", "extendedLegacy",
            "extendedNestedSegwit", "extendedNativeSegwit", "solanaSeed", "solanaKeypair", "rawEd25519"]
        if data.count == 32, accounts.allSatisfy({ account in
            guard let path = account.derivationPath, path.hasPrefix("private-key:") else { return false }
            return formats.contains(String(path.dropFirst(12)))
        }) {
            return OathImportedPrivateKey(bytes: data, networks: networks,
                compressed: accounts.contains(where: { $0.derivationPath == "private-key:wifUncompressed" }) ? false : nil)
        }
        // Old Bitcoin imports encoded one key in multiple descriptors. Feed
        // that key into the EXISTING importer; do not install legacy scripts.
        // A collection with unrelated keys cannot be reduced to its first key.
        guard networks == [.bitcoin], data.count <= 1_048_576,
              accounts.allSatisfy({ $0.derivationPath == "bitcoin-imported-collection:v1" }) else {
            throw LegacyUpgradeError.unsupportedWallet
        }
        let document = try JSONDecoder().decode(PrivateKeyCollection.self, from: data)
        guard let first = document.sources.first?.descriptor,
              accounts.count == 1,
              document.sources.count <= 1_024,
              document.sources.allSatisfy({ $0.descriptor.key == first.key && $0.descriptor.node == first.node
                  && $0.descriptor.compressed == first.compressed && $0.descriptor.electrumOldBranch == nil }) else {
            throw LegacyUpgradeError.unsupportedWallet
        }
        if let node = first.node {
            guard first.compressed, node.privateKey == first.key, node.privateKey.count == 32,
                  node.chainCode.count == 32, node.parentFingerprint.count == 4 else { throw LegacyUpgradeError.invalidCredential }
            var payload = Data([0x04, 0x88, 0xad, 0xe4, node.depth]) + node.parentFingerprint
            payload += Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: node.childNumber >> ($0 * 8)) })
            payload += node.chainCode + Data([0]) + node.privateKey
            defer { payload.resetBytes(in: 0..<payload.count) }
            let parsed = try BitcoinKeys.decodeImport(Base58.encode(data: payload))
            guard let primary = document.sources.first(where: { $0.internalBranch != true }) ?? document.sources.first,
                  let extended = parsed.extended else { throw LegacyUpgradeError.invalidCredential }
            let publicKey = try BitcoinKeys.importPublicKey(extended, relativePath: primary.identityPath())
            guard let recorded = accounts.first?.publicKey, matchesPublicKey(recorded, keys: [publicKey]) else {
                throw LegacyUpgradeError.addressMismatch
            }
            return .init(bytes: parsed.bytes, networks: networks, compressed: parsed.compressed, bitcoinExtendedKey: parsed.extended)
        }
        guard PrivateKey.isValid(data: first.key, curve: .secp256k1), let key = PrivateKey(data: first.key),
              document.sources.allSatisfy({ ($0.descriptor.path ?? []).isEmpty }),
              let recorded = accounts.first?.publicKey,
              matchesPublicKey(recorded, keys: [key.getPublicKeySecp256k1(compressed: first.compressed).data]) else {
            throw LegacyUpgradeError.addressMismatch
        }
        return .init(bytes: first.key, networks: networks, compressed: first.compressed)
    }

    private struct PrivateKeyCollection: Decodable {
        struct Node: Decodable, Equatable {
            let privateKey: Data, chainCode: Data, parentFingerprint: Data
            let depth: UInt8
            let childNumber: UInt32
        }
        struct Descriptor: Decodable {
            enum Component: Decodable {
                case child(UInt32), alternatives([UInt32]), wildcard(hardened: Bool)
            }
            let key: Data
            let compressed: Bool
            let node: Node?
            let electrumOldBranch: Int?
            let path: [Component]?
        }
        struct Source: Decodable {
            let descriptor: Descriptor
            let internalBranch: Bool?
            let rangeStart: UInt32?

            func identityPath() throws -> String {
                let parts = descriptor.path ?? []
                guard parts.count <= 32, (rangeStart ?? 0) < 0x8000_0000 else { throw LegacyUpgradeError.invalidCredential }
                return try parts.enumerated().reduce("m") { path, entry in
                    let child: UInt32
                    switch entry.element {
                    case .child(let value): child = value
                    case .alternatives(let values):
                        guard (2...16).contains(values.count), let value = values.first else { throw LegacyUpgradeError.invalidCredential }
                        child = value
                    case .wildcard(let hardened):
                        guard entry.offset == parts.count - 1 else { throw LegacyUpgradeError.invalidCredential }
                        child = (rangeStart ?? 0) | (hardened ? 0x8000_0000 : 0)
                    }
                    return path + "/" + String(child & 0x7fff_ffff) + (child >= 0x8000_0000 ? "'" : "")
                }
            }
        }
        let sources: [Source]
        private enum CodingKeys: String, CodingKey { case format, version, material, sources }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if c.contains(.format) || c.contains(.version) || c.contains(.material) {
                guard try c.decode(String.self, forKey: .format) == "bitcoinImportedWallet",
                      try c.decode(Int.self, forKey: .version) == 1, !c.contains(.sources) else { throw LegacyUpgradeError.invalidCredential }
                sources = try c.decode(Self.self, forKey: .material).sources
            } else { sources = try c.decode([Source].self, forKey: .sources) }
        }
    }

}

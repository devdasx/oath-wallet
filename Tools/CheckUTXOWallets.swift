import Foundation
import OathBitcoin
import OathCloudBackup
import OathDatabase

extension CheckMultiWallet {
    /// Production import deduplication, restore identity and encrypted export.
    /// Curve/BIP32 input is a published fixture; the host profile adapter remains
    /// synthetic because WalletCore's binary is iOS-only.
    @MainActor static func checkUTXOKeyIdentity() async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let dogeFixtureURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OATH_TEST_DOGECOIN_VECTORS"]!)
        let dogeFixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: dogeFixtureURL)) as! [String: Any]
        let ltcFixtureURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OATH_TEST_LITECOIN_VECTORS"]!)
        let ltcFixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: ltcFixtureURL)) as! [String: Any]
        let pin: [UInt8] = [4, 1, 7, 9, 2, 6]
        for chain in [OathImportChain.bitcoin, .dogecoin, .litecoin, .bitcoincash] {
            let fixtures = chain == .litecoin ? ltcFixtures : dogeFixtures
            let network = UTXONetwork(rawValue: chain.id)!
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathUTXOIdentity-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
            try await OathDataEnvironment.seed(db)
            let storage = WalletMemory(), biometrics = MemoryBiometrics()
            let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
            func material(_ name: String) throws -> OathImportedPrivateKey {
                let encoded = fixtures[name] as! String
                let decoded = try network.decodeImport(encoded)
                return .init(bytes: decoded.bytes, networks: [chain], compressed: true,
                    bitcoinExtendedKey: chain == .bitcoin ? decoded.extended : nil,
                    dogecoinExtendedKey: chain == .dogecoin ? decoded.extended : nil,
                    bitcoinCashExtendedKey: chain == .bitcoincash ? decoded.extended : nil,
                    litecoinExtendedKey: chain == .litecoin ? decoded.extended : nil)
            }
            let root = try material((chain == .bitcoin || chain == .bitcoincash) ? "rootXprv" : "root")
            let otherRoot = try material((chain == .bitcoin || chain == .bitcoincash) ? "otherRootXprv" : "otherRoot")
            let compressed = OathImportedPrivateKey(bytes: root.bytes, networks: [chain], compressed: true)
            let uncompressed = OathImportedPrivateKey(bytes: root.bytes, networks: [chain], compressed: false)
            let descriptor = try root.bitcoinDescriptor()
            check(descriptor.network == network && descriptor.branches.allSatisfy(\.isHD), "Production adapter preserves chain and HD scope")
            check(try uncompressed.bitcoinDescriptor().types == [.legacy], "Uncompressed imports stay Legacy")
            check(try compressed.bitcoinDescriptor().branches.allSatisfy { !$0.isHD }, "Raw keys do not become HD wallets")
            check(root.bytes == otherRoot.bytes && !root.hasSameIdentity(as: otherRoot), "Chain code must be part of wallet identity")
            check(!compressed.hasSameIdentity(as: uncompressed), "Compression must be part of wallet identity")
            try await vault.create(digits: pin, importing: nil, privateKey: compressed)
            let session = OathWalletSession(vault: vault)
            await session.finishedSetup()
            let firstID = session.displayedProfile!.id.uuidString
            let uncompressedID = try await session.addWallet(requestID: UUID(), privateKey: uncompressed)
            check(uncompressedID != firstID && session.wallets.count == 2, "Uncompressed import must not select the compressed wallet")
            let legacy = OathImportedPrivateKey(bytes: root.bytes, networks: [chain])
            let aliasID = try await session.addWallet(requestID: UUID(), privateKey: legacy)
            check(aliasID == firstID && session.wallets.count == 2, "Original nil compression is the compressed-key alias")
            let rootID = try await session.addWallet(requestID: UUID(), privateKey: root)
            check(rootID != firstID && session.wallets.count == 3, "HD root must not select its finite raw private key")
            let otherID = try await session.addWallet(requestID: UUID(), privateKey: otherRoot)
            check(otherID != rootID && session.wallets.count == 4, "Different chain codes must remain separate wallets")
            let prefixAlias = try material("rootXprv")
            let prefixID = try await session.addWallet(requestID: UUID(), privateKey: prefixAlias)
            check(prefixID == rootID && session.wallets.count == 4, "Equivalent dgpv/xprv prefixes must deduplicate")
            let encrypted = try await vault.encryptedCloudBackup(walletID: rootID, password: "public-fixture-password")
            let backup = try BackupDocument.open(encrypted, password: "public-fixture-password")
            check(backup.privateKey?.dogecoinExtendedKey == root.dogecoinExtendedKey
                  && backup.privateKey?.bitcoinExtendedKey == root.bitcoinExtendedKey
                  && backup.privateKey?.litecoinExtendedKey == root.litecoinExtendedKey
                  && backup.privateKey?.bitcoinCashExtendedKey == root.bitcoinCashExtendedKey, "Vault-to-cloud mapping preserves HD scope")
            let restored = try await vault.restoreWallet(OathRestoredWallet(backup: backup))
            check(restored.id.uuidString == rootID, "Restoring an existing HD backup selects that HD wallet")
            for (id, replacement) in [(firstID, uncompressed), (rootID, otherRoot)] {
                let collision = BackupWallet(id: UUID(uuidString: id)!, name: "Conflict fixture", mnemonic: "", language: "", createdAt: .now,
                    accounts: [.init(network: chain.id, derivationPath: "imported", index: 0)],
                    privateKey: .init(bytes: replacement.bytes, networks: [chain.id], compressed: replacement.compressed,
                        bitcoinExtendedKey: replacement.bitcoinExtendedKey, dogecoinExtendedKey: replacement.dogecoinExtendedKey, litecoinExtendedKey: replacement.litecoinExtendedKey, bitcoinCashExtendedKey: replacement.bitcoinCashExtendedKey))
                do { _ = try await vault.restoreWallet(OathRestoredWallet(backup: collision)); preconditionFailure("Conflicting recovery identity was accepted") }
                catch { check(error as? CloudBackupError == .fileConflict, "UUID collision with another key scope must fail closed") }
            }
            await session.lock()
        }
        print("Passed \(checks) UTXO wallet identity checks (public fixtures, host vault/restore).")
        return checks
    }
}

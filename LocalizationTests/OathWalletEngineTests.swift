import XCTest
import WalletCore
import CryptoKit
import Observation
import OathDatabase
import GRDB
import OathCloudBackup
@testable import OathAtmosphere

/// All deterministic inputs are public upstream test fixtures, never live keys.
@MainActor final class OathWalletEngineTests: XCTestCase {
    private let fixture = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private let pin: [UInt8] = [2, 9, 4, 8, 1, 6]

    private func secret(_ phrase: String) throws -> OathWalletSecret {
        try OathWalletEngine.imported(XCTUnwrap(OathMnemonicValidator.bundled?.verifiedPhrase(phrase)))
    }

    func testEveryChainMatchesConfiguredDefault() throws {
        let source = try secret(fixture)
        let profile = try OathWalletEngine.profile(for: source)
        let wallet = try XCTUnwrap(HDWallet(mnemonic: fixture, passphrase: ""))
        XCTAssertEqual(profile.addresses.count, OathImportChain.allCases.count)
        XCTAssertEqual(Set(profile.addresses.map(\.chain)), Set(OathImportChain.allCases))
        for address in profile.addresses {
            if address.chain == .solana {
                XCTAssertEqual(address.path, "m/44'/501'/0'/0'")
                XCTAssertEqual(address.address, "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk")
                continue
            }
            XCTAssertEqual(address.path, address.chain.walletCoin.derivationPath(), address.chain.name)
            XCTAssertEqual(address.address, wallet.getAddressForCoin(coin: address.chain.walletCoin), address.chain.name)
            XCTAssertTrue(AnyAddress.isValid(string: address.address, coin: address.chain.walletCoin))
        }
        let evm = profile.addresses.filter { $0.chain.isEVM }
        XCTAssertEqual(evm.count, OathImportChain.allCases.filter(\.isEVM).count)
        XCTAssertEqual(Set(evm.map(\.address)).count, 1)
        XCTAssertEqual(Set(profile.addresses.map(\.address)).count, OathImportChain.allCases.filter { !$0.isEVM }.count + 1)
        XCTAssertEqual(evm.first?.address, "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
    }

    func testThorchainDerivationVector() throws {
        // Independently executed with WalletCore 4.8.4 WASM on the host.
        let profile = try OathWalletEngine.profile(for: secret(fixture), chains: [.thorchain])
        XCTAssertEqual(profile.addresses.count, 1)
        XCTAssertEqual(profile.addresses.first?.path, "m/44'/931'/0'/0/0")
        XCTAssertEqual(profile.addresses.first?.address, "thor1gm00vwsfcp48enm4uv9e5dhm37jtd0ye27wrx0")
    }

    func testPublishedTrustWalletAddressVectors() throws {
        // Source: wallet-core 4.8.4 / swift/Tests/HDWalletTests.swift.
        let upstreamPhrase = "ripple scissors kick mammal hire column oak again sun offer wealth tomorrow wagon turn fatal"
        let wallet = try XCTUnwrap(HDWallet(mnemonic: upstreamPhrase, passphrase: "TREZOR"))
        var passphraseSource = try secret(upstreamPhrase)
        passphraseSource.passphrase = "TREZOR"
        let passphraseProfile = try OathWalletEngine.profile(for: passphraseSource)
        let vectors: [(OathImportChain, String)] = [
            (.bitcoin, "bc1qumwjg8danv2vm29lp5swdux4r60ezptzz7ce85"),
            (.ethereum, "0x27Ef5cDBe01777D62438AfFeb695e33fC2335979"),
            (.hyperevm, "0x27Ef5cDBe01777D62438AfFeb695e33fC2335979"),
            (.litecoin, "ltc1qmj6hw649d7q2teduv599zv9ls9akz60gkdwnp7"),
            (.tron, "THJrqfbBhoB1vX97da6S6nXWkafCxpyCNB"),
            (.bitcoincash, "bitcoincash:qqxktqe0pzf0yepvap9rf2g8zxq8t5mqx50dwpqlxl"),
            (.xrpl, "r36yxStAh7qgTQNHTzjZvXybCTzUFhrfav"),
            (.stellar, "GCRWFRVQP5XS7I4SFCL374VKV6OHJ3L3H3SDVGH7FW73N7LSNYJXOLDK"),
            (.dogecoin, "DJRoWqKj6hVmZMEMPahJ7UsqaYCtEJ3xv9")
        ]
        for (chain, expected) in vectors {
            let key = try XCTUnwrap(wallet.getKey(coin: chain.walletCoin, derivationPath: chain.walletPath))
            XCTAssertEqual(chain.walletCoin.deriveAddress(privateKey: key), expected, chain.name)
            XCTAssertEqual(passphraseProfile.addresses.first { $0.chain == chain }?.address, expected, chain.name)
        }
        // Source: tests/common/HDWallet/HDWalletTests.cpp, NearKey.
        let near = try OathWalletEngine.profile(for: secret("owner erupt swamp room swift final allow unaware hint identify figure cotton"))
        XCTAssertEqual(near.addresses.first { $0.chain == .near }?.address,
                       "b8d5df25047841365008f30fb6b30dd820e9a84d869f05623d114e96831f2fbf")
        // Source: tests/chains/TheOpenNetwork/TWAnyAddressTests.cpp.
        let ton = try OathWalletEngine.profile(for: secret("stuff diamond cycle federal scan spread pigeon people engage teach snack grain"))
        XCTAssertEqual(ton.addresses.first { $0.chain == .ton }?.address,
                       "UQDYW_1eScJVxtitoBRksvoV9cCYo4uKGWLVNIHB1JqRRyQx")
    }

    func testGeneratedWalletAndNonEnglishImport() throws {
        let first = try OathWalletEngine.create(), second = try OathWalletEngine.create()
        XCTAssertTrue(first.mnemonic != second.mnemonic)
        XCTAssertTrue(OathMnemonicValidator.bundled?.validate(first.mnemonic).isValid == true)
        XCTAssertEqual(OathMnemonicValidator.words(in: first.mnemonic).count, 12)
        XCTAssertFalse(first.backedUp)
        // A known zero-entropy Japanese BIP-39 fixture. The seed MUST use this
        // language's words, never the English words for the same entropy.
        let japanese = Array(repeating: "あいこくしん", count: 11).joined(separator: " ") + " あおぞら"
        let imported = try secret(japanese)
        XCTAssertEqual(imported.language, "japanese")
        let profile = try OathWalletEngine.profile(for: imported)
        let direct = try XCTUnwrap(HDWallet(mnemonic: japanese, passphrase: "", check: false))
        XCTAssertEqual(profile.addresses.first { $0.chain == .ethereum }?.address, direct.getAddressForCoin(coin: .ethereum))
        let english = try OathWalletEngine.profile(for: secret(fixture))
        XCTAssertNotEqual(profile.addresses, english.addresses)
        XCTAssertThrowsError(try OathWalletEngine.imported(.init(phrase: "invalid phrase", language: "english")))
    }

    func testPrivateKeyExportsRoundTripToEverySavedAddress() throws {
        let source = try secret(fixture)
        let profile = try OathWalletEngine.profile(for: source)
        for address in profile.addresses {
            let account = OathPrivateKeyAccount(id: address.id, chain: address.chain,
                                              address: address.address, path: address.path)
            let exported = try OathWalletEngine.privateKey(for: source, account: account)
            let bytes = try decodeExport(exported.value, chain: address.chain)
            let restoredKey = try XCTUnwrap(PrivateKey(data: bytes))
            XCTAssertEqual(address.chain.walletCoin.deriveAddress(privateKey: restoredKey), address.address, address.chain.name)
            // Compare public addresses only; XCTest must never log a key value.
            XCTAssertFalse(exported.value.isEmpty)
        }
    }

    func testPassphraseExportMatchesEveryChainAndNeverTheBaseWallet() throws {
        let base = try secret(fixture)
        let baseProfile = try OathWalletEngine.profile(for: base)
        var source = base
        source.passphrase = "TREZOR"
        let profile = try OathWalletEngine.profile(for: source)
        XCTAssertEqual(profile.addresses.count, baseProfile.addresses.count)
        for address in profile.addresses {
            XCTAssertNotEqual(address.address, baseProfile.addresses.first { $0.chain == address.chain }?.address)
            let account = OathPrivateKeyAccount(id: address.id, chain: address.chain, address: address.address, path: address.path)
            let exported = try OathWalletEngine.privateKey(for: source, account: account)
            let restored = try XCTUnwrap(PrivateKey(data: decodeExport(exported.value, chain: address.chain)))
            XCTAssertEqual(address.chain.walletCoin.deriveAddress(privateKey: restored), address.address, address.chain.name)
            XCTAssertThrowsError(try OathWalletEngine.privateKey(for: base, account: account))
        }
    }

    func testPassphraseNormalizationAtDerivationAndExportBoundaries() throws {
        var composed = try secret(fixture)
        composed.passphrase = "  TéST 🔑  "
        var decomposed = composed
        decomposed.passphrase = try RecoveryPassphrase.normalized(composed.passphrase!)
        let normalized = try OathWalletEngine.profile(for: decomposed)
        XCTAssertEqual(try OathWalletEngine.profile(for: composed).addresses, normalized.addresses)
        let direct = try XCTUnwrap(HDWallet(mnemonic: fixture, passphrase: decomposed.passphrase!))
        XCTAssertEqual(normalized.addresses.first { $0.chain == .ethereum }?.address, direct.getAddressForCoin(coin: .ethereum))
        let address = try XCTUnwrap(normalized.addresses.first { $0.chain == .ethereum })
        let account = OathPrivateKeyAccount(id: address.id, chain: address.chain, address: address.address, path: address.path)
        let exported = try OathWalletEngine.privateKey(for: composed, account: account)
        let key = try XCTUnwrap(PrivateKey(data: decodeExport(exported.value, chain: .ethereum)))
        XCTAssertEqual(CoinType.ethereum.deriveAddress(privateKey: key), address.address)
        var trimmed = composed
        trimmed.passphrase = "TéST 🔑"
        XCTAssertNotEqual(try OathWalletEngine.profile(for: trimmed).addresses, normalized.addresses)
        for invalid in ["", "one\0two", String(repeating: "a", count: 257)] {
            var source = composed
            source.passphrase = invalid
            XCTAssertThrowsError(try OathWalletEngine.profile(for: source))
            XCTAssertThrowsError(try OathWalletEngine.privateKey(for: source, account: account))
        }
    }

    func testPrivateKeyExportUsesSavedPathAndRejectsMismatches() throws {
        let source = try secret(fixture)
        let wallet = try XCTUnwrap(HDWallet(mnemonic: fixture, passphrase: ""))
        let alternate = "m/44'/60'/0'/0/1"
        let key = try XCTUnwrap(wallet.getKey(coin: .ethereum, derivationPath: alternate))
        let address = CoinType.ethereum.deriveAddress(privateKey: key)
        let account = OathPrivateKeyAccount(id: "public-fixture", chain: .ethereum, address: address, path: alternate)
        let exported = try OathWalletEngine.privateKey(for: source, account: account)
        let restored = try XCTUnwrap(PrivateKey(data: decodeExport(exported.value, chain: .ethereum)))
        XCTAssertEqual(CoinType.ethereum.deriveAddress(privateKey: restored), address)
        let wrongPath = OathPrivateKeyAccount(id: account.id, chain: account.chain,
                                             address: address, path: account.chain.walletPath)
        XCTAssertThrowsError(try OathWalletEngine.privateKey(for: source, account: wrongPath))
        let anotherWallet = try secret("owner erupt swamp room swift final allow unaware hint identify figure cotton")
        XCTAssertThrowsError(try OathWalletEngine.privateKey(for: anotherWallet, account: account))
        for path in ["", "m", "m/", "m//0", "m/2147483648", "m/-1", "m/0h", "m/1'/bad"] {
            let invalid = OathPrivateKeyAccount(id: account.id, chain: account.chain, address: address, path: path)
            XCTAssertThrowsError(try OathWalletEngine.privateKey(for: source, account: invalid))
        }
    }

    /// Decode the external representation, then derive its public address.
    /// Checks the prefixes, payload lengths and public half of Ed25519 keypairs.
    private func decodeExport(_ value: String, chain: OathImportChain) throws -> Data {
        switch chain {
        case .bitcoin, .bitcoincash, .litecoin, .dogecoin:
            let payload = try XCTUnwrap(Base58.decode(string: value))
            XCTAssertEqual(payload.count, 34)
            XCTAssertEqual(payload.first, chain == .litecoin ? 176 : (chain == .dogecoin ? 158 : 128))
            XCTAssertEqual(payload.last, 1)
            return Data(payload.dropFirst().dropLast())
        case .solana, .near:
            if chain == .near { XCTAssertTrue(value.hasPrefix("ed25519:")) }
            let text = chain == .near ? String(value.dropFirst(8)) : value
            let payload = try XCTUnwrap(Base58.decodeNoCheck(string: text))
            XCTAssertEqual(payload.count, 64)
            let seed = Data(payload.prefix(32))
            let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
            XCTAssertTrue(Data(payload.suffix(32)) == publicKey)
            return seed
        case .stellar:
            XCTAssertTrue(value.hasPrefix("S")); XCTAssertEqual(value.count, 56)
            let payload = try XCTUnwrap(Base32.decode(string: value))
            XCTAssertEqual(payload.count, 35); XCTAssertEqual(payload.first, 144)
            // Independent bit-wise polynomial long division, including the
            // two zero bytes appended by CRC16/XModem before reduction.
            var remainder: UInt32 = 0
            for byte in payload.dropLast(2) + Data([0, 0]) {
                for bit in (0..<8).reversed() {
                    remainder = (remainder << 1) | UInt32((byte >> bit) & 1)
                    if remainder & 0x10000 != 0 { remainder ^= 0x11021 }
                }
            }
            let stored = UInt32(payload[payload.count - 2]) | UInt32(payload[payload.count - 1]) << 8
            XCTAssertEqual(remainder, stored)
            return Data(payload.dropFirst().dropLast(2))
        case .sui:
            XCTAssertTrue(value.hasPrefix("suiprivkey1"))
            let payload = try XCTUnwrap(Bech32.decode(string: value))
            XCTAssertEqual(payload.count, 33); XCTAssertEqual(payload.first, 0)
            return Data(payload.dropFirst())
        case .aptos:
            XCTAssertTrue(value.hasPrefix("ed25519-priv-0x"))
            return try decodeHex(String(value.dropFirst(15)))
        case .xrpl:
            XCTAssertTrue(value.hasPrefix("00")); XCTAssertEqual(value.count, 66)
            return try decodeHex(String(value.dropFirst(2)))
        case .ton, .tron, .thorchain:
            return try decodeHex(value)
        default:
            XCTAssertTrue(chain.isEVM && value.hasPrefix("0x"))
            return try decodeHex(String(value.dropFirst(2)))
        }
    }

    private func decodeHex(_ value: String) throws -> Data {
        XCTAssertEqual(value.count, 64)
        let bytes = Array(value.utf8)
        return Data(try stride(from: 0, to: bytes.count, by: 2).map {
            try XCTUnwrap(UInt8(String(decoding: bytes[$0..<$0 + 2], as: UTF8.self), radix: 16))
        })
    }

    func testEncryptionRejectsWrongPINAndTampering() throws {
        let original = try secret(fixture)
        let (sealed, key) = try OathVaultEnvelope.seal(original, digits: pin)
        let encoded = try JSONEncoder().encode(sealed)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(fixture))
        XCTAssertTrue(try sealed.open(using: sealed.key(for: pin)).mnemonic == fixture)
        XCTAssertThrowsError(try sealed.open(using: sealed.key(for: [0, 0, 0, 0, 0, 0])))
        var bytes = sealed.sealed
        bytes[bytes.count - 1] ^= 1
        let tampered = OathVaultEnvelope(version: sealed.version, id: sealed.id, salt: sealed.salt,
                                        iterations: sealed.iterations, sealed: bytes)
        XCTAssertThrowsError(try tampered.open(using: key))
        let changedID = OathVaultEnvelope(version: 1, id: UUID(), salt: sealed.salt,
                                         iterations: sealed.iterations, sealed: sealed.sealed)
        XCTAssertThrowsError(try changedID.open(using: key))
    }

    func testAtomicCommitPersistenceAndThrottling() async throws {
        let database = try await makeTestDatabase()
        let storage = WalletMemoryStorage()
        let vault = OathWalletVault(storage: storage, database: database)
        let phrase = try XCTUnwrap(OathMnemonicValidator.bundled?.verifiedPhrase(fixture))
        storage.rejectInsert = true
        do { try await vault.create(digits: pin, importing: phrase); XCTFail("Insert should fail") }
        catch { }
        let absent = try await vault.exists()
        XCTAssertFalse(absent)
        storage.rejectInsert = false
        try await vault.create(digits: pin, importing: phrase)
        let original = try await vault.unlockedProfile()
        do { try await vault.create(digits: pin, importing: nil); XCTFail("Cannot replace an existing wallet") }
        catch { XCTAssertEqual(error as? OathPasscodeSaveError, .alreadyConfigured) }
        await vault.lock()
        do { _ = try await vault.recoveryWords(); XCTFail("Locked secret must be inaccessible") }
        catch { XCTAssertEqual(error as? OathWalletError, .locked) }

        let reopened = OathWalletVault(storage: storage, database: database)
        let restored = try await reopened.unlock(digits: pin)
        XCTAssertEqual(original, restored)
        await reopened.lock()
        let now = Date()
        for _ in 0..<5 {
            do { _ = try await reopened.unlock(digits: [0, 0, 0, 0, 0, 0], now: now); XCTFail("Wrong PIN") }
            catch { XCTAssertEqual(error as? OathWalletError, .wrongPasscode) }
        }
        let afterRestart = OathWalletVault(storage: storage, database: database)
        do { _ = try await afterRestart.unlock(digits: pin, now: now); XCTFail("Restart cannot reset throttle") }
        catch { XCTAssertEqual(error as? OathWalletError, .throttled(now.addingTimeInterval(30))) }
        let recovered = try await afterRestart.unlock(digits: pin, now: now.addingTimeInterval(31))
        XCTAssertEqual(recovered, original)
    }

    func testRefreshReadsCommittedSQLStateWithoutUnlockingOrReplacingWallet() async throws {
        let database = try await makeTestDatabase()
        let storage = WalletMemoryStorage()
        let vault = OathWalletVault(storage: storage, database: database)
        let phrase = try XCTUnwrap(OathMnemonicValidator.bundled?.verifiedPhrase(fixture))
        try await vault.create(digits: pin, importing: phrase)
        let original = try await vault.unlockedProfile()
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()

        let writer = OathWalletVault(storage: storage, database: database)
        _ = try await writer.unlock(digits: pin)
        _ = try await writer.markBackedUp()
        try await session.refresh()
        guard case .home(let updated) = session.state else { return XCTFail("Refresh left home") }
        XCTAssertTrue(updated.backedUp)
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.addresses, original.addresses)

        let saved = try XCTUnwrap(storage.read("vault-v1"))
        let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: saved)
        var bytes = envelope.sealed
        bytes[bytes.count - 1] ^= 1
        let corrupted = OathVaultEnvelope(version: envelope.version, id: envelope.id,
                                         salt: envelope.salt, iterations: envelope.iterations, sealed: bytes)
        try storage.update(JSONEncoder().encode(corrupted), account: "vault-v1")
        // Refresh no longer reopens or derives secrets. It reads committed
        // metadata only; a subsequent unlock still authenticates the vault.
        try await session.refresh()
        guard case .home(let preserved) = session.state else { return XCTFail("Refresh destroyed current state") }
        XCTAssertEqual(preserved, updated)

        await session.lock()
        try await session.refresh()
        guard case .locked = session.state else { return XCTFail("Refresh unlocked wallet") }
        do { _ = try await vault.reloadProfile(); XCTFail("Locked vault cannot refresh") }
        catch { XCTAssertEqual(error as? OathWalletError, .locked) }
    }

    func testSlowRefreshDoesNotBlockMainActorOrRepublishUnchangedState() async throws {
        let database = try await makeTestDatabase()
        let storage = WalletMemoryStorage()
        let vault = OathWalletVault(storage: storage, database: database)
        let phrase = try XCTUnwrap(OathMnemonicValidator.bundled?.verifiedPhrase(fixture))
        try await vault.create(digits: pin, importing: phrase)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()
        let vaultRead = expectation(description: "Refresh must not read the encrypted vault")
        vaultRead.isInverted = true
        storage.onRead = { _ in vaultRead.fulfill() }
        let published = expectation(description: "Unchanged profile should not be republished")
        published.isInverted = true
        withObservationTracking { _ = session.state } onChange: { published.fulfill() }
        try await session.refresh()
        await fulfillment(of: [vaultRead, published], timeout: 0.05)
    }
}

extension OathWalletEngineTests {
    func testSolanaBothPathsMatchIndependentVectorsAndKeyExports() throws {
        // BIP39 + SLIP-0010 + Ed25519, independently generated by
        // Tools/GenerateSolanaVectors.py. Compare only public addresses.
        let vectors: [(String?, Int, String, String)] = [
            (nil, 0, "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk", "GjJyeC1r2RgkuoCWMyPYkCWSGSGLcz266EaAkLA27AhL"),
            (nil, 1, "Hh8QwFUA6MtVu1qAoq12ucvFHNwCcVTV7hpWjeY1Hztb", "ANf3TEKFL6jPWjzkndo4CbnNdUNkBk4KHPggJs2nu8Xi"),
            (nil, 7, "9h1cLBiraaUqM1CdJTaVaew1oQtgQUW24FZ8YdnLLgJY", "9P7hqHbmAeafcMDhwKQJLh5QAkpY9a1818TkNn8LBn2R"),
            ("TREZOR", 0, "7zSmbu6gKkb6HB7UDPtHYjwCWuBHU1D4TpNZFm4sndQe", "9md2ZNCYw622wTzgHn71kh9T6mFSoB4USnA4QdvY8oM4"),
            ("TREZOR", 7, "B7ncfVP6ShwN9UEGmLCKDoAi2sSauHFKLFeFB9RguQun", "2xc85pDKLMnHFuuz5JajBF2mDk1dKkeTwu5MgZpyvr7r")
        ]
        for (passphrase, index, phantom, trust) in vectors {
            var source = try secret(fixture)
            source.passphrase = passphrase
            let account = AccountRecord(id: "fixture", walletID: source.id.uuidString, networkID: "solana", address: trust,
                derivationPath: try SolanaDerivation.trustWallet.path(accountIndex: index), accountIndex: index)
            let addresses = try OathWalletEngine.solanaReceiveAddresses(for: source, account: account)
            XCTAssertEqual(addresses.map(\.address), [phantom, trust])
            XCTAssertEqual(addresses.map(\.derivation), [.phantom, .trustWallet])
            for address in addresses {
                let exported = try OathWalletEngine.privateKey(for: source, account: .init(id: address.path, chain: .solana,
                    address: address.address, path: address.path))
                let key = try XCTUnwrap(PrivateKey(data: decodeExport(exported.value, chain: .solana)))
                XCTAssertEqual(CoinType.solana.deriveAddress(privateKey: key), address.address)
            }
        }
        let original = try OathWalletEngine.profile(for: secret(fixture))
        XCTAssertEqual(original.addresses.first { $0.chain == .solana }?.path, "m/44'/501'/0'/0'")
    }

    func testSolanaLegacyReceiveSelectionPersistsAndCloudRestoreKeepsIt() async throws {
        let db = try await makeTestDatabase()
        let source = try secret(fixture)
        let originalPath = "m/44'/501'/0'"
        let legacy = BackupWallet(id: source.id, name: "Public fixture", mnemonic: fixture, language: "english", createdAt: .now,
            accounts: [.init(network: "solana", derivationPath: originalPath, index: 0)])
        let memory = WalletMemoryStorage()
        let vault = OathWalletVault(storage: memory, database: db)
        try await vault.createRestoredWallet(digits: pin, restoration: OathRestoredWallet(backup: legacy))
        let accountID = source.id.uuidString + ":solana:0"
        let initial = try await vault.solanaReceiveState(accountID: accountID)
        XCTAssertEqual(initial.selected.derivation, .phantom)
        let accounts = try await db.accounts(walletID: source.id.uuidString)
        XCTAssertEqual(accounts.first?.derivationPath, originalPath)
        let changed = try await vault.solanaReceiveState(accountID: accountID, selecting: originalPath)
        XCTAssertEqual(changed.selected.derivation, .trustWallet)
        await vault.lock()
        do { _ = try await vault.solanaReceiveState(accountID: accountID); XCTFail("Locked vault exposed a receive operation") } catch { }
        let reopened = OathWalletVault(storage: memory, database: db)
        _ = try await reopened.unlock(digits: pin)
        let persisted = try await reopened.solanaReceiveState(accountID: accountID)
        XCTAssertEqual(persisted.selected, changed.selected)
        let exports = try await reopened.privateKeyAccounts(walletID: source.id.uuidString)
        XCTAssertEqual(exports.count, 2)
        XCTAssertEqual(Set(exports.map(\.address)), Set(initial.addresses.map(\.address)))
        for account in exports {
            let exported = try await reopened.privateKey(walletID: source.id.uuidString, accountID: account.id, digits: pin)
            let key = try XCTUnwrap(PrivateKey(data: decodeExport(exported.value, chain: .solana)))
            XCTAssertEqual(CoinType.solana.deriveAddress(privateKey: key), account.address)
        }
        let encrypted = try await reopened.encryptedCloudBackup(walletID: source.id.uuidString, password: "public-fixture-password")
        let backup = try BackupDocument.open(encrypted, password: "public-fixture-password")
        XCTAssertEqual(backup.accounts.first?.solanaReceivePath, originalPath)
        XCTAssertEqual(backup.accounts.first?.derivationPath, originalPath)
        let newDB = try await makeTestDatabase()
        let restored = OathWalletVault(storage: WalletMemoryStorage(), database: newDB)
        try await restored.createRestoredWallet(digits: pin, restoration: OathRestoredWallet(backup: backup))
        let restoredState = try await restored.solanaReceiveState(accountID: accountID)
        XCTAssertEqual(restoredState, persisted)
        // A pre-selector backup still resolves to the existing wallet, and must
        // not overwrite its saved receive choice or its original account path.
        let existing = try await reopened.restoreWallet(OathRestoredWallet(backup: legacy))
        XCTAssertEqual(existing.id, source.id)
        let stillSelected = try await reopened.solanaReceiveState(accountID: accountID)
        XCTAssertEqual(stillSelected.selected, changed.selected)
    }

    func testSolanaRawKeyHasOneAddressAndNoDerivedPath() async throws {
        let wallet = try XCTUnwrap(HDWallet(mnemonic: fixture, passphrase: ""))
        let key = try XCTUnwrap(wallet.getKey(coin: .solana, derivationPath: "m/44'/501'/0'"))
        let db = try await makeTestDatabase()
        let vault = OathWalletVault(storage: WalletMemoryStorage(), database: db)
        try await vault.create(digits: pin, importing: nil, privateKey: .init(bytes: key.data, networks: [.solana]))
        let profile = try await vault.unlockedProfile()
        let accountID = try XCTUnwrap(profile.addresses.first?.accountID)
        let state = try await vault.solanaReceiveState(accountID: accountID)
        XCTAssertEqual(state.addresses.count, 1)
        XCTAssertEqual(state.selected.path, "imported")
        XCTAssertEqual(state.selected.address, CoinType.solana.deriveAddress(privateKey: key))
        do { _ = try await vault.solanaReceiveState(accountID: accountID, selecting: "m/44'/501'/0'/0'"); XCTFail("Raw key became HD") } catch { }
    }

    func testSolanaRejectsMismatchedIdentityAndBackupPreference() throws {
        let source = try secret(fixture)
        let account = AccountRecord(id: "test", walletID: source.id.uuidString, networkID: "solana",
            address: "GjJyeC1r2RgkuoCWMyPYkCWSGSGLcz266EaAkLA27AhL", derivationPath: "m/44'/501'/0'/0'")
        XCTAssertThrowsError(try OathWalletEngine.solanaReceiveAddresses(for: source, account: account))
        let badBackup = BackupWallet(id: source.id, name: "Fixture", mnemonic: fixture, language: "english", createdAt: .now,
            accounts: [.init(network: "solana", derivationPath: "m/44'/501'/0'", index: 0, solanaReceivePath: "m/44'/501'/7'")])
        XCTAssertThrowsError(try OathRestoredWallet(backup: badBackup))
    }
}

private final class WalletMemoryStorage: OathVaultStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]
    func erase() throws { lock.withLock { records.removeAll() } }
    var rejectInsert = false // Set before/after awaited actor calls only.
    var interruptAfterVaultInsert = false
    var interruptVaultUpdate = false
    var interruptAfterVaultUpdate = false
    var rejectCompletion = false
    var onRead: (@Sendable (String) -> Void)? // Configured before starting the tested actor call.
    func read(_ account: String) throws -> Data? {
        onRead?(account)
        return lock.withLock { records[account] }
    }
    func insert(_ data: Data, account: String) throws {
        try lock.withLock {
            if rejectCompletion && account == "legacy-upgrade-complete-v2" && !data.isEmpty { throw LegacyUpgradeError.interrupted }
            guard !rejectInsert else { throw OathWalletError.unavailable }
            guard records[account] == nil else { throw OathPasscodeSaveError.alreadyConfigured }
            records[account] = data
            if interruptAfterVaultInsert && account == "vault-v1" { throw LegacyUpgradeError.interrupted }
        }
    }
    func update(_ data: Data, account: String) throws {
        try lock.withLock {
            guard records[account] != nil else { throw OathWalletError.unavailable }
            if rejectCompletion && account == "legacy-upgrade-complete-v2" && !data.isEmpty { throw LegacyUpgradeError.interrupted }
            if interruptVaultUpdate && account == "vault-v1" { throw LegacyUpgradeError.interrupted }
            records[account] = data
            if interruptAfterVaultUpdate && account == "vault-v1" { throw LegacyUpgradeError.interrupted }
        }
    }
}

extension OathWalletEngineTests {
    private func legacyFixture(protected: Bool = true, biometric: Bool = false, count: Int = 1) throws
        -> (LegacyWalletSnapshot, LegacyTestSecrets) {
        let hd = try XCTUnwrap(HDWallet(mnemonic: fixture, passphrase: ""))
        let address = try XCTUnwrap(hd.getAddressForCoin(coin: .ethereum))
        let publicKey = try XCTUnwrap(hd.getKeyForCoin(coin: .ethereum)).getPublicKeySecp256k1(compressed: false).description
        let ids = (0..<count).map { _ in UUID().uuidString.lowercased() }
        let wallets: [[String: Any]] = ids.enumerated().map { index, id in
            ["id": id, "name": "Synthetic upgrade \(index)", "kind": "importedRecoveryPhrase",
             "secretKeyReference": "synthetic-key-\(index)", "isSelected": index == count - 1,
             "sortOrder": index, "createdAt": 1_700_000_000.0, "recoveryScheme": "bip39"]
        }
        let accounts: [[String: Any]] = ids.map { id in
            ["id": id + "-ethereum", "walletID": id, "networkID": "eth", "address": address,
             "normalizedAddress": address.lowercased(), "derivationPath": "m/44'/60'/0'/0/0",
             "publicKey": publicKey,
             "accountIndex": 0, "isWatchOnly": false, "isEnabled": true]
        }
        let object: [String: Any] = ["wallets": wallets, "accounts": accounts,
            "security": ["appLockEnabled": protected, "biometricEnabled": biometric,
                "passcodeReference": "synthetic-verifier", "failedAttempts": 0,
                "privacyShieldEnabled": true, "autoLockSeconds": 30, "language": "en", "currency": "USD"],
            "bitcoinAddresses": [], "bitcoinPreferences": [], "bitcoinSelections": [], "recoveryExtensions": []]
        let source = try JSONDecoder().decode(LegacyWalletSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        let salt = Data(repeating: 17, count: 32)
        let record = try OathPasscodeRecord.make(digits: pin, salt: Array(salt), iterations: 210_000)
        let verifier = try JSONSerialization.data(withJSONObject: ["algorithm": "pbkdf2-hmac-sha256",
            "iterations": 210_000, "salt": salt.base64EncodedString(), "verifier": Data(record.verifier).base64EncodedString()])
        var values = Dictionary(uniqueKeysWithValues: ids.indices.map { ("synthetic-key-\($0)", Data(fixture.utf8)) })
        values["synthetic-verifier"] = verifier
        return (source, LegacyTestSecrets(values))
    }

    private func replacementVault(_ storage: WalletMemoryStorage, _ db: OathDatabase) -> OathWalletVault {
        OathWalletVault(storage: storage, biometricStore: OathBiometricCredentialStore(
            service: "oath.synthetic.upgrade." + UUID().uuidString, installation: nil),
            database: db, resetEnvironment: LegacyTestResetEnvironment())
    }

    private func writeLegacySource(_ source: LegacyWalletSnapshot) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wallet.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE wallets(id TEXT, profileID TEXT, name TEXT, kind TEXT, secretKeyReference TEXT,
                    isSelected BOOLEAN, sortOrder INTEGER, createdAt DOUBLE, archivedAt DOUBLE, recoveryScheme TEXT);
                CREATE TABLE walletAccounts(id TEXT, walletID TEXT, networkID TEXT, address TEXT, normalizedAddress TEXT,
                    label TEXT, derivationPath TEXT, accountIndex INTEGER, publicKey TEXT, isWatchOnly BOOLEAN, isEnabled BOOLEAN);
                CREATE TABLE userSettings(profileID TEXT, appLockEnabled BOOLEAN, biometricEnabled BOOLEAN,
                    autoLockSeconds INTEGER, privacyShieldEnabled BOOLEAN, languageIdentifier TEXT, currencyCode TEXT);
                CREATE TABLE profileSecurity(profileID TEXT, passcodeKeychainReference TEXT, failedAttemptCount INTEGER, lockedUntil DOUBLE);
                """)
            let security = source.security
            try db.execute(sql: "INSERT INTO userSettings VALUES ('local-default',?,?,?,?,?,?)", arguments: [
                security.appLockEnabled, security.biometricEnabled, security.autoLockSeconds,
                security.privacyShieldEnabled, security.language, security.currency])
            try db.execute(sql: "INSERT INTO profileSecurity VALUES ('local-default',?,?,?)", arguments: [
                security.passcodeReference, security.failedAttempts, security.lockedUntil])
            for w in source.wallets {
                try db.execute(sql: "INSERT INTO wallets VALUES (?,'local-default',?,?,?,?,?,?,NULL,?)", arguments: [
                    w.id, w.name, w.kind, w.secretKeyReference, w.isSelected, w.sortOrder, w.createdAt, w.recoveryScheme])
            }
            for a in source.accounts {
                try db.execute(sql: "INSERT INTO walletAccounts VALUES (?,?,?,?,?,?,?,?,?,?,?)", arguments: [
                    a.id, a.walletID, a.networkID, a.address, a.normalizedAddress, a.label,
                    a.derivationPath, a.accountIndex, a.publicKey, a.isWatchOnly, a.isEnabled])
            }
        }
        return url
    }

    func testLegacyLaunchTakesPriorityOverExistingTestVaultAndPendingReset() async throws {
        let (source, _) = try legacyFixture()
        let url = try writeLegacySource(source)
        let db = try await makeTestDatabase(), memory = WalletMemoryStorage()
        // Even unreadable test-vault contents must not select the new unlock screen.
        try memory.insert(Data("obsolete test vault".utf8), account: "vault-v1")
        _ = try await db.beginWalletReset()
        let session = OathWalletSession(vault: replacementVault(memory, db), legacySourceURL: url)
        await session.load()
        XCTAssertTrue(session.isUpgrading); XCTAssertFalse(session.isLocked)
        XCTAssertFalse(session.resetting); XCTAssertFalse(session.presentsOnboarding)
        XCTAssertEqual(session.legacyPhase, .passcode)
        let pending = try await db.pendingWalletReset(); XCTAssertNotNil(pending)
        let unchanged = try await LegacyWalletSource.read(at: url)
        XCTAssertEqual(unchanged?.wallets, source.wallets)
    }

    func testLegacyReplacementUsesOldPINAndReplacesDifferentTestWallets() async throws {
        let (source, secrets) = try legacyFixture(count: 3)
        let db = try await makeTestDatabase(), memory = WalletMemoryStorage()
        let vault = replacementVault(memory, db), testPIN: [UInt8] = [1, 1, 1, 1, 1, 1]
        try await vault.create(digits: testPIN, importing: nil)
        let before = try memory.read("vault-v1"), oldRows = try await db.wallets()
        try await db.setSetting("migration.legacyV1", value: String(repeating: "f", count: 64))
        do { _ = try await vault.migrateLegacy(source, digits: testPIN, secrets: secrets, verifySource: false); XCTFail("New test PIN must not authorize old keys") }
        catch { XCTAssertEqual(error as? OathWalletError, .wrongPasscode) }
        XCTAssertEqual(try memory.read("vault-v1"), before)
        XCTAssertFalse(secrets.references.contains { $0.hasPrefix("synthetic-key-") })
        let unchanged = try await db.wallets(); XCTAssertEqual(unchanged, oldRows)
        let active = try await vault.migrateLegacy(source, digits: pin, secrets: secrets, verifySource: false)
        XCTAssertEqual(active.id, source.activeWalletID.flatMap(UUID.init(uuidString:)))
        let rows = try await db.wallets()
        XCTAssertEqual(Set(rows.map(\.id)), Set(source.wallets.map { $0.id.uppercased() }))
        XCTAssertEqual(rows.map(\.name), source.wallets.map(\.name))
        let needed = try await vault.needsLegacyMigration(source); XCTAssertFalse(needed)
        await vault.lock()
        do { _ = try await vault.unlock(digits: testPIN); XCTFail("Old test PIN remains active") }
        catch { XCTAssertEqual(error as? OathWalletError, .wrongPasscode) }
        _ = try await vault.unlock(digits: pin)
    }

    func testLegacyMissingKeyPreservesExistingTestVaultUntilRetry() async throws {
        let (source, complete) = try legacyFixture(count: 2)
        let db = try await makeTestDatabase(), memory = WalletMemoryStorage(), vault: OathWalletVault
        vault = replacementVault(memory, db)
        try await vault.create(digits: pin, importing: nil)
        let before = try memory.read("vault-v1"), rows = try await db.wallets()
        var values = complete.values; values.removeValue(forKey: "synthetic-key-1")
        do { _ = try await vault.migrateLegacy(source, digits: pin, secrets: LegacyTestSecrets(values), verifySource: false); XCTFail("Incomplete migration accepted") }
        catch { XCTAssertEqual(error as? LegacyUpgradeError, .keyUnavailable) }
        XCTAssertEqual(try memory.read("vault-v1"), before)
        let after = try await db.wallets(); XCTAssertEqual(after, rows)
        XCTAssertNil(try memory.read("legacy-upgrade-complete-v2"))
    }

    func testLegacyReplacementIgnoresCorruptTestVaultAndOldUnlockThrottle() async throws {
        let (source, secrets) = try legacyFixture()
        let db = try await makeTestDatabase(), memory = WalletMemoryStorage()
        try memory.insert(Data("obsolete test vault".utf8), account: "vault-v1")
        try memory.insert(JSONEncoder().encode(OathUnlockAttempts(failures: 20, blockedUntil: .distantFuture)), account: "unlock-attempts-v1")
        let vault = replacementVault(memory, db)
        _ = try await vault.migrateLegacy(source, digits: pin, secrets: secrets, verifySource: false)
        await vault.lock()
        _ = try await vault.unlock(digits: pin)
        let needed = try await vault.needsLegacyMigration(source); XCTAssertFalse(needed)
    }

    func testLegacyReplacementDoesNotDecryptObsoleteInstallationWrappedRecord() async throws {
        let (source, secrets) = try legacyFixture()
        let db = try await makeTestDatabase(), raw = WalletMemoryStorage()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let installation = OathInstallationSecurity(keys: OathInstallationKeyFile(directory: directory), credentials: LegacyTestCredentialCleanup())
        let storage = OathInstallationVaultStorage(raw: raw, installation: installation)
        try installation.prepare()
        try raw.insert(Data("unreadable obsolete ciphertext".utf8), account: "vault-v1")
        XCTAssertThrowsError(try storage.read("vault-v1"))
        let vault = OathWalletVault(storage: storage, biometricStore: OathBiometricCredentialStore(
            service: "oath.synthetic.upgrade." + UUID().uuidString, installation: nil),
            database: db, resetEnvironment: LegacyTestResetEnvironment())
        _ = try await vault.migrateLegacy(source, digits: pin, secrets: secrets, verifySource: false)
        await vault.lock()
        _ = try await vault.unlock(digits: pin)
        let needed = try await vault.needsLegacyMigration(source); XCTAssertFalse(needed)
        XCTAssertNotEqual(try raw.read("vault-v1"), try storage.read("vault-v1"))
    }

    func testLegacyCompletedMigrationPreservesLaterEditsAndNewPasscode() async throws {
        let (source, secrets) = try legacyFixture()
        let db = try await makeTestDatabase(), memory = WalletMemoryStorage(), vault: OathWalletVault
        vault = replacementVault(memory, db)
        let active = try await vault.migrateLegacy(source, digits: pin, secrets: secrets, verifySource: false)
        try await db.renameWallet(active.id.uuidString, name: "Edited after migration")
        let authorization = try await vault.authorizeSecurityChange(digits: pin)
        let newPIN: [UInt8] = [3, 3, 3, 3, 3, 3]
        try await vault.setPasscode(newPIN, authorization: authorization)
        let before = try memory.read("vault-v1")
        let restarted = replacementVault(memory, db)
        let pending = try await restarted.needsLegacyMigration(source); XCTAssertFalse(pending)
        let route = OathWalletSession(vault: restarted, legacySourceURL: try writeLegacySource(source))
        await route.load()
        XCTAssertTrue(route.isLocked); XCTAssertFalse(route.isUpgrading)
        _ = try await restarted.migrateLegacy(source, digits: newPIN, secrets: secrets, verifySource: false)
        XCTAssertEqual(try memory.read("vault-v1"), before)
        let rows = try await db.wallets(); XCTAssertEqual(rows.first?.name, "Edited after migration")
    }

    func testLegacyReplacementInterruptionsRequireRetryAndNeverDuplicate() async throws {
        let (source, secrets) = try legacyFixture(count: 2)
        for stage in 0..<3 {
            let db = try await makeTestDatabase(), memory = WalletMemoryStorage()
            let vault = replacementVault(memory, db)
            if stage == 0 {
                try memory.insert(Data("old test vault".utf8), account: "vault-v1")
                memory.interruptAfterVaultUpdate = true
            } else if stage == 1 { memory.interruptVaultUpdate = true }
            else { memory.rejectCompletion = true }
            do { _ = try await vault.migrateLegacy(source, digits: pin, secrets: secrets, verifySource: false); XCTFail("Expected interruption") }
            catch { XCTAssertEqual(error as? LegacyUpgradeError, .interrupted) }
            XCTAssertEqual(try memory.read("legacy-upgrade-complete-v2"), Data())
            let restarted = replacementVault(memory, db)
            let pending = try await restarted.needsLegacyMigration(source); XCTAssertTrue(pending)
            memory.interruptAfterVaultUpdate = false; memory.interruptVaultUpdate = false; memory.rejectCompletion = false
            _ = try await restarted.migrateLegacy(source, digits: pin, secrets: secrets, verifySource: false)
            let rows = try await db.wallets(); XCTAssertEqual(rows.count, 2)
            let completed = try await restarted.needsLegacyMigration(source); XCTAssertFalse(completed)
        }
    }

    func testLegacyChangedSourceReplacesPreviouslyCompletedMigration() async throws {
        let (source, secrets) = try legacyFixture()
        let (changed, changedSecrets) = try legacyFixture(protected: false, count: 2)
        let db = try await makeTestDatabase(), memory = WalletMemoryStorage(), vault: OathWalletVault
        vault = replacementVault(memory, db)
        _ = try await vault.migrateLegacy(source, digits: pin, secrets: secrets, verifySource: false)
        let pending = try await vault.needsLegacyMigration(changed); XCTAssertTrue(pending)
        _ = try await vault.migrateLegacy(changed, digits: nil, secrets: changedSecrets, verifySource: false)
        await vault.lock()
        let active = try await vault.unlockWithoutPasscode()
        XCTAssertEqual(active.id, changed.activeWalletID.flatMap(UUID.init(uuidString:)))
        let rows = try await db.wallets(); XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows.contains { $0.id == source.wallets[0].id.uppercased() })
    }

    func testLegacyIncorrectAuthenticationNeverReadsWalletKeys() async throws {
        let (source, secrets) = try legacyFixture()
        let storage = WalletMemoryStorage(), db = try await makeTestDatabase()
        let vault = OathWalletVault(storage: storage, database: db)
        for _ in 0..<5 {
            do { _ = try await vault.migrateLegacy(source, digits: [1, 1, 1, 1, 1, 1], secrets: secrets, verifySource: false); XCTFail("Incorrect PIN accepted") }
            catch { XCTAssertEqual(error as? OathWalletError, .wrongPasscode) }
        }
        let restarted = OathWalletVault(storage: storage, database: db)
        do { _ = try await restarted.migrateLegacy(source, digits: pin, secrets: secrets, verifySource: false); XCTFail("Throttle lost on restart") }
        catch { guard case .throttled = error as? OathWalletError else { return XCTFail("Expected durable throttle") } }
        XCTAssertFalse(secrets.references.contains { $0.hasPrefix("synthetic-key-") })
        XCTAssertNil(try storage.read("vault-v1"))
        let wallets = try await db.wallets(); XCTAssertTrue(wallets.isEmpty)
    }

    func testLegacyMissingKeyIsAtomicAndRetryable() async throws {
        let (source, complete) = try legacyFixture(count: 2)
        var incomplete = complete.values; incomplete.removeValue(forKey: "synthetic-key-1")
        let storage = WalletMemoryStorage(), db = try await makeTestDatabase()
        let vault = OathWalletVault(storage: storage, database: db)
        do { _ = try await vault.migrateLegacy(source, digits: pin, secrets: LegacyTestSecrets(incomplete), verifySource: false); XCTFail("Missing key accepted") }
        catch { XCTAssertEqual(error as? LegacyUpgradeError, .keyUnavailable) }
        XCTAssertNil(try storage.read("vault-v1"))
        let empty = try await db.wallets(); XCTAssertTrue(empty.isEmpty)
        let result = try await vault.migrateLegacy(source, digits: pin, secrets: complete, verifySource: false)
        XCTAssertEqual(result.id, source.activeWalletID.flatMap(UUID.init(uuidString:)))
        let wallets = try await vault.wallets(); XCTAssertEqual(wallets.count, 2)
    }

    func testLegacyInterruptionAfterEncryptedCommitResumesWithAuthentication() async throws {
        let (source, secrets) = try legacyFixture()
        let storage = WalletMemoryStorage(), db = try await makeTestDatabase()
        storage.interruptAfterVaultInsert = true
        let vault = OathWalletVault(storage: storage, database: db)
        do { _ = try await vault.migrateLegacy(source, digits: pin, secrets: secrets, verifySource: false); XCTFail("Interruption was not injected") }
        catch { XCTAssertEqual(error as? LegacyUpgradeError, .interrupted) }
        XCTAssertNotNil(try storage.read("vault-v1"))
        let empty = try await db.wallets(); XCTAssertTrue(empty.isEmpty)
        storage.interruptAfterVaultInsert = false
        let restarted = OathWalletVault(storage: storage, database: db)
        do { _ = try await restarted.unlock(digits: [1, 1, 1, 1, 1, 1]); XCTFail("Pending migration bypassed authentication") }
        catch { XCTAssertEqual(error as? OathWalletError, .wrongPasscode) }
        let stillEmpty = try await db.wallets(); XCTAssertTrue(stillEmpty.isEmpty)
        let result = try await restarted.unlock(digits: pin)
        XCTAssertEqual(result.id, source.activeWalletID.flatMap(UUID.init(uuidString:)))
        let wallets = try await restarted.wallets(); XCTAssertEqual(wallets.count, 1)
    }

    func testLegacyInterruptionAfterDatabaseCommitDoesNotDuplicateWallets() async throws {
        let (source, secrets) = try legacyFixture(count: 2)
        let storage = WalletMemoryStorage(), db = try await makeTestDatabase()
        storage.interruptVaultUpdate = true
        let vault = OathWalletVault(storage: storage, database: db)
        do { _ = try await vault.migrateLegacy(source, digits: pin, secrets: secrets, verifySource: false); XCTFail("Interruption was not injected") }
        catch { XCTAssertEqual(error as? LegacyUpgradeError, .interrupted) }
        let committed = try await db.wallets(); XCTAssertEqual(committed.count, 2)
        storage.interruptVaultUpdate = false
        let restarted = OathWalletVault(storage: storage, database: db)
        for _ in 0..<3 {
            _ = try await restarted.unlock(digits: pin)
            let wallets = try await restarted.wallets(); XCTAssertEqual(wallets, committed)
            await restarted.lock()
        }
    }

    func testLegacyStaleReceiptUnlockRequiresPasscodeAndFinishesPendingJournal() async throws {
        let (source, secrets) = try legacyFixture(count: 2)
        let storage = WalletMemoryStorage(), db = try await makeTestDatabase()
        storage.interruptVaultUpdate = true
        let first = OathWalletVault(storage: storage, database: db)
        do { _ = try await first.migrateLegacy(source, digits: pin, secrets: secrets, verifySource: false); XCTFail("Expected interrupted journal cleanup") }
        catch { XCTAssertEqual(error as? LegacyUpgradeError, .interrupted) }
        // Reproduce the reported upgrade state: a valid PIN-protected pending
        // journal alongside an older SQL receipt for these same wallets.
        let stale = String(repeating: "f", count: 64)
        try await db.setSetting("migration.legacyV1", value: stale)
        let firstID = try XCTUnwrap(source.wallets.first.flatMap { UUID(uuidString: $0.id)?.uuidString })
        try await db.renameWallet(firstID, name: "Kept existing name")
        try await db.setSetting("activeWalletID", value: firstID)
        let before = try await db.wallets()
        storage.interruptVaultUpdate = false
        let restarted = OathWalletVault(storage: storage, database: db)
        do { _ = try await restarted.unlock(digits: [1, 1, 1, 1, 1, 1]); XCTFail("Receipt recovery bypassed the PIN") }
        catch { XCTAssertEqual(error as? OathWalletError, .wrongPasscode) }
        var settings = try await db.settings(); XCTAssertEqual(settings["migration.legacyV1"], stale)
        // A second interruption after receipt repair must also be restart-safe.
        storage.interruptVaultUpdate = true
        do { _ = try await restarted.unlock(digits: pin); XCTFail("Expected journal cleanup interruption") }
        catch { XCTAssertEqual(error as? LegacyUpgradeError, .interrupted) }
        storage.interruptVaultUpdate = false
        let final = OathWalletVault(storage: storage, database: db)
        for _ in 0..<3 {
            let profile = try await final.unlock(digits: pin)
            XCTAssertEqual(profile.id.uuidString, firstID)
            let wallets = try await final.wallets(); XCTAssertEqual(wallets, before)
            let raw = try XCTUnwrap(storage.read("vault-v1"))
            let sealed = try JSONDecoder().decode(OathVaultEnvelope.self, from: raw)
            let opened = try sealed.openContents(using: sealed.key(for: pin))
            XCTAssertNil(opened.legacyUpgrade)
            XCTAssertEqual(opened.wallets.count, 2)
            XCTAssertTrue(sealed.passcodeEnabled)
            settings = try await db.settings()
            XCTAssertEqual(settings["migration.legacyV1"], try source.fingerprint)
            await final.lock()
        }
    }

    func testLegacyJournalCannotAuthorizeUnrelatedWallets() throws {
        let (source, secrets) = try legacyFixture()
        var (contents, batch) = try OathLegacyUpgrade.prepare(source, secrets: secrets)
        let root = try XCTUnwrap(contents.wallets.first?.id)
        var wallets = batch.wallets
        wallets[0].vaultReference = "another-vault"
        contents.legacyUpgrade = LegacyUpgradeBatch(sourceFingerprint: batch.sourceFingerprint,
            wallets: wallets, accounts: batch.accounts, activeWalletID: batch.activeWalletID, settings: batch.settings)
        XCTAssertThrowsError(try contents.validate(rootID: root)) {
            XCTAssertEqual($0 as? OathWalletError, .corruptVault)
        }
        contents.legacyUpgrade = batch
        XCTAssertNoThrow(try contents.validate(rootID: root))
        contents.wallets.removeAll()
        XCTAssertThrowsError(try contents.validate(rootID: root))
    }

    func testLegacyDisabledPasscodeDoesNotRequireOrReadOldVerifier() async throws {
        let (source, complete) = try legacyFixture(protected: false)
        var values = complete.values; values.removeValue(forKey: "synthetic-verifier")
        let secrets = LegacyTestSecrets(values), storage = WalletMemoryStorage(), db = try await makeTestDatabase()
        let vault = OathWalletVault(storage: storage, database: db)
        let result = try await vault.migrateLegacy(source, digits: nil, secrets: secrets, verifySource: false)
        XCTAssertFalse(secrets.references.contains { $0.contains("verifier") })
        let security = try await vault.securityState(); XCTAssertFalse(security.passcodeEnabled)
        await vault.lock()
        let restarted = OathWalletVault(storage: storage, database: db)
        let reopened = try await restarted.unlockWithoutPasscode()
        XCTAssertEqual(reopened.id, result.id)
        await vault.lock()
    }

    func testLegacyBiometricTransitionSurvivesRestartUntilExplicitChoice() async throws {
        let (source, secrets) = try legacyFixture(biometric: true)
        let storage = WalletMemoryStorage(), db = try await makeTestDatabase()
        let vault = OathWalletVault(storage: storage, database: db)
        _ = try await vault.migrateLegacy(source, digits: pin, secrets: secrets, verifySource: false)
        await vault.lock()
        let restarted = OathWalletVault(storage: storage, database: db)
        _ = try await restarted.unlock(digits: pin)
        let pending = try await restarted.legacyBiometricTransitionRequired(); XCTAssertTrue(pending)
        let session = OathWalletSession(vault: restarted, legacySourceURL: try writeLegacySource(source))
        await session.load()
        await session.unlock(pin)
        XCTAssertTrue(session.isUpgrading)
        XCTAssertEqual(session.legacyPhase, .biometrics)
        XCTAssertFalse(session.isUnlocked)
        try await restarted.finishLegacyBiometricTransition()
        await restarted.lock()
        _ = try await restarted.unlock(digits: pin)
        let cleared = try await restarted.legacyBiometricTransitionRequired(); XCTAssertFalse(cleared)
        let security = try await restarted.securityState(); XCTAssertTrue(security.passcodeEnabled)
        XCTAssertFalse(security.biometricsEnabled)
    }

    func testLegacyVerifierBackupOnlyForMissingOrCorruptPrimary() throws {
        let (_, secrets) = try legacyFixture()
        let credential = try XCTUnwrap(secrets.values["synthetic-verifier"])
        let missing = LegacyTestSecrets(["synthetic-verifier.passcode-verifier-backup": credential])
        XCTAssertTrue(try OathLegacyPasscodeCredential.read(reference: "synthetic-verifier", secrets: missing).matches(pin))
        let corrupt = LegacyTestSecrets(["synthetic-verifier": Data([0]), "synthetic-verifier.passcode-verifier-backup": credential])
        XCTAssertTrue(try OathLegacyPasscodeCredential.read(reference: "synthetic-verifier", secrets: corrupt).matches(pin))
        let valid = LegacyTestSecrets(["synthetic-verifier": credential, "synthetic-verifier.passcode-verifier-backup": credential])
        XCTAssertFalse(try OathLegacyPasscodeCredential.read(reference: "synthetic-verifier", secrets: valid).matches([1,1,1,1,1,1]))
        XCTAssertEqual(valid.references, ["synthetic-verifier"])
    }

    func testLegacyUsesCurrentImportRulesInsteadOfOldAddressTypes() throws {
        let (source, secrets) = try legacyFixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        var accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        accounts[0]["networkID"] = "solana"
        accounts[0]["derivationPath"] = "m/44'/501'/7'/0'"
        accounts[0]["accountIndex"] = 7
        let hd = try XCTUnwrap(HDWallet(mnemonic: fixture, passphrase: ""))
        let key = try XCTUnwrap(hd.getKey(coin: .solana, derivationPath: "m/44'/501'/7'/0'"))
        accounts[0]["publicKey"] = key.getPublicKeyEd25519().data.base64EncodedString()
        accounts[0]["address"] = CoinType.solana.deriveAddress(privateKey: key)
        object["accounts"] = accounts
        let legacy = try JSONDecoder().decode(LegacyWalletSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        let (contents, batch) = try OathLegacyUpgrade.prepare(legacy, secrets: secrets)
        let expected = try OathWalletEngine.profile(for: OathWalletEngine.imported(XCTUnwrap(OathMnemonicValidator.bundled?.verifiedPhrase(fixture))))
        XCTAssertEqual(batch.accounts.count, expected.addresses.count)
        for address in expected.addresses {
            let actual = try XCTUnwrap(batch.accounts.first { $0.networkID == address.chain.id })
            XCTAssertEqual(actual.address, address.address)
            XCTAssertEqual(actual.derivationPath, address.path)
            XCTAssertEqual(actual.accountIndex, 0)
        }
        XCTAssertNil(contents.wallets[0].restoration)
    }

    func testLegacyExtendedPrivateKeyUsesExistingImporterWithoutLosingChainCode() throws {
        let (source, _) = try legacyFixture(protected: false)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        var wallets = try XCTUnwrap(object["wallets"] as? [[String: Any]])
        wallets[0]["kind"] = "importedPrivateKey"; object["wallets"] = wallets
        var accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        accounts[0]["networkID"] = "bitcoin"
        let bytes = Data(repeating: 1, count: 32), chainCode = Data(repeating: 2, count: 32)
        accounts[0]["publicKey"] = try XCTUnwrap(PrivateKey(data: bytes)).getPublicKeySecp256k1(compressed: true).description
        accounts[0]["derivationPath"] = "bitcoin-imported-collection:v1"; object["accounts"] = accounts
        let legacy = try JSONDecoder().decode(LegacyWalletSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        let node: [String: Any] = ["privateKey": bytes.base64EncodedString(), "chainCode": chainCode.base64EncodedString(),
            "depth": 0, "parentFingerprint": Data(repeating: 0, count: 4).base64EncodedString(), "childNumber": 0]
        let descriptor: [String: Any] = ["key": bytes.base64EncodedString(), "node": node, "compressed": true]
        let data = try JSONSerialization.data(withJSONObject: ["sources": [["descriptor": descriptor], ["descriptor": descriptor]]])
        let (contents, _) = try OathLegacyUpgrade.prepare(legacy, secrets: LegacyTestSecrets(["synthetic-key-0": data]))
        let material = try XCTUnwrap(contents.wallets[0].privateKey)
        let encoded = try XCTUnwrap(material.bitcoinExtendedKey)
        let payload = try XCTUnwrap(Base58.decode(string: encoded))
        XCTAssertEqual(Data(payload[13..<45]), chainCode)
        XCTAssertEqual(Data(payload.suffix(32)), bytes)
        let normal = try OathWalletEngine.importedPrivateKey(encoded, choice: XCTUnwrap(OathPrivateKeyChoice.all.first { $0.networks == [.bitcoin] }))
        XCTAssertTrue(normal.hasSameIdentity(as: material))
        // A public identity mismatch must reject even a structurally valid node.
        var wrongAccounts = accounts
        wrongAccounts[0]["publicKey"] = String(repeating: "0", count: 66)
        object["accounts"] = wrongAccounts
        let wrong = try JSONDecoder().decode(LegacyWalletSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try OathLegacyUpgrade.prepare(wrong, secrets: LegacyTestSecrets(["synthetic-key-0": data]))) {
            XCTAssertEqual($0 as? LegacyUpgradeError, .addressMismatch)
        }
        var different = descriptor; different["key"] = Data(repeating: 3, count: 32).base64EncodedString()
        let mixed = try JSONSerialization.data(withJSONObject: ["sources": [["descriptor": descriptor], ["descriptor": different]]])
        XCTAssertThrowsError(try OathLegacyUpgrade.prepare(legacy, secrets: LegacyTestSecrets(["synthetic-key-0": mixed]))) {
            XCTAssertEqual($0 as? LegacyUpgradeError, .unsupportedWallet)
        }
    }

    func testLegacyMismatchedRecoveryMaterialCannotCommitAnyWallet() async throws {
        let (source, original) = try legacyFixture(protected: false, count: 2)
        var values = original.values
        let other = try OathWalletEngine.create()
        values["synthetic-key-1"] = Data(other.mnemonic.utf8)
        let storage = WalletMemoryStorage(), db = try await makeTestDatabase()
        let vault = OathWalletVault(storage: storage, database: db)
        do {
            _ = try await vault.migrateLegacy(source, digits: nil, secrets: LegacyTestSecrets(values), verifySource: false)
            XCTFail("Unrelated recovery material accepted")
        } catch { XCTAssertEqual(error as? LegacyUpgradeError, .addressMismatch) }
        XCTAssertNil(try storage.read("vault-v1"))
        let wallets = try await db.wallets()
        XCTAssertTrue(wallets.isEmpty)
        _ = try await vault.migrateLegacy(source, digits: nil, secrets: original, verifySource: false)
        let retried = try await db.wallets()
        XCTAssertEqual(retried.count, 2)
    }

    func testLegacyUnsupportedWalletKeepsEntireUpgradeUncommitted() async throws {
        let (source, original) = try legacyFixture(protected: false, count: 2)
        for kind in ["watchOnly", "hardware", "importedPrivateKey"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
            var wallets = try XCTUnwrap(object["wallets"] as? [[String: Any]])
            wallets[1]["kind"] = kind; object["wallets"] = wallets
            let unsupported = try JSONDecoder().decode(LegacyWalletSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            let storage = WalletMemoryStorage(), db = try await makeTestDatabase()
            let vault = OathWalletVault(storage: storage, database: db)
            do {
                _ = try await vault.migrateLegacy(unsupported, digits: nil, secrets: original, verifySource: false)
                XCTFail("Unsupported wallet accepted")
            } catch { XCTAssertEqual(error as? LegacyUpgradeError, .unsupportedWallet) }
            XCTAssertNil(try storage.read("vault-v1"))
            let stored = try await db.wallets()
            XCTAssertTrue(stored.isEmpty)
        }
    }

    func testLegacyCleanInstallShowsOnboardingAndCorruptSourceDoesNot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("wallet.sqlite")
        let storage = WalletMemoryStorage(), db = try await makeTestDatabase()
        let clean = OathWalletSession(vault: OathWalletVault(storage: storage, database: db), legacySourceURL: source)
        await clean.load(); XCTAssertTrue(clean.presentsOnboarding)
        try Data("corrupt synthetic database".utf8).write(to: source)
        let damaged = OathWalletSession(vault: OathWalletVault(storage: storage, database: db), legacySourceURL: source)
        await damaged.load(); XCTAssertFalse(damaged.presentsOnboarding)
        guard case .unavailable = damaged.state else { return XCTFail("Unreadable legacy data must fail closed") }
    }

    /// Run only after installing the old fixture app and updating in place.
    /// Uses the real app container and default Keychain namespace, never a phone.
    func testLegacyInPlaceUpgradeIntegration() async throws {
        guard ProcessInfo.processInfo.environment["OATH_VERIFY_UPGRADE_FIXTURE"] == "1" else {
            throw XCTSkip("Requires the explicitly prepared legacy simulator fixture")
        }
        #if targetEnvironment(simulator)
        let readSource = try await LegacyWalletSource.read(at: OathLegacyUpgrade.sourceURL)
        let source = try XCTUnwrap(readSource)
        XCTAssertEqual(source.wallets.count, 13)
        let vault = OathWalletVault()
        if ProcessInfo.processInfo.environment["OATH_RESET_MIGRATION_FIXTURE"] == "1" {
            // Repeat the upgrade matrix using ONLY this explicitly created
            // simulator fixture. Never erase the old database or its Keychain.
            let data = try Data(contentsOf: URL.documentsDirectory.appendingPathComponent("legacy-upgrade-public.json"))
            let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let original = try XCTUnwrap(manifest["wallets"] as? [[String: Any]])
            let ids = Set(original.compactMap { $0["id"] as? String }.map { $0.uppercased() })
            guard ids.count == 13, ids == Set(source.wallets.map { $0.id.uppercased() }) else { return XCTFail("Not the synthetic upgrade fixture") }
            let db = try await vault.database()
            let existing = try await db.wallets(includingDeleted: true)
            guard existing.allSatisfy({ ids.contains($0.id) }) else { return XCTFail("Refusing to reset unrelated wallets") }
            for wallet in existing { try await db.deleteWalletMetadata(wallet.id) }
            try await db.setSetting("migration.legacyV1", value: nil)
            try await db.setSetting("activeWalletID", value: nil)
            try OathVaultKeychain().erase()
            if ProcessInfo.processInfo.environment["OATH_SEED_CONFLICTING_NEW_VAULT"] == "1" {
                // Same-container regression: legacy fixture remains intact while
                // unrelated new-app wallets and a different PIN also exist.
                try await vault.create(digits: [1, 1, 1, 1, 1, 1], importing: nil)
                await vault.lock()
                let mustMigrate = try await vault.needsLegacyMigration(source)
                XCTAssertTrue(mustMigrate)
            }
        }
        let exists = try await vault.exists()
        if !exists, source.security.appLockEnabled {
            let route = OathWalletSession(vault: vault)
            await route.load()
            XCTAssertTrue(route.isUpgrading)
            XCTAssertFalse(route.presentsOnboarding)
            do {
                _ = try await vault.migrateLegacy(source, digits: [1, 1, 1, 1, 1, 1])
                XCTFail("Wrong authentication must not migrate")
            } catch { XCTAssertEqual(error as? OathWalletError, .wrongPasscode) }
            let unchanged = try await vault.exists()
            XCTAssertFalse(unchanged)
        }
        let profile = try await vault.migrateLegacy(source, digits: source.security.appLockEnabled ? pin : nil)
        // Per the approved migration policy, compare with the CURRENT import
        // rules. Legacy-only paths/types must not be introduced into the app.
        let (_, expected) = try OathLegacyUpgrade.prepare(source, secrets: OathLegacyKeychain())
        XCTAssertEqual(profile.id, source.activeWalletID.flatMap(UUID.init(uuidString:)))
        let db = try await vault.database()
        let wallets = try await vault.wallets()
        XCTAssertEqual(wallets.count, 13)
        let security = try await vault.securityState()
        XCTAssertEqual(security.passcodeEnabled, source.security.appLockEnabled)
        XCTAssertFalse(security.biometricsEnabled)
        var signedCount = 0, unchangedAddressCount = 0
        let challenge = Data(SHA256.hash(data: Data("Oath legacy upgrade synthetic signing check".utf8)))
        for old in source.wallets {
            let id = try XCTUnwrap(UUID(uuidString: old.id)).uuidString
            let migrated = try XCTUnwrap(wallets.first { $0.id == id })
            XCTAssertEqual(migrated.name, old.name)
            XCTAssertEqual(migrated.kind, old.kind == "created" ? "hd" : old.kind == "importedPrivateKey" ? "privateKey" : "imported")
            let accounts = try await db.accounts(walletID: id)
            let originals = expected.accounts.filter { $0.walletID == id }
            // Current rules may add chains and replace retired address types.
            for original in originals {
                let account = try XCTUnwrap(accounts.first { $0.id == original.id })
                XCTAssertEqual(account.address, original.address)
                XCTAssertEqual(account.accountIndex, original.accountIndex)
                XCTAssertEqual(account.derivationPath, original.derivationPath)
                let chain = try OathLegacyUpgrade.chain(original.networkID)
                XCTAssertEqual(account.networkID, chain.id)
                if let previous = source.accounts.first(where: {
                    $0.walletID == old.id && (try? OathLegacyUpgrade.chain($0.networkID)) == chain
                        && $0.derivationPath == account.derivationPath && $0.accountIndex == account.accountIndex
                }) {
                    XCTAssertEqual(chain.isEVM ? account.address.lowercased() : account.address,
                                   chain.isEVM ? previous.address.lowercased() : previous.address)
                    unchangedAddressCount += 1
                }
                let export: OathPrivateKeyExport
                if security.passcodeEnabled { export = try await vault.privateKey(walletID: id, accountID: account.id, digits: pin) }
                else { export = try await vault.privateKeyWithBiometrics(walletID: id, accountID: account.id, reason: "Synthetic upgrade verification") }
                var bytes: Data
                if [.bitcoin, .litecoin, .dogecoin, .bitcoincash].contains(chain) {
                    let decoded = try XCTUnwrap(Base58.decode(string: export.value))
                    bytes = Data(decoded.dropFirst().prefix(32))
                } else { bytes = try decodeExport(export.value, chain: chain) }
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                let key = try XCTUnwrap(PrivateKey(data: bytes))
                let signature = try XCTUnwrap(key.sign(digest: challenge, curve: chain.walletCoin.curve))
                XCTAssertTrue(key.getPublicKey(coinType: chain.walletCoin).verify(signature: signature, message: challenge))
                signedCount += 1
            }
        }
        XCTAssertEqual(signedCount, expected.accounts.count)
        XCTAssertGreaterThan(unchangedAddressCount, 100, "Compare with the old app's independently generated public addresses")
        let backupData = try await vault.encryptedCloudBackup(walletID: profile.id.uuidString, password: "synthetic-upgrade-backup")
        let backup = try BackupDocument.open(backupData, password: "synthetic-upgrade-backup")
        XCTAssertEqual(backup.passphrase?.count, 300)
        XCTAssertEqual(backup.legacyPassphrase, true)
        let restored = try OathRestoredWallet(backup: backup)
        for account in expected.accounts where account.walletID == profile.id.uuidString {
            let address = try XCTUnwrap(restored.profile.addresses.first { $0.chain.id == account.networkID && $0.accountIndex == account.accountIndex })
            XCTAssertEqual(address.address, account.address, "Restoring the migrated backup must retain the same keys")
        }
        for _ in 0..<3 {
            await vault.lock()
            let reopened: OathWalletProfile
            if security.passcodeEnabled { reopened = try await vault.unlock(digits: pin) }
            else { reopened = try await vault.unlockWithoutPasscode() }
            XCTAssertEqual(reopened.id, profile.id)
            let count = try await vault.wallets().count
            XCTAssertEqual(count, 13)
        }
        // Retained original data remains readable and unchanged after success.
        let rereadSource = try await LegacyWalletSource.read(at: OathLegacyUpgrade.sourceURL)
        let original = try XCTUnwrap(rereadSource)
        XCTAssertEqual(try source.fingerprint, try original.fingerprint)
        var report: [String: Any] = ["wallets": wallets.count, "signedAccounts": signedCount, "unchangedAddressesChecked": unchangedAddressCount,
                                    "activePreserved": true, "namesPreserved": true, "passcodeEnabled": security.passcodeEnabled,
                                    "usesCurrentImportRules": true]
        if ProcessInfo.processInfo.environment["OATH_VERIFY_UPGRADE_HOME"] == "1" {
            let session = OathWalletSession(vault: vault)
            await session.load()
            if security.passcodeEnabled { await session.unlock(pin) }
            XCTAssertTrue(session.isUnlocked)
            XCTAssertFalse(session.presentsOnboarding)
            XCTAssertEqual(session.displayedProfile?.id, profile.id)
            // A positive provider observation proves a new fetch, rather than
            // mistaking an empty list for successful history synchronization.
            var balances = false, history = false
            for _ in 0..<60 {
                let snapshot = try await db.snapshot(walletID: profile.id.uuidString, currency: "USD")
                balances = snapshot.holdings.contains { ($0.balanceObservedAt ?? 0) > Date().addingTimeInterval(-180).timeIntervalSince1970 }
                history = snapshot.accountSync.contains { $0.stream == "transactions" && $0.complete && $0.lastSuccess != nil }
                if balances && history { break }
                try await Task.sleep(for: .seconds(1))
            }
            XCTAssertTrue(balances, "No fresh balance observation after opening Home")
            XCTAssertTrue(history, "No completed history fetch after opening Home")
            report["homeOpened"] = session.isUnlocked
            report["freshBalances"] = balances; report["historyFetched"] = history
        }
        try JSONSerialization.data(withJSONObject: report).write(to: URL.documentsDirectory.appendingPathComponent("legacy-upgrade-verification.json"), options: .atomic)
        #else
        XCTFail("Never run upgrade fixture tests on a physical device")
        #endif
    }
}

private final class LegacyTestSecrets: OathLegacySecretReading, @unchecked Sendable {
    let values: [String: Data]
    private let lock = NSLock()
    private var reads: [String] = []
    var references: [String] { lock.withLock { reads } }
    init(_ values: [String: Data]) { self.values = values }
    func read(reference: String) throws -> Data {
        lock.withLock { reads.append(reference) }
        guard let value = values[reference] else { throw LegacyUpgradeError.keyUnavailable }
        return value
    }
}

private struct LegacyTestResetEnvironment: OathResetEnvironment {
    func suspend() async { }
    func reopen() async { }
    func eraseLocalFiles() async throws { throw LegacyUpgradeError.interrupted }
}

private struct LegacyTestCredentialCleanup: OathInstallationCredentialClearing {
    func clear() throws { }
}

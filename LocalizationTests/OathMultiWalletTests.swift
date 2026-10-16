import XCTest
import OathDatabase
@testable import OathAtmosphere

/// Uses the real WalletCore adapter and public BIP-39 fixtures. These tests are
/// compiled by the generic-iOS build; execution requires an authorized runtime.
@MainActor final class OathMultiWalletTests: XCTestCase {
    private let pin: [UInt8] = [2, 9, 4, 8, 1, 6]

    func testAddImportAndSwitchPreserveAllRecoveryMaterialAndAddresses() async throws {
        let (session, _) = try await fixture()
        let original = try XCTUnwrap(session.displayedProfile)
        let originalWords = try await session.vault.recoveryWords()
        let generatedID = UUID()
        try await session.addWallet(requestID: generatedID)
        let generated = try XCTUnwrap(session.displayedProfile)
        XCTAssertEqual(generated.id, generatedID)
        XCTAssertEqual(generated.addresses.count, 30)
        XCTAssertFalse(generated.backedUp)
        for chain in OathImportChain.allCases {
            XCTAssertNotEqual(original.addresses.first { $0.chain == chain }?.address,
                              generated.addresses.first { $0.chain == chain }?.address)
        }
        let generatedWords = try await session.vault.recoveryWords()
        let phrase = try XCTUnwrap(OathMnemonicValidator.bundled?.verifiedPhrase(
            "legal winner thank year wave sausage worth useful legal winner thank yellow"))
        let importedID = UUID()
        try await session.addWallet(requestID: importedID, importing: phrase)
        XCTAssertEqual(session.displayedProfile?.id, importedID)
        XCTAssertEqual(session.wallets.count, 3)
        let importedWords = try await session.vault.recoveryWords()
        XCTAssertTrue(importedWords == OathMnemonicValidator.words(in: phrase.phrase))
        try await session.addWallet(requestID: UUID(), importing: phrase)
        XCTAssertEqual(session.displayedProfile?.id, importedID)
        XCTAssertEqual(session.wallets.count, 3, "Importing an existing phrase must select its wallet")
        try await session.selectWallet(original.id)
        let reopenedOriginalWords = try await session.vault.recoveryWords()
        XCTAssertTrue(reopenedOriginalWords == originalWords)
        XCTAssertEqual(session.displayedProfile, original)
        try await session.selectWallet(generatedID)
        let reopenedGeneratedWords = try await session.vault.recoveryWords()
        XCTAssertTrue(reopenedGeneratedWords == generatedWords)
        XCTAssertEqual(session.displayedProfile, generated)
        await session.lock()
    }

    func testOriginalFaceIDCredentialOpensSelectedAdditionalWalletAfterColdLaunch() async throws {
        let (session, storage) = try await fixture()
        let credential = try await session.vault.biometricCredential()
        let addedID = UUID()
        try await session.addWallet(requestID: addedID)
        let selected = try XCTUnwrap(session.displayedProfile)
        let database = try await session.vault.database()
        await session.lock()
        let restartedVault = OathWalletVault(storage: storage,
            biometricStore: MultiWalletBiometrics(credential: credential), database: database)
        let restarted = OathWalletSession(vault: restartedVault)
        await restarted.load()
        XCTAssertTrue(restarted.isLocked)
        XCTAssertEqual(restarted.displayedProfile, selected)
        await restarted.unlockWithBiometrics(automatically: true)
        XCTAssertTrue(restarted.isUnlocked)
        XCTAssertEqual(restarted.displayedProfile, selected)
        XCTAssertEqual(restarted.portfolio?.wallet.id, addedID.uuidString)
        await restarted.lock()
        await restarted.unlock(pin)
        XCTAssertTrue(restarted.isUnlocked)
        XCTAssertEqual(restarted.displayedProfile, selected)
        await restarted.lock()
    }

    func testInterruptedMetadataCommitRecoversOriginalGeneratedWalletOnUnlock() async throws {
        let (session, _) = try await fixture()
        let addedID = UUID()
        try await session.addWallet(requestID: addedID)
        let original = try XCTUnwrap(session.displayedProfile)
        let words = try await session.vault.recoveryWords()
        let database = try await session.vault.database()
        await session.lock()
        try await database.deleteWalletMetadata(addedID.uuidString)
        await session.unlock(pin)
        XCTAssertTrue(session.isUnlocked)
        XCTAssertEqual(session.wallets.count, 2, "Every protected member must recover its public metadata")
        try await session.addWallet(requestID: addedID)
        XCTAssertEqual(session.wallets.count, 2)
        XCTAssertEqual(session.displayedProfile, original)
        let repairedWords = try await session.vault.recoveryWords()
        XCTAssertTrue(repairedWords == words, "Repair must never generate a replacement recovery phrase")
        await session.lock()
    }

    private func fixture() async throws -> (OathWalletSession, MultiWalletMemory) {
        let storage = MultiWalletMemory()
        let database = try await makeTestDatabase()
        let vault = OathWalletVault(storage: storage, biometricStore: MultiWalletBiometrics(credential: nil),
                                   database: database)
        let phrase = try XCTUnwrap(OathMnemonicValidator.bundled?.verifiedPhrase(
            String(repeating: "abandon ", count: 11) + "about"))
        try await vault.create(digits: pin, importing: phrase)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()
        return (session, storage)
    }
}

private actor MultiWalletBiometrics: OathBiometricCredentialStoring {
    var credential: Data?
    func hasEnrollment() -> Bool { credential != nil }
    func disable() { credential = nil }
    init(credential: Data?) { self.credential = credential }
    func read(reason: String) throws -> Data {
        guard let credential else { throw OathBiometricCredentialError.missing }
        return credential
    }
    func enableIfAvailable(strings: OathLocalizer,
                           credentialProvider: (@Sendable () async throws -> Data)?) async -> OathBiometricSetupResult { .unavailable }
}

private final class MultiWalletMemory: OathVaultStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]
    func erase() throws { lock.withLock { records.removeAll() } }
    func read(_ account: String) throws -> Data? { lock.withLock { records[account] } }
    func insert(_ data: Data, account: String) throws {
        try lock.withLock {
            guard records[account] == nil else { throw OathPasscodeSaveError.alreadyConfigured }
            records[account] = data
        }
    }
    func update(_ data: Data, account: String) throws {
        try lock.withLock {
            guard records[account] != nil else { throw OathWalletError.unavailable }
            records[account] = data
        }
    }
}

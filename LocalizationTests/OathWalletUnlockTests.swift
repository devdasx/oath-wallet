import XCTest
import OathDatabase
import Security
@testable import OathAtmosphere

@MainActor
final class OathWalletUnlockTests: XCTestCase {
    private let pin: [UInt8] = [2, 9, 4, 8, 1, 6]

    func testRelockRetainsOnlyDisplayStateAndRejectsActionsUntilAuthenticated() async throws {
        let (vault, _, profile) = try await fixture()
        let session = OathWalletSession(vault: vault)
        await session.load()
        XCTAssertTrue(session.isLocked)
        XCTAssertEqual(session.displayedProfile, profile, "Cold launch prepares Home only as a locked backdrop")
        XCTAssertNotNil(session.portfolio)
        do { _ = try await vault.unlockedProfile(); XCTFail("Display metadata must not unlock the vault") }
        catch { XCTAssertEqual(error as? OathWalletError, .locked) }
        await session.unlock(pin)
        let displayed = try XCTUnwrap(session.displayedProfile)
        let snapshot = try XCTUnwrap(session.portfolio)
        await session.lock()
        XCTAssertTrue(session.isLocked)
        XCTAssertEqual(session.displayedProfile, displayed)
        XCTAssertEqual(session.portfolio, snapshot, "The blurred background must not reset balances on lock")
        do { _ = try await vault.recoveryWords(); XCTFail("The display snapshot is not an unlocked vault") }
        catch { XCTAssertEqual(error as? OathWalletError, .locked) }
        do { try await session.toggleBalancesHidden(); XCTFail("Locked views cannot change settings") }
        catch { XCTAssertEqual(error as? OathWalletError, .locked) }
        try await session.refresh()
        XCTAssertEqual(session.portfolio, snapshot)
        await session.unlock([0, 0, 0, 0, 0, 0])
        XCTAssertTrue(session.isLocked)
        XCTAssertEqual(session.displayedProfile, displayed)
        await session.unlock(pin)
        XCTAssertFalse(session.isLocked)
        XCTAssertEqual(session.displayedProfile, profile)
        XCTAssertEqual(session.portfolio, snapshot)
    }

    func testColdLaunchBackdropUsesMatchingVaultNotAnotherWalletSelection() async throws {
        let (vault, _, profile) = try await fixture()
        let database = try await vault.database()
        let otherID = UUID().uuidString
        try await database.importWalletIfNeeded(
            WalletRecord(id: otherID, name: "Other public fixture", kind: "watchOnly",
                         vaultReference: "other", createdAt: 1), accounts: [])
        try await database.setSetting("activeWalletID", value: otherID)
        let session = OathWalletSession(vault: vault)
        await session.load()
        XCTAssertTrue(session.isLocked)
        XCTAssertEqual(session.displayedProfile?.id, profile.id)
        XCTAssertEqual(session.portfolio?.wallet.id, profile.id.uuidString)
        do { _ = try await vault.recoveryWords(); XCTFail("A backdrop must not expose recovery material") }
        catch { XCTAssertEqual(error as? OathWalletError, .locked) }
        do { _ = try await vault.biometricCredential(); XCTFail("A backdrop must not expose the wallet key") }
        catch { XCTAssertEqual(error as? OathWalletError, .locked) }
    }

    func testMissingColdLaunchMetadataDoesNotPreventAuthenticatedMigration() async throws {
        let (vault, _, profile) = try await fixture()
        let database = try await vault.database()
        try await database.deleteWalletMetadata(profile.id.uuidString)
        let session = OathWalletSession(vault: vault)
        await session.load()
        XCTAssertTrue(session.isLocked)
        XCTAssertNil(session.displayedProfile)
        XCTAssertNil(session.portfolio)
        do { _ = try await vault.unlockedProfile(); XCTFail("Missing display metadata cannot bypass authentication") }
        catch { XCTAssertEqual(error as? OathWalletError, .locked) }
        await session.unlock(pin)
        XCTAssertFalse(session.isLocked)
        XCTAssertEqual(session.displayedProfile, profile)
        XCTAssertNotNil(session.portfolio)
    }

    func testFreshInstallStillShowsOnboardingWithoutHomeMetadata() async throws {
        let database = try await makeTestDatabase()
        let vault = OathWalletVault(storage: UnlockTestStorage(), biometricStore: UnlockTestBiometrics(),
                                   database: database)
        let session = OathWalletSession(vault: vault)
        await session.load()
        guard case .onboarding = session.state else { return XCTFail("An empty install must start onboarding") }
        XCTAssertNil(session.displayedProfile)
        XCTAssertNil(session.portfolio)
    }

    func testAutomaticAttemptWithoutEnrollmentLeavesPasscodeAvailable() async throws {
        let (vault, biometrics, profile) = try await fixture()
        await biometrics.setCredential(nil)
        let session = OathWalletSession(vault: vault)
        await session.load()
        await session.unlockWithBiometrics(automatically: true)
        guard case .locked = session.state else { return XCTFail("Missing credential unlocked wallet") }
        XCTAssertNil(session.notice)
        XCTAssertFalse(session.busy)
        XCTAssertFalse(session.biometricRepairNeeded)
        await session.unlockWithBiometrics()
        XCTAssertFalse(session.security.biometricsEnabled)
        XCTAssertNil(session.notice, "No enrollment keeps Face ID off; enabling it belongs in Security")
        XCTAssertFalse(session.biometricRepairNeeded)
        await session.unlock(pin)
        guard case .home(let opened) = session.state else { return XCTFail("PIN fallback did not open home") }
        XCTAssertEqual(opened, profile)
        let enrollments = await biometrics.enrollments
        XCTAssertEqual(enrollments, 0, "Automatic access must not enroll a passcode-only wallet")
    }

    func testStaleBiometricKeyRequiresCorrectPasscodeThenRepairs() async throws {
        // A missing item now means Face ID is off. An existing invalid item
        // still needs the verified-PIN repair path used by older installations.
        for invalid in [Data("old-enrollment-token".utf8)] {
            let (vault, biometrics, profile) = try await fixture()
            await biometrics.setCredential(invalid)
            let session = OathWalletSession(vault: vault)
            await session.load()
            await session.unlockWithBiometrics()
            guard case .locked = session.state else { return XCTFail("Invalid key unlocked wallet") }
            XCTAssertFalse(session.busy)
            XCTAssertTrue(session.biometricRepairNeeded)
            XCTAssertNil(session.notice, "Biometric failure leaves the app passcode available without an alert")
            await session.unlock([0, 0, 0, 0, 0, 0])
            XCTAssertEqual(session.notice, .unlockIncorrect)
            let before = await biometrics.enrollments
            XCTAssertEqual(before, 0, "Wrong PIN cannot replace the biometric key")
            await session.unlock(pin)
            guard case .home(let opened) = session.state else { return XCTFail("Correct PIN did not open home") }
            XCTAssertEqual(opened, profile)
            XCTAssertFalse(session.biometricRepairNeeded)
            XCTAssertFalse(session.busy)
            let after = await biometrics.enrollments
            XCTAssertEqual(after, 1)
            await session.lock()
            await session.unlockWithBiometrics()
            guard case .home(let restored) = session.state else { return XCTFail("Repaired biometrics did not open home") }
            XCTAssertEqual(restored, profile)
        }
    }

    func testWalletBoundKeyCannotOpenAnotherWallet() async throws {
        let (first, _, _) = try await fixture()
        _ = try await first.unlock(digits: pin)
        let otherCredential = try await first.biometricCredential()
        let (vault, biometrics, _) = try await fixture()
        await biometrics.setCredential(otherCredential)
        let session = OathWalletSession(vault: vault)
        await session.load()
        await session.unlockWithBiometrics()
        guard case .locked = session.state else { return XCTFail("Another wallet's key unlocked this wallet") }
        XCTAssertNil(session.notice, "Biometric failure leaves the app passcode available without an alert")
        do { _ = try await vault.unlockedProfile(); XCTFail("Vault retained an unauthenticated profile") }
        catch { XCTAssertEqual(error as? OathWalletError, .locked) }
    }

    func testLateBiometricCompletionCannotReopenOrEraseANewerSession() async throws {
        let (vault, biometrics, profile) = try await fixture()
        let session = OathWalletSession(vault: vault)
        await session.load()
        await biometrics.holdNextRead()
        let oldAttempt = Task { await session.unlockWithBiometrics() }
        await biometrics.waitForRead()
        XCTAssertTrue(session.busy)
        await session.lock()
        XCTAssertFalse(session.busy)
        do { _ = try await vault.unlockedProfile(); XCTFail("Background lock must clear the vault") }
        catch { XCTAssertEqual(error as? OathWalletError, .locked) }
        await session.unlock(pin)
        await biometrics.releaseRead()
        await oldAttempt.value
        guard case .home(let current) = session.state else { return XCTFail("Old callback erased newer session") }
        XCTAssertEqual(current, profile)
        let saved = try await vault.unlockedProfile()
        XCTAssertEqual(saved, profile)
        XCTAssertFalse(session.busy)
        XCTAssertNil(session.notice)
    }

    private func fixture() async throws -> (OathWalletVault, UnlockTestBiometrics, OathWalletProfile) {
        let biometrics = UnlockTestBiometrics()
        let database = try await makeTestDatabase()
        let vault = OathWalletVault(storage: UnlockTestStorage(), biometricStore: biometrics, database: database)
        let phrase = try XCTUnwrap(OathMnemonicValidator.bundled?.verifiedPhrase(
            String(repeating: "abandon ", count: 11) + "about"))
        try await vault.create(digits: pin, importing: phrase)
        let profile = try await vault.unlockedProfile()
        await biometrics.setCredential(try await vault.biometricCredential())
        await vault.lock()
        return (vault, biometrics, profile)
    }
}

/// Opt-in native check. The host sends simulated matches only on the disposable
/// simulator; all credentials below belong to a public test vector.
@MainActor
final class OathWalletNativeBiometricTests: XCTestCase {
    func testStaleProtectedCredentialCanBeRepairedAndUnlockAgain() async throws {
        guard ProcessInfo.processInfo.environment["OATH_NATIVE_BIOMETRIC_TESTS"] == "1" else {
            throw XCTSkip("Requires an explicitly managed disposable simulator with simulated Face ID")
        }
        let service = "org.oathwallet.biometric-regression." + UUID().uuidString
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service,
                           kSecAttrAccount as String: "biometric-enrollment-v1",
                           kSecUseDataProtectionKeychain as String: true] as CFDictionary)
        }
        let biometrics = OathBiometricCredentialStore(service: service, installation: nil)
        let database = try await makeTestDatabase()
        let vault = OathWalletVault(storage: UnlockTestStorage(), biometricStore: biometrics, database: database)
        let pin: [UInt8] = [2, 9, 4, 8, 1, 6]
        let phrase = try XCTUnwrap(OathMnemonicValidator.bundled?.verifiedPhrase(
            String(repeating: "abandon ", count: 11) + "about"))
        try await vault.create(digits: pin, importing: phrase)
        let expected = try await vault.unlockedProfile()
        // Models an old verifier-only enrollment, not a valid wallet key.
        print("OATH_NATIVE_LEGACY_ENROLL_READY")
        let result = await biometrics.enableIfAvailable(strings: OathLocalizer(.english),
            credentialProvider: { Data("legacy-enrollment-test-token".utf8) })
        XCTAssertEqual(result, .enabled(.faceID))
        await vault.lock()
        let session = OathWalletSession(vault: vault)
        await session.load()
        print("OATH_NATIVE_STALE_KEY_READY")
        await session.unlockWithBiometrics()
        guard case .locked = session.state else { return XCTFail("A face match is not a wallet decryption key") }
        XCTAssertTrue(session.biometricRepairNeeded)
        XCTAssertNil(session.notice, "Biometric failure leaves the app passcode available without an alert")
        print("OATH_NATIVE_REPAIR_READY")
        await session.unlock(pin)
        guard case .home(let repaired) = session.state else { return XCTFail("Passcode recovery did not open home") }
        XCTAssertEqual(repaired, expected)
        XCTAssertFalse(session.biometricRepairNeeded, "Native Keychain must accept the replacement key")
        await session.lock()
        print("OATH_NATIVE_REPAIRED_UNLOCK_READY")
        await session.unlockWithBiometrics()
        guard case .home(let opened) = session.state else { return XCTFail("Repaired protected key did not unlock") }
        XCTAssertEqual(opened, expected)
        XCTAssertFalse(session.busy)
    }
}

private actor UnlockTestBiometrics: OathBiometricCredentialStoring {
    func hasEnrollment() -> Bool { credential != nil }
    func disable() { credential = nil }
    private var credential: Data?
    private var hold = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private(set) var enrollments = 0

    func setCredential(_ credential: Data?) { self.credential = credential }
    func holdNextRead() { hold = true }
    func waitForRead() async {
        if waiting == nil { await withCheckedContinuation { observer = $0 } }
    }
    func releaseRead() { waiting?.resume(); waiting = nil }
    func read(reason: String) async throws -> Data {
        if hold {
            hold = false
            await withCheckedContinuation {
                waiting = $0
                observer?.resume(); observer = nil
            }
        }
        guard let credential else { throw OathBiometricCredentialError.missing }
        return credential
    }
    func enableIfAvailable(strings: OathLocalizer,
                           credentialProvider: (@Sendable () async throws -> Data)?) async -> OathBiometricSetupResult {
        do {
            credential = try await credentialProvider?()
            enrollments += 1
            return .enabled(.faceID)
        } catch { return .failed(kind: .faceID, reason: .storage) }
    }
}

private final class UnlockTestStorage: OathVaultStorage, @unchecked Sendable {
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

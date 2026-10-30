import Foundation
import OathDatabase
import OathCloudBackup
import CryptoKit

/// A bounded derivation gate verifies that expensive work stays off MainActor
/// and that background locking cancels a write before its commit point.
final class DerivationGate: @unchecked Sendable {
    static let shared = DerivationGate()
    private let condition = NSCondition()
    private var armed = false
    private var entered = false
    private var invocations = 0
    func arm() { condition.lock(); armed = true; entered = false; condition.unlock() }
    var isWaiting: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    var count: Int { condition.lock(); defer { condition.unlock() }; return invocations }
    func release() { condition.lock(); armed = false; condition.broadcast(); condition.unlock() }
    func waitIfArmed() {
        condition.lock()
        defer { condition.unlock() }
        invocations += 1
        guard armed else { return }
        entered = true
        while armed {
            precondition(condition.wait(until: Date().addingTimeInterval(5)), "Host derivation gate timed out")
        }
    }
}

final class WalletMemory: OathVaultStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]
    private var rejectsErase = false
    func rejectNextErase() { lock.withLock { rejectsErase = true } }
    func erase() throws {
        try lock.withLock {
            if rejectsErase { rejectsErase = false; throw OathWalletError.unavailable }
            records.removeAll()
        }
    }
    private var rejectsUpdate = false
    func rejectNextUpdate() { lock.withLock { rejectsUpdate = true } }
    func read(_ account: String) throws -> Data? { lock.withLock { records[account] } }
    func insert(_ data: Data, account: String) throws {
        try lock.withLock {
            guard records[account] == nil else { throw OathPasscodeSaveError.alreadyConfigured }
            records[account] = data
        }
    }
    func update(_ data: Data, account: String) throws {
        try lock.withLock {
            if rejectsUpdate { rejectsUpdate = false; throw OathWalletError.unavailable }
            guard records[account] != nil else { throw OathWalletError.unavailable }
            records[account] = data
        }
    }
}

actor MemoryBiometrics: OathBiometricCredentialStoring {
    private var nextReadError: OathBiometricCredentialError?
    func failNextRead(_ error: OathBiometricCredentialError) { nextReadError = error }
    var enrollmentProbeFails = false
    func failEnrollmentProbe(_ value: Bool) { enrollmentProbeFails = value }
    func hasEnrollment() throws -> Bool {
        if enrollmentProbeFails { throw OathBiometricCredentialError.unavailable }
        return credential != nil
    }
    func disable() { credential = nil }
    var credential: Data?
    private(set) var reads = 0
    private var pauseNext = false
    private var pendingRead: CheckedContinuation<Void, Never>?
    private var enrollmentAllowed = false
    private(set) var enrollmentRequests = 0
    private var nextEnrollmentResult: OathBiometricSetupResult?
    func returnNextEnrollment(_ result: OathBiometricSetupResult) { nextEnrollmentResult = result }
    private var pauseEnrollment = false
    private var pendingEnrollment: CheckedContinuation<Void, Never>?
    var isEnrollmentWaiting: Bool { pendingEnrollment != nil }
    func allowEnrollment() { enrollmentAllowed = true }
    func pauseNextEnrollment() { pauseEnrollment = true }
    func releaseEnrollment() { pendingEnrollment?.resume(); pendingEnrollment = nil }
    var isWaiting: Bool { pendingRead != nil }
    func enroll(_ value: Data) { credential = value }
    func clear() { credential = nil }
    func pauseNextRead() { pauseNext = true }
    func releaseRead() { pendingRead?.resume(); pendingRead = nil }
    func read(reason: String) async throws -> Data {
        reads += 1
        if let error = nextReadError { nextReadError = nil; throw error }
        if pauseNext {
            pauseNext = false
            // Deliberately ignores cancellation, like an OS reply that was
            // already in flight. The caller must reject a stale result.
            await withCheckedContinuation { pendingRead = $0 }
        }
        guard let credential else { throw OathBiometricCredentialError.missing }
        return credential
    }
    func enableIfAvailable(strings: OathLocalizer,
                           credentialProvider: (@Sendable () async throws -> Data)?) async -> OathBiometricSetupResult {
        // Synthetic credential only; never asks macOS to authenticate a user.
        enrollmentRequests += 1
        if let result = nextEnrollmentResult { nextEnrollmentResult = nil; return result }
        guard enrollmentAllowed, let credentialProvider else { return .unavailable }
        do {
            let candidate = try await credentialProvider()
            if pauseEnrollment {
                pauseEnrollment = false
                await withCheckedContinuation { pendingEnrollment = $0 }
            }
            credential = candidate
            return .enabled(.faceID)
        } catch { return .failed(kind: .faceID, reason: .storage) }
    }
}

private struct CredentialIdentity: Decodable, Equatable {
    let walletID: UUID
    let key: Data
    static func matches(_ lhs: Data, _ rhs: Data) throws -> Bool {
        // JSON object field order is not part of the credential identity.
        try JSONDecoder().decode(Self.self, from: lhs) == JSONDecoder().decode(Self.self, from: rhs)
    }
}

@main struct CheckMultiWallet {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ result: Bool, _ label: String) {
            precondition(result, label)
            checks += 1
        }
        let fullEVM = OathImportChain.allCases.filter(\.isEVM)
        let legacyEVM = fullEVM.filter { $0 != .robinhood }
        let oldKey = OathImportedPrivateKey(bytes:Data(repeating:1,count:32),networks:legacyEVM)
        let expandedKey = OathImportedPrivateKey(bytes:Data(repeating:1,count:32),networks:fullEVM)
        check(oldKey.isFullEVMScope && oldKey.hasSameIdentity(as:expandedKey), "Robinhood enrollment must preserve a pre-upgrade EVM import identity")
        let narrowKey = OathImportedPrivateKey(bytes:Data(repeating:1,count:32),networks:[.ethereum])
        check(!narrowKey.isFullEVMScope && !narrowKey.hasSameIdentity(as:expandedKey), "Robinhood must not expand a narrow import scope")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OathMultiWallet-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wallet.sqlite")
        let database = try await OathDatabase.open(at: url)
        try await OathDataEnvironment.seed(database)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: database)
        let pin: [UInt8] = [2, 9, 4, 8, 1, 6] // Synthetic host fixture only.
        let firstPhrase = OathValidatedMnemonic(phrase: "synthetic first fixture", language: "english")
        try await vault.create(digits: pin, importing: firstPhrase)
        let root = try await vault.unlockedProfile()
        let credential = try await vault.biometricCredential()
        await biometrics.enroll(credential)
        check(root.addresses.count == OathImportChain.allCases.count, "Initial metadata must contain the supported networks")
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()
        check(session.isUnlocked && session.wallets.count == 1, "Initial session must contain its first wallet")
        check(session.presentsOnboarding && session.pendingCustomizationID == root.id.uuidString,
              "Welcome import must keep its navigation stack for customization after passcode and Face ID")
        session.finishInitialCustomization()
        check(session.presentsOnboarding, "Setup cannot skip an uncommitted customization")
        await session.lock()
        await session.unlock(pin)
        check(session.pendingCustomizationID == root.id.uuidString && session.presentsOnboarding,
              "A warm background lock must preserve initial customization")
        try await session.customizeWallet(root.id.uuidString, name: "Personal", colorHex: nil)
        check(session.pendingCustomizationID == nil && session.portfolio?.wallet.name == "Personal",
              "Apply must publish the committed metadata before navigating Home")
        session.finishInitialCustomization()
        check(!session.presentsOnboarding, "Only completed customization can finish initial setup")
        let generatedID = UUID()
        let addedID = try await session.addWallet(requestID: generatedID)
        check(addedID == generatedID.uuidString && session.pendingCustomizationID == addedID && !session.presentsOnboarding,
              "Additional creation must route the saved identity directly to Customize, without PIN setup")
        check(session.displayedProfile?.id == generatedID && session.wallets.count == 2, "Create must select the additional wallet")
        check(session.portfolio?.accounts.count == OathImportChain.allCases.count, "Additional accounts must be committed before presentation")
        check(session.portfolio?.wallet.kind == "hd", "Generated wallet metadata must retain its kind")
        check(session.portfolio?.wallet.backedUp == false, "A new wallet cannot claim to be backed up")
        check(try await CredentialIdentity.matches(vault.biometricCredential(), credential), "Adding a wallet must retain the existing Face ID key")
        let secondPhrase = OathValidatedMnemonic(phrase: "synthetic imported fixture", language: "english")
        let importedID = UUID()
        let addedImportID = try await session.addWallet(requestID: importedID, importing: secondPhrase)
        check(addedImportID == importedID.uuidString && session.pendingCustomizationID == addedImportID,
              "Additional import must route its committed identity to Customize")
        check(session.wallets.count == 3 && session.displayedProfile?.id == importedID, "Import must select a third wallet")
        check(session.portfolio?.wallet.kind == "imported" && session.portfolio?.wallet.backedUp == true,
              "Imported recovery metadata must describe the imported wallet")
        check(try await vault.recoveryWords() == OathMnemonicValidator.words(in: secondPhrase.phrase), "Selected recovery material must match import")
        check(try await database.settings()["activeWalletID"] == importedID.uuidString, "Selection must be stored in SQLite")

        // Retry the exact request and import the same phrase again. Neither may
        // duplicate an account, overwrite another wallet, or change its identity.
        try await session.addWallet(requestID: importedID, importing: secondPhrase)
        let duplicateID = try await session.addWallet(requestID: UUID(), importing: secondPhrase)
        check(duplicateID == importedID.uuidString, "Duplicate imports must customize the actual existing identity")
        check(session.wallets.count == 3 && session.displayedProfile?.id == importedID, "Idempotent imports must select the existing wallet")
        try await session.selectWallet(root.id)
        check(try await vault.recoveryWords() == OathMnemonicValidator.words(in: firstPhrase.phrase), "First wallet must survive additions")
        check(session.portfolio?.wallet.id == root.id.uuidString, "Display and signing identity must agree")
        try await database.saveBalances([
            BalanceRecord(accountID: root.id.uuidString + ":bitcoin:0", assetID: "bitcoin:native", networkID: "bitcoin",
                          amountAtomic: "100000000", observedAt: 1, source: "host-fixture"),
            BalanceRecord(accountID: importedID.uuidString + ":bitcoin:0", assetID: "bitcoin:native", networkID: "bitcoin",
                          amountAtomic: "250000000", observedAt: 1, source: "host-fixture")
        ])
        try await session.selectWallet(importedID)
        check(session.portfolio?.holdings.first { $0.networkID == "bitcoin" }?.amountAtomic == "250000000", "Selected balance must not leak from another wallet")
        try await session.selectWallet(root.id)
        check(session.portfolio?.holdings.first { $0.networkID == "bitcoin" }?.amountAtomic == "100000000", "Switching back must restore the first wallet's balance")

        // Renaming is a SQL-only metadata edit for the chosen member. It must
        // update both observations without selecting it or rewriting secrets.
        let protectedBeforeRename = try storage.read("vault-v1")
        let profileBeforeRename = session.displayedProfile
        try await session.renameWallet(root.id.uuidString, name: "  Spending  ")
        for _ in 0..<200 where session.portfolio?.wallet.name != "Spending"
            || session.wallets.first(where: { $0.id == root.id.uuidString })?.name != "Spending" {
            try await Task.sleep(for: .milliseconds(5))
        }
        check(session.portfolio?.wallet.name == "Spending", "Home must observe the committed selected-wallet name")
        check(session.wallets.first { $0.id == root.id.uuidString }?.name == "Spending", "The switcher and Settings must observe the same committed name")
        try await session.renameWallet(generatedID.uuidString, name: "  ادخار 🏡  ")
        for _ in 0..<200 where session.wallets.first(where: { $0.id == generatedID.uuidString })?.name != "ادخار 🏡" {
            try await Task.sleep(for: .milliseconds(5))
        }
        check(session.wallets.first { $0.id == generatedID.uuidString }?.name == "ادخار 🏡", "An inactive wallet can be renamed with a Unicode name")
        check(session.displayedProfile == profileBeforeRename && session.portfolio?.wallet.name == "Spending", "Renaming another wallet must leave the selected portfolio and addresses intact")
        check(try await database.settings()["activeWalletID"] == root.id.uuidString, "Renaming must not change the stored selection")
        check(try storage.read("vault-v1") == protectedBeforeRename, "Renaming must not touch encrypted secrets or passcode material")
        do { try await session.renameWallet(UUID().uuidString, name: "Unknown"); preconditionFailure("Unknown rename was accepted") }
        catch { check(error as? StoreError == .missingRecord, "Only managed wallets can be renamed") }
        let cancelledRename = Task { try await session.renameWallet(root.id.uuidString, name: "Cancelled") }
        cancelledRename.cancel()
        do { try await cancelledRename.value; preconditionFailure("Cancelled rename was accepted") }
        catch { check(error is CancellationError, "Cancelled edits stop before their write") }
        check(try await database.wallet(root.id.uuidString)?.name == "Spending", "Cancellation must preserve the committed name")

        let derivationsBeforeCustomize = DerivationGate.shared.count
        try await session.customizeWallet(root.id.uuidString, name: "Spending", colorHex: "DF438D")
        try await session.customizeWallet(generatedID.uuidString, name: "ادخار 🏡", colorHex: "12989C")
        for _ in 0..<200 where session.portfolio?.wallet.colorHex != "DF438D"
            || session.wallets.first(where: { $0.id == generatedID.uuidString })?.colorHex != "12989C" {
            try await Task.sleep(for: .milliseconds(5))
        }
        check(session.portfolio?.wallet.colorHex == "DF438D", "Home must observe the selected wallet's committed color")
        check(session.wallets.first { $0.id == generatedID.uuidString }?.colorHex == "12989C", "Inactive wallets retain separate colors")
        check(session.displayedProfile == profileBeforeRename, "Customization must not switch wallets or change addresses")
        check(DerivationGate.shared.count == derivationsBeforeCustomize, "Customization must never derive wallet keys")
        check(try storage.read("vault-v1") == protectedBeforeRename, "Customization must not rewrite encrypted secrets")
        let cancelledCustomize = Task { try await session.customizeWallet(root.id.uuidString, name: "Cancelled", colorHex: "000000") }
        cancelledCustomize.cancel()
        do { try await cancelledCustomize.value; preconditionFailure("Cancelled customization was accepted") }
        catch { check(error is CancellationError, "Cancelled customization stops before its write") }
        do { try await session.customizeWallet(UUID().uuidString, name: "Unknown", colorHex: "FFFFFF"); preconditionFailure("Unmanaged customization accepted") }
        catch { check(error as? StoreError == .missingRecord, "Customization accepts only managed wallets") }

        // Recovery disclosure must reauthenticate THAT member without changing
        // the active wallet, deriving addresses or modifying protected data.
        let derivationsBeforeReveal = DerivationGate.shared.count
        let exportByPIN = try await vault.recoveryWords(walletID: importedID.uuidString, digits: pin)
        check(exportByPIN == OathMnemonicValidator.words(in: secondPhrase.phrase), "Fresh PIN must reveal the requested inactive wallet")
        let readsBeforeReveal = await biometrics.reads
        let exportByFaceID = try await vault.recoveryWordsWithBiometrics(walletID: importedID.uuidString, reason: "Host fixture")
        check(exportByFaceID == exportByPIN, "Face ID and PIN must authorize the same requested member")
        check(await biometrics.reads == readsBeforeReveal + 1, "An unlocked app must still perform a fresh biometric key read")
        check(try await database.settings()["activeWalletID"] == root.id.uuidString
              && session.displayedProfile == profileBeforeRename, "Revealing another wallet must not select it")
        check(try storage.read("vault-v1") == protectedBeforeRename, "Viewing a phrase must not rewrite the vault")
        check(DerivationGate.shared.count == derivationsBeforeReveal, "Phrase authorization must not rederive accounts")

        let readsBeforeUnknown = await biometrics.reads
        do { _ = try await vault.recoveryWordsWithBiometrics(walletID: UUID().uuidString, reason: "Host fixture"); preconditionFailure("Unknown wallet was disclosed") }
        catch { check(error as? OathWalletError == .unavailable, "Unknown wallet must fail before prompting") }
        check(await biometrics.reads == readsBeforeUnknown, "An unknown member must not invoke biometric authentication")
        await biometrics.enroll(Data([0, 1, 2]))
        do { _ = try await vault.recoveryWordsWithBiometrics(walletID: root.id.uuidString, reason: "Host fixture"); preconditionFailure("Invalid credential was accepted") }
        catch { check(error as? OathBiometricCredentialError == .invalid, "A face match without a valid vault key must not authorize disclosure") }

        // Missing enrollment opens the PIN page. Wrong PIN uses the existing
        // persistent attempt limit and never releases words to display state.
        await biometrics.clear()
        let disclosure = OathRecoveryPhraseModel(walletID: importedID.uuidString, reader: vault)
        let readsBeforeAcknowledgement = await biometrics.reads
        check(disclosure.phase == .warning && disclosure.words.isEmpty && !disclosure.busy,
              "The initial warning must not contain recovery material or start authentication")
        disclosure.acknowledge(reason: "Host fixture")
        disclosure.acknowledge(reason: "Host fixture")
        for _ in 0..<1000 where disclosure.busy { try await Task.sleep(for: .milliseconds(5)) }
        check(disclosure.phase == .passcode && disclosure.words.isEmpty, "No enrolled Face ID must require the app PIN")
        check(await biometrics.reads == readsBeforeAcknowledgement + 1, "Repeated acknowledgement must not open duplicate prompts")
        disclosure.submit([1, 2])
        check(!disclosure.busy && disclosure.words.isEmpty, "Incomplete PIN must not start validation")
        disclosure.submit([0, 0, 0, 0, 0, 0])
        for _ in 0..<1000 where disclosure.busy { try await Task.sleep(for: .milliseconds(5)) }
        check(disclosure.phase == .passcode && disclosure.notice == .unlockIncorrect && disclosure.words.isEmpty,
              "Wrong PIN must leave the user on the passcode page without revealing words")
        disclosure.submit(pin)
        for _ in 0..<1000 where disclosure.busy { try await Task.sleep(for: .milliseconds(5)) }
        check(disclosure.phase == .revealed && disclosure.words == exportByPIN,
              "A correct PIN must reveal only the requested wallet")
        disclosure.cancelAuthentication()
        check(disclosure.phase == .warning && disclosure.words.isEmpty && disclosure.passphrase == nil,
              "Backgrounding must discard revealed recovery material and require fresh authorization")
        disclosure.returnToWarning()
        check(disclosure.phase == .warning && disclosure.words.isEmpty, "Leaving the reveal flow must discard its display material")

        // Even a correct PIN cannot bypass the shared persistent lockout.
        for _ in 0..<5 {
            do { _ = try await vault.recoveryWords(walletID: root.id.uuidString, digits: [0, 0, 0, 0, 0, 0]); preconditionFailure("Wrong PIN disclosed a wallet") }
            catch { check(error as? OathWalletError == .wrongPasscode, "Invalid disclosure PIN must count toward the persisted limit") }
        }
        do { _ = try await vault.recoveryWords(walletID: root.id.uuidString, digits: pin); preconditionFailure("Disclosure bypassed PIN lockout") }
        catch {
            if case .throttled = error as? OathWalletError { check(true, "Disclosure must enforce the same PIN lockout") }
            else { preconditionFailure("Expected persisted PIN lockout") }
        }
        await biometrics.enroll(credential)
        disclosure.acknowledge(reason: "Host fixture")
        for _ in 0..<1000 where disclosure.busy { try await Task.sleep(for: .milliseconds(5)) }
        check(disclosure.phase == .revealed && disclosure.words == exportByPIN,
              "Fresh biometric authorization must go directly from acknowledgement to the requested words")
        check(try await vault.recoveryWords(walletID: root.id.uuidString, digits: pin)
              == OathMnemonicValidator.words(in: firstPhrase.phrase), "Successful biometrics must reset failed PIN attempts")
        disclosure.returnToWarning()

        // A late successful OS reply after leaving the warning cannot navigate
        // or repopulate the model. No key material is printed by this fixture.
        await biometrics.pauseNextRead()
        disclosure.acknowledge(reason: "Host fixture")
        for _ in 0..<1000 { if await biometrics.isWaiting { break }; try await Task.sleep(for: .milliseconds(5)) }
        check(await biometrics.isWaiting, "A biometric request must actually be pending for the cancellation check")
        disclosure.returnToWarning()
        await biometrics.releaseRead()
        _ = try await vault.wallets() // Barrier after the released actor read.
        for _ in 0..<20 { await Task.yield() }
        check(disclosure.phase == .warning && disclosure.words.isEmpty && !disclosure.busy,
              "A cancelled disclosure must ignore a late successful authentication result")

        await biometrics.pauseNextRead()
        let pendingReveal = Task { try await vault.recoveryWordsWithBiometrics(walletID: importedID.uuidString, reason: "Host fixture") }
        for _ in 0..<1000 { if await biometrics.isWaiting { break }; try await Task.sleep(for: .milliseconds(5)) }
        check(await biometrics.isWaiting, "A biometric request must be pending before locking")
        await session.lock()
        await biometrics.releaseRead()
        do { _ = try await pendingReveal.value; preconditionFailure("Locked app returned recovery material") }
        catch { check(error is CancellationError, "Locking the app must invalidate an in-flight biometric disclosure") }
        do { _ = try await vault.recoveryWords(walletID: importedID.uuidString, digits: pin); preconditionFailure("Disclosure unlocked a locked session") }
        catch { check(error as? OathWalletError == .locked, "The recovery flow cannot unlock the app behind its lock screen") }
        await session.unlock(pin)
        check(session.isUnlocked && session.displayedProfile?.id == root.id, "Recovery authentication must leave session routing intact")

        // Private-key disclosure is the reverse ordering: metadata-only list,
        // fresh account-scoped authentication, warning, acknowledgement, value.
        let exportsBeforeList = DerivationGate.shared.count
        let keyFlow = OathPrivateKeyModel(walletID: importedID.uuidString, reader: vault)
        await keyFlow.load()
        check(keyFlow.loaded && keyFlow.accounts.count == OathImportChain.allCases.count + 1 && keyFlow.key == nil && keyFlow.phase == .chains,
              "Private-key list must contain all supported accounts without secret material")
        check(DerivationGate.shared.count == exportsBeforeList, "Loading the private-key list must never derive keys")
        guard let solana = keyFlow.accounts.first(where: { $0.chain == .solana }),
              let bitcoin = keyFlow.accounts.first(where: { $0.chain == .bitcoin }) else {
            preconditionFailure("Missing synthetic export account")
        }
        keyFlow.acknowledge()
        check(keyFlow.key == nil && keyFlow.phase == .chains, "Acknowledgement cannot bypass chain authentication")
        let readsBeforeBadAccount = await biometrics.reads
        do {
            _ = try await vault.privateKeyWithBiometrics(walletID: importedID.uuidString,
                accountID: root.id.uuidString + ":solana:0", reason: "Host fixture")
            preconditionFailure("A foreign account was authorized")
        } catch { check(error as? OathWalletError == .unavailable, "Reject accounts owned by another wallet") }
        check(await biometrics.reads == readsBeforeBadAccount, "Invalid accounts must fail before biometric prompts")

        let readsBeforeKey = await biometrics.reads
        keyFlow.select(solana, reason: "Host fixture")
        keyFlow.select(bitcoin, reason: "Host fixture")
        for _ in 0..<1000 where keyFlow.busy { try await Task.sleep(for: .milliseconds(5)) }
        check(keyFlow.phase == .warning && keyFlow.key == nil && keyFlow.selected == solana,
              "Face ID success must show the warning before exposing the selected key")
        check(await biometrics.reads == readsBeforeKey + 1, "Duplicate taps cannot authorize two chains")
        check(DerivationGate.shared.count == exportsBeforeList + 1, "Export derives only the requested account")
        keyFlow.acknowledge()
        let expectedSolana = "synthetic-export-" + importedID.uuidString + solana.chain.id + solana.path
        check(keyFlow.phase == .revealed && keyFlow.key?.value == expectedSolana,
              "Acknowledgement reveals only the authenticated inactive wallet's account")
        keyFlow.cancelAuthentication()
        check(keyFlow.key?.value == expectedSolana, "The revealed key follows the existing app-lock snapshot policy")
        keyFlow.returnToWarning()
        check(keyFlow.phase == .warning && keyFlow.key == nil, "Back to warning removes the displayed value")
        keyFlow.acknowledge()
        check(keyFlow.key?.value == expectedSolana, "The same authorized warning can reveal again")
        keyFlow.returnToChains()
        keyFlow.acknowledge()
        check(keyFlow.phase == .chains && keyFlow.selected == nil && keyFlow.key == nil,
              "Leaving an account clears its key and authorization")
        check(try await database.settings()["activeWalletID"] == root.id.uuidString
              && session.displayedProfile == profileBeforeRename, "Key export must not switch the selected wallet")
        check(try storage.read("vault-v1") == protectedBeforeRename, "Key export cannot rewrite protected wallets")

        await biometrics.clear()
        keyFlow.select(bitcoin, reason: "Host fixture")
        for _ in 0..<1000 where keyFlow.busy { try await Task.sleep(for: .milliseconds(5)) }
        check(keyFlow.phase == .passcode && keyFlow.key == nil, "Missing Face ID must require the app passcode")
        keyFlow.submit([1, 2]); keyFlow.submit([99, 1, 2, 3, 4, 5])
        check(!keyFlow.busy && keyFlow.phase == .passcode, "Malformed PIN must not start key derivation")
        keyFlow.submit([0, 0, 0, 0, 0, 0])
        for _ in 0..<1000 where keyFlow.busy { try await Task.sleep(for: .milliseconds(5)) }
        check(keyFlow.phase == .passcode && keyFlow.key == nil && keyFlow.notice == .unlockIncorrect,
              "Wrong PIN cannot reach the warning or reveal a key")
        keyFlow.submit(pin)
        for _ in 0..<1000 where keyFlow.busy { try await Task.sleep(for: .milliseconds(5)) }
        check(keyFlow.phase == .warning && keyFlow.key == nil, "Correct PIN shows the warning first")
        keyFlow.returnToPasscode()
        keyFlow.acknowledge()
        check(keyFlow.phase == .passcode && keyFlow.key == nil, "Backing into PIN revokes the pending key")
        keyFlow.submit(pin)
        for _ in 0..<1000 where keyFlow.busy { try await Task.sleep(for: .milliseconds(5)) }
        keyFlow.acknowledge()
        check(keyFlow.key?.value == "synthetic-export-" + importedID.uuidString + bitcoin.chain.id + bitcoin.path,
              "PIN and biometric paths bind exports to their selected accounts")
        keyFlow.returnToChains()

        // Export shares the persisted app/recovery PIN throttling, including
        // valid credentials while the timer is active.
        for _ in 0..<5 {
            do { _ = try await vault.privateKey(walletID: importedID.uuidString, accountID: bitcoin.id,
                                              digits: [0, 0, 0, 0, 0, 0]); preconditionFailure("Wrong PIN exported key") }
            catch { check(error as? OathWalletError == .wrongPasscode, "Key export records invalid PIN attempts") }
        }
        do { _ = try await vault.privateKey(walletID: importedID.uuidString, accountID: bitcoin.id, digits: pin)
            preconditionFailure("Export bypassed PIN lockout")
        } catch {
            if case .throttled = error as? OathWalletError { check(true, "Key export enforces persistent lockout") }
            else { preconditionFailure("Expected private-key PIN lockout") }
        }
        await biometrics.enroll(credential)
        keyFlow.select(solana, reason: "Host fixture")
        for _ in 0..<1000 where keyFlow.busy { try await Task.sleep(for: .milliseconds(5)) }
        keyFlow.cancelAuthentication()
        keyFlow.acknowledge()
        check(keyFlow.phase == .chains && keyFlow.key == nil, "Backgrounding clears an unacknowledged authenticated key")

        await biometrics.pauseNextRead()
        keyFlow.select(solana, reason: "Host fixture")
        for _ in 0..<1000 { if await biometrics.isWaiting { break }; try await Task.sleep(for: .milliseconds(5)) }
        check(await biometrics.isWaiting, "A private-key biometric reply must be pending before cancellation")
        keyFlow.returnToChains()
        await biometrics.releaseRead()
        _ = try await vault.wallets()
        for _ in 0..<20 { await Task.yield() }
        check(keyFlow.phase == .chains && keyFlow.key == nil && !keyFlow.busy,
              "A late successful biometric reply cannot revive the private-key flow")

        await biometrics.pauseNextRead()
        let pendingKey = Task { try await vault.privateKeyWithBiometrics(walletID: importedID.uuidString,
            accountID: solana.id, reason: "Host fixture") }
        for _ in 0..<1000 { if await biometrics.isWaiting { break }; try await Task.sleep(for: .milliseconds(5)) }
        check(await biometrics.isWaiting, "A private-key read must be pending before the lock race")
        await session.lock()
        await biometrics.releaseRead()
        do { _ = try await pendingKey.value; preconditionFailure("Locked app exported a key") }
        catch { check(error is CancellationError, "Lock invalidates in-flight private-key authorization") }
        do { _ = try await vault.privateKey(walletID: importedID.uuidString, accountID: bitcoin.id, digits: pin)
            preconditionFailure("Private-key flow bypassed the app lock")
        } catch { check(error as? OathWalletError == .locked, "Key disclosure cannot unlock a locked app") }
        await session.unlock(pin)

        // The UI executor must keep running while single-account derivation
        // runs on the vault actor; cancellation must reject its completed value.
        DerivationGate.shared.arm()
        let derivingKey = Task { try await vault.privateKey(walletID: importedID.uuidString,
                                                           accountID: solana.id, digits: pin) }
        for _ in 0..<1000 where !DerivationGate.shared.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        check(DerivationGate.shared.isWaiting, "Key derivation must execute off the UI actor")
        derivingKey.cancel()
        DerivationGate.shared.release()
        do { _ = try await derivingKey.value; preconditionFailure("Cancelled derivation exported a key") }
        catch { check(error is CancellationError, "Cancellation discards a completed key derivation") }

        // Encrypting an inactive wallet must export THAT member and its
        // committed metadata, without selecting it or changing the app PIN.
        try await session.customizeWallet(importedID.uuidString, name: "Travel 🏖", colorHex: "209750")
        let exported = try await vault.encryptedCloudBackup(walletID: importedID.uuidString, password: "synthetic-backup-password")
        let decoded = try await Task.detached {
            try BackupDocument.open(exported, password: "synthetic-backup-password")
        }.value
        check(decoded.id == importedID && decoded.mnemonic == secondPhrase.phrase, "Cloud backup must contain the requested member, not the selected wallet")
        check(decoded.accounts.count == OathImportChain.allCases.count && decoded.language == secondPhrase.language, "Cloud backup must retain language and all derivation paths")
        check(decoded.name == "Travel 🏖" && decoded.colorHex == "209750", "The encrypted backup must carry the requested wallet's committed name and color")
        check(try await database.settings()["activeWalletID"] == root.id.uuidString, "Backing up an inactive wallet must not change selection")
        check(try storage.read("vault-v1") == protectedBeforeRename, "Cloud encryption must not change app PIN or vault")
        let cancelledBackup = Task { try await vault.encryptedCloudBackup(walletID: root.id.uuidString, password: "synthetic-backup-password") }
        cancelledBackup.cancel()
        do { _ = try await cancelledBackup.value; preconditionFailure("Cancelled backup exported data") }
        catch { check(error is CancellationError, "Cancelled export must not return ciphertext for upload") }

        try await session.selectWallet(importedID)
        await session.lock()
        check(session.isLocked, "Lock must cover the retained Home")
        do { _ = try await vault.encryptedCloudBackup(walletID: root.id.uuidString, password: "synthetic-backup-password"); preconditionFailure("Locked backup was accepted") }
        catch { check(error as? OathWalletError == .locked, "Cloud backup must require an unlocked vault") }
        do { _ = try await vault.recoveryWords(); preconditionFailure("Locked vault returned recovery material") }
        catch { check(error as? OathWalletError == .locked, "Lock must discard the entire secret collection") }
        do { try await session.addWallet(requestID: UUID()); preconditionFailure("Locked add was accepted") }
        catch { check(error as? OathWalletError == .locked, "Adding requires authentication") }
        do { try await session.selectWallet(root.id); preconditionFailure("Locked switch was accepted") }
        catch { check(error as? OathWalletError == .locked, "Switching requires authentication") }
        do { try await session.renameWallet(root.id.uuidString, name: "Locked edit"); preconditionFailure("Locked rename was accepted") }
        catch { check(error as? OathWalletError == .locked, "Renaming requires authentication") }
        do { try await session.customizeWallet(root.id.uuidString, name: "Locked", colorHex: "000000"); preconditionFailure("Locked customization accepted") }
        catch { check(error as? OathWalletError == .locked, "Customization requires authentication") }

        // Real database/envelope reopen, using the original enrolled key.
        let reopened = try await OathDatabase.open(at: url)
        let restartedVault = OathWalletVault(storage: storage, biometricStore: biometrics, database: reopened)
        let restarted = OathWalletSession(vault: restartedVault)
        await restarted.load()
        check(restarted.isLocked && restarted.displayedProfile?.id == importedID, "Cold launch must show the selected Home beneath the lock")
        check(restarted.wallets.count == 3, "Cold launch must read all wallet names without granting access")
        check(restarted.wallets.first { $0.id == root.id.uuidString }?.name == "Spending"
              && restarted.wallets.first { $0.id == generatedID.uuidString }?.name == "ادخار 🏡",
              "Names must survive a new database connection and cold session")
        check(restarted.wallets.first { $0.id == root.id.uuidString }?.colorHex == "DF438D"
              && restarted.wallets.first { $0.id == generatedID.uuidString }?.colorHex == "12989C",
              "Per-wallet colors must survive relaunch and a cancelled edit")
        await restarted.unlockWithBiometrics(automatically: true)
        check(restarted.isUnlocked && restarted.displayedProfile?.id == importedID, "Original Face ID credential must open the selected wallet")
        check(restarted.pendingCustomizationID == nil && !restarted.presentsOnboarding,
              "Completed wallets must not re-enter customization on cold launch")
        try await restarted.selectWallet(generatedID)
        await restarted.lock()
        await restarted.unlock(pin)
        check(restarted.isUnlocked && restarted.displayedProfile?.id == generatedID, "The same PIN must reopen every selected wallet")
        check(try await CredentialIdentity.matches(restartedVault.biometricCredential(), credential), "Selection must never rebind Face ID")

        // A failed atomic protected-store update must leave all old ciphertext
        // and database records intact; retrying must succeed exactly once.
        let before = try storage.read("vault-v1")
        storage.rejectNextUpdate()
        let retryID = UUID()
        do { try await restarted.addWallet(requestID: retryID); preconditionFailure("Expected storage failure") }
        catch { check(restarted.isUnlocked && !restarted.changingWallet, "A failed addition must keep the original session usable") }
        check(try storage.read("vault-v1") == before, "Failed addition must not overwrite existing wallets")
        check(try await reopened.wallet(retryID.uuidString) == nil, "Failed protected commit must not create metadata")
        try await restarted.addWallet(requestID: retryID)
        check(restarted.wallets.count == 4 && restarted.displayedProfile?.id == retryID, "Retry must create exactly one wallet")

        // Simulate a public-metadata conflict after the encrypted commit. The
        // added secret stays durable and repair uses it instead of regenerating.
        let interruptedID = UUID()
        try await reopened.importWalletIfNeeded(WalletRecord(id: interruptedID.uuidString, name: "Foreign fixture",
            kind: "watchOnly", vaultReference: "foreign", createdAt: 0), accounts: [])
        do { try await restarted.addWallet(requestID: interruptedID); preconditionFailure("Expected metadata conflict") }
        catch { check(restarted.displayedProfile?.id == retryID, "Metadata failure must retain the last usable selection") }
        check(restarted.wallets.count == 4, "Unrelated metadata must be excluded from the switcher")
        try await reopened.deleteWalletMetadata(interruptedID.uuidString)
        await restarted.lock()
        await restarted.unlock(pin)
        check(restarted.isUnlocked && restarted.wallets.count == 5, "Unlock must repair a durable wallet's missing metadata")
        try await restarted.addWallet(requestID: interruptedID)
        check(restarted.wallets.count == 5 && restarted.displayedProfile?.id == interruptedID, "Retry after repair must reuse the durable identity")
        check(restarted.pendingCustomizationID == interruptedID.uuidString,
              "Repair after an interrupted commit must recover the pending customization too")
        let encrypted = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
        let members = try encrypted.openContents(using: encrypted.key(for: pin))
        check(members.wallets.count == 5 && members.wallets.first?.id == root.id, "Every protected wallet must survive repair")

        // Pause only the synthetic derivation adapter. A main-actor operation
        // must remain responsive, and a background lock must cancel the commit.
        let cancelledID = UUID()
        DerivationGate.shared.arm()
        let adding = Task { try await restarted.addWallet(requestID: cancelledID) }
        for _ in 0..<400 where !DerivationGate.shared.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        check(DerivationGate.shared.isWaiting, "Derivation must run outside the UI executor")
        let locking = Task { await restarted.lock() }
        for _ in 0..<400 where !restarted.isLocked { try await Task.sleep(for: .milliseconds(5)) }
        check(restarted.isLocked && !restarted.changingWallet, "Background lock must publish without waiting for derivation")
        DerivationGate.shared.release()
        await locking.value
        do { _ = try await adding.value; preconditionFailure("Cancelled creation completed") }
        catch { check(error is CancellationError, "Background creation must stop before committing") }
        check(try await reopened.wallet(cancelledID.uuidString) == nil, "Cancelled creation must not insert metadata")
        await restarted.unlock(pin)
        check(restarted.isUnlocked && restarted.wallets.count == 5, "Cancellation must preserve every existing wallet")
        check(restarted.displayedProfile?.id == interruptedID, "Cancelled addition must not change the selected wallet")
        check(try await CredentialIdentity.matches(restartedVault.biometricCredential(), credential), "Background cancellation must preserve Face ID enrollment")
        await restarted.lock()
        let resumed = OathWalletSession(vault: OathWalletVault(storage: storage, biometricStore: biometrics, database: reopened))
        await resumed.load()
        check(resumed.isLocked && !resumed.presentsOnboarding, "Cold resume authenticates before continuing customization")
        await resumed.unlock(pin)
        check(resumed.pendingCustomizationID == interruptedID.uuidString && resumed.wallets.count == 5,
              "Cold resume must continue the same unfinished wallet without generating another")
        try await resumed.customizeWallet(interruptedID.uuidString, name: "Resumed", colorHex: "8B36C9")
        check(resumed.pendingCustomizationID == nil, "Resumed Apply clears the durable pending step")
        await resumed.lock()

        // Generated first wallets use the same completion contract as mnemonic
        // imports. The real passcode model's biometric ordering is unchanged.
        let firstDB = try await OathDatabase.open(at: directory.appendingPathComponent("first-generated.sqlite"))
        try await OathDataEnvironment.seed(firstDB)
        let firstVault = OathWalletVault(storage: WalletMemory(), biometricStore: MemoryBiometrics(), database: firstDB)
        try await firstVault.create(digits: pin, importing: nil)
        let firstSession = OathWalletSession(vault: firstVault)
        await firstSession.finishedSetup()
        check(firstSession.presentsOnboarding && firstSession.pendingCustomizationID != nil,
              "Welcome Create must finish at Customize, just like Welcome Import")
        try await firstSession.customizeWallet(firstSession.pendingCustomizationID!, name: "First", colorHex: "126BB5")
        firstSession.finishInitialCustomization()
        check(!firstSession.presentsOnboarding && firstSession.portfolio?.wallet.colorHex == "126BB5",
              "Generated first-wallet Apply must open Home with the selected artwork")
        await firstSession.lock()
        // Key-only wallets must persist without fabricating recovery words or
        // broadening their network scope. Use synthetic bytes and derivation.
        let keyDB = try await OathDatabase.open(at: directory.appendingPathComponent("private-key.sqlite"))
        try await OathDataEnvironment.seed(keyDB)
        let keyStorage = WalletMemory(), keyBiometrics = MemoryBiometrics()
        let keyVault = OathWalletVault(storage: keyStorage, biometricStore: keyBiometrics, database: keyDB)
        let material = OathImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: [.ethereum, .base])
        try await keyVault.create(digits: pin, importing: nil, privateKey: material)
        let keySession = OathWalletSession(vault: keyVault)
        await keySession.finishedSetup()
        let keyID = keySession.displayedProfile!.id.uuidString
        check(keySession.presentsOnboarding && keySession.pendingCustomizationID == keyID,
              "Welcome key import must finish security setup before Customize")
        check(keySession.portfolio?.wallet.kind == "privateKey", "SQL must distinguish key-only wallets")
        check(Set(keySession.portfolio!.accounts.map(\.networkID)) == Set(["ethereum", "base"]),
              "Private key import must only persist the selected scope")
        check(keySession.portfolio!.accounts.allSatisfy { $0.derivationPath == "imported" },
              "A single key must never claim a made-up HD derivation path")
        try await keySession.customizeWallet(keyID, name: "Key wallet", colorHex: "DF438D")
        keySession.finishInitialCustomization()
        check(!keySession.presentsOnboarding, "Applying key wallet customization opens Home")
        let keyCredential = try await keyVault.biometricCredential()
        await keyBiometrics.enroll(keyCredential)
        do { _ = try await keyVault.recoveryWords(walletID: keyID, digits: pin); preconditionFailure("A key has no recovery phrase") }
        catch { check(error as? OathWalletError == .unavailable, "Recovery phrase export must fail closed for key-only wallets") }
        let backup = try await keyVault.encryptedCloudBackup(walletID: keyID, password: "fixture-password")
        let openedBackup = try BackupDocument.open(backup, password: "fixture-password")
        check(openedBackup.privateKey?.bytes == material.bytes && openedBackup.mnemonic.isEmpty,
              "Encrypted backup must retain the imported material type")
        check(openedBackup.name == "Key wallet" && openedBackup.colorHex == "DF438D",
              "Key-only backups must retain customization")
        let addedKeyID = try await keySession.addWallet(requestID: UUID(), privateKey: material)
        check(addedKeyID == keyID && keySession.wallets.count == 1, "Equivalent keys and scope must deduplicate")
        let reordered = OathImportedPrivateKey(bytes: material.bytes, networks: [.base, .ethereum])
        let reorderedID = try await keySession.addWallet(requestID: UUID(), privateKey: reordered)
        check(reorderedID == keyID && keySession.wallets.count == 1, "Network ordering cannot duplicate a key wallet")
        let single = OathImportedPrivateKey(bytes: Data(repeating: 8, count: 32), networks: [.solana])
        let singleID = try await keySession.addWallet(requestID: UUID(), privateKey: single)
        check(keySession.wallets.count == 2 && keySession.pendingCustomizationID == singleID,
              "Additional key import must go directly to Customize under the same app lock")
        check(keySession.portfolio?.accounts.count == 1, "Non-EVM import must not invent other networks")
        check(try await CredentialIdentity.matches(keyVault.biometricCredential(), keyCredential),
              "Key import preserves the existing Face ID credential")
        let ciphertext = try keyStorage.read("vault-v1")!
        let sealedKeys = try JSONDecoder().decode(OathVaultEnvelope.self, from: ciphertext)
        let allKeys = try sealedKeys.openContents(using: sealedKeys.key(for: pin))
        check(allKeys.wallets.count == 2 && allKeys.wallets.allSatisfy { $0.privateKey != nil },
              "Key-only wallets must remain encrypted and must not enter remote credential capture")
        check(!String(decoding: ciphertext, as: UTF8.self).contains(material.bytes.base64EncodedString()),
              "Raw private keys must not leak through the persisted envelope")
        await keySession.lock()
        let restoredKeys = OathWalletSession(vault: OathWalletVault(storage: keyStorage, biometricStore: keyBiometrics,
                                                                  database: keyDB))
        await restoredKeys.load()
        check(restoredKeys.isLocked, "Cold key-only wallet launch must require authentication")
        await restoredKeys.unlock(pin)
        check(restoredKeys.isUnlocked && restoredKeys.wallets.count == 2 && restoredKeys.pendingCustomizationID == singleID,
              "Key-only wallets and incomplete customization must survive relaunch")
        try await restoredKeys.selectWallet(UUID(uuidString: keyID)!)
        check(restoredKeys.portfolio?.wallet.name == "Key wallet" && restoredKeys.portfolio?.wallet.colorHex == "DF438D",
              "Key wallet selection must read its saved identity from SQL")
        await restoredKeys.lock()
        checks += try await checkWalletLifecycle()
        checks += try await checkSecurity()
        checks += try await checkReset()
        checks += try await checkPassphraseWallets()
        checks += try await checkCloudRestore()
        checks += try await checkUTXOKeyIdentity()
        print("Passed \(checks) host multiwallet integration checks (production vault/session/SQLite, fixture derivation; no simulator, Keychain or live network).")
    }

    @MainActor static func checkSecurity() async throws -> Int {
        var checks = 0
        func check(_ result: Bool, _ label: String) { precondition(result, label); checks += 1 }
        func reject<E: Error & Equatable>(_ expected: E, _ label: String,
                                         _ operation: () async throws -> Void) async {
            do { try await operation(); preconditionFailure(label) }
            catch { check(error as? E == expected, label) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OathSecurity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try await OathDatabase.open(at: directory.appendingPathComponent("security.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let pin: [UInt8] = [1, 6, 9, 2, 8, 4], replacement: [UInt8] = [9, 2, 8, 4, 1, 6]
        let enabledPIN: [UInt8] = [8, 4, 1, 6, 9, 2]
        let phrase = OathValidatedMnemonic(phrase: "synthetic security fixture", language: "english")
        try await vault.create(digits: pin, importing: phrase)
        let original = try await vault.biometricCredential()
        await biometrics.enroll(original)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()
        let root = session.displayedProfile!.id
        try await session.customizeWallet(root.uuidString, name: "Security fixture", colorHex: "DF438D")
        session.finishInitialCustomization()
        let other = try await session.addWallet(requestID: UUID())
        try await session.selectWallet(root)
        let members = Set(session.wallets.map(\.id))
        check(session.security == .init(passcodeEnabled: true, biometricsEnabled: true), "Legacy enrollment must retain passcode and Face ID")
        let access = OathSecurityAccessModel(session: session)
        func settleAccess() async throws {
            for _ in 0..<1_000 where access.busy { try await Task.sleep(for: .milliseconds(5)) }
            check(!access.busy, "Security entry authentication finishes within the test deadline")
        }
        let entryReads = await biometrics.reads
        access.begin(reason: "Synthetic Security entry")
        access.begin(reason: "Duplicate tap")
        check(!access.isAuthorized && access.busy, "Security stays hidden while authentication is pending")
        try await settleAccess()
        let firstEntryReads = await biometrics.reads
        check(access.isAuthorized && firstEntryReads == entryReads + 1,
              "Opening Security makes exactly one fresh biometric read")
        await reject(OathWalletError.locked, "Entry authentication must not authorize a credential change") {
            try await vault.setPasscode(replacement, authorization: nil)
        }
        access.cancel()
        check(!access.isAuthorized, "Leaving Security immediately revokes entry access")
        access.begin(reason: "Synthetic second visit")
        try await settleAccess()
        let secondEntryReads = await biometrics.reads
        check(access.isAuthorized && secondEntryReads == entryReads + 2,
              "Every new Security visit authenticates again")
        access.cancel()
        await biometrics.failNextRead(.cancelled)
        access.begin(reason: "Synthetic cancelled Face ID")
        try await settleAccess()
        check(access.phase == .passcode && !access.isAuthorized && access.notice == nil,
              "Cancelling Face ID offers the app passcode without granting access or showing an error")
        await biometrics.failNextRead(.unavailable)
        access.begin(reason: "Synthetic unavailable Face ID")
        try await settleAccess()
        check(access.phase == .passcode && !access.isAuthorized, "Unavailable Face ID falls back to app passcode")
        access.submit(replacement)
        try await settleAccess()
        check(access.phase == .passcode && access.notice == .unlockIncorrect && !access.isAuthorized,
              "Incorrect PIN remains on entry with the shared inline rejection")
        access.submit(pin)
        try await settleAccess()
        check(access.isAuthorized && access.notice == nil, "Correct PIN opens Security after a failed attempt")
        access.cancel()
        await biometrics.pauseNextRead()
        access.begin(reason: "Synthetic delayed Face ID")
        for _ in 0..<400 where !(await biometrics.isWaiting) { try await Task.sleep(for: .milliseconds(5)) }
        check(await biometrics.isWaiting, "Security entry has an in-flight OS response")
        access.cancel() // Real background/exit invalidates the visit.
        await biometrics.releaseRead()
        try await Task.sleep(for: .milliseconds(30))
        check(access.phase == .idle && !access.isAuthorized && !access.busy,
              "A late Face ID response cannot reopen Security after leaving")
        await session.lock()
        await reject(OathWalletError.locked, "A locked vault rejects Security entry") {
            try await vault.authenticateSecurityAccess(digits: pin, reason: "")
        }
        let readsBeforeManualLock = await biometrics.reads
        await session.unlockWithBiometrics(automatically: true)
        check(session.isLocked, "An automatic Face ID attempt must never undo Manual Lock")
        check(await biometrics.reads == readsBeforeManualLock, "Manual Lock must not even request biometric authentication")
        check(!session.allowsAutomaticBiometricUnlock && !session.busy && session.notice == nil,
              "Manual Lock leaves an idle, usable passcode screen without an automatic prompt")
        // Recreated lock views and reactivation may request authentication again.
        // Session intent must outlive those UI events, including scene disconnect.
        session.enteredBackground(delay: .immediately)
        session.enteringForeground()
        await session.lock(reason: .automatic)
        for _ in 0..<3 { await session.unlockWithBiometrics(automatically: true) }
        check(session.isLocked && !session.allowsAutomaticBiometricUnlock,
              "Lifecycle events must not rearm an existing manual lock")
        check(await biometrics.reads == readsBeforeManualLock,
              "Repeated automatic requests after Manual Lock never reach the biometric store")
        await reject(OathWalletError.locked, "Manual Lock also clears the vault, not just the screen") {
            _ = try await vault.unlockedProfile()
        }
        await session.unlockWithBiometrics()
        check(session.isUnlocked && session.security.biometricsEnabled,
              "An explicit Face ID button tap still unlocks and preserves enrollment")
        check(await biometrics.reads == readsBeforeManualLock + 1,
              "An explicit biometric tap performs exactly one credential read")
        await session.lock()
        await session.unlock(pin)
        check(session.isUnlocked, "The passcode must still unlock after Manual Lock")

        session.enteredBackground(delay: .immediately)
        check(session.isLocked && session.allowsAutomaticBiometricUnlock,
              "A new background lock restores automatic Face ID after explicit unlock")
        await session.unlockWithBiometrics(automatically: true)
        check(session.isUnlocked, "Automatic Face ID still opens a normal background lock")

        // An OS reply can arrive after cancellation; it must not override a
        // newer manual lock or start another prompt when the scene reactivates.
        session.enteredBackground(delay: .immediately)
        await biometrics.pauseNextRead()
        let pendingAutomaticUnlock = Task { await session.unlockWithBiometrics(automatically: true) }
        for _ in 0..<400 where !(await biometrics.isWaiting) { try await Task.sleep(for: .milliseconds(5)) }
        check(await biometrics.isWaiting, "Automatic biometric regression reached its suspended reply")
        await session.lock()
        await biometrics.releaseRead()
        await pendingAutomaticUnlock.value
        check(session.isLocked && !session.busy && session.notice == nil,
              "A late successful biometric reply cannot undo a newer manual lock")
        let readsAfterCancelledUnlock = await biometrics.reads
        await session.unlockWithBiometrics(automatically: true)
        check(await biometrics.reads == readsAfterCancelledUnlock,
              "A cancelled automatic reply cannot rearm automatic prompting")
        await reject(OathWalletError.locked, "A cancelled automatic unlock leaves the vault locked") {
            _ = try await vault.unlockedProfile()
        }

        let coldBiometricSession = OathWalletSession(vault: OathWalletVault(
            storage: storage, biometricStore: biometrics, database: db))
        await coldBiometricSession.load()
        check(coldBiometricSession.isLocked && coldBiometricSession.allowsAutomaticBiometricUnlock,
              "A fresh process retains normal automatic Face ID eligibility")
        await coldBiometricSession.unlockWithBiometrics(automatically: true)
        check(coldBiometricSession.isUnlocked, "Cold launch still authenticates automatically with enrolled biometrics")
        await coldBiometricSession.lock()
        await session.unlock(pin)
        check(session.isUnlocked, "Passcode remains available after the cancelled automatic attempt")
        check(OathLockDelay(settings: [:]) == .immediately, "Missing lock-delay setting defaults to Immediately")
        check(OathLockDelay(settings: [OathLockDelay.settingKey: "bad"]) == .immediately, "Invalid delay fails closed")
        check(OathLockDelay(settings: [OathLockDelay.settingKey: "-1"]) == .immediately, "Unsupported delay fails closed")
        let start = ContinuousClock.now
        for delay in OathLockDelay.allCases {
            var policy = OathAutoLockPolicy()
            policy.leave(delay: delay, now: start)
            if delay != .immediately {
                check(!policy.requiresLock(now: start.advanced(by: .seconds(delay.rawValue - 1))), "Grace must last until its exact deadline")
            }
            check(policy.requiresLock(now: start.advanced(by: .seconds(delay.rawValue))), "Each deadline must lock at its boundary")
            policy.leave(delay: .tenMinutes, now: start.advanced(by: .seconds(30)))
            check(policy.deadline == start.advanced(by: .seconds(delay.rawValue)), "Duplicate lifecycle events cannot extend grace")
            policy.reset()
            check(!policy.requiresLock(now: start.advanced(by: .seconds(900))), "Returning within grace must clear the old deadline")
        }
        await reject(OathWalletError.wrongPasscode, "Wrong current PIN cannot authorize changes") {
            _ = try await vault.authorizeSecurityChange(digits: replacement)
        }
        await reject(OathWalletError.locked, "Changing PIN needs fresh authorization") {
            try await vault.setPasscode(replacement, authorization: nil)
        }
        let cancelled = try await vault.authorizeSecurityChange(digits: pin)
        await vault.cancelSecurityAuthorization(cancelled)
        await reject(OathWalletError.locked, "Cancelled authorization cannot disable PIN") {
            try await vault.setPasscode(nil, authorization: cancelled)
        }

        let model = OathSecurityModel(session: session)
        model.begin(.changePasscode)
        check(model.phase == .verify, "Change PIN must first show current-PIN verification")
        model.verify(pin, strings: .current)
        for _ in 0..<1_000 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
        check(model.phase == .newPasscode && model.authorization != nil, "Only verified PIN can advance to new PIN entry")
        let enrollmentsBeforeChange = await biometrics.enrollmentRequests
        try await OathSecurityPasscodeStore(session: session, authorization: model.authorization).save(replacement)
        let preserved = await OathSecurityBiometrics(session: session, shouldEnroll: model.enrollBiometricsAfterPasscode).enableIfAvailable()
        check(preserved == .unavailable && !model.enrollBiometricsAfterPasscode,
              "Changing a PIN preserves the existing biometric preference")
        check(await biometrics.enrollmentRequests == enrollmentsBeforeChange, "Changing PIN does not prompt to enroll again")
        model.completed()
        check(model.phase == .idle && model.authorization == nil, "Completed PIN flow discards its authorization")
        check(try await CredentialIdentity.matches(vault.biometricCredential(), original), "PIN change must preserve enrolled Face ID key")
        let sealed = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
        check(sealed.version == 3 && sealed.protection?.deviceKey == nil, "New PIN wraps the key without persisting it in plaintext")
        check(Set(try sealed.openContents(using: sealed.key(for: replacement)).wallets.map { $0.id.uuidString }) == members,
              "PIN rotation must retain every wallet")
        await session.lock()
        await session.unlock(pin)
        check(session.isLocked && session.notice == .unlockIncorrect, "Old PIN must stop opening the vault")
        await session.unlock(replacement)
        check(session.isUnlocked && Set(session.wallets.map(\.id)) == members, "New PIN opens the unchanged wallet set")
        check(session.portfolio?.wallet.name == "Security fixture" && session.portfolio?.wallet.colorHex == "DF438D",
              "Security changes must preserve names, colors and selection")
        await session.lock()
        await session.unlockWithBiometrics()
        check(session.isUnlocked, "Existing biometric credential still opens after PIN change")

        // A failed atomic Keychain replacement must retain the working old PIN.
        let authorization = try await vault.authorizeSecurityChange(digits: replacement)
        let beforeFailure = try storage.read("vault-v1")
        storage.rejectNextUpdate()
        await reject(OathWalletError.unavailable, "Failed write must not report a committed PIN") {
            try await vault.setPasscode(pin, authorization: authorization)
        }
        check(try storage.read("vault-v1") == beforeFailure, "Failed replacement leaves the entire old encrypted record intact")
        await session.lock()
        await session.unlock(replacement)
        check(session.isUnlocked, "Existing PIN remains usable after write failure")
        await reject(OathWalletError.locked, "Locking revokes pending security authorization") {
            try await vault.setPasscode(nil, authorization: authorization)
        }

        model.disableBiometrics()
        for _ in 0..<400 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
        check(session.security == .init(passcodeEnabled: true, biometricsEnabled: false), "Face ID may be disabled independently of PIN")
        check(await biometrics.credential == nil, "Disabling Face ID removes its protected key")
        // Even a stale credential returned by the OS cannot bypass opt-out.
        await biometrics.enroll(original)
        let reads = await biometrics.reads
        await reject(OathBiometricCredentialError.missing, "Disabled Face ID must never authorize recovery words") {
            _ = try await vault.recoveryWordsWithBiometrics(walletID: root.uuidString, reason: "Synthetic test")
        }
        check(await biometrics.reads == reads, "Disabled Face ID must not prompt anywhere")
        access.begin(reason: "Synthetic passcode-only entry")
        try await settleAccess()
        let passcodeOnlyReads = await biometrics.reads
        check(access.phase == .passcode && passcodeOnlyReads == reads,
              "Disabled Face ID opens passcode entry without a biometric read")
        access.submit(replacement)
        try await settleAccess()
        check(access.isAuthorized, "Passcode-only Security entry succeeds with the correct PIN")
        access.cancel()
        await session.lock()
        await session.unlockWithBiometrics()
        check(session.isLocked && session.notice == nil, "Automatic or manual Face ID cannot bypass an explicit disable")
        await session.unlock(replacement)
        check(session.isUnlocked, "PIN remains available with Face ID disabled")
        await biometrics.allowEnrollment()
        let requestsBeforeToggle = await biometrics.enrollmentRequests
        let attemptsBeforeToggle = try storage.read("unlock-attempts-v1")
        model.enableBiometrics(strings: .current)
        check(model.phase == .idle && model.busy && model.authorization == nil,
              "Face ID toggle goes directly to OS enrollment without current-PIN verification")
        model.enableBiometrics(strings: .current)
        for _ in 0..<400 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
        check(session.security.biometricsEnabled && !model.busy && model.notice == nil,
              "A fresh biometric match and stored key enable Face ID")
        check(await biometrics.enrollmentRequests == requestsBeforeToggle + 1, "Duplicate Face ID toggles cannot duplicate prompts")
        check(try storage.read("unlock-attempts-v1") == attemptsBeforeToggle, "Enabling Face ID never verifies a PIN")
        await biometrics.failEnrollmentProbe(true)
        let probed = try await vault.securityState()
        check(probed.passcodeEnabled && !probed.biometricsEnabled, "Unavailable enrollment metadata must keep PIN available")
        await biometrics.failEnrollmentProbe(false)

        await biometrics.pauseNextEnrollment()
        let enrollment = Task { try await vault.enableBiometrics(strings: .current) }
        for _ in 0..<400 where !(await biometrics.isEnrollmentWaiting) { try await Task.sleep(for: .milliseconds(5)) }
        check(await biometrics.isEnrollmentWaiting, "Enrollment fixture reached its suspended reply")
        try await vault.disableBiometrics()
        await biometrics.releaseEnrollment()
        await reject(OathWalletError.locked, "A late enrollment response cannot reverse Face ID disable") { _ = try await enrollment.value }
        check(try await !vault.securityState().biometricsEnabled, "Biometric opt-out survives a late OS save")
        try await session.refreshSecurity()

        for result: OathBiometricSetupResult in [.unavailable, .failed(kind: .faceID, reason: .cancelled),
                                                .failed(kind: .faceID, reason: .notRecognized),
                                                .failed(kind: .faceID, reason: .storage)] {
            await biometrics.returnNextEnrollment(result)
            model.enableBiometrics(strings: .current)
            for _ in 0..<400 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
            check(session.security.passcodeEnabled && !session.security.biometricsEnabled && !model.busy,
                  "Unavailable, rejected, cancelled or unsaved Face ID never enables its toggle")
            check(model.phase == .idle, "Failed Face ID does not push the current-PIN screen")
            if case .failed(_, .cancelled) = result { check(model.notice == nil, "Not Now dismisses enrollment quietly") }
            model.cancel()
        }

        await biometrics.pauseNextEnrollment()
        model.enableBiometrics(strings: .current)
        for _ in 0..<400 where !(await biometrics.isEnrollmentWaiting) { try await Task.sleep(for: .milliseconds(5)) }
        check(await biometrics.isEnrollmentWaiting, "Direct enrollment waits for an OS reply")
        model.cancel()
        await biometrics.releaseEnrollment()
        try await Task.sleep(for: .milliseconds(50))
        try await session.refreshSecurity()
        check(!session.security.biometricsEnabled && model.phase == .idle && !model.busy,
              "Leaving Security cancels enrollment even if a successful OS reply arrives later")

        await biometrics.pauseNextEnrollment()
        let lockingEnrollment = Task { try await vault.enableBiometrics(strings: .current) }
        for _ in 0..<400 where !(await biometrics.isEnrollmentWaiting) { try await Task.sleep(for: .milliseconds(5)) }
        check(await biometrics.isEnrollmentWaiting, "Enrollment reached lock race")
        await session.lock()
        await biometrics.releaseEnrollment()
        do { _ = try await lockingEnrollment.value; preconditionFailure("Locked enrollment must fail") }
        catch { check(error is CancellationError, "A lock rejects the pending biometric enrollment") }
        await session.unlock(replacement)
        check(session.isUnlocked && !session.security.biometricsEnabled, "Late enrollment cannot re-enable Face ID after locking")

        await biometrics.pauseNextEnrollment()
        let failedEnrollmentWrite = Task { try await vault.enableBiometrics(strings: .current) }
        for _ in 0..<400 where !(await biometrics.isEnrollmentWaiting) { try await Task.sleep(for: .milliseconds(5)) }
        check(await biometrics.isEnrollmentWaiting, "Enrollment reached its final persistence check")
        storage.rejectNextUpdate()
        await biometrics.releaseEnrollment()
        await reject(OathWalletError.unavailable, "Failed preference commit must not enable Face ID") { _ = try await failedEnrollmentWrite.value }
        check(try await !vault.securityState().biometricsEnabled, "Saved biometric key alone cannot bypass a failed enable commit")

        let offAuthorization = try await vault.authorizeSecurityChange(digits: replacement)
        try await vault.setPasscode(nil, authorization: offAuthorization)
        try await session.refreshSecurity()
        check(session.security == .init(passcodeEnabled: false, biometricsEnabled: false), "Disabling PIN must always disable Face ID")
        let unprotectedReads = await biometrics.reads
        access.begin(reason: "Synthetic unprotected entry")
        try await settleAccess()
        let readsAfterUnprotectedEntry = await biometrics.reads
        check(access.isAuthorized && readsAfterUnprotectedEntry == unprotectedReads,
              "Security remains accessible without a prompt when both protections are off")
        access.cancel()
        let noPIN = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
        let oldKey = try JSONDecoder().decode(CredentialIdentity.self, from: original).key
        await reject(OathWalletError.wrongPasscode, "Removing PIN rotates the old biometric payload key") {
            _ = try noPIN.openContents(using: SymmetricKey(data: oldKey))
        }
        check(noPIN.protection?.wrappedKey == nil && noPIN.protection?.deviceKey?.count == 32,
              "Disabled mode uses the device-protected Keychain key")
        await reject(OathWalletError.locked, "Disabled mode cannot mint new biometric credentials") { _ = try await vault.biometricCredential() }
        let revealReads = await biometrics.reads
        let words = try await vault.recoveryWordsWithBiometrics(walletID: root.uuidString, reason: "Synthetic test")
        check(words == OathMnemonicValidator.words(in: phrase.phrase), "Recovery disclosure works when both protections are explicitly off")
        let account = try await vault.privateKeyAccounts(walletID: other).first!
        _ = try await vault.privateKeyWithBiometrics(walletID: other, accountID: account.id, reason: "Synthetic test")
        check(await biometrics.reads == revealReads, "Disabled protection must not prompt for phrase or private-key disclosure")
        session.enteredBackground(delay: .immediately)
        await session.lock()
        check(session.isUnlocked, "Manual and background lock must not create an unreachable PIN screen when PIN is disabled")
        let added = try await session.addWallet(requestID: UUID())
        let allMembers = members.union([added])
        await vault.lock()
        let restartedVault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let restarted = OathWalletSession(vault: restartedVault)
        await restarted.load()
        check(restarted.isUnlocked && Set(restarted.wallets.map(\.id)) == allMembers,
              "Cold launch without a PIN restores all wallets, including later additions")
        check(await biometrics.reads == revealReads, "Passcode-disabled cold launch must not issue Face ID")

        let enabledModel = OathSecurityModel(session: restarted)
        enabledModel.enablePasscode()
        check(enabledModel.phase == .newPasscode && enabledModel.authorization == nil, "Enabling from device mode goes directly to new PIN setup")
        let automaticEnrollment = OathSecurityBiometrics(session: restarted, shouldEnroll: enabledModel.enrollBiometricsAfterPasscode)
        let setup = OathPasscodeSetupModel(store: OathSecurityPasscodeStore(session: restarted, authorization: nil),
            biometrics: automaticEnrollment, timing: .init(advance: .milliseconds(1), mismatch: .milliseconds(1)))
        let beforeSetup = await biometrics.enrollmentRequests
        enabledPIN.forEach { setup.enter(Int($0)) }
        for _ in 0..<400 where setup.step != .confirm { try await Task.sleep(for: .milliseconds(5)) }
        check(setup.step == .confirm && setup.acceptsInput, "Settings passcode setup advances to confirmation")
        check(await biometrics.enrollmentRequests == beforeSetup, "Face ID waits until confirmation and save")
        await biometrics.pauseNextEnrollment()
        enabledPIN.forEach { setup.enter(Int($0)) }
        for _ in 0..<400 where !(await biometrics.isEnrollmentWaiting) { try await Task.sleep(for: .milliseconds(5)) }
        check(setup.phase == .enablingBiometrics && restarted.security.passcodeEnabled && !restarted.security.biometricsEnabled,
              "Confirmed passcode is saved before automatic Face ID enrollment starts")
        check(await biometrics.enrollmentRequests == beforeSetup + 1, "New passcode automatically requests Face ID exactly once")
        await biometrics.releaseEnrollment()
        for _ in 0..<400 where setup.phase != .succeeded { try await Task.sleep(for: .milliseconds(5)) }
        enabledModel.completed()
        check(setup.phase == .succeeded && setup.biometricResult == .enabled(.faceID), "Successful biometric enrollment completes passcode setup")
        check(restarted.security == .init(passcodeEnabled: true, biometricsEnabled: true), "Re-enabling PIN enables Face ID after its fresh match")

        // Exercise the actual Settings adapter and confirmed-passcode save on
        // cancellation, failure and unavailable hardware, not just a mock model.
        for result: OathBiometricSetupResult in [.unavailable, .failed(kind: .faceID, reason: .cancelled),
                                                .failed(kind: .faceID, reason: .notRecognized)] {
            let disable = try await restartedVault.authorizeSecurityChange(digits: enabledPIN)
            try await restartedVault.setPasscode(nil, authorization: disable)
            try await restarted.refreshSecurity()
            enabledModel.enablePasscode()
            let declinedSetup = OathPasscodeSetupModel(
                store: OathSecurityPasscodeStore(session: restarted, authorization: nil),
                biometrics: OathSecurityBiometrics(session: restarted, shouldEnroll: enabledModel.enrollBiometricsAfterPasscode),
                timing: .init(advance: .milliseconds(1), mismatch: .milliseconds(1)))
            await biometrics.returnNextEnrollment(result)
            let beforeDeclined = await biometrics.enrollmentRequests
            enabledPIN.forEach { declinedSetup.enter(Int($0)) }
            for _ in 0..<400 where declinedSetup.step != .confirm { try await Task.sleep(for: .milliseconds(5)) }
            enabledPIN.forEach { declinedSetup.enter(Int($0)) }
            for _ in 0..<400 where declinedSetup.phase != .succeeded && declinedSetup.phase != .biometricsFailed {
                try await Task.sleep(for: .milliseconds(5))
            }
            check(await biometrics.enrollmentRequests == beforeDeclined + 1, "Confirmed PIN automatically attempts enrollment even when it is declined")
            check(restarted.security == .init(passcodeEnabled: true, biometricsEnabled: false),
                  "Declined or unavailable Face ID keeps the saved passcode enabled and Face ID off")
            if result == .unavailable {
                check(declinedSetup.phase == .succeeded, "Unavailable hardware completes with passcode protection")
            } else {
                check(declinedSetup.phase == .biometricsFailed, "Enrollment failure offers the same recovery as onboarding")
                declinedSetup.continueWithPasscode()
                check(declinedSetup.phase == .succeeded, "The user can finish with the already saved passcode")
            }
            enabledModel.completed()
        }
        let secured = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
        await reject(OathWalletError.wrongPasscode, "Enabling PIN revokes the previous device-mode payload key") {
            _ = try secured.openContents(using: noPIN.deviceKey())
        }
        let cold = OathWalletSession(vault: OathWalletVault(storage: storage, biometricStore: biometrics, database: db))
        await cold.load()
        check(cold.isLocked, "Cold launch always asks for authentication when PIN protection is enabled")
        await cold.unlock(enabledPIN)
        check(cold.isUnlocked && Set(cold.wallets.map(\.id)) == allMembers, "Re-enabled PIN opens the full saved vault")
        for delay in [OathLockDelay.oneMinute, .fiveMinutes, .tenMinutes] {
            let now = ContinuousClock.now
            cold.enteredBackground(delay: delay, now: now)
            cold.enteringForeground(now: now.advanced(by: .seconds(delay.rawValue - 1)))
            check(cold.isUnlocked, "Foreground within selected grace must retain the current screen")
            cold.enteredBackground(delay: delay, now: now)
            cold.enteringForeground(now: now.advanced(by: .seconds(delay.rawValue)))
            check(cold.isLocked, "Foreground at each deadline locks synchronously before exposing content")
            check(cold.allowsAutomaticBiometricUnlock, "Every expired lock delay permits automatic authentication")
            await cold.unlock(enabledPIN)
            check(cold.isUnlocked, "Expired timer lock still accepts the current PIN")
        }
        cold.enteredBackground(delay: .immediately)
        check(cold.isLocked, "Default immediately policy locks synchronously on background")
        await cold.unlock(enabledPIN)
        cold.enteredBackground(delay: .tenMinutes)
        await cold.lock()
        check(cold.isLocked, "Manual Lock always overrides an active grace period")
        await cold.unlock(enabledPIN)
        cold.enteringForeground()
        let edit = OathSecurityModel(session: cold)
        edit.begin(.disablePasscode)
        edit.verify(enabledPIN, strings: .current)
        edit.cancel()
        try await Task.sleep(for: .milliseconds(50))
        check(edit.phase == .idle && cold.security.passcodeEnabled, "Leaving before verification finishes must cancel disable")
        await cold.lock()

        // Reject malformed protection instead of treating it as unlocked mode.
        var malformed = secured
        malformed.protection = .init(wrappedKey: secured.protection?.wrappedKey, deviceKey: Data(repeating: 1, count: 32))
        await reject(OathWalletError.corruptVault, "An envelope cannot advertise both protection modes") { _ = try malformed.deviceKey() }
        malformed.protection = .init(wrappedKey: nil, deviceKey: Data(repeating: 1, count: 31))
        await reject(OathWalletError.corruptVault, "Malformed device keys must fail closed") { _ = try malformed.deviceKey() }
        print("Passed \(checks) targeted security checks (synthetic credentials, host clock boundaries and production vault/session).")
        return checks
    }
}

private actor ResetFixtureEnvironment: OathResetEnvironment {
    var failErase = false
    private(set) var suspensions = 0
    private(set) var erasures = 0
    private(set) var reopened = 0
    func failNextErase() { failErase = true }
    func suspend() { suspensions += 1 }
    func eraseLocalFiles() throws {
        erasures += 1
        if failErase { failErase = false; throw CocoaError(.fileWriteNoPermission) }
    }
    func reopen() { reopened += 1 }
    func eraseEmptyWalletFiles() throws { try eraseLocalFiles() }
}

private final class ResetKeyFixture: OathInstallationKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func read() throws -> Data? { lock.withLock { data } }
    func write(_ data: Data) throws { lock.withLock { self.data = data } }
}

private struct ResetCredentialFixture: OathInstallationCredentialClearing {
    func clear() throws { }
}

extension CheckMultiWallet {
    @MainActor static func checkReset() async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func rejects(_ message: String, _ operation: () async throws -> Void) async {
            do { try await operation(); preconditionFailure(message) } catch { checks += 1 }
        }
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<500 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("Reset fixture did not finish")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OathResetHost-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try await OathDatabase.open(at: directory.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let pin: [UInt8] = [1, 2, 8, 4, 7, 3]
        let storage = WalletMemory(), biometrics = MemoryBiometrics(), environment = ResetFixtureEnvironment()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db, resetEnvironment: environment)
        try await vault.create(digits: pin, importing: nil)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()
        _ = try await session.addWallet(requestID: UUID())
        let members = Set(session.wallets.map(\.id))
        try await db.setSetting("language", value: "ar")
        try await db.setSetting("security.lockDelay", value: "300")
        try await db.setSetting("currency", value: "USD")
        try await db.savePrices([.init(assetID: "bitcoin:native", currency: "USD", value: "12.34", observedAt: 1, source: "fixture")])

        let model = OathResetModel(session: session)
        model.begin(reason: "Synthetic reset")
        try await wait { model.phase == .passcode }
        check(try await db.pendingWalletReset() == nil, "Opening reset must not record destructive intent")
        model.submit([0,0,0,0,0,0])
        try await wait { !model.busy }
        check(model.phase == .passcode && model.notice == .unlockIncorrect, "Wrong PIN cannot open the warning")
        model.submit(pin)
        try await wait { model.phase == .warning }
        let beforeConfirm = try await db.pendingWalletReset()
        let stillExists = try await vault.exists()
        check(beforeConfirm == nil && stillExists, "Authorization alone erases nothing")
        model.cancel()
        check(Set(session.wallets.map(\.id)) == members, "Leaving warning keeps all wallets")
        await rejects("Unknown reset capability must be rejected") { try await vault.beginReset(authorization: UUID()) }
        let now = ContinuousClock.now
        let expired = try await vault.authorizeReset(digits: pin, reason: "", now: now)
        await rejects("Expired capability must be rejected") {
            try await vault.beginReset(authorization: expired, now: now.advanced(by: .seconds(121)))
        }
        let revoked = try await vault.authorizeReset(digits: pin, reason: "")
        await vault.cancelResetAuthorization(revoked)
        await rejects("Cancelled capability must be rejected") { try await vault.beginReset(authorization: revoked) }
        let locked = try await vault.authorizeReset(digits: pin, reason: "")
        await session.lock()
        await rejects("Lock must revoke reset capability") { try await vault.beginReset(authorization: locked) }
        await session.unlock(pin)

        await biometrics.enroll(try await vault.biometricCredential())
        try await session.refreshSecurity()
        let previousReads = await biometrics.reads
        model.begin(reason: "Synthetic reset")
        try await wait { model.phase == .warning }
        check(await biometrics.reads == previousReads + 1, "Enrolled Face ID must freshly authenticate before warning")
        model.cancel()
        await biometrics.pauseNextRead()
        model.begin(reason: "Synthetic reset")
        for _ in 0..<500 { if await biometrics.isWaiting { break }; try await Task.sleep(for: .milliseconds(10)) }
        model.cancel()
        await biometrics.releaseRead()
        try await Task.sleep(for: .milliseconds(30))
        check(model.phase == .idle && !model.busy, "Late Face ID reply cannot reopen the reset warning")
        check(try await db.pendingWalletReset() == nil, "Cancelled biometrics must not commit a reset")

        // Key deletion fails after confirmed intent; nothing may use the vault
        // and a new process must resume the same journal without fresh auth.
        storage.rejectNextErase()
        let confirmed = try await vault.authorizeReset(digits: pin, reason: "")
        try await session.resetApp(authorization: confirmed)
        check(session.resetting && session.resetFailed && !session.isUnlocked, "Failed erase stays blocked with retry")
        check(session.wallets.isEmpty && session.portfolio == nil && session.displayedProfile == nil, "Reset discards displayed wallet metadata")
        check(!session.allowsBackgroundWalletWork, "Failed reset cannot restart background wallet services")
        check(try await db.pendingWalletReset() != nil, "Partial reset retains durable intent")
        await rejects("Resetting vault cannot be unlocked") { _ = try await vault.unlock(digits: pin) }
        let nextVault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db, resetEnvironment: environment)
        let nextSession = OathWalletSession(vault: nextVault)
        await nextSession.load()
        try await wait { nextSession.presentsOnboarding || nextSession.resetFailed }
        check(nextSession.presentsOnboarding && !nextSession.isUnlocked, "Cold launch finishes confirmed reset before onboarding")
        let vaultExists = try await nextVault.exists()
        let walletRows = try await db.wallets()
        check(!vaultExists && walletRows.isEmpty, "Every vault member and ledger wallet is removed")
        check(try await db.pendingWalletReset() == nil, "Journal clears only after successful recovery")
        check(try await !biometrics.hasEnrollment(), "Reset removes biometric credentials")
        check(try storage.read("unlock-attempts-v1") == nil, "Reset removes persisted PIN attempt counters")
        let settings = try await db.settings()
        check(settings["language"] == "ar" && settings["security.lockDelay"] == "300", "App preferences survive reset")
        check(settings["activeWalletID"] == nil, "Deleted wallet selection is removed")
        check(await environment.reopened == 1, "Background services reopen only after all reset steps succeed")
        try await nextVault.create(digits: pin, importing: nil)
        await nextSession.finishedSetup()
        check(nextSession.isUnlocked && nextSession.wallets.count == 1, "Creating a new wallet after reset works")
        check(!members.contains(nextSession.wallets[0].id), "Reset must never resurrect an old wallet")
        check(nextSession.portfolio?.holdings.first { $0.assetID == "bitcoin:native" }?.price == "12.34", "Cached prices survive into the next wallet")

        // Device-only protection skips both credential prompts, but still
        // requires the warning and explicit confirmation.
        let change = try await nextVault.authorizeSecurityChange(digits: pin)
        try await nextVault.setPasscode(nil, authorization: change)
        try await nextSession.refreshSecurity()
        let unsecured = OathResetModel(session: nextSession)
        let readCount = await biometrics.reads
        unsecured.begin(reason: "Synthetic reset")
        try await wait { unsecured.phase == .warning }
        check(await biometrics.reads == readCount, "Security-disabled reset never prompts for biometrics")
        check(try await db.pendingWalletReset() == nil, "Security-disabled reset still requires confirmation")
        await environment.failNextErase()
        unsecured.confirm(); unsecured.confirm()
        try await wait { nextSession.resetFailed }
        check(nextSession.resetting && !nextSession.presentsOnboarding, "Post-database file failure cannot expose onboarding")
        check(try await db.pendingWalletReset() != nil, "File cleanup failure retains journal")
        await nextSession.retryReset()
        check(nextSession.presentsOnboarding && !nextSession.resetting, "Explicit retry completes idempotent reset")

        let installation = OathInstallationSecurity(keys: ResetKeyFixture(), credentials: ResetCredentialFixture())
        let ciphertext = try installation.seal(Data("synthetic fixture".utf8), context: "test")
        try installation.reset()
        await rejects("Old ciphertext must be unusable after outer-key rotation") { _ = try installation.open(ciphertext, context: "test") }
        let fresh = try installation.seal(Data([1,2,3]), context: "test")
        check(try installation.open(fresh, context: "test") == Data([1,2,3]), "New installation key remains usable")

        let outside = directory.appendingPathComponent("outside")
        let owned = directory.appendingPathComponent("owned", isDirectory: true)
        try Data([1]).write(to: outside)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: owned.appendingPathComponent("link"), withDestinationURL: outside)
        try OathResetFileCleanup.empty(owned)
        check(try Data(contentsOf: outside) == Data([1]), "Cleanup unlinks symlinks without deleting their target")
        check(FileManager.default.fileExists(atPath: owned.path), "Cleanup preserves the system-owned directory itself")
        try OathResetFileCleanup.remove([owned.appendingPathComponent("absent")])
        checks += 1
        print("Passed \(checks) reset checks (synthetic stores, interrupted cleanup, authorization, preferences and key rotation).")
        return checks
    }
}

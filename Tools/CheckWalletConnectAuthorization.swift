import Foundation
import OathDatabase
import OathAnkr

/// Real vault and imported-key signer; synthetic biometric store, public key fixture.
@main struct CheckWalletConnectAuthorization {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ reason: String) { precondition(value, reason); checks += 1 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathWCAuth-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: WalletMemory(), biometricStore: biometrics, database: db)
        let key = Data(repeating: 0, count: 31) + Data([1]), pin: [UInt8] = [1,2,3,4,5,6]
        try await vault.create(digits: pin, importing: nil, privateKey: .init(bytes: key, networks: [.ethereum]))
        let profile = try await vault.unlockedProfile()
        let account = try await db.accounts(walletID: profile.id.uuidString).first!
        let message = Data("Oath scanner authorization fixture".utf8)
        func sign(_ digits: [UInt8]?) async throws -> String {
            try await vault.signWalletConnectMessage(walletID: profile.id.uuidString, accountID: account.id, message: message, digits: digits, reason: "Test")
        }
        do { _ = try await sign([9,9,9,9,9,9]); preconditionFailure("Wrong PIN signed") }
        catch { check(error as? OathWalletError == .wrongPasscode, "Wrong PIN rejected") }
        do { _ = try await sign(nil); preconditionFailure("Missing biometric enrollment signed") }
        catch { check(error is OathBiometricCredentialError, "Missing biometrics routes to passcode") }
        let signature = try await sign(pin)
        check(signature == (try OathWalletConnectMessage.sign(message, key: key, account: account.address)), "Vault signature matches reviewed bytes")
        do {
            _ = try await vault.signWalletConnectMessage(walletID: "different-wallet", accountID: account.id, message: message, digits: pin, reason: "Test")
            preconditionFailure("Cross-wallet request signed")
        } catch { check(error as? OathWalletError == .locked, "Cross-wallet identity rejected") }
        await biometrics.enroll(try await vault.biometricCredential())
        check(try await sign(nil) == signature, "Biometric authorization signs identical message")
        let typedJSON = Data("""
        {"types":{"EIP712Domain":[{"name":"chainId","type":"uint256"}],"Note":[{"name":"contents","type":"string"}]},"primaryType":"Note","domain":{"chainId":1},"message":{"contents":"Oath typed authorization fixture"}}
        """.utf8)
        let typed = try WalletConnectTypedData(json: typedJSON, chainID: 1, account: account.address)
        func signTyped(_ digits: [UInt8]?) async throws -> String {
            try await vault.signWalletConnectTypedData(walletID: profile.id.uuidString, accountID: account.id,
                data: typed, digits: digits, reason: "Test")
        }
        check(try await signTyped(pin) == typed.sign(privateKey: key, account: account.address), "Typed request signs exactly the independent reviewed digest")
        do { _ = try await signTyped([9,9,9,9,9,9]); preconditionFailure("Wrong PIN signed typed data") }
        catch { check(error as? OathWalletError == .wrongPasscode, "Typed data requires correct PIN") }
        do {
            _ = try await vault.signWalletConnectTypedData(walletID: "different-wallet", accountID: account.id, data: typed, digits: pin, reason: "Test")
            preconditionFailure("Cross-wallet typed request signed")
        } catch { check(error as? OathWalletError == .locked, "Typed signing rejects cross-wallet identity") }
        let wrongChain = try WalletConnectTypedData(json: Data(String(decoding: typedJSON, as: UTF8.self).replacingOccurrences(of: "\"chainId\":1", with: "\"chainId\":56").utf8), chainID: 56, account: account.address)
        do {
            _ = try await vault.signWalletConnectTypedData(walletID: profile.id.uuidString, accountID: account.id, data: wrongChain, digits: pin, reason: "Test")
            preconditionFailure("Wrong account network signed typed data")
        } catch { check(error as? WalletConnectTypedData.Failure == .wrongChain, "Typed signing binds account network") }
        await biometrics.pauseNextRead()
        let pending = Task { try await signTyped(nil) }
        for _ in 0..<200 { if await biometrics.isWaiting { break }; try await Task.sleep(for: .milliseconds(5)) }
        check(await biometrics.isWaiting, "Fresh biometric authorization requested")
        await vault.lock(); await biometrics.releaseRead()
        do { _ = try await pending.value; preconditionFailure("Locked vault accepted late signature") }
        catch { check(error is CancellationError || error as? OathWalletError == .locked, "Lock invalidates authorization") }
        do { _ = try await sign(pin); preconditionFailure("Locked vault signed") }
        catch { check(error as? OathWalletError == .locked, "Locked signing rejected") }
        do { _ = try await signTyped(pin); preconditionFailure("Locked vault signed typed data") }
        catch { check(error as? OathWalletError == .locked, "Locked typed signing rejected") }
        print("Passed \(checks) WalletConnect authorization host checks. Real vault/PIN/imported-key signer; simulated biometric storage. No app, user wallet, device or network used.")
    }
}

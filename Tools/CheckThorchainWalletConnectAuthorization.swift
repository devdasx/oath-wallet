import Foundation
import OathDatabase
import OathAnkr

/// Uses the production vault, passcode and imported-key signer. The biometric
/// store is a host fixture; this does not claim camera, device or relay coverage.
@main struct CheckThorchainWalletConnectAuthorization {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ reason: String) { precondition(value, reason); checks += 1 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ThorchainWCVault-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: WalletMemory(), biometricStore: biometrics, database: db)
        let pin: [UInt8] = [1,2,3,4,5,6]
        try await vault.create(digits: pin, importing: nil, privateKey: .init(bytes: Data(repeating: 7, count: 32), networks: [.thorchain]))
        let profile = try await vault.unlockedProfile()
        let walletID = profile.id.uuidString
        let account = try await db.accounts(walletID: walletID).first!
        let pub = try await vault.thorchainPublicKey(walletID: walletID, accountID: account.id)
        let other = try ThorchainSendCrypto.address(publicKey: ThorchainSendCrypto.publicKey(privateKey: Data(repeating: 8, count: 32)), network: .mainnet)
        let doc: SolanaJSON = .object(["chain_id": .string("thorchain-1"), "account_number": .string("10"), "sequence": .string("0"), "fee": .object(["gas": .string("500000000"), "amount": .array([])]), "memo": .string("public test"), "msgs": .array([.object(["type": .string("thorchain/MsgSend"), "value": .object(["from_address": .string(account.address), "to_address": .string(other), "amount": .array([.object(["denom": .string("rune"), "amount": .string("1000")])])])])])])
        let request = try ThorchainWalletConnectRequest(method: "cosmos_signAmino", params: .object(["signerAddress": .string(account.address), "signDoc": doc]), sender: account.address, publicKey: pub)
        do { _ = try await vault.signThorchainWalletConnect(walletID: walletID, accountID: account.id, request: request, digits: [9,9,9,9,9,9], reason: "Test"); preconditionFailure("Wrong PIN signed") }
        catch { check(error as? OathWalletError == .wrongPasscode, "Wrong PIN rejected") }
        do { _ = try await vault.signThorchainWalletConnect(walletID: walletID, accountID: account.id, request: request, digits: nil, reason: "Test"); preconditionFailure("Missing biometrics signed") }
        catch { check(error is OathBiometricCredentialError, "Missing biometrics returns passcode fallback") }
        let signed = try await vault.signThorchainWalletConnect(walletID: walletID, accountID: account.id, request: request, digits: pin, reason: "Test")
        check(signed == (try request.sign(privateKey: Data(repeating: 7, count: 32))), "Production vault signs exact approved document")
        for (wallet, id) in [("other-wallet", account.id), (walletID, "other-account")] {
            do { _ = try await vault.signThorchainWalletConnect(walletID: wallet, accountID: id, request: request, digits: pin, reason: "Test"); preconditionFailure("Cross-account signed") }
            catch { check(error as? OathWalletError == .locked, "Cross-account request rejected") }
        }
        await biometrics.enroll(try await vault.biometricCredential())
        let biometric = try await vault.signThorchainWalletConnect(walletID: walletID, accountID: account.id, request: request, digits: nil, reason: "Test")
        check(biometric == signed, "Biometric authorization signs identical intent")
        await biometrics.pauseNextRead()
        let pending = Task { try await vault.signThorchainWalletConnect(walletID: walletID, accountID: account.id, request: request, digits: nil, reason: "Test") }
        for _ in 0..<200 {
            if await biometrics.isWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        check(await biometrics.isWaiting, "Biometric read entered")
        await vault.lock(); await biometrics.releaseRead()
        do { _ = try await pending.value; preconditionFailure("Locked vault signed") }
        catch { check(error is CancellationError || error as? OathWalletError == .locked, "Lock invalidates in-flight authorization") }
        do { _ = try await vault.signThorchainWalletConnect(walletID: walletID, accountID: account.id, request: request, digits: pin, reason: "Test"); preconditionFailure("Locked vault signed") }
        catch { check(error as? OathWalletError == .locked, "Locked signing rejected") }
        print("Passed \(checks) THORChain WalletConnect authorization checks; production vault and imported-key signing, host biometric fixture.")
    }
}

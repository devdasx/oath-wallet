import Foundation
import OathDatabase
import OathAnkr

/// Real production vault/passcode/journal and imported-key signer. Only the
/// OS biometric store and HD derivation are host fixtures; no app or network.
@main struct CheckThorchainSendAuthorization {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value:Bool,_ reason:String) { precondition(value,reason); checks += 1 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ThorchainVault-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage:WalletMemory(),biometricStore:biometrics,database:db)
        let pin:[UInt8] = [1,2,3,4,5,6]
        try await vault.create(digits:pin,importing:nil,privateKey:.init(bytes:Data(repeating:7,count:32),networks:[.thorchain]))
        let profile = try await vault.unlockedProfile()
        let account = try await db.accounts(walletID:profile.id.uuidString).first!
        let plan = ThorchainSendPlan(network:.mainnet,sender:account.address,recipient:try ThorchainSendCrypto.address(publicKey:ThorchainSendCrypto.publicKey(privateKey:Data(repeating:8,count:32)),network:.mainnet),reference:"native",publicKey:try ThorchainSendCrypto.publicKey(privateKey:Data(repeating:7,count:32)),decimals:8,
            requestedAmount:"1000",amount:"1000",assetBalance:"100000000",nativeBalance:"100000000",accountNumber:10,sequence:0,fee:2000000,height:100,timeoutHeight:130)
        let quote = OathThorchainQuote(walletID:profile.id.uuidString,accountID:account.id,assetID:"thorchain:native",plan:plan)
        let now = Date.now.timeIntervalSince1970
        try await db.saveDraft(.init(id:"send",walletID:quote.walletID,accountID:account.id,networkID:"thorchain",assetID:quote.assetID,idempotencyKey:"send",recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:now,updatedAt:now))
        try await db.queueThorchainSend(sendID:"send",plan:plan)
        do { _ = try await vault.signThorchainSend(sendID:"send",quote:quote,digits:[9,9,9,9,9,9],reason:"Test"); preconditionFailure("Wrong PIN signed") }
        catch { check(error as? OathWalletError == .wrongPasscode,"Wrong PIN rejected") }
        let unsigned = try await db.send("send"); check(unsigned?.signedPayload == nil,"Failed authentication persists no signature")
        do { _ = try await vault.signThorchainSend(sendID:"send",quote:quote,digits:nil,reason:"Test"); preconditionFailure("Missing biometrics signed") }
        catch { check(error is OathBiometricCredentialError,"Missing biometrics returns passcode fallback") }
        let signed = try await vault.signThorchainSend(sendID:"send",quote:quote,digits:pin,reason:"Test")
        try ThorchainSendCrypto.verify(signed,plan:plan); check(!signed.bytes.isEmpty,"Authenticated signature covers exact reviewed bytes")
        let wrong = OathThorchainQuote(walletID:"other-wallet",accountID:account.id,assetID:quote.assetID,plan:plan)
        do { _ = try await vault.signThorchainSend(sendID:"send",quote:wrong,digits:pin,reason:"Test"); preconditionFailure("Wrong wallet signed") }
        catch { check(error as? ThorchainSendError == .changed,"Cross-wallet request rejected") }
        await biometrics.enroll(try await vault.biometricCredential())
        let authenticated = try await vault.signThorchainSend(sendID:"send",quote:quote,digits:nil,reason:"Test")
        try ThorchainSendCrypto.verify(authenticated,plan:plan); check(authenticated.bytes == signed.bytes,"Biometrics authorize identical intent")
        await biometrics.pauseNextRead()
        let pending = Task { try await vault.signThorchainSend(sendID:"send",quote:quote,digits:nil,reason:"Test") }
        for _ in 0..<200 {
            if await biometrics.isWaiting { break }
            try await Task.sleep(for:.milliseconds(5))
        }
        check(await biometrics.isWaiting,"Biometric read entered")
        await vault.lock(); await biometrics.releaseRead()
        do { _ = try await pending.value; preconditionFailure("Locked vault accepted stale authorization") }
        catch { check(error is CancellationError || error as? OathWalletError == .locked,"Lock invalidates in-flight authorization") }
        do { _ = try await vault.signThorchainSend(sendID:"send",quote:quote,digits:pin,reason:"Test"); preconditionFailure("Locked vault signed") }
        catch { check(error as? OathWalletError == .locked,"Locked signing rejected") }
        print("Passed \(checks) Thorchain send authorization host checks. Production vault, PIN and imported-key signer; synthetic biometric store, no HD derivation, network, simulator or device.")
    }
}

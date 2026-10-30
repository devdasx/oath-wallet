import Foundation
import OathDatabase
import OathAnkr

/// Real production vault/passcode/journal and imported-key signer. Only the
/// OS biometric store and HD derivation are host fixtures; no app or network.
@main struct CheckArcSendAuthorization {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value:Bool,_ reason:String) { precondition(value,reason); checks += 1 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArcVault-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage:WalletMemory(),biometricStore:biometrics,database:db)
        let pin:[UInt8] = [1,2,3,4,5,6]
        try await vault.create(digits:pin,importing:nil,privateKey:.init(bytes:Data(repeating:7,count:32),networks:[.arc]))
        let profile = try await vault.unlockedProfile()
        let account = try await db.accounts(walletID:profile.id.uuidString).first!
        let plan = ArcSendPlan(network:.mainnet,sender:account.address.lowercased(),recipient:try ArcSendCrypto.address(privateKey:Data(repeating:8,count:32)),reference:"native",decimals:18,
            requestedAmount:"1000",amount:"1000",assetBalance:"1000000000000000000",nativeBalance:"1000000000000000000",nonce:0,gasLimit:21000,maxFeePerGas:41000000000,maxPriorityFeePerGas:1000000000,blockHeight:100)
        let quote = OathArcQuote(walletID:profile.id.uuidString,accountID:account.id,assetID:"arc:native",plan:plan)
        let now = Date.now.timeIntervalSince1970
        try await db.saveDraft(.init(id:"send",walletID:quote.walletID,accountID:account.id,networkID:"arc",assetID:quote.assetID,idempotencyKey:"send",recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:now,updatedAt:now))
        try await db.queueArcSend(sendID:"send",plan:plan)
        do { _ = try await vault.signArcSend(sendID:"send",quote:quote,digits:[9,9,9,9,9,9],reason:"Test"); preconditionFailure("Wrong PIN signed") }
        catch { check(error as? OathWalletError == .wrongPasscode,"Wrong PIN rejected") }
        let unsigned = try await db.send("send"); check(unsigned?.signedPayload == nil,"Failed authentication persists no signature")
        do { _ = try await vault.signArcSend(sendID:"send",quote:quote,digits:nil,reason:"Test"); preconditionFailure("Missing biometrics signed") }
        catch { check(error is OathBiometricCredentialError,"Missing biometrics returns passcode fallback") }
        let signed = try await vault.signArcSend(sendID:"send",quote:quote,digits:pin,reason:"Test")
        try ArcSendCrypto.verify(signed,plan:plan); check(!signed.bytes.isEmpty,"Authenticated signature covers exact reviewed bytes")
        let wrong = OathArcQuote(walletID:"other-wallet",accountID:account.id,assetID:quote.assetID,plan:plan)
        do { _ = try await vault.signArcSend(sendID:"send",quote:wrong,digits:pin,reason:"Test"); preconditionFailure("Wrong wallet signed") }
        catch { check(error as? ArcSendError == .changed,"Cross-wallet request rejected") }
        await biometrics.enroll(try await vault.biometricCredential())
        let authenticated = try await vault.signArcSend(sendID:"send",quote:quote,digits:nil,reason:"Test")
        try ArcSendCrypto.verify(authenticated,plan:plan); check(authenticated.bytes == signed.bytes,"Biometrics authorize identical intent")
        await biometrics.pauseNextRead()
        let pending = Task { try await vault.signArcSend(sendID:"send",quote:quote,digits:nil,reason:"Test") }
        for _ in 0..<200 {
            if await biometrics.isWaiting { break }
            try await Task.sleep(for:.milliseconds(5))
        }
        check(await biometrics.isWaiting,"Biometric read entered")
        await vault.lock(); await biometrics.releaseRead()
        do { _ = try await pending.value; preconditionFailure("Locked vault accepted stale authorization") }
        catch { check(error is CancellationError || error as? OathWalletError == .locked,"Lock invalidates in-flight authorization") }
        do { _ = try await vault.signArcSend(sendID:"send",quote:quote,digits:pin,reason:"Test"); preconditionFailure("Locked vault signed") }
        catch { check(error as? OathWalletError == .locked,"Locked signing rejected") }
        print("Passed \(checks) Arc send authorization host checks. Production vault, PIN and imported-key signer; synthetic biometric store, no HD derivation, network, simulator or device.")
    }
}

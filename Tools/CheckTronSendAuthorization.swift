import Foundation
import OathDatabase
import OathAnkr

/// Real production vault/passcode/journal and imported-key signer. Only the
/// OS biometric store and HD derivation are host fixtures; no app or network.
@main struct CheckTronSendAuthorization {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value:Bool,_ reason:String) { precondition(value,reason); checks += 1 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TronVault-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage:WalletMemory(),biometricStore:biometrics,database:db)
        let pin:[UInt8] = [1,2,3,4,5,6]
        try await vault.create(digits:pin,importing:nil,privateKey:.init(bytes:Data(repeating:7,count:32),networks:[.tron]))
        let profile = try await vault.unlockedProfile()
        let account = try await db.accounts(walletID:profile.id.uuidString).first!
        let ms=UInt64(Date.now.timeIntervalSince1970*1000)
        var plan = TronSendPlan(network:.mainnet,sender:account.address,recipient:try TronSendCrypto.address(privateKey:Data(repeating:8,count:32)),reference:"native",amount:"1000000",requestedAmount:"1000000",assetBalance:"100000000",decimals:6,nativeBalance:100000000,fee:1000,estimatedFee:100,feeLimit:0,energyPrice:100,bandwidthPrice:1000,blockID:"0000000000000064"+String(repeating:"a",count:48),blockNumber:100,timestamp:ms,expiration:ms+180000)
        let permissionMode=ProcessInfo.processInfo.environment["OATH_PERMISSION_AUTH"]=="1"
        if permissionMode {
            var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan)) as! [String:Any]
            object["amount"]="0";object["requestedAmount"]="0";object["feeLimit"]=1000000
            object["removal"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(TronPermissionRemoval(contract:plan.recipient,spender:plan.sender,expected:"123")))
            plan=try JSONDecoder().decode(TronSendPlan.self,from:JSONSerialization.data(withJSONObject:object))
        }
        let quote = OathTronQuote(walletID:profile.id.uuidString,accountID:account.id,assetID:"tron:native",plan:plan)
        let sendID=UUID().uuidString
        let now = Date.now.timeIntervalSince1970
        try await db.saveDraft(.init(id:sendID,walletID:quote.walletID,accountID:account.id,networkID:"tron",assetID:quote.assetID,idempotencyKey:sendID,recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:now,updatedAt:now))
        try await db.queueTronSend(sendID:sendID,plan:plan)
        do { _ = try await vault.signTronSend(sendID:sendID,quote:quote,digits:[9,9,9,9,9,9],reason:"Test"); preconditionFailure("Wrong PIN signed") }
        catch { check(error as? OathWalletError == .wrongPasscode,"Wrong PIN rejected") }
        let unsigned = try await db.send(sendID); check(unsigned?.signedPayload == nil,"Failed authentication persists no signature")
        do { _ = try await vault.signTronSend(sendID:sendID,quote:quote,digits:nil,reason:"Test"); preconditionFailure("Missing biometrics signed") }
        catch { check(error is OathBiometricCredentialError,"Missing biometrics returns passcode fallback") }
        let signed = try await vault.signTronSend(sendID:sendID,quote:quote,digits:pin,reason:"Test")
        try TronSendCrypto.verify(signed,plan:plan); check(!signed.bytes.isEmpty,"Authenticated signature covers exact reviewed bytes")
        let wrong = OathTronQuote(walletID:"other-wallet",accountID:account.id,assetID:quote.assetID,plan:plan)
        do { _ = try await vault.signTronSend(sendID:sendID,quote:wrong,digits:pin,reason:"Test"); preconditionFailure("Wrong wallet signed") }
        catch { check(error as? TronSendError == .changed,"Cross-wallet request rejected") }
        if permissionMode {
            let scope=try PermissionBatchScope.tron(sendID:sendID,walletID:quote.walletID,accountID:quote.accountID,plan:plan)
            let grant=try await vault.authorizePermissionBatch([scope],digits:pin,reason:"Test")
            let batchSigned=try await vault.signTronSend(sendID:sendID,quote:quote,digits:nil,reason:"",permissionAuthorization:grant)
            try TronSendCrypto.verify(batchSigned,plan:plan)
            check(!batchSigned.bytes.isEmpty,"Scoped batch signs exact removal without retaining PIN")
            do { _=try await vault.signTronSend(sendID:sendID,quote:quote,digits:nil,reason:"",permissionAuthorization:grant);preconditionFailure("Replayed grant") }
            catch { check(error as? PermissionError == .changed,"Batch item capability cannot be reused") }
            await vault.endPermissionBatch(grant)
        }
        await biometrics.enroll(try await vault.biometricCredential())
        let authenticated = try await vault.signTronSend(sendID:sendID,quote:quote,digits:nil,reason:"Test")
        try TronSendCrypto.verify(authenticated,plan:plan); check(authenticated.hash == signed.hash,"Biometrics authorize identical intent")
        await biometrics.pauseNextRead()
        let pending = Task { try await vault.signTronSend(sendID:sendID,quote:quote,digits:nil,reason:"Test") }
        for _ in 0..<200 {
            if await biometrics.isWaiting { break }
            try await Task.sleep(for:.milliseconds(5))
        }
        check(await biometrics.isWaiting,"Biometric read entered")
        await vault.lock(); await biometrics.releaseRead()
        do { _ = try await pending.value; preconditionFailure("Locked vault accepted stale authorization") }
        catch { check(error is CancellationError || error as? OathWalletError == .locked,"Lock invalidates in-flight authorization") }
        do { _ = try await vault.signTronSend(sendID:sendID,quote:quote,digits:pin,reason:"Test"); preconditionFailure("Locked vault signed") }
        catch { check(error as? OathWalletError == .locked,"Locked signing rejected") }
        if permissionMode {try await db.journalTronSignature(sendID:sendID,signed:signed);let removal=try await db.permissionRemoval(sendID:sendID);check(removal?.status=="pending","Authenticated removal is durable before broadcast")}
        print("Passed \(checks) Tron send authorization host checks. Production vault, PIN and imported-key signer; synthetic biometric store, no HD derivation, network, simulator or device.")
    }
}

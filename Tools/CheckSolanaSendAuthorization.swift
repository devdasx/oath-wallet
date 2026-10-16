import Foundation
import OathDatabase
import OathAnkr

/// Real production vault/passcode/journal and imported-key signer. Only the
/// OS biometric store and HD derivation are host fixtures; no app or network.
@main struct CheckSolanaSendAuthorization {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value:Bool,_ reason:String) { precondition(value,reason); checks += 1 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SolanaVault-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage:WalletMemory(),biometricStore:biometrics,database:db)
        let pin:[UInt8] = [1,2,3,4,5,6]
        try await vault.create(digits:pin,importing:nil,privateKey:.init(bytes:Data(repeating:7,count:32),networks:[.solana]))
        let profile = try await vault.unlockedProfile()
        let account = try await db.accounts(walletID:profile.id.uuidString).first!
        var plan = SolanaSendPlan(network:.mainnet,sender:account.address,recipient:try SolanaSendCrypto.address(privateKey:Data(repeating:8,count:32)),
            requestedAmount:1000000,amount:1000000,assetBalance:100000000,nativeBalance:100000000,blockhash:SolanaSendCrypto.encode(Data(repeating:3,count:32)),lastValidBlockHeight:100,slot:10,transactionFee:5000)
        let permissionMode=ProcessInfo.processInfo.environment["OATH_PERMISSION_AUTH"]=="1"
        if permissionMode {
            var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan)) as! [String:Any]
            object["amount"]=0;object["requestedAmount"]=0
            object["removal"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(SolanaPermissionRemoval(account:plan.recipient,mint:SolanaSendCrypto.encode(Data(repeating:3,count:32)),program:SolanaIdentity.tokenProgram,delegate:SolanaSendCrypto.encode(Data(repeating:4,count:32)),amount:123)))
            plan=try JSONDecoder().decode(SolanaSendPlan.self,from:JSONSerialization.data(withJSONObject:object))
        }
        let quote = OathSolanaQuote(walletID:profile.id.uuidString,accountID:account.id,assetID:"solana:native",plan:plan)
        let sendID=UUID().uuidString
        let now = Date.now.timeIntervalSince1970
        try await db.saveDraft(.init(id:sendID,walletID:quote.walletID,accountID:account.id,networkID:"solana",assetID:quote.assetID,idempotencyKey:sendID,recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:now,updatedAt:now))
        try await db.queueSolanaSend(sendID:sendID,plan:plan)
        do { _ = try await vault.signSolanaSend(sendID:sendID,quote:quote,digits:[9,9,9,9,9,9],reason:"Test"); preconditionFailure("Wrong PIN signed") }
        catch { check(error as? OathWalletError == .wrongPasscode,"Wrong PIN rejected") }
        let unsigned = try await db.send(sendID); check(unsigned?.signedPayload == nil,"Failed authentication persists no signature")
        do { _ = try await vault.signSolanaSend(sendID:sendID,quote:quote,digits:nil,reason:"Test"); preconditionFailure("Missing biometrics signed") }
        catch { check(error is OathBiometricCredentialError,"Missing biometrics returns passcode fallback") }
        let signed = try await vault.signSolanaSend(sendID:sendID,quote:quote,digits:pin,reason:"Test")
        try SolanaSendCrypto.verify(signed,plan:plan); check(!signed.bytes.isEmpty,"Authenticated signature covers exact reviewed bytes")
        let wrong = OathSolanaQuote(walletID:"other-wallet",accountID:account.id,assetID:quote.assetID,plan:plan)
        do { _ = try await vault.signSolanaSend(sendID:sendID,quote:wrong,digits:pin,reason:"Test"); preconditionFailure("Wrong wallet signed") }
        catch { check(error as? SolanaSendError == .changed,"Cross-wallet request rejected") }
        if permissionMode {
            let scope=try PermissionBatchScope.solana(sendID:sendID,walletID:quote.walletID,accountID:quote.accountID,plan:plan)
            let grant=try await vault.authorizePermissionBatch([scope],digits:pin,reason:"Test")
            let batchSigned=try await vault.signSolanaSend(sendID:sendID,quote:quote,digits:nil,reason:"",permissionAuthorization:grant)
            try SolanaSendCrypto.verify(batchSigned,plan:plan)
            check(!batchSigned.bytes.isEmpty,"Scoped batch signs exact removal without retaining PIN")
            do { _=try await vault.signSolanaSend(sendID:sendID,quote:quote,digits:nil,reason:"",permissionAuthorization:grant);preconditionFailure("Replayed grant") }
            catch { check(error as? PermissionError == .changed,"Batch item capability cannot be reused") }
            await vault.endPermissionBatch(grant)
        }
        let wcBytes = Data([1]) + Data(repeating: 0, count: 64) + (try SolanaSendCrypto.message(plan))
        let wcParams = try JSONEncoder().encode(SolanaJSON.object(["transaction": .string(wcBytes.base64EncodedString())]))
        for network in [SolanaSendNetwork.mainnet, .devnet, .testnet] {
            let request = try WalletConnectSolanaRequest(method: "solana_signTransaction", chain: network.walletConnectChain, account: account.address, params: wcParams)
            do { _ = try await vault.signWalletConnectSolana(walletID: profile.id.uuidString, accountID: account.id, request: request, digits: [9,9,9,9,9,9], reason: "Test"); preconditionFailure("WC wrong PIN signed") }
            catch { check(error as? OathWalletError == .wrongPasscode, "WC PIN rejection") }
            let response = try await vault.signWalletConnectSolana(walletID: profile.id.uuidString, accountID: account.id, request: request, digits: pin, reason: "Test")
            try request.transactions[0].verifySigned(response.transactions[0], requireAll: true)
            check(!response.transactions.isEmpty, "WalletConnect supports exact approved cluster")
        }
        await biometrics.enroll(try await vault.biometricCredential())
        let authenticated = try await vault.signSolanaSend(sendID:sendID,quote:quote,digits:nil,reason:"Test")
        try SolanaSendCrypto.verify(authenticated,plan:plan); check(try SolanaSendCrypto.message(plan) == Data(authenticated.bytes.dropFirst(65)),"Biometrics authorize identical intent")
        await biometrics.pauseNextRead()
        let pending = Task { try await vault.signSolanaSend(sendID:sendID,quote:quote,digits:nil,reason:"Test") }
        for _ in 0..<200 {
            if await biometrics.isWaiting { break }
            try await Task.sleep(for:.milliseconds(5))
        }
        check(await biometrics.isWaiting,"Biometric read entered")
        await vault.lock(); await biometrics.releaseRead()
        do { _ = try await pending.value; preconditionFailure("Locked vault accepted stale authorization") }
        catch { check(error is CancellationError || error as? OathWalletError == .locked,"Lock invalidates in-flight authorization") }
        do { _ = try await vault.signSolanaSend(sendID:sendID,quote:quote,digits:pin,reason:"Test"); preconditionFailure("Locked vault signed") }
        catch { check(error as? OathWalletError == .locked,"Locked signing rejected") }
        if permissionMode {try await db.journalSolanaSignature(sendID:sendID,signed:signed);let removal=try await db.permissionRemoval(sendID:sendID);check(removal?.status=="pending","Authenticated removal is durable before broadcast")}
        print("Passed \(checks) Solana send authorization host checks. Production vault, PIN and imported-key signer; synthetic biometric store, no HD derivation, network, simulator or device.")
    }
}

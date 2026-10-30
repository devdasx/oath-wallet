import Foundation
import OathDatabase
import OathAnkr

/// Real production vault/passcode/journal and imported-key signer. Only the
/// OS biometric store and HD derivation are host fixtures; no app or network.
@main struct CheckEVMSendAuthorization {
    @MainActor static func main() async throws {
        var checks = 0
        let network = EVMSendNetwork(rawValue: ProcessInfo.processInfo.environment["OATH_EVM_AUTH_NETWORK"] ?? "arbitrum") ?? .arbitrum
        func check(_ value:Bool,_ reason:String) { precondition(value,reason); checks += 1 }
        let evmChains=OathImportChain.allCases.filter { $0.isEVM && $0 != .arc }
        check(Set(evmChains.map(\.rawValue))==Set(EVMSendNetwork.allCases.filter{!$0.isTestnet && $0 != .arc}.map(\.rawValue)),"Every EVM catalog chain has a send adapter")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EVMVault-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let biometrics = MemoryBiometrics()
        let storage = SendReadRecordingStorage()
        let vault = OathWalletVault(storage:storage,biometricStore:biometrics,database:db)
        let pin:[UInt8] = [1,2,3,4,5,6]
        try await vault.create(digits:pin,importing:nil,privateKey:.init(bytes:Data(repeating:7,count:32),networks:[OathImportChain(rawValue:network.rawValue)!]))
        let profile = try await vault.unlockedProfile()
        let account = try await db.accounts(walletID:profile.id.uuidString).first!
        var plan = EVMSendPlan(network:network,sender:account.address.lowercased(),recipient:try EVMSendCrypto.address(privateKey:Data(repeating:8,count:32)),reference:"native",decimals:18,
            requestedAmount:"1000",amount:"1000",assetBalance:"1000000000000000000",nativeBalance:"1000000000000000000",nonce:0,gasLimit:21000,maxFeePerGas:41000000000,maxPriorityFeePerGas:1000000000,blockHeight:100)
        let permissionMode=ProcessInfo.processInfo.environment["OATH_PERMISSION_AUTH"]=="1"
        if permissionMode {
            var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan)) as! [String:Any]
            object["amount"]="0";object["requestedAmount"]="0";object["gasLimit"]=70000
            object["removal"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(EVMPermissionRemoval(kind:.token,contract:plan.recipient,spender:"0x"+String(repeating:"3",count:40),expected:"123")))
            plan=try JSONDecoder().decode(EVMSendPlan.self,from:JSONSerialization.data(withJSONObject:object))
        }
        let quote = OathEVMQuote(walletID:profile.id.uuidString,accountID:account.id,assetID:network.rawValue+":native",plan:plan)
        let now = Date.now.timeIntervalSince1970
        try await db.saveDraft(.init(id:"send",walletID:quote.walletID,accountID:account.id,networkID:network.rawValue,assetID:quote.assetID,idempotencyKey:"send",recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:now,updatedAt:now))
        try await db.queueEVMSend(sendID:"send",plan:plan)
        do { _ = try await vault.signEVMSend(sendID:"send",quote:quote,digits:[9,9,9,9,9,9],reason:"Test"); preconditionFailure("Wrong PIN signed") }
        catch { check(error as? OathWalletError == .wrongPasscode,"Wrong PIN rejected") }
        let unsigned = try await db.send("send"); check(unsigned?.signedPayload == nil,"Failed authentication persists no signature")
        do { _ = try await vault.signEVMSend(sendID:"send",quote:quote,digits:nil,reason:"Test"); preconditionFailure("Missing biometrics signed") }
        catch { check(error is OathBiometricCredentialError,"Missing biometrics returns passcode fallback") }
        let signed = try await vault.signEVMSend(sendID:"send",quote:quote,digits:pin,reason:"Test")
        try EVMSendCrypto.verify(signed,plan:plan); check(!signed.bytes.isEmpty,"Authenticated signature covers exact reviewed bytes")
        let wrong = OathEVMQuote(walletID:"other-wallet",accountID:account.id,assetID:quote.assetID,plan:plan)
        do { _ = try await vault.signEVMSend(sendID:"send",quote:wrong,digits:pin,reason:"Test"); preconditionFailure("Wrong wallet signed") }
        catch { check(error as? EVMSendError == .changed,"Cross-wallet request rejected") }
        await biometrics.enroll(try await vault.biometricCredential())
        let authenticated = try await vault.signEVMSend(sendID:"send",quote:quote,digits:nil,reason:"Test")
        try EVMSendCrypto.verify(authenticated,plan:plan); check(authenticated.bytes == signed.bytes,"Biometrics authorize identical intent")
        checks += try await checkSendPreparation(biometrics: biometrics, storage: storage) { prepare in
            _ = try await vault.signEVMSend(sendID:"send", quote:quote, digits:nil, reason:"Test", prepare:prepare)
        }
        await biometrics.pauseNextRead()
        let pending = Task { try await vault.signEVMSend(sendID:"send",quote:quote,digits:nil,reason:"Test") }
        for _ in 0..<200 {
            if await biometrics.isWaiting { break }
            try await Task.sleep(for:.milliseconds(5))
        }
        check(await biometrics.isWaiting,"Biometric read entered")
        await vault.lock(); await biometrics.releaseRead()
        do { _ = try await pending.value; preconditionFailure("Locked vault accepted stale authorization") }
        catch { check(error is CancellationError || error as? OathWalletError == .locked,"Lock invalidates in-flight authorization") }
        do { _ = try await vault.signEVMSend(sendID:"send",quote:quote,digits:pin,reason:"Test"); preconditionFailure("Locked vault signed") }
        catch { check(error as? OathWalletError == .locked,"Locked signing rejected") }
        if permissionMode {try await db.journalEVMSignature(sendID:"send",signed:signed);let removal=try await db.permissionRemoval(sendID:"send");check(removal?.status=="pending","Authenticated removal is durable before broadcast")}
        print("Passed \(checks) \(network.rawValue) send authorization host checks. Production vault, PIN and imported-key signer; synthetic biometric store, no HD derivation, network, simulator or device.")
    }
}

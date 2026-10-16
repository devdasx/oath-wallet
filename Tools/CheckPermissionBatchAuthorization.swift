import Foundation
import OathDatabase
import OathAnkr

/// Production vault, passcode and imported-key EVM signer. Local synthetic
/// credentials and database only; never reads the user's vault or broadcasts.
@main struct CheckPermissionBatchAuthorization {
    @MainActor static func main() async throws {
        var checks=0
        func check(_ value:Bool,_ reason:String) { precondition(value,reason);checks += 1 }
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("PermissionBatchAuth-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let db=try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let biometrics=MemoryBiometrics()
        let vault=OathWalletVault(storage:WalletMemory(),biometricStore:biometrics,database:db)
        let pin:[UInt8]=[1,2,3,4,5,6]
        try await vault.create(digits:pin,importing:nil,privateKey:.init(bytes:Data(repeating:7,count:32),networks:[.arbitrum]))
        let profile=try await vault.unlockedProfile()
        let account=try await db.accounts(walletID:profile.id.uuidString).first!
        let recipient=try EVMSendCrypto.address(privateKey:Data(repeating:8,count:32))
        func quote(nonce:UInt64,removal:Bool=true)->OathEVMQuote {
            let plan=EVMSendPlan(network:.arbitrum,sender:account.address.lowercased(),recipient:recipient,
                reference:"native",decimals:18,requestedAmount:removal ? "0":"1000",amount:removal ? "0":"1000",
                assetBalance:"1000000000000000000",nativeBalance:"1000000000000000000",nonce:nonce,gasLimit:70000,
                maxFeePerGas:41000000000,maxPriorityFeePerGas:1000000000,blockHeight:100+nonce,
                removal:removal ? .init(kind:.token,contract:recipient,spender:"0x"+String(repeating:"3",count:40),expected:"123"):nil)
            return .init(walletID:profile.id.uuidString,accountID:account.id,assetID:"arbitrum:native",plan:plan)
        }
        func queue(_ id:String,_ q:OathEVMQuote) async throws {
            let now=Date.now.timeIntervalSince1970
            try await db.saveDraft(.init(id:id,walletID:q.walletID,accountID:account.id,networkID:"arbitrum",assetID:q.assetID,
                idempotencyKey:id,recipient:q.plan.recipient,amountAtomic:String(q.plan.amount),state:"draft",createdAt:now,updatedAt:now))
            try await db.queueEVMSend(sendID:id,plan:q.plan)
        }
        let id=UUID().uuidString,q=quote(nonce:0)
        let scope=try PermissionBatchScope.evm(sendID:id,walletID:q.walletID,accountID:q.accountID,plan:q.plan)
        do { _=try await vault.authorizePermissionBatch([scope],digits:[9,9,9,9,9,9],reason:"Test");preconditionFailure("Wrong PIN granted batch") }
        catch { check(error as? OathWalletError == .wrongPasscode,"Wrong PIN rejected") }
        do { _=try await vault.authorizePermissionBatch([scope],digits:nil,reason:"Test");preconditionFailure("Missing biometrics granted batch") }
        catch { check(error is OathBiometricCredentialError,"Passcode fallback preserved") }
        let nextID=UUID().uuidString,next=quote(nonce:1)
        let nextScope=try PermissionBatchScope.evm(sendID:nextID,walletID:next.walletID,accountID:next.accountID,plan:next.plan)
        let grant=try await vault.authorizePermissionBatch([scope,nextScope],digits:pin,reason:"Test")
        try await queue(id,q)
        let signed=try await vault.signEVMSend(sendID:id,quote:q,digits:nil,reason:"",permissionAuthorization:grant)
        try EVMSendCrypto.verify(signed,plan:q.plan);check(!signed.bytes.isEmpty,"Fresh batch authentication signs exact first removal")
        do { _=try await vault.signEVMSend(sendID:id,quote:q,digits:nil,reason:"",permissionAuthorization:grant);preconditionFailure("Replayed capability") }
        catch { check(error as? PermissionError == .changed,"Each item is single use") }
        try await db.journalEVMSignature(sendID:id,signed:signed)
        try await db.settleEVMSend(sendID:id,receipt:.init(hash:signed.hash,outcome:.confirmed,fee:50000,height:100,timestamp:Date.now.timeIntervalSince1970))
        try await queue(nextID,next)
        let nextSigned=try await vault.signEVMSend(sendID:nextID,quote:next,digits:nil,reason:"",permissionAuthorization:grant)
        try EVMSendCrypto.verify(nextSigned,plan:next.plan);check(!nextSigned.bytes.isEmpty,"Second reviewed removal needs no retained PIN")
        _=try await db.transitionSend(nextID,from:"queued",to:"cancelled")
        await vault.endPermissionBatch(grant)
        let transferID=UUID().uuidString,transfer=quote(nonce:1,removal:false)
        try await queue(transferID,transfer)
        let fakeScope=try PermissionBatchScope(sendID:transferID,walletID:transfer.walletID,accountID:transfer.accountID,
            network:"arbitrum",owner:transfer.plan.sender,removal:scope.removal,maximumFee:transfer.plan.fee)
        let transferGrant=try await vault.authorizePermissionBatch([fakeScope],digits:pin,reason:"Test")
        do { _=try await vault.signEVMSend(sendID:transferID,quote:transfer,digits:nil,reason:"",permissionAuthorization:transferGrant);preconditionFailure("Removal grant signed transfer") }
        catch { check(error as? PermissionError == .changed,"No transfer or arbitrary calldata capability") }
        await vault.endPermissionBatch(transferGrant)
        _=try await db.transitionSend(transferID,from:"queued",to:"cancelled")
        let lowID=UUID().uuidString,lowQuote=quote(nonce:1)
        try await queue(lowID,lowQuote)
        let low=try PermissionBatchScope(sendID:lowID,walletID:lowQuote.walletID,accountID:lowQuote.accountID,
            network:"arbitrum",owner:lowQuote.plan.sender,removal:scope.removal,maximumFee:lowQuote.plan.fee-1)
        let lowGrant=try await vault.authorizePermissionBatch([low],digits:pin,reason:"Test")
        do { _=try await vault.signEVMSend(sendID:lowID,quote:lowQuote,digits:nil,reason:"",permissionAuthorization:lowGrant);preconditionFailure("Exceeded reviewed fee") }
        catch { check(error as? PermissionError == .changed,"Fee limit enforced at vault") }
        await vault.lock()
        check(!(await vault.permissionBatchIsAuthorized(lowGrant)),"Lock revokes batch")
        _=try await vault.unlock(digits:pin)
        check(!(await vault.permissionBatchIsAuthorized(lowGrant)),"Unlock never revives old consent")
        do { _=try await vault.signEVMSend(sendID:lowID,quote:lowQuote,digits:nil,reason:"",permissionAuthorization:lowGrant);preconditionFailure("Old consent revived") }
        catch { check(error as? PermissionError == .changed,"Stale capability rejected after unlock") }
        let security=try await vault.authorizeSecurityChange(digits:pin)
        try await vault.setPasscode(nil,authorization:security)
        let openScope=try PermissionBatchScope.evm(sendID:lowID,walletID:lowQuote.walletID,accountID:lowQuote.accountID,plan:lowQuote.plan)
        let openGrant=try await vault.authorizePermissionBatch([openScope],digits:nil,reason:"Test")
        let openSigned=try await vault.signEVMSend(sendID:lowID,quote:lowQuote,digits:nil,reason:"",permissionAuthorization:openGrant)
        try EVMSendCrypto.verify(openSigned,plan:lowQuote.plan)
        check(!openSigned.bytes.isEmpty,"Disabled security needs no PIN or Face ID")
        await vault.endPermissionBatch(openGrant)
        print("Passed \(checks) batch authorization host checks; production vault/signatures, synthetic local credentials, no network or device.")
    }
}

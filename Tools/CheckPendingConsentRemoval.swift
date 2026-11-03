import Foundation
import OathDatabase
import OathAnkr

@main struct CheckWalletConnectAuthorization {
    @MainActor static func main() async throws {
        var passed = 0, failed = 0
        func check(_ value: Bool, _ name: String) {
            FileHandle.standardOutput.write(Data("\(value ? "PASS" : "FAIL"): \(name)\n".utf8))
            if value { passed += 1 } else { failed += 1 }
        }
        let pin: [UInt8] = [1,2,3,4,5,6]
        for operation in ["soft removal","permanent removal","remove and restore","other wallet removal","failed save","lock"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathPendingConsent-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:folder) }
            let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
            try await OathDataEnvironment.seed(db)
            let storage = WalletMemory(), bio = MemoryBiometrics()
            let vault = OathWalletVault(storage:storage,biometricStore:bio,database:db)
            try await vault.create(digits:pin,importing:nil,privateKey:.init(bytes:Data(repeating:0,count:31)+Data([1]),networks:[.ethereum]))
            let target = try await vault.unlockedProfile().id.uuidString
            let second = try await vault.addWallet(requestID:UUID(),importing:nil,privateKey:.init(bytes:Data(repeating:0,count:31)+Data([2]),networks:[.ethereum])).id.uuidString
            let account = try await db.accounts(walletID:target).first!
            let scope = try PermissionBatchScope(sendID:UUID().uuidString,walletID:target,accountID:account.id,
                network:"ethereum",owner:account.address.lowercased(),removal:.evm(.init(kind:.token,
                contract:"0x"+String(repeating:"3",count:40),spender:"0x"+String(repeating:"4",count:40),expected:"123")),maximumFee:100_000)
            await bio.enroll(try await vault.biometricCredential())
            await bio.pauseNextRead()
            let pending = Task { try await vault.authorizePermissionBatch([scope],digits:nil,reason:"Fixture") }
            for _ in 0..<1000 { if await bio.isWaiting { break }; try await Task.sleep(for:.milliseconds(5)) }
            guard await bio.isWaiting else { await bio.releaseRead(); throw OathWalletError.unavailable }
            check(true,operation+" biometric read held")
            if operation == "lock" { await vault.lock() }
            else {
                let action = OathWalletRemovalAction(ids:[operation == "other wallet removal" ? second:target],permanently:false)
                let grant = try await vault.authorizeWalletRemoval(action,digits:pin,reason:"Fixture")
                if operation == "failed save" {
                    storage.rejectNextUpdate()
                    do { _ = try await vault.removeWallets(action,authorization:grant); check(false,operation+" expected save failure") }
                    catch { check(error as? OathWalletError == .unavailable,operation+" expected save failure") }
                } else {
                    _ = try await vault.removeWallets(action,authorization:grant)
                    if operation == "permanent removal" {
                        let purge = OathWalletRemovalAction(ids:[target],permanently:true)
                        let approval = try await vault.authorizeWalletRemoval(purge,digits:pin,reason:"Fixture")
                        _ = try await vault.removeWallets(purge,authorization:approval)
                    } else if operation == "remove and restore" { _ = try await vault.recoverDeletedWallets([target]) }
                }
            }
            await bio.releaseRead()
            let shouldAuthorize = ["other wallet removal","failed save"].contains(operation)
            do {
                let grant = try await pending.value
                let authorized = await vault.permissionBatchIsAuthorized(grant)
                check(shouldAuthorize && authorized,operation+" delayed consent")
            } catch { check(!shouldAuthorize && (error is CancellationError || error as? OathWalletError == .locked),operation+" delayed consent") }
            if operation == "remove and restore" {
                let fresh = try await vault.authorizePermissionBatch([scope],digits:pin,reason:"Fixture")
                check(await vault.permissionBatchIsAuthorized(fresh),operation+" fresh consent")
            }
        }
        FileHandle.standardOutput.write(Data("Pending consent checks: \(passed) passed, \(failed) failed\n".utf8))
        if failed > 0 { exit(1) }
    }
}

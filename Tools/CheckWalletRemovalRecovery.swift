import Foundation
import OathDatabase
import SQLite3

@main struct CheckWalletRemovalRecovery {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value:Bool,_ label:String) { precondition(value,label); checks += 1; print("PASS: "+label) }
        let pin:[UInt8] = [1,2,3,4,5,6]
        for mode in ["passcode","biometric","device key"] {
            for committed in [false,true] {
                let prefix = mode + (committed ? " / after encrypted commit" : " / before encrypted commit")
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathRemovalRecovery-"+UUID().uuidString)
                defer { try? FileManager.default.removeItem(at:folder) }
                let url = folder.appendingPathComponent("wallet.sqlite")
                let db = try await OathDatabase.open(at:url)
                try await OathDataEnvironment.seed(db)
                let storage = WalletMemory(), bio = MemoryBiometrics()
                let vault = OathWalletVault(storage:storage,biometricStore:bio,database:db)
                try await vault.create(digits:pin,importing:nil,privateKey:.init(bytes:Data(repeating:7,count:32),networks:[.xrpl]))
                let target = try await vault.unlockedProfile().id.uuidString
                _ = try await vault.addWallet(requestID:UUID(),importing:nil,privateKey:.init(bytes:Data(repeating:8,count:32),networks:[.xrpl]))
                if mode == "biometric" { await bio.enroll(try await vault.biometricCredential()) }
                if mode == "device key" {
                    let grant = try await vault.authorizeSecurityChange(digits:pin)
                    try await vault.setPasscode(nil,authorization:grant)
                }
                func sql(_ text:String) throws {
                    var connection:OpaquePointer?
                    guard sqlite3_open(url.path,&connection) == SQLITE_OK else { throw OathWalletError.unavailable }
                    defer { sqlite3_close(connection) }
                    guard sqlite3_exec(connection,text,nil,nil,nil) == SQLITE_OK else { throw OathWalletError.unavailable }
                }
                if committed {
                    try sql("CREATE TRIGGER fixture_reject_removal BEFORE UPDATE OF deletedAt ON wallets WHEN NEW.deletedAt IS NOT NULL BEGIN SELECT RAISE(ABORT,'fixture'); END;")
                    let action = OathWalletRemovalAction(ids:[target],permanently:false)
                    let grant = try await vault.authorizeWalletRemoval(action,digits:mode == "device key" ? nil:pin,reason:"Synthetic interruption")
                    do { _ = try await vault.removeWallets(action,authorization:grant); preconditionFailure("Expected metadata write failure") }
                    catch { check(true,prefix+" / metadata failure observed") }
                    try sql("DROP TRIGGER fixture_reject_removal")
                } else {
                    _ = try await db.reserveWalletRemoval([target])
                    check(true,prefix+" / durable reservation before key write")
                }
                check(try await db.pendingWalletRemovalReservations().count == 1,prefix+" / fence persists before restart")
                let coldDB = try await OathDatabase.open(at:url)
                let cold = OathWalletVault(storage:storage,biometricStore:bio,database:coldDB)
                if mode == "passcode" { _ = try await cold.unlock(digits:pin) }
                else if mode == "biometric" { _ = try await cold.unlockWithBiometrics(reason:"Synthetic restart") }
                else { _ = try await cold.unlockWithoutPasscode() }
                check(try await coldDB.pendingWalletRemovalReservations().isEmpty,prefix+" / authenticated replay releases fence")
                check(try await (coldDB.wallet(target)?.deletedAt != nil) == committed,prefix+" / replay follows encrypted membership")
                check(try await cold.wallets(includingDeleted:true).count == 2,prefix+" / both retained wallets survive")
            }
        }
        print("Passed \(checks) wallet removal recovery checks. Synthetic memory credentials and real encrypted vault/database; no device or network.")
    }
}

import Foundation
@testable import OathDatabase
import GRDB
import OathAnkr

// Public synthetic keys only; actual vault, encrypted envelope, GRDB, EVM
// imported-key signing and typed-data implementations. No OS credential store.
@main struct CheckWalletConnectAuthorization {
    @MainActor static func main() async throws {
        var passed = 0, failed = 0
        func check(_ value: Bool, _ name: String) {
            emit("\(value ? "PASS" : "FAIL"): \(name)")
            if value { passed += 1 } else { failed += 1 }
        }
        let pin: [UInt8] = [1,2,3,4,5,6]
        for typed in [false,true] {
            for operation in ["soft removal","permanent removal","remove and restore","other wallet removal","failed save","lock"] {
                let prefix = "\(typed ? "typed" : "message") / \(operation)"
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathRemovalRead-"+UUID().uuidString)
                defer { try? FileManager.default.removeItem(at:folder) }
                let db = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
                try await OathDataEnvironment.seed(db)
                let storage = WalletMemory(), bio = MemoryBiometrics()
                let vault = OathWalletVault(storage:storage,biometricStore:bio,database:db)
                let key = Data(repeating:0,count:31)+Data([1])
                try await vault.create(digits:pin,importing:nil,privateKey:.init(bytes:key,networks:[.ethereum]))
                let target = try await vault.unlockedProfile().id.uuidString
                let second = try await vault.addWallet(requestID:UUID(),importing:nil,privateKey:.init(bytes:Data(repeating:0,count:31)+Data([2]),networks:[.ethereum])).id.uuidString
                let account = try await db.accounts(walletID:target).first!
                let message = Data("Oath delayed account read fixture".utf8)
                let payload = try WalletConnectTypedData(json:Data("""
                {"types":{"EIP712Domain":[{"name":"chainId","type":"uint256"}],"Note":[{"name":"contents","type":"string"}]},"primaryType":"Note","domain":{"chainId":1},"message":{"contents":"Oath delayed account read fixture"}}
                """.utf8),chainID:1,account:account.address)
                func sign(_ digits: [UInt8]?) async throws -> String {
                    if typed { return try await vault.signWalletConnectTypedData(walletID:target,accountID:account.id,data:payload,digits:digits,reason:"Fixture") }
                    return try await vault.signWalletConnectMessage(walletID:target,accountID:account.id,message:message,digits:digits,reason:"Fixture")
                }
                let expected = try typed ? payload.sign(privateKey:key,account:account.address) : OathWalletConnectMessage.sign(message,key:key,account:account.address)
                check(try await sign(pin)==expected,prefix+" initial signature")
                let scope = try PermissionBatchScope(sendID:UUID().uuidString,walletID:target,accountID:account.id,
                    network:"ethereum",owner:account.address.lowercased(),removal:.evm(.init(kind:.token,
                    contract:"0x"+String(repeating:"3",count:40),spender:"0x"+String(repeating:"4",count:40),expected:"123")),maximumFee:100_000)
                let batch = try await vault.authorizePermissionBatch([scope],digits:pin,reason:"Fixture")
                check(await vault.permissionBatchIsAuthorized(batch),prefix+" initial batch consent")
                let gate = AccountReadGate()
                try await withThrowingTaskGroup(of:Void.self) { group in
                    for _ in 0..<4 {
                        group.addTask {
                            try await db.pool.read { connection in
                                connection.trace { event in
                                    if case let .statement(statement) = event { gate.trace(statement.sql) }
                                }
                                try gate.installReader()
                            }
                        }
                    }
                    try await group.waitForAll()
                }
                gate.arm()
                defer { gate.release() }
                let pending = Task { try await sign(pin) }
                for _ in 0..<5000 { if gate.isWaiting { break }; try await Task.sleep(for:.milliseconds(1)) }
                guard gate.isWaiting else { gate.release(); throw OathWalletError.unavailable }
                check(true,prefix+" account read held")
                if operation == "lock" { await vault.lock() }
                else {
                    let action = OathWalletRemovalAction(ids:[operation == "other wallet removal" ? second:target],permanently:false)
                    let grant = try await vault.authorizeWalletRemoval(action,digits:pin,reason:"Fixture")
                    if operation == "failed save" {
                        storage.rejectNextUpdate()
                        do { _ = try await vault.removeWallets(action,authorization:grant);check(false,prefix+" expected save failure") }
                        catch { check(error as? OathWalletError == .unavailable,prefix+" expected save failure") }
                    } else {
                        _ = try await vault.removeWallets(action,authorization:grant)
                        if operation == "permanent removal" {
                            let purge = OathWalletRemovalAction(ids:[target],permanently:true)
                            let approval = try await vault.authorizeWalletRemoval(purge,digits:pin,reason:"Fixture")
                            _ = try await vault.removeWallets(purge,authorization:approval)
                        } else if operation == "remove and restore" { _ = try await vault.recoverDeletedWallets([target]) }
                    }
                }
                let shouldSign = ["other wallet removal","failed save"].contains(operation)
                guard !gate.didTimeout else { throw OathWalletError.unavailable }
                check(await vault.permissionBatchIsAuthorized(batch) == shouldSign,prefix+" batch consent lifetime")
                gate.release()
                do { let signature = try await pending.value;check(shouldSign && signature==expected,prefix+" delayed result") }
                catch { check(!shouldSign && (error is CancellationError || error as? OathWalletError == .locked),prefix+" delayed result") }
                if operation == "remove and restore" {
                    check(try await sign(pin)==expected,prefix+" fresh restored signature")
                    let freshBatch = try await vault.authorizePermissionBatch([scope],digits:pin,reason:"Fixture")
                    check(await vault.permissionBatchIsAuthorized(freshBatch),prefix+" fresh restored batch consent")
                }
            }
        }
        emit("Removal account-read checks: \(passed) passed, \(failed) failed")
        if failed>0 { exit(1) }
    }
}

// Hold one actual GRDB account SELECT after vault authentication. Reader
// callbacks are installed on all four connections; other reads/writes remain
// available so lifecycle work can finish before the held SELECT resumes.
func emit(_ text:String) { FileHandle.standardOutput.write(Data((text+"\n").utf8)) }

final class AccountReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var readers = 0
    private var armed = false
    private var waiting = false
    private var released = false
    private var timedOut = false
    func installReader() throws {
        condition.lock(); defer { condition.unlock() }
        readers += 1; condition.broadcast()
        let deadline = Date().addingTimeInterval(10)
        while readers < 4 {
            guard condition.wait(until:deadline) else { throw OathWalletError.unavailable }
        }
    }
    func arm() { condition.lock(); armed = true; condition.unlock() }
    var isWaiting: Bool { condition.lock(); defer { condition.unlock() }; return waiting }
    var didTimeout: Bool { condition.lock(); defer { condition.unlock() }; return timedOut }
    func trace(_ sql:String) {
        condition.lock(); defer { condition.unlock() }
        guard armed, sql.hasPrefix("SELECT * FROM \"walletAccounts\" WHERE "), sql.contains("\"id\"") else { return }
        armed = false; waiting = true; condition.broadcast()
        let deadline = Date().addingTimeInterval(30)
        while !released {
            guard condition.wait(until:deadline) else { timedOut = true; return }
        }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

import Foundation
import OathDatabase
import OathAnkr

// Controlled storage boundary, not a change to the vault or database code.
// All keys and transactions are public synthetic fixtures. No broadcast.
final class RemovalWriteGate: OathVaultStorage, @unchecked Sendable {
    private let memory = WalletMemory()
    private let condition = NSCondition()
    private var armed = false, entered = false
    func arm() { condition.lock(); armed = true; entered = false; condition.unlock() }
    var waiting: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func release() { condition.lock(); armed = false; condition.broadcast(); condition.unlock() }
    func rejectNextUpdate() { memory.rejectNextUpdate() }
    func read(_ account: String) throws -> Data? { try memory.read(account) }
    func insert(_ data: Data, account: String) throws { try memory.insert(data, account: account) }
    func erase() throws { try memory.erase() }
    func update(_ data: Data, account: String) throws {
        condition.lock()
        if account == "vault-v1", armed {
            entered = true
            let deadline = Date().addingTimeInterval(30)
            while armed {
                guard condition.wait(until: deadline) else {
                    condition.unlock(); throw OathWalletError.unavailable
                }
            }
        }
        condition.unlock()
        try memory.update(data, account: account)
    }
}

@main struct CheckWalletConnectRemovalRace {
    @MainActor static func main() async throws {
        var passed = 0, failed = 0
        func check(_ value: Bool, _ label: String) {
            print("\(value ? "PASS" : "FAIL"): \(label)")
            if value { passed += 1 } else { failed += 1 }
        }
        let pin: [UInt8] = [1,2,3,4,5,6]
        for ordering in ["journal first", "journal during vault write", "removal first", "vault write fails"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathRemovalRace-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
            try await OathDataEnvironment.seed(db)
            let storage = RemovalWriteGate()
            let vault = OathWalletVault(storage: storage, database: db)
            try await vault.create(digits: pin, importing: nil, privateKey: .init(bytes: Data(repeating:7,count:32), networks:[.xrpl]))
            let target = try await vault.unlockedProfile().id.uuidString
            _ = try await vault.addWallet(requestID:UUID(), importing:nil, privateKey:.init(bytes:Data(repeating:8,count:32),networks:[.xrpl]))
            let account = try await db.accounts(walletID: target).first!
            let tx: XrplJSON = .object(["TransactionType":.string("Payment"),"Account":.string(account.address),"Destination":.string(account.address),"Amount":.string("100"),"Fee":.string("12"),"Sequence":.number("42"),"LastLedgerSequence":.number("120")])
            let request = try WalletConnectXrplRequest(method:"xrpl_signTransaction",chain:"xrpl:0",account:account.address,params:JSONEncoder().encode(XrplJSON.object(["tx_json":tx])))
            struct ReviewFixture: Encodable {
                let request: WalletConnectXrplRequest, transaction: XrplJSON
                let firstLedger: UInt32, createdAt: Date
            }
            let plan = try JSONDecoder().decode(WalletConnectXrplReview.self, from:JSONEncoder().encode(ReviewFixture(request:request,transaction:tx,firstLedger:100,createdAt:.now)))
            let signed = try await vault.signWalletConnectXrpl(walletID:target, accountID:account.id, request:request, review:plan, digits:pin, reason:"Synthetic removal race")
            try request.verify(signed, review:plan)
            check(true,ordering+" / production vault signature verifies")
            let action = OathWalletRemovalAction(ids:[target],permanently:false)
            let grant = try await vault.authorizeWalletRemoval(action,digits:pin,reason:"Synthetic removal race")
            func journal() async throws {
                _ = try await db.journalWalletConnectXrpl(id:"pending",walletID:target,accountID:account.id,plan:plan,signed:signed)
            }
            var removed = false, journaled = false
            if ordering == "journal first" {
                try await journal(); journaled = true
                do { _ = try await vault.removeWallets(action,authorization:grant); removed = true }
                catch { check(error as? StoreError == .invalidTransition,ordering+" / pending work rejects removal") }
            } else if ordering == "removal first" {
                _ = try await vault.removeWallets(action,authorization:grant); removed = true
                do { try await journal(); journaled = true }
                catch { check(error as? XrplSendError == .wrongOwner,ordering+" / removed wallet rejects journal") }
            } else {
                storage.arm()
                if ordering == "vault write fails" { storage.rejectNextUpdate() }
                let removal = Task.detached { try await vault.removeWallets(action,authorization:grant) }
                for _ in 0..<5000 { if storage.waiting { break }; try await Task.sleep(for:.milliseconds(1)) }
                guard storage.waiting else { storage.release(); _ = try? await removal.value; throw OathWalletError.unavailable }
                check(true,ordering+" / held after pending preflight before encrypted commit")
                do { try await journal(); journaled = true } catch { print("Journal rejected at held boundary") }
                storage.release()
                do { _ = try await removal.value; removed = true }
                catch { check(ordering == "vault write fails" && error as? OathWalletError == .unavailable,ordering+" / removal failure expected") }
            }
            check(!(removed && journaled),ordering+" / removal and new pending work are exclusive")
            if ordering == "vault write fails" {
                try await journal()
                check(true,ordering+" / retry can persist after rejected encrypted write")
            }
            let row = try await db.walletConnectXrplSubmission("pending")
            let pending = try await db.pendingWalletConnectXrplSubmissions()
            check(row == nil || pending.count == 1,ordering+" / every saved pending row remains recoverable")
            let cold = try await OathDatabase.open(at:folder.appendingPathComponent("wallet.sqlite"))
            let recovered = try await cold.pendingWalletConnectXrplSubmissions()
            check(row == nil || recovered.count == 1,ordering+" / restart preserves recoverability")
            if ordering == "journal during vault write", removed {
                let removedAt = try await db.wallet(target)!.deletedAt!
                _ = try await vault.maintainDeletedWallets(now:Date(timeIntervalSince1970:removedAt+OathVaultContents.retention+1))
                let retained = try await db.walletConnectXrplSubmission("pending")
                check(!journaled || retained != nil,ordering+" / pending row survives retention")
            }
        }
        print("Removal journal race checks: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
